//! 黑盒测试十：专家积累的回写闭环 (The Persona Write-back Closure Test)
//!
//! 猜想：运行期的"积累"（置信度演进 + 本能烧录）不该只活在内存/journal——它应能
//! 被**回写为声明式 ZON 专家资产**，使下次冷启动即"更聪明"，且该资产可 review /
//! 可 git 管理 / 可移植，同时不破坏任何零信任红线。
//!
//! 闭环：`zig-expert.zon → 激活 activate → 学习 updateConfidence → exportProfile
//!        → zig-expert.zon(v2) → 冷启动重加载 → 学出来的本能反射立即生效`
//!
//! 黑盒断言（仅经 root.zig 公共接口观测）：
//!   1. 置信度演进被持久化：学习后 0.6 → 1.0 写回，重加载后仍是 1.0。
//!   2. 本能烧录被持久化：源里 instinct=false 的 forbid 种子经反复成功烧录为 instinct，
//!      回写产物里 instinct=true。
//!   3. **冷启动即生效**：用回写产物重建一个全新 Agent（新内存/新仲裁器），写命中
//!      该 forbid 种子 context 的敏感操作，立即被本能反射 (L-1:instinct) 否决——
//!      无需重新学习。这正是"使用专家形成的积累"（能力③）。
//!   4. ctx_filter 按域切分导出：仅导出 `zig:std` 域时只含该域种子。
//!   5. 零信任仍在：回写产物无 reflexes、无密钥字段，重加载后 L0 安全包络照旧否决危险命令。

const std = @import("std");
const lib = @import("sovereign");
const harness = @import("harness.zig");

const Dir = std.Io.Dir;
const Io = std.Io;
const Action = lib.Action;

