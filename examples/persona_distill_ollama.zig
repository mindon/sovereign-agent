//! Sovereign-Agent × 在线自蒸馏 (Self-Distillation) 端到端演示（需网络/LLM，独立入口）。
//!
//! 回答"专家能否通过 LLM API 自行蒸馏所需知识？"——**能**，但严格贴合内核的
//! "非完美记忆 + 零信任"哲学，全链路守住三条红线：
//!
//!   链路： raw_text ──distill(LLM)──> DistilledSeed[] ──ingestDistilled──> memory
//!          ──(运行期 updateConfidence 演进/烧录)──> exportProfile ──> .zon(待审)
//!          ──> 人工 git diff / PR ──> 升级为正式专家资产
//!
//! 红线：
//!   1. 蒸馏种子只进"不可信区"：confidence 一律 clamp ≤ 0.5，且 instinct 恒 false
//!      （本能只能靠运行期反复验证烧录或人工 review 晋升，模型无权直接写否决反射）。
//!   2. 蒸馏是在线、非确定性的，**不进** `zig build examples` 那套离线确定性黑盒；
//!      产物是"待审知识"，须经 exportProfile 回写 .zon → 人工 PR 才升级为专家资产。
//!   3. 防 SSRF：本 demo **不发起任意外联抓 URL**，原始知识文本由调用方直接传入；
//!      蒸馏原语只访问显式配置的 LLM base_url（默认本地 127.0.0.1:11434）。
//!
//! 运行：`zig build run-distill`（需 Ollama/OpenAI 兼容后端；见 EnvConfig 环境变量）。

const std = @import("std");
const lib = @import("sovereign");

const Io = std.Io;
const Dir = std.Io.Dir;

/// 待蒸馏的**原始知识文本**（示例内联，模拟调用方在白名单内抓好后传入）。
/// 真实用法可从受信来源（如 ziglang.org 白名单）抓取后喂入，蒸馏原语本身不外联。
const RAW_KNOWLEDGE =
    \\Zig build system (master): b.addExecutable takes a root_module created via
    \\b.createModule({ .root_source_file, .target, .optimize }). Call
    \\b.installArtifact(exe) so outputs land in zig-out; without it nothing is installed.
    \\I/O is explicit on master: obtain std.Io from std.Io.Threaded and pass `io` to
    \\Dir/File operations. Allocating std APIs take an explicit allocator (no hidden
    \\allocations); thread the allocator through. Prefer slices over many-pointers.
    \\std.mem.eql([]const u8, a, b) compares byte slices for equality.
;

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

    std.debug.print("\n=== Sovereign-Agent × 在线自蒸馏 (Self-Distillation) 演示 ===\n", .{});
    std.debug.print("端点: {s}  model: {s}\n", .{ cfg.base_url, cfg.model });

    var client = cfg.client(a, io);
    defer client.deinit();

    // 连通性预检。
    {
        const ping = client.chat(a, "Reply with a single word: OK", "ping", false) catch |err| {
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

    const domain = "zig";

    // 1) 在线蒸馏：raw_text → 结构化种子（arena 持有产物字符串）。
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    std.debug.print("\n[1/3] 蒸馏中（domain={s}, {d} 字节原始知识）...\n", .{ domain, RAW_KNOWLEDGE.len });
    const seeds = client.distill(a, arena.allocator(), domain, RAW_KNOWLEDGE) catch |err| {
        std.debug.print("  [蒸馏失败] {s} -> 退出\n", .{@errorName(err)});
        return;
    };
    std.debug.print("  模型蒸馏出 {d} 条候选种子。\n", .{seeds.len});
    for (seeds, 0..) |s, i| {
        std.debug.print("    #{d} [ctx={s} conf={d:.2}] {s}\n", .{ i, s.context, s.confidence, s.content });
    }

    // 2) 零信任安全注入：clamp 置信度 ≤ 0.5、instinct 恒 false、按域打标签。
    var mem = lib.MemoryManager.init(a);
    defer mem.deinit();
    const n = try mem.ingestDistilled(domain, seeds, 0.5);
    std.debug.print("\n[2/3] 已安全注入 {d} 条（零信任：conf≤0.5, instinct=false）。\n", .{n});
    const stats = try mem.renderConfidenceStats(a);
    defer a.free(stats);
    std.debug.print("{s}", .{stats});
    std.debug.print("  是否引入任何本能反射: {}（应为 false）\n", .{mem.hasInstincts()});

    // 3) 回写为"待审"专家资产 .zon（供人工 git diff / PR 升级；不自动生效）。
    const out_path = "experts/zig-expert.distilled.zon";
    const meta: lib.ProfileConfig = .{
        .name = "zig-expert-distilled",
        .description = "AUTO-DISTILLED (untrusted) — review before promoting to a real expert",
        .llm = .{ .system_prompt = "You are a Zig assistant. Treat distilled seeds as unverified hints." },
    };
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try lib.exportProfile(a, &buf.writer, meta, &mem, domain);

    var file = try dir.createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, buf.written());
    std.debug.print(
        "\n[3/3] 已回写待审资产: {s}（{d} 字节）\n  下一步：人工 `git diff` 审阅 → PR 升级为正式专家。\n",
        .{ out_path, buf.written().len },
    );
    std.debug.print("=== 演示结束 ===\n", .{});
}
