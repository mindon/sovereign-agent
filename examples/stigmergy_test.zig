//! 黑盒测试六：环境计算与去中心化协同 (The Stigmergy Test)
//!
//! 猜想：两个**零通信、不共享任何内存状态**的 agent 实例，可仅经由文件系统
//! 留下/读取“信息素”足迹实现间接协同（蚂蚁隐喻）；足迹随时间按半衰期衰减，
//! 使环境变化时旧经验自然淡出（契合 Contextual Exception，无需删记忆）；
//! 环境实测足迹可与记忆软置信度融合，抬升被环境反复验证的策略的排序。
//!
//! 黑盒断言（仅经由公共接口观测）：
//!   1. agent-A 留下足迹后，全新的 agent-B 能感知到（经文件系统协同，非内存）。
//!   2. 经过一个半衰期，强度衰减为一半（旧足迹自然淡出）。
//!   3. 叠加：新足迹在衰减后的旧值之上累积。
//!   4. 融合检索：环境强足迹使一个软置信度更低的策略反超排序（去中心化协同）。

const std = @import("std");
const lib = @import("sovereign");
const harness = @import("harness.zig");

const Dir = std.Io.Dir;

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    var chk = harness.Checker.init("测试六 环境计算与去中心化协同（The Stigmergy Test）");

    const ctx_key = "deploy:strategy-blue";

    // —— 阶段一：两个独立 agent 经文件系统协同（零内存共享） ——
    chk.section("阶段一：agent-A 留痕，全新 agent-B 感知（经环境而非内存）");
    var agent_a = lib.Stigmergy.init(a); // 模拟进程 A 的实例
    agent_a.half_life_s = 100;
    agent_a.clear(io, dir, ctx_key);
    defer agent_a.clear(io, dir, ctx_key);

    try agent_a.deposit(io, dir, ctx_key, 4.0, 1000);

    var agent_b = lib.Stigmergy.init(a); // 全新实例，不共享 agent_a 的任何字段
    agent_b.half_life_s = 100;
    const sensed = try agent_b.sense(io, dir, ctx_key, 1000); // dt=0
    chk.note("agent-B 感知强度 = {d:.4}", .{sensed});
    chk.check(harness.approx(sensed, 4.0, 1e-6), "全新 agent-B 经文件系统感知到 agent-A 的足迹");

    // —— 阶段二：半衰期衰减（旧足迹自然淡出） ——
    chk.section("阶段二：经过一个半衰期，强度衰减为一半");
    const decayed = try agent_b.sense(io, dir, ctx_key, 1100); // 经过 half_life_s=100
    chk.note("一个半衰期后 = {d:.4}", .{decayed});
    chk.check(harness.approx(decayed, 2.0, 1e-6), "强度衰减为一半（4.0 -> 2.0）");

    // —— 阶段三：足迹在衰减后的旧值之上累积 ——
    chk.section("阶段三：新足迹在衰减后的旧值上累积");
    try agent_b.deposit(io, dir, ctx_key, 1.0, 1100); // 衰减到 2.0 后 +1.0
    const acc = try agent_b.sense(io, dir, ctx_key, 1100);
    chk.check(harness.approx(acc, 3.0, 1e-6), "叠加结果 = 2.0 + 1.0 = 3.0");

    // —— 阶段四：环境足迹融合，重排序记忆 ——
    chk.section("阶段四：环境强足迹使低软置信度策略反超排序");
    var mem = lib.MemoryManager.init(a);
    defer mem.deinit();
    const sa = try mem.addSeed("rollout", "strategy-A", 0.60); // 软置信度更高
    const sb = try mem.addSeed("rollout", "strategy-B", 0.50); // 软置信度更低

    var field = lib.Stigmergy.init(a);
    field.clear(io, dir, "strategy-A");
    field.clear(io, dir, "strategy-B");
    defer field.clear(io, dir, "strategy-A");
    defer field.clear(io, dir, "strategy-B");

    // 纯软置信度：A 在前。
    const plain = try mem.fetchSeeds(a, "rollout");
    defer a.free(plain);
    chk.check(plain.len == 2 and plain[0] == sa, "纯软记忆排序：strategy-A 居首");

    // 环境中 strategy-B 被反复验证成功（强足迹）。
    try field.deposit(io, dir, "strategy-B", 5.0, 1000);
    const blended = try mem.fetchSeedsBlended(a, io, dir, &field, "rollout", 1000, 0.5);
    defer a.free(blended);
    chk.note("融合后首位 = seed#{d}（strategy-B={d}）", .{ blended[0], sb });
    chk.check(blended.len == 2 and blended[0] == sb, "融合环境足迹后：strategy-B 反超居首（去中心化协同）");

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
