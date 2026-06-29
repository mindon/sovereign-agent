//! 测试一：幻觉拦截与惩罚测试（The Sabotage Test）
//!
//! 猜想：一条**高置信度的幻觉记忆**（断言一个并不存在的发布二进制）即便被
//! Agent 完全信任并据此提议写操作，也必然在 `transact` 的零信任仲裁中被拦截，
//! 且该破坏性种子会受到**惩罚**——置信度下调 + 标记 Contextual Exception，
//! 同时**不污染**对正常操作的处理（无误杀）。
//!
//! 黑盒断言（仅经由公共接口观测）：
//!   1. 受幻觉驱动的写操作返回 error.VerificationFailed（被拦截）。
//!   2. 拦截原因被准确归因到那颗幻觉种子（conflict_seed）。
//!   3. 该种子受罚：置信度 0.90 -> 0.55（markException -0.25，failure -0.10），
//!      信任层级由 trusted 跌至 medium，且被打上环境特异性例外。
//!   4. 记忆未被删除（非完美记忆原则：保留历史 + 修正因子）。
//!   5. 一条正常写入仍被正确提交（无误杀），账本最终一致。

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

    const journal_path = ".example_sabotage_journal.jsonl";
    dir.deleteFile(io, journal_path) catch {};

    var journal = lib.Journal.init(a, io, dir, journal_path);
    defer journal.deinit();
    try journal.ensureFile();

    var memory = lib.MemoryManager.init(a);
    defer memory.deinit();

    var arbiter = lib.Arbiter.init(io, dir);

    var ctx: lib.AgentContext = .{
        .gpa = a,
        .io = io,
        .dir = dir,
        .journal = &journal,
        .memory = &memory,
        .arbiter = &arbiter,
        // 无执行器：写操作若通过仲裁即视为无副作用地成功提交（便于黑盒观察）。
    };

    var chk = harness.Checker.init("测试一 幻觉拦截与惩罚（The Sabotage Test）");

    // —— 注入记忆：一颗正常种子 + 一颗高置信度幻觉“破坏种子” ——
    _ = try memory.addSeed("config.json", "service config is JSON with keys port and host", 0.80);
    const sabotage = try memory.addSeed(
        "deploy",
        "assert_exists=/opt/ghost/__nonexistent_release__/bin",
        0.90,
    );
    const initial_conf = memory.get(sabotage).?.confidence;
    chk.note("破坏种子 #{d} 初始: conf={d:.2} tier={s}", .{
        sabotage, initial_conf, @tagName(memory.get(sabotage).?.tier()),
    });

    // —— 阶段一：Agent 听信幻觉，提议写一个“启动幻影二进制”的脚本 ——
    chk.section("阶段一：受幻觉驱动的写操作必须被拦截");
    const sabotage_payload = "#!/bin/sh\nexec /opt/ghost/__nonexistent_release__/bin --serve\n";
    const result = ctx.submit(.write, "deploy", sabotage_payload);
    chk.check(result == error.VerificationFailed, "幻觉驱动的写操作被仲裁拒绝 (VerificationFailed)");
    chk.check(ctx.rejected == 1 and ctx.committed == 0, "账本计数：rejected=1, committed=0");
    chk.check(
        std.mem.indexOf(u8, arbiter.last.reason, "hallucination") != null,
        "拦截原因为防幻觉冲突",
    );
    chk.check(arbiter.last.conflict_seed == sabotage, "拦截被准确归因到那颗幻觉种子 (conflict_seed)");

    // —— 阶段二：破坏种子受到惩罚（不删除，但下调置信度 + 标记例外）——
    chk.section("阶段二：破坏种子受罚（惩罚机制）");
    const s = memory.get(sabotage).?;
    chk.note("受罚后: conf={d:.2} tier={s} exception={?s}", .{ s.confidence, @tagName(s.tier()), s.exception });
    chk.check(s.confidence < initial_conf, "置信度被下调（受到惩罚）");
    chk.check(harness.approx(s.confidence, 0.55, 1e-9), "置信度精确演化至 0.55（-0.25 例外 + -0.10 失败）");
    chk.check(s.tier() == .medium, "信任层级由 trusted 跌至 medium");
    chk.check(s.exception != null, "被打上环境特异性例外 (Contextual Exception)");
    chk.check(memory.get(sabotage) != null, "记忆未被删除（保留历史 + 修正因子）");

    // —— 阶段三：正常写入不受牵连（无误杀），账本一致 ——
    chk.section("阶段三：正常操作无误杀，账本一致");
    try ctx.submit(.write, "config.json", "{\"port\":8080,\"host\":\"0.0.0.0\"}");
    chk.check(ctx.committed == 1, "一条合法写入被正确提交（无误杀）");

    var state = try lib.rebuildState(a, io, dir, journal_path);
    defer state.deinit();
    chk.note("审计: committed={d} rejected={d} consistent={}", .{ state.committed, state.rejected, state.isConsistent() });
    chk.check(state.committed == 1 and state.rejected == 1, "确定性重放：committed=1, rejected=1");
    chk.check(state.isConsistent(), "账本一致（无悬挂 pending）");

    dir.deleteFile(io, journal_path) catch {};

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
