//! 黑盒测试八：专家模式切换 (The Persona Test)
//!
//! 猜想：把“专家模式”收敛为**一个声明式 `ExpertProfile`**，一次覆盖五维
//! （①领域知识 ②禁忌反射 ③学习/本能超参 ④敏感度档位 ⑤角色/模型），并通过
//! `activate(ctx)` 焊到内核现成旋钮上。因为**状态在账本、不在节点**，切换是
//! 热的、可审计、可完整回退的；且敏感度**只增不减**——L0 安全包络永不可被绕过。
//!
//! 黑盒断言（仅经由公共接口观测）：
//!   1. ③ 激活后学习超参被应用（learning_rate）。
//!   2. ④ 保守档：连良性 read 都升级为同步强校验（strict_all）。
//!   3. ④ 但 L0 反射不可降级：危险命令在保守档下依旧被否决。
//!   4. ② 专家自带禁忌反射抢占：写 prod 被专家层否决。
//!   5. ①+② 预烧录本能：写禁忌 context 被组合栈中的本能反射否决 (L-1:instinct)。
//!   6. ⑤ 角色提示覆盖生效（systemPrompt）。
//!   7. 审计：切换写成一条 committed 的 think 事件落入账本。
//!   8. Session.deinit 完整还原运行时旋钮（无残留热回退）。
//!   9. Registry 按名切换；未知专家报错。

const std = @import("std");
const lib = @import("sovereign");
const harness = @import("harness.zig");

const Dir = std.Io.Dir;
const Io = std.Io;
const Action = lib.Action;
const Verdict = lib.Verdict;
const SeedClaim = lib.arbiter.SeedClaim;

