//! 黑盒测试九：配置驱动的可插拔专家 (The Pluggable Persona Config Test)
//!
//! 猜想：把专家画像从硬编码 `[]const ExpertProfile` 改为运行时从 ZON 配置加载，
//! 不改内核语义即可"无代码增删专家"；且配置只能表达声明式数据——密钥进不来、
//! 敏感度只增不减、L0 安全包络与本能反射仍是最终物理防线。
//!
//! 黑盒断言（仅经公共接口观测）：
//!   1. loadBytes 严格解析：合法画像映射为 ExpertProfile，reflexes 恒空。
//!   2. loadDir 目录聚合：仅收 *.zon、忽略其它文件，且按文件名**字典序**确定排序。
//!   3. registry().switchTo 与既有内核完全兼容（保守档生效）。
//!   4. ① forbid 型 instinct 种子经组合栈本能反射否决写敏感 context (L-1:instinct)。
//!   5. ④ 保守档不可降级：危险命令仍被 L0 安全包络否决（L0 不可绕过）。
//!   6. 密钥字段 / 未知字段 / 非法敏感度枚举一律解析失败（零信任红线）。

const std = @import("std");
const lib = @import("sovereign");
const harness = @import("harness.zig");

const Dir = std.Io.Dir;
const Io = std.Io;
const Action = lib.Action;

fn writeFile(io: Io, dir: Dir, path: []const u8, bytes: []const u8) !void {
    var f = try dir.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    var chk = harness.Checker.init("测试九 配置驱动的可插拔专家（Pluggable Persona Config）");

    // —— 1. loadBytes：单个内联画像 ——
    chk.section("loadBytes：严格解析 + 映射（reflexes 恒空）");
    {
        const src =
            \\.{ .name = "inline-x", .sensitivity = .conservative,
            \\   .seeds = .{ .{ .context = "c", .content = "forbid: no", .instinct = true } } }
        ;
        var reg = try lib.loadPersonaBytes(a, src);
        defer reg.deinit();
        chk.check(reg.count() == 1, "内联单画像加载成功");
        chk.check(std.mem.eql(u8, reg.profiles[0].name, "inline-x"), "name 正确解析");
        chk.check(reg.profiles[0].reflexes.len == 0, "reflexes 恒空（配置不携带代码）");
        chk.check(reg.profiles[0].sensitivity == .conservative, "sensitivity=.conservative 解析");
    }

    // —— 2. loadDir：目录聚合 + 排序确定性 ——
    chk.section("loadDir：仅 *.zon、字典序排序确定性");
    const test_dir = ".test_experts_cfg";
    dir.deleteTree(io, test_dir) catch {};
    try dir.createDirPath(io, test_dir);
    defer dir.deleteTree(io, test_dir) catch {};

    // 故意乱序命名，并混入一个非 .zon 文件（应被忽略）。
    try writeFile(io, dir, test_dir ++ "/b_ops.zon",
        \\.{ .name = "ops-conservative", .sensitivity = .conservative,
        \\   .learning_rate = 0.02,
        \\   .seeds = .{
        \\     .{ .context = "release", .content = "forbid: no release on friday", .confidence = 0.95, .instinct = true },
        \\   },
        \\   .llm = .{ .system_prompt = "You are a cautious SRE." } }
    );
    try writeFile(io, dir, test_dir ++ "/a_generalist.zon",
        \\.{ .name = "generalist", .description = "baseline" }
    );
    try writeFile(io, dir, test_dir ++ "/c_researcher.zon",
        \\.{ .name = "researcher", .learning_rate = 0.15,
        \\   .llm = .{ .provider = .openai, .model = "gpt-4o-mini" } }
    );
    try writeFile(io, dir, test_dir ++ "/notes.txt", "not a zon file, must be ignored");

    var creg = try lib.loadPersonaDir(a, io, dir, test_dir);
    defer creg.deinit();

    chk.check(creg.count() == 3, "仅聚合 3 个 *.zon（notes.txt 被忽略）");
    chk.check(std.mem.eql(u8, creg.profiles[0].name, "generalist"), "排序[0]=generalist (a_*)");
    chk.check(std.mem.eql(u8, creg.profiles[1].name, "ops-conservative"), "排序[1]=ops-conservative (b_*)");
    chk.check(std.mem.eql(u8, creg.profiles[2].name, "researcher"), "排序[2]=researcher (c_*)");

    // —— 3~5. registry().switchTo 与内核集成 ——
    chk.section("registry().switchTo：与既有内核完全兼容");
    const jpath = ".test_persona_cfg_journal.jsonl";
    dir.deleteFile(io, jpath) catch {};
    defer dir.deleteFile(io, jpath) catch {};

    var journal = lib.Journal.init(a, io, dir, jpath);
    defer journal.deinit();
    try journal.ensureFile();

    var memory = lib.MemoryManager.init(a);
    defer memory.deinit();

    var arb = lib.Arbiter.init(io, dir);

    var ctx: lib.AgentContext = .{
        .gpa = a,
        .io = io,
        .dir = dir,
        .journal = &journal,
        .memory = &memory,
        .arbiter = &arb,
    };

    const reg = creg.registry();
    chk.check(reg.find("researcher") != null, "Registry.find 命中配置加载的专家");
    chk.check(reg.find("ghost") == null, "Registry.find 未知专家返回 null");

    var sess = try reg.switchTo(a, &ctx, "ops-conservative");
    defer sess.deinit(&ctx);
    chk.check(arb.strict_all, "④ 保守档生效（strict_all）");
    chk.check(std.mem.indexOf(u8, sess.systemPrompt("fallback"), "cautious SRE") != null, "⑤ 角色提示覆盖生效");

    chk.section("① forbid 型 instinct 经组合栈本能反射否决");
    const rel: Action = .{ .id = 0, .action = .write, .context = "release", .payload = "go" };
    chk.check(!try arb.verify(rel, &.{}), "写 release 被本能反射否决");
    chk.check(std.mem.eql(u8, arb.last.layer, "L-1:instinct"), "归因到本能层 L-1:instinct");

    chk.section("④ L0 安全包络不可被任何配置绕过");
    const danger: Action = .{ .id = 0, .action = .execute, .context = "x", .payload = "rm -rf /" };
    chk.check(!try arb.verify(danger, &.{}), "危险命令在保守档下依旧被否决");
    chk.check(std.mem.eql(u8, arb.last.layer, "L0:safety-envelope"), "归因 L0：安全包络");

    // —— 6. 零信任红线：非法配置一律拒绝 ——
    chk.section("零信任红线：密钥/未知字段/非法敏感度一律拒绝");
    chk.check(
        std.meta.isError(lib.loadPersonaBytes(a, ".{ .name = \"x\", .api_key = \"sk-nope\" }")),
        "顶层 api_key 被拒（密钥 env-only）",
    );
    chk.check(
        std.meta.isError(lib.loadPersonaBytes(a, ".{ .name = \"x\", .llm = .{ .base_url = \"http://10.0.0.1\" } }")),
        "llm.base_url 被拒（无此字段）",
    );
    chk.check(
        std.meta.isError(lib.loadPersonaBytes(a, ".{ .name = \"x\", .unknown_field = 1 }")),
        "未知字段被拒（严格 schema）",
    );
    chk.check(
        std.meta.isError(lib.loadPersonaBytes(a, ".{ .name = \"x\", .sensitivity = .relaxed }")),
        "非法敏感度 .relaxed 被拒（无低于 standard 的档位）",
    );

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
