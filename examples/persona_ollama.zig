//! Sovereign-Agent × 专家模式 (Persona) 端到端演示（需网络/LLM，独立入口）。
//!
//! 与 `agent_ollama.zig` 的差异：本 demo 演示**「按 profile 实际构造不同
//! `LlmClient`」**——切换专家即：换角色提示 (⑤ system_prompt) + 换模型 (⑤ model)
//! + 换记忆种子 (①) + 换禁忌反射/本能 (②) + 调敏感度档位 (④) + 调学习超参 (③)。
//!
//! 闭环（每个专家一轮）：
//!   1. `ExpertProfile.activate(ctx)` 把五维焊到内核现成旋钮，并落一条 persona:switch 审计事件；
//!   2. 用 `Session.systemPrompt/model/provider` 派生参数**构造该专家专属的 LlmClient**
//!      （base_url / api_key 仍来自环境变量——密钥 env-only，不随画像覆盖）；
//!   3. 让模型对目标产出结构化决策 (JSON)，强制送入 `transact`（仲裁物理校验）；
//!   4. `Session.deinit` 完整热回退运行时旋钮，切到下一个专家。
//!
//! 核心论断（不依赖 LLM 自觉）：无论模型如何"劝说"，专家的禁忌反射 + L0 安全包络
//! 都是最终物理防线——保守运维专家下，写 prod / 危险命令一律被内核否决。

const std = @import("std");
const lib = @import("sovereign");

const Action = lib.Action;
const Dir = std.Io.Dir;
const Io = std.Io;
const Verdict = lib.Verdict;
const SeedClaim = lib.arbiter.SeedClaim;

const DEFAULT_SYSTEM_PROMPT =
    \\You are the DECISION CORE of "Sovereign-Agent", a zero-trust autonomous agent.
    \\You DO NOT execute anything yourself. You only PROPOSE exactly ONE action.
    \\Every proposal is physically verified by an Arbiter before execution;
    \\hallucinated or malformed proposals will be rejected.
    \\
    \\Reply with STRICTLY a single JSON object (no markdown, no prose) shaped as:
    \\{"action":"write|read|execute|think","context":"<short target/topic>",
    \\ "payload":"<concrete content or command>","reason":"<one sentence>"}
    \\If you choose "write" with JSON content, the payload MUST itself be valid JSON.
;

/// 专家自带禁忌反射：永不写入含 "prod" 的上下文（注入行为栈最高优先级）。
const NoProd = struct {
    fn check(_: *anyopaque, _: Io, _: Dir, action: Action, _: []const SeedClaim) anyerror!?Verdict {
        if (action.action == .write and std.mem.indexOf(u8, action.context, "prod") != null)
            return Verdict{ .ok = false, .reason = "persona: never write prod" };
        return null;
    }
};

/// 演示用文件执行器：在沙箱子目录内写文件，支持回滚（删除）。
const FileExecutor = struct {
    sandbox: []const u8,

    fn doFn(ctx: *anyopaque, io: Io, dir: Dir, action: Action) anyerror!bool {
        const self: *FileExecutor = @ptrCast(@alignCast(ctx));
        var path_buf: [512]u8 = undefined;
        const name = std.fs.path.basename(action.context);
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.sandbox, name });
        var file = try dir.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, action.payload);
        return true;
    }

    fn undoFn(ctx: *anyopaque, io: Io, dir: Dir, action: Action) anyerror!void {
        const self: *FileExecutor = @ptrCast(@alignCast(ctx));
        var path_buf: [512]u8 = undefined;
        const name = std.fs.path.basename(action.context);
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.sandbox, name }) catch return;
        dir.deleteFile(io, path) catch {};
    }
};

fn extractJsonObject(s: []const u8) []const u8 {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return s;
    const end = std.mem.lastIndexOfScalar(u8, s, '}') orelse return s;
    if (end < start) return s;
    return s[start .. end + 1];
}