/// 极简 Agent 环境组装（journal + memory + arbiter + ctx），黑盒复用。
const Env = struct {
    journal: lib.Journal,
    memory: lib.MemoryManager,
    arbiter: lib.Arbiter,
    ctx: lib.AgentContext,

    fn init(e: *Env, a: std.mem.Allocator, io: Io, dir: Dir, jpath: []const u8) !void {
        dir.deleteFile(io, jpath) catch {};
        e.journal = lib.Journal.init(a, io, dir, jpath);
        try e.journal.ensureFile();
        e.memory = lib.MemoryManager.init(a);
        e.arbiter = lib.Arbiter.init(io, dir);
        e.ctx = .{
            .gpa = a,
            .io = io,
            .dir = dir,
            .journal = &e.journal,
            .memory = &e.memory,
            .arbiter = &e.arbiter,
        };
    }

    fn deinit(e: *Env, io: Io, dir: Dir, jpath: []const u8) void {
        e.journal.deinit();
        e.memory.deinit();
        dir.deleteFile(io, jpath) catch {};
    }
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    var chk = harness.Checker.init("测试十 专家积累的回写闭环（Persona Write-back Closure）");

    // —— 蒸馏专家（含一条“待烧录”的 forbid 种子：初始 instinct=false）——
    const src =
        \\.{
        \\    .name = "zig-expert",
        \\    .description = "distilled zig knowledge (test)",
        \\    .seeds = .{
        \\        .{ .context = "zig:build", .content = "b.installArtifact required for outputs", .confidence = 0.6 },
        \\        .{ .context = "zig:unsafe", .content = "forbid: @ptrCast without alignment proof", .confidence = 0.6 },
        \\        .{ .context = "zig:std:mem", .content = "prefer std.mem.eql for byte compare", .confidence = 0.5 },
        \\    },
        \\    .learning_rate = 0.1,
        \\    .llm = .{ .system_prompt = "You are a Zig master tracking master branch." },
        \\}
    ;

    // —— 阶段 A：加载 → 激活 → 学习 ——
    chk.section("阶段 A：加载 → 激活 → 学习（updateConfidence 烧录本能）");
    var reg = try lib.loadPersonaBytes(a, src);
    defer reg.deinit();
    const profile = reg.registry().find("zig-expert").?;

    const jpath_a = ".test_export_a.jsonl";
    var env_a: Env = undefined;
    try env_a.init(a, io, dir, jpath_a);
    defer env_a.deinit(io, dir, jpath_a);

    var sess = try profile.activate(a, &env_a.ctx);
    defer sess.deinit(&env_a.ctx);

    // 冷启动时 zig:unsafe 尚非本能 → 写它不应被本能反射否决。
    const unsafe_write: Action = .{ .id = 0, .action = .write, .context = "zig:unsafe", .payload = "@ptrCast(x)" };
    chk.check(try env_a.arbiter.verify(unsafe_write, &.{}), "学习前：写 zig:unsafe 未被本能否决（种子尚非本能）");

    // 学习：让 zig:build 与 zig:unsafe 反复成功 → 置信度饱和且烧录为本能。
    const build_ids = try env_a.memory.fetchSeeds(a, "zig:build");
    defer a.free(build_ids);
    const unsafe_ids = try env_a.memory.fetchSeeds(a, "zig:unsafe");
    defer a.free(unsafe_ids);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        env_a.memory.updateConfidence(build_ids, .success);
        env_a.memory.updateConfidence(unsafe_ids, .success);
    }
    chk.check(env_a.memory.get(build_ids[0]).?.instinct, "学习后：zig:build 已烧录为本能");
    chk.check(env_a.memory.get(unsafe_ids[0]).?.instinct, "学习后：zig:unsafe(forbid) 已烧录为本能");
    chk.check(harness.approx(env_a.memory.get(build_ids[0]).?.confidence, 1.0, 1e-9), "学习后：zig:build 置信度饱和至 1.0");

    // —— 阶段 B：回写为完整 ProfileConfig ZON ——
    chk.section("阶段 B：exportProfile 回写为可解析的 ZON 资产");
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    try lib.exportProfile(a, &w.writer, lib.metaFromProfile(profile.*), &env_a.memory, null);
    const written = w.written();
    const dumped = try a.allocSentinel(u8, written.len, 0);
    defer a.free(dumped);
    @memcpy(dumped, written);
    chk.note("回写产物（v2）:\n{s}", .{dumped});
    chk.check(std.mem.indexOf(u8, dumped, "zig-expert") != null, "产物含专家名");
    chk.check(std.mem.indexOf(u8, dumped, "You are a Zig master") != null, "产物含角色提示（system_prompt）");

    // —— 阶段 C：冷启动重加载 → 断言积累已持久 ——
    chk.section("阶段 C：冷启动重加载 → 演进/烧录被持久化");
    var reg2 = try lib.loadPersonaBytes(a, dumped);
    defer reg2.deinit();
    const p2 = reg2.registry().find("zig-expert").?;
    chk.check(p2.seeds.len == 3, "重加载：3 条种子完好");
    chk.check(harness.approx(p2.learning_rate, 0.1, 1e-9), "重加载：learning_rate 保留");

    var found_build = false;
    var found_unsafe = false;
    for (p2.seeds) |s| {
        if (std.mem.eql(u8, s.context, "zig:build")) {
            found_build = true;
            chk.check(harness.approx(s.confidence, 1.0, 1e-9), "① 置信度演进持久化：zig:build=1.0");
            chk.check(s.instinct, "② 本能烧录持久化：zig:build.instinct=true");
        }
        if (std.mem.eql(u8, s.context, "zig:unsafe")) {
            found_unsafe = true;
            chk.check(s.instinct, "② 本能烧录持久化：zig:unsafe(forbid).instinct=true（源里为 false）");
        }
    }
    chk.check(found_build and found_unsafe, "重加载：关键种子均在");

    // —— 阶段 D：用回写产物冷启动一个**全新** Agent → 学出的反射即刻生效 ——
    chk.section("阶段 D：全新 Agent 冷启动 → 学出的 forbid 本能立即反射否决（能力③核心）");
    const jpath_b = ".test_export_b.jsonl";
    var env_b: Env = undefined;
    try env_b.init(a, io, dir, jpath_b);
    defer env_b.deinit(io, dir, jpath_b);

    var sess2 = try p2.activate(a, &env_b.ctx);
    defer sess2.deinit(&env_b.ctx);

    const unsafe_write2: Action = .{ .id = 0, .action = .write, .context = "zig:unsafe", .payload = "@ptrCast(x)" };
    chk.check(!try env_b.arbiter.verify(unsafe_write2, &.{}), "冷启动即否决：写 zig:unsafe 被本能反射拦截（无需再学习）");
    chk.check(std.mem.eql(u8, env_b.arbiter.last.layer, "L-1:instinct"), "归因到本能层 L-1:instinct");

    // —— 阶段 E：ctx_filter 按域切分导出 ——
    chk.section("阶段 E：ctx_filter 按域切分导出（仅 zig:std）");
    var w2: std.Io.Writer.Allocating = .init(a);
    defer w2.deinit();
    try env_a.memory.dumpSeedsZon(&w2.writer, "zig:std");
    const only_std = w2.written();
    chk.check(std.mem.indexOf(u8, only_std, "std.mem.eql") != null, "含 zig:std:mem 种子");
    chk.check(std.mem.indexOf(u8, only_std, "installArtifact") == null, "已过滤掉 zig:build 种子");
    chk.check(std.mem.indexOf(u8, only_std, "@ptrCast") == null, "已过滤掉 zig:unsafe 种子");

    // —— 阶段 F：零信任红线仍在 ——
    chk.section("阶段 F：回写产物仍是纯声明式 → 零信任红线不变");
    chk.check(p2.reflexes.len == 0, "回写产物 reflexes 恒空（不携带代码）");
    const danger: Action = .{ .id = 0, .action = .execute, .context = "x", .payload = "rm -rf /" };
    chk.check(!try env_b.arbiter.verify(danger, &.{}), "危险命令仍被 L0 安全包络否决");
    chk.check(std.mem.eql(u8, env_b.arbiter.last.layer, "L0:safety-envelope"), "归因 L0：安全包络");

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
