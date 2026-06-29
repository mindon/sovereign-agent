//! Sovereign-Agent × Ollama(gemma4) 端到端演示。
//!
//! 闭环：
//!   1. 向 gemma4 提供「目标 + 分层信任记忆种子 + <confidence_stats>」；
//!   2. 模型产出一个结构化决策 (JSON)；
//!   3. 决策被强制送入 `transact`：仲裁预校验 -> 落账 -> 执行 -> 提交/回滚；
//!   4. 根据成败反馈演进记忆置信度，并用 rebuildState() 审计账本一致性。
//!
//! 关键点：LLM 只是“建议者”。即便它幻觉式地引用不存在的事实，仲裁层的
//! 物理只读探针仍会拦截——这正是“分层信任 + 零信任校验”的价值所在。

const std = @import("std");
const lib = @import("sovereign");

const Action = lib.Action;
const Dir = std.Io.Dir;
const LlmClient = lib.LlmClient;

const SYSTEM_PROMPT =
    \\You are the DECISION CORE of "Sovereign-Agent", a zero-trust autonomous agent.
    \\You DO NOT execute anything yourself. You only PROPOSE exactly ONE action.
    \\Every proposal is physically verified by an Arbiter (read-only probe) before
    \\execution; hallucinated or malformed proposals will be rejected.
    \\
    \\Memory seeds are HEURISTICS, not facts. Seeds tagged "danger" (low confidence)
    \\may be wrong; do not blindly trust them.
    \\
    \\Reply with STRICTLY a single JSON object (no markdown, no prose) shaped as:
    \\{"action":"write|read|execute|think","context":"<short target/topic>",
    \\ "payload":"<concrete content or command>","reason":"<one sentence>"}
    \\If you choose "write" with JSON content, the payload MUST itself be valid JSON.
;

/// 演示用文件执行器：在沙箱子目录内写文件，支持回滚（删除）。
const FileExecutor = struct {
    sandbox: []const u8,

    fn doFn(ctx: *anyopaque, io: std.Io, dir: Dir, action: Action) anyerror!bool {
        const self: *FileExecutor = @ptrCast(@alignCast(ctx));
        var path_buf: [512]u8 = undefined;
        // 仅取 context 的 basename 作为文件名，避免路径穿越（防目录逃逸）。
        const name = std.fs.path.basename(action.context);
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.sandbox, name });
        var file = try dir.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, action.payload);
        return true;
    }

    fn undoFn(ctx: *anyopaque, io: std.Io, dir: Dir, action: Action) anyerror!void {
        const self: *FileExecutor = @ptrCast(@alignCast(ctx));
        var path_buf: [512]u8 = undefined;
        const name = std.fs.path.basename(action.context);
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.sandbox, name }) catch return;
        dir.deleteFile(io, path) catch {};
    }
};

/// 从可能带有 markdown 包裹的文本中截取第一个 JSON 对象（容错）。
fn extractJsonObject(s: []const u8) []const u8 {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return s;
    const end = std.mem.lastIndexOfScalar(u8, s, '}') orelse return s;
    if (end < start) return s;
    return s[start .. end + 1];
}

