//! 黑盒测试五：持续学习与本能烧录 (The Instinct Test)
//!
//! 猜想：软记忆（连续可逆的置信度）在被环境**反复验证**后，会“烧录”为本能
//! (Instinct)——一种抗灾难性遗忘、零 LLM 成本、最高优先级的反射；而当环境
//! 确实改变（连续失败），本能又能被**解除烧录**回归软记忆。烧录出的禁忌
//! 还可直接注入包容式行为栈，作为最高优先级反射否决危险模式。
//!
//! 黑盒断言（仅经由公共接口观测）：
//!   1. 反复成功 → 自动烧录为本能（instinct=true，hasInstincts()=true）。
//!   2. 阻尼抗遗忘：本能种子单次失败仅以 0.25× 学习率衰减（远小于普通软记忆）。
//!   3. 解除烧录：连续失败达阈值 → 本能降级回软记忆（instinct=false）。
//!   4. 本能反射注入行为栈 → 命中禁忌 context 的写/执行被毫秒级否决并归因冲突种子。

const std = @import("std");
const lib = @import("sovereign");
const harness = @import("harness.zig");

const Dir = std.Io.Dir;
const Action = lib.Action;

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    var chk = harness.Checker.init("测试五 持续学习与本能烧录（The Instinct Test）");

    // —— 阶段一：反复成功 → 烧录为本能 ——
    chk.section("阶段一：反复验证成功，软记忆烧录为本能");
    var mem = lib.MemoryManager.init(a);
    defer mem.deinit();
    const id = try mem.addSeed("deploy", "use atomic rename", 0.5);
    var ids = [_]u64{id};
    chk.check(!mem.get(id).?.instinct, "初始为软记忆（非本能）");
    var i: usize = 0;
    while (i < 5) : (i += 1) mem.updateConfidence(&ids, .success);
    chk.note("5 次成功后: conf={d:.2} success_count={d}", .{ mem.get(id).?.confidence, mem.get(id).?.success_count });
    chk.check(mem.get(id).?.instinct, "反复验证后自动烧录为本能 (instinct)");
    chk.check(mem.hasInstincts(), "记忆系统报告存在本能");

    // —— 阶段二：阻尼抗灾难性遗忘 ——
    chk.section("阶段二：本能享有阻尼，单次失败不被撼动");
    const before = mem.get(id).?.confidence; // 1.0
    mem.updateConfidence(&ids, .failure);
    const after = mem.get(id).?.confidence;
    chk.note("单次失败: {d:.4} -> {d:.4}（衰减 {d:.4}）", .{ before, after, before - after });
    chk.check(harness.approx(before - after, 0.025, 1e-9), "本能仅以 0.25× 学习率衰减（0.025，抗灾难性遗忘）");
    chk.check(mem.get(id).?.instinct, "单次失败后仍是本能");

    // —— 阶段三：连续失败 → 解除烧录 ——
    chk.section("阶段三：环境已变，连续失败解除烧录");
    mem.updateConfidence(&ids, .failure); // 连续第 2 次
    mem.updateConfidence(&ids, .failure); // 连续第 3 次（达阈值）
    chk.check(!mem.get(id).?.instinct, "连续失败达阈值 → 解除烧录，回归软记忆");
    chk.check(!mem.hasInstincts(), "记忆系统报告本能已清空");

    // —— 阶段四：本能反射注入行为栈，否决禁忌模式 ——
    chk.section("阶段四：烧录的禁忌作为最高优先级反射注入行为栈");
    var mem2 = lib.MemoryManager.init(a);
    defer mem2.deinit();
    const forbidden = try mem2.addSeed("prod-deploy", "forbid: never auto-deploy to prod", 0.95);
    mem2.get(forbidden).?.instinct = true; // 模拟已烧录的禁忌本能

    var stack: lib.BehaviorStack = .{};
    const layers = [_]lib.Layer{mem2.instinctReflex()};
    stack.reflexes = &layers;

    const bad: Action = .{ .id = 1, .action = .write, .context = "prod-deploy", .payload = "go" };
    const v_bad = try stack.evaluate(io, dir, bad, &.{});
    chk.check(!v_bad.ok, "命中禁忌 context 的写被本能反射否决");
    chk.check(v_bad.conflict_seed == forbidden, "否决被准确归因到那颗本能种子 (conflict_seed)");
    chk.check(std.mem.eql(u8, v_bad.layer, "L-1:instinct"), "裁决归因到最高优先级本能层 L-1:instinct");

    const ok: Action = .{ .id = 2, .action = .write, .context = "notes.md", .payload = "hello" };
    const v_ok = try stack.evaluate(io, dir, ok, &.{});
    chk.check(v_ok.ok, "不相关 context 不受本能反射影响（无误杀）");

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