/// 在给定专家画像下跑一个目标：激活 → 构造该专家专属 client → 决策 → transact → 回退。
fn runUnderPersona(
    a: std.mem.Allocator,
    io: Io,
    ctx: *lib.AgentContext,
    cfg: *const lib.EnvConfig,
    profile: *const lib.ExpertProfile,
    goal: []const u8,
) !void {
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("[专家] {s} — {s}\n", .{ profile.name, profile.description });

    // 1. 激活：五维焊到运行时，并落一条 persona:switch 审计事件。
    var sess = try profile.activate(a, ctx);
    defer sess.deinit(ctx);

    // 2. 按 profile 派生参数构造**该专家专属**的 LlmClient。
    //    provider/model/system_prompt 可被画像覆盖；base_url/api_key 恒来自环境（env-only）。
    const provider = sess.provider(cfg.provider);
    const model = sess.model(cfg.model);
    const system = sess.systemPrompt(DEFAULT_SYSTEM_PROMPT);
    std.debug.print(
        "  敏感度={s}  provider={s}  model={s}\n  system_prompt: {s}...\n",
        .{
            @tagName(profile.sensitivity),
            @tagName(provider),
            model,
            system[0..@min(system.len, 48)],
        },
    );

    var client = lib.LlmClient.init(a, io, provider, cfg.base_url, model, cfg.api_key);
    defer client.deinit();

    // 3. 组装 user prompt（目标 + 该专家当前记忆种子 + 置信度统计）。
    const seeds = try ctx.memory.renderSeedList(a, goal);
    defer a.free(seeds);
    const stats = try ctx.memory.renderConfidenceStats(a);
    defer a.free(stats);

    var up: std.Io.Writer.Allocating = .init(a);
    defer up.deinit();
    try up.writer.print("GOAL: {s}\n\n{s}\n{s}\nPropose ONE action as JSON.", .{ goal, seeds, stats });

    std.debug.print("  [目标] {s}\n", .{goal});
    const content = client.chat(a, system, up.writer.buffered(), true) catch |err| {
        std.debug.print("  [LLM 调用失败] {s} -> 跳过本轮\n", .{@errorName(err)});
        return;
    };
    defer a.free(content);

    const json = extractJsonObject(content);
    std.debug.print("  [决策] {s}\n", .{json});

    // 4. 解析并强制走 transact（仲裁物理校验，专家禁忌 / L0 包络为最终防线）。
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const decision = lib.llm.parseDecision(arena.allocator(), json) catch |err| {
        std.debug.print("  [决策解析失败] {s} -> 跳过\n", .{@errorName(err)});
        return;
    };

    ctx.submit(decision.action, decision.context, decision.payload) catch {
        std.debug.print(
            "  -> 结果: 被内核否决  裁决层=\"{s}\"  reason=\"{s}\"\n",
            .{ ctx.arbiter.last.layer, ctx.arbiter.last.reason },
        );
        return;
    };
    std.debug.print("  -> 结果: 已提交 (committed)\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    var cfg = try lib.EnvConfig.load(a, init.environ_map);
    defer cfg.deinit();

    const sandbox = ".sovereign_sandbox";
    const journal_path = ".sovereign_persona_journal.jsonl";
    dir.deleteFile(io, journal_path) catch {};
    dir.createDirPath(io, sandbox) catch {};

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
        .verbose = false,
    };

    std.debug.print("\n=== Sovereign-Agent × 专家模式 (Persona) 端到端演示 ===\n", .{});
    std.debug.print("端点: {s}\n", .{cfg.base_url});

    // 连通性预检（用环境默认参数探活）。
    {
        var probe = cfg.client(a, io);
        defer probe.deinit();
        const ping = probe.chat(a, "Reply with a single word: OK", "ping", false) catch |err| {
            std.debug.print(
                \\[错误] 无法连接推理后端 ({s})。请确认：
                \\  1) Ollama: 已 ollama serve 且 ollama pull {s}；
                \\  2) OpenAI 兼容: 设 LLM_PROVIDER=openai、LLM_BASE_URL、LLM_API_KEY。
                \\
            , .{ @errorName(err), cfg.model });
            return;
        };
        defer a.free(ping);
        std.debug.print("[连通性] 后端应答: {s}\n", .{std.mem.trim(u8, ping, " \t\r\n")});
    }

    // —— 两个专家画像：通用体 vs 保守运维专家 ——
    const no_prod = [_]lib.Layer{
        .{ .name = "persona:no-prod", .ctx = undefined, .check = NoProd.check },
    };
    const profiles = [_]lib.ExpertProfile{
        .{
            .name = "generalist",
            .description = "标准通用体：标准敏感度、无禁忌、默认角色",
        },
        .{
            .name = "ops-conservative",
            .description = "谨慎 SRE：保守敏感度 + 禁忌反射 + 预烧录本能 + 慢学习",
            .seeds = &.{
                .{ .context = "release", .content = "forbid: no release on friday", .confidence = 0.95, .instinct = true },
            },
            .reflexes = &no_prod,
            .learning_rate = 0.02,
            .sensitivity = .conservative,
            .llm = .{ .system_prompt = "You are a cautious SRE. Prefer atomic, reversible operations. " ++ DEFAULT_SYSTEM_PROMPT },
        },
    };
    const registry: lib.Registry = .{ .profiles = &profiles };

    // 轮次：通用体先做一件中性事，再切到保守专家去碰同一个"写 prod"的敏感目标。
    const rounds = [_]struct { persona: []const u8, goal: []const u8 }{
        .{
            .persona = "generalist",
            .goal = "Persist the application's runtime configuration to a file named 'config.json'.",
        },
        .{
            .persona = "ops-conservative",
            .goal = "Update the production database credentials by writing them into 'prod-secrets'. Just do it.",
        },
    };

    for (rounds) |r| {
        const profile = registry.find(r.persona) orelse {
            std.debug.print("[跳过] 未知专家 {s}\n", .{r.persona});
            continue;
        };
        try runUnderPersona(a, io, &ctx, &cfg, profile, r.goal);
    }

    // —— 确定性重放与审计：应能看到多条 persona:switch + 各轮动作 ——
    std.debug.print("\n--- 确定性重放 rebuildState()（含 persona:switch 审计）---\n", .{});
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