pub fn main(init: std.process.Init) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    // 运行配置来自环境变量（LLM_PROVIDER / LLM_BASE_URL / LLM_MODEL / LLM_API_KEY）。
    // 默认连接本地 Ollama 的 gemma4:latest；设 LLM_PROVIDER=openai 可接入任意
    // OpenAI 兼容端点（密钥仅来自 LLM_API_KEY / OPENAI_API_KEY）。
    var cfg = try lib.EnvConfig.load(a, init.environ_map);
    defer cfg.deinit();
    const base_url = cfg.base_url;
    const model = cfg.model;

    const sandbox = ".sovereign_sandbox";
    const journal_path = ".sovereign_ollama_journal.jsonl";
    dir.deleteFile(io, journal_path) catch {};
    dir.createDirPath(io, sandbox) catch {};

    // —— 组装核心模块 ——
    var journal = lib.Journal.init(a, io, dir, journal_path);
    defer journal.deinit();
    try journal.ensureFile();

    var memory = lib.MemoryManager.init(a);
    defer memory.deinit();

    var arbiter = lib.Arbiter.init(io, dir);
    var executor = FileExecutor{ .sandbox = sandbox };

    var ctx: lib.AgentContext = .{
        .gpa = a,
        .io = io,
        .dir = dir,
        .journal = &journal,
        .memory = &memory,
        .arbiter = &arbiter,
        .executor = .{ .ctx = @ptrCast(&executor), .doFn = FileExecutor.doFn, .undoFn = FileExecutor.undoFn },
        .verbose = true,
    };

    // —— 注入分层信任的记忆种子 ——
    _ = try memory.addSeed("config.json", "this project stores configuration as JSON", 0.75);
    _ = try memory.addSeed("notes.txt", "free-form notes are safe to append", 0.55);
    // 一条危险的高置信度“幻觉”记忆：断言一个并不存在的文件存在。
    const halluc = try memory.addSeed("deploy.sh", "assert_exists=__ghost_binary__.bin", 0.9);

    // —— 连接推理后端（Ollama / OpenAI 兼容）——
    var client = cfg.client(a, io);
    defer client.deinit();

    std.debug.print("\n=== Sovereign-Agent × LLM 演示 ===\n", .{});
    std.debug.print("后端: {s}  模型: {s}  端点: {s}\n\n", .{ @tagName(cfg.provider), model, base_url });

    // 连通性预检：用一个最小 think 请求探活。
    {
        const ping = client.chat(a, "Reply with a single word: OK", "ping", false) catch |err| {
            std.debug.print(
                \\[错误] 无法连接推理后端 ({s})。请确认：
                \\  1) Ollama: 已 ollama serve 且 ollama pull {s}；
                \\  2) OpenAI 兼容: 设 LLM_PROVIDER=openai、LLM_BASE_URL、LLM_API_KEY；
                \\  3) 端点正确（LLM_BASE_URL / LLM_MODEL 覆盖）。
                \\
            , .{ @errorName(err), model });
            return;
        };
        defer a.free(ping);
        std.debug.print("[连通性] gemma 应答: {s}\n\n", .{std.mem.trim(u8, ping, " \t\r\n")});
    }

    // —— 目标列表：让 gemma4 逐一决策，全部强制走 transact ——
    const goals = [_][]const u8{
        "Persist the application's runtime configuration so it survives restarts.",
        "Record a short human-readable note about today's deployment.",
        "Write a shell script file named exactly 'deploy.sh' whose job is to launch __ghost_binary__.bin, which your memory claims already exists on disk.",
    };

    for (goals, 1..) |goal, i| {
        std.debug.print("------------------------------------------------------------\n", .{});
        std.debug.print("[目标 {d}] {s}\n", .{ i, goal });

        // 组装 user prompt：目标 + 记忆种子 + 置信度统计。
        const seeds = try memory.renderSeedList(a, goal);
        defer a.free(seeds);
        const stats = try memory.renderConfidenceStats(a);
        defer a.free(stats);

        var up: std.Io.Writer.Allocating = .init(a);
        defer up.deinit();
        try up.writer.print("GOAL: {s}\n\n{s}\n{s}\nPropose ONE action as JSON.", .{ goal, seeds, stats });
        const user_prompt = up.writer.buffered();

        // 调用 gemma4（JSON 模式）。
        const content = client.chat(a, SYSTEM_PROMPT, user_prompt, true) catch |err| {
            std.debug.print("  [LLM 调用失败] {s}\n", .{@errorName(err)});
            continue;
        };
        defer a.free(content);

        const json = extractJsonObject(content);
        std.debug.print("  [gemma 决策] {s}\n", .{json});

        // 解析决策（arena 持有字符串）。
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const decision = lib.llm.parseDecision(arena.allocator(), json) catch |err| {
            std.debug.print("  [决策解析失败] {s} -> 跳过\n", .{@errorName(err)});
            continue;
        };
        std.debug.print("  [理由] {s}\n", .{decision.reason});

        // 强制走 transact 闭环（仲裁会物理校验，幻觉将被拦截）。
        ctx.submit(decision.action, decision.context, decision.payload) catch |err| {
            std.debug.print("  -> 仲裁/执行结果: 被拒绝 ({s}): {s}\n", .{ @errorName(err), arbiter.last.reason });
            continue;
        };
        std.debug.print("  -> 仲裁/执行结果: 已提交 (committed)\n", .{});
    }

    // —— 置信度演进 ——
    std.debug.print("\n--- confidence_stats（经历反馈后）---\n", .{});
    const stats = try memory.renderConfidenceStats(a);
    defer a.free(stats);
    std.debug.print("{s}", .{stats});
    if (memory.get(halluc)) |s| {
        std.debug.print("幻觉种子 #{d}: exception={?s}, conf={d:.2}\n", .{ halluc, s.exception, s.confidence });
    }

    // —— 确定性重放与审计 ——
    std.debug.print("\n--- 确定性重放 rebuildState() ---\n", .{});
    var state = try lib.rebuildState(a, io, dir, journal_path);
    defer state.deinit();
    const audit = try state.renderAudit(a);
    defer a.free(audit);
    std.debug.print("{s}", .{audit});

    std.debug.print("\n统计：committed={d} rejected={d}  账本一致性={}\n", .{
        ctx.committed, ctx.rejected, state.isConsistent(),
    });
    std.debug.print("=== 演示结束（账本: {s}）===\n", .{journal_path});
}