/// 一条专家自带的禁忌反射：永不写入含 "prod" 的上下文（最高优先级）。
const NoProd = struct {
    fn check(_: *anyopaque, _: Io, _: Dir, action: Action, _: []const SeedClaim) anyerror!?Verdict {
        if (action.action == .write and std.mem.indexOf(u8, action.context, "prod") != null)
            return Verdict{ .ok = false, .reason = "persona: never write prod" };
        return null;
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

    const path = ".test_persona_example.jsonl";
    dir.deleteFile(io, path) catch {};

    var journal = lib.Journal.init(a, io, dir, path);
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

    var chk = harness.Checker.init("测试八 专家模式切换（The Persona Test）");

    // —— 声明一个“保守运维专家”画像（统一 ExpertProfile，一次到位）——
    const reflexes = [_]lib.Layer{
        .{ .name = "persona:no-prod", .ctx = undefined, .check = NoProd.check },
    };
    const ops: lib.ExpertProfile = .{
        .name = "ops-conservative",
        .description = "谨慎的 SRE：保守敏感度 + 禁忌反射 + 预烧录本能",
        .seeds = &.{
            .{ .context = "release", .content = "forbid: no release on friday", .confidence = 0.95, .instinct = true },
        },
        .reflexes = &reflexes,
        .learning_rate = 0.02,
        .sensitivity = .conservative,
        .llm = .{ .system_prompt = "You are a cautious SRE. Prefer atomic, reversible operations." },
    };

    // —— 激活 ——
    chk.section("激活专家画像：五维一次写入运行时");
    var sess = try ops.activate(a, &ctx);

    // ③ 学习超参。
    chk.note("learning_rate = {d:.3}", .{memory.learning_rate});
    chk.check(harness.approx(memory.learning_rate, 0.02, 1e-9), "③ 学习超参被应用 (learning_rate=0.02)");

    // ④ 保守档：良性 read 升级为同步强校验。
    chk.section("④ 敏感度档位（只增不减）");
    const before_sync = arb.sync_checks;
    const rd: Action = .{ .id = 0, .action = .read, .context = "config.json", .payload = "" };
    chk.check(try arb.verify(rd, &.{}), "良性 read 仍放行（无误杀）");
    chk.check(arb.sync_checks == before_sync + 1, "保守档使良性 read 升级为同步强校验 (strict_all)");

    // ④ 但 L0 不可降级。
    const danger: Action = .{ .id = 0, .action = .execute, .context = "x", .payload = "rm -rf /" };
    chk.check(!try arb.verify(danger, &.{}), "危险命令在保守档下依旧被否决");
    chk.check(std.mem.eql(u8, arb.last.layer, "L0:safety-envelope"), "归因 L0：安全包络不可被任何专家绕过");

    // ② 专家自带禁忌反射抢占。
    chk.section("② 禁忌反射（专家自带，最高优先级）");
    const prod: Action = .{ .id = 0, .action = .write, .context = "prod-cfg", .payload = "{\"k\":1}" };
    chk.check(!try arb.verify(prod, &.{}), "写 prod 被专家禁忌反射否决");
    chk.note("裁决层=\"{s}\" reason=\"{s}\"", .{ arb.last.layer, arb.last.reason });
    chk.check(std.mem.eql(u8, arb.last.layer, "persona:no-prod"), "归因到专家反射层");

    // ①+② 预烧录本能。
    chk.section("①+② 预烧录本能：组合栈中的本能反射持续生效");
    const rel: Action = .{ .id = 0, .action = .write, .context = "release", .payload = "go" };
    chk.check(!try arb.verify(rel, &.{}), "写禁忌 context (release) 被本能反射否决");
    chk.check(std.mem.eql(u8, arb.last.layer, "L-1:instinct"), "归因到最高优先级本能层 L-1:instinct");

    // ⑤ 角色提示覆盖。
    chk.section("⑤ 角色/模型覆盖（驱动层读取，不进 transact）");
    chk.check(std.mem.indexOf(u8, sess.systemPrompt("fallback"), "cautious SRE") != null, "角色提示覆盖生效");
    chk.check(std.mem.eql(u8, sess.model("gpt-4o-mini"), "gpt-4o-mini"), "未覆盖的模型回退到 fallback");

    // 审计：切换落账。
    chk.section("审计：切换动作作为 committed think 事件落账");
    const data = try dir.readFileAlloc(io, path, a, .unlimited);
    defer a.free(data);
    chk.check(std.mem.indexOf(u8, data, "\"action\":\"think\"") != null, "账本含一条 think 事件");
    chk.check(std.mem.indexOf(u8, data, "ops-conservative") != null, "事件 payload 携带专家名（可重放追溯）");
    chk.check(std.mem.indexOf(u8, data, "\"status\":\"committed\"") != null, "该切换事件为 committed 状态");

    // —— 热回退：完整还原 ——
    chk.section("热回退：Session.deinit 完整还原运行时旋钮");
    sess.deinit(&ctx);
    chk.check(!arb.strict_all, "敏感度档位已还原（strict_all=false）");
    chk.check(harness.approx(memory.learning_rate, 0.1, 1e-9), "learning_rate 还原到默认 0.1");
    chk.check(arb.stack.reflexes.len == 0, "组合反射栈已释放并还原为空");
    // 还原后：良性 read 回到异步放行（不再全量强校验）。
    const after_sync = arb.sync_checks;
    const rd2: Action = .{ .id = 0, .action = .read, .context = "config.json", .payload = "" };
    chk.check(try arb.verify(rd2, &.{}), "还原后良性 read 放行");
    chk.check(arb.sync_checks == after_sync, "还原后良性 read 不再升级为同步强校验（回到异步）");

    // —— Registry 按名切换 ——
    chk.section("Registry：按名切换 / 枚举 / 未知专家");
    const profiles = [_]lib.ExpertProfile{
        .{ .name = "generalist" },
        ops,
    };
    const reg: lib.Registry = .{ .profiles = &profiles };
    chk.check(reg.find("generalist") != null, "find 命中已注册专家");
    chk.check(reg.find("ghost") == null, "find 未知专家返回 null");
    var sess2 = try reg.switchTo(a, &ctx, "ops-conservative");
    chk.check(arb.strict_all, "switchTo 激活专家（保守档生效）");
    sess2.deinit(&ctx);
    if (reg.switchTo(a, &ctx, "ghost")) |_| {
        chk.check(false, "未知专家应报错");
    } else |err| {
        chk.check(err == error.UnknownPersona, "switchTo 未知专家返回 error.UnknownPersona");
    }

    dir.deleteFile(io, path) catch {};

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
