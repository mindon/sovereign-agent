//! 黑盒测试七：无状态路由拓扑 (The Stateless Routing Test)
//!
//! 猜想：因为 `rebuildState` 能从 append-only 账本**确定性重建**全部状态，
//! 处理节点便可**不持有任何跨请求状态**——连单调事务 id 也从账本派生。
//! 由此：读节点可水平 fan-out（只读副本，不改账本），写节点崩溃可热替换
//! （状态在账本不在节点），读写分离且与确定性重放形成审计闭环。
//!
//! 黑盒断言（仅经由公共接口 dispatch / rebuildState 观测）：
//!   1. 节点-1 处理首个写：从空账本派生 id=1 并提交。
//!   2. 全新节点-2（不共享内存状态）处理次个写：仍从账本派生 id=2（状态在账本）。
//!   3. 读请求路由到只读副本：服务自重放视图，**不改变账本记录数**。
//!   4. 写节点经 Arbiter 否决破坏性 execute：账本如实记录一条 rejected。
//!   5. 确定性重放对账：committed/rejected/max_id 与逐步操作完全一致。

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

    const path = ".example_routing_journal.jsonl";
    dir.deleteFile(io, path) catch {};
    defer dir.deleteFile(io, path) catch {};

    var chk = harness.Checker.init("测试七 无状态路由拓扑（The Stateless Routing Test）");

    // —— 节点-1 与节点-2：各自独立的 Arbiter/Memory，零共享内存 ——
    var arb1 = lib.Arbiter.init(io, dir);
    var mem1 = lib.MemoryManager.init(a);
    defer mem1.deinit();

    var arb2 = lib.Arbiter.init(io, dir);
    var mem2 = lib.MemoryManager.init(a);
    defer mem2.deinit();

    // —— 阶段一：节点-1 处理首个写，从空账本派生 id=1 ——
    chk.section("阶段一：节点-1 从空账本派生 id=1 并提交");
    const w1: Action = .{ .id = 0, .action = .write, .context = "cfg", .payload = "v1" };
    const r1 = try lib.dispatch(a, io, dir, path, w1, &arb1, &mem1);
    chk.check(r1.route == .commit_leader, "写请求路由到提交主节点 (commit_leader)");
    chk.check(r1.committed and r1.assigned_id == 1, "提交成功，派生 id=1");

    // —— 阶段二：全新节点-2（不共享内存）仍从账本派生 id=2 ——
    chk.section("阶段二：全新节点-2 从账本派生 id=2（状态在账本不在节点）");
    const w2: Action = .{ .id = 0, .action = .write, .context = "cfg", .payload = "v2" };
    const r2 = try lib.dispatch(a, io, dir, path, w2, &arb2, &mem2);
    chk.note("节点-2 与节点-1 不共享任何内存状态，id 仍单调递增 = {d}", .{r2.assigned_id});
    chk.check(r2.committed and r2.assigned_id == 2, "全新节点提交成功，派生 id=2（账本是唯一真相源）");

    // —— 阶段三：读请求路由到只读副本，不改账本 ——
    chk.section("阶段三：读路由到只读副本，账本记录数不变");
    var before = try lib.rebuildState(a, io, dir, path);
    const recs_before = before.total_records;
    before.deinit();
    const rd: Action = .{ .id = 0, .action = .read, .context = "cfg", .payload = "" };
    const rr = try lib.dispatch(a, io, dir, path, rd, &arb1, &mem1);
    chk.check(rr.route == .read_replica, "读请求路由到只读副本 (read_replica)");
    chk.check(!rr.committed, "只读副本不提交、不变更账本");
    var after_read = try lib.rebuildState(a, io, dir, path);
    const recs_after = after_read.total_records;
    after_read.deinit();
    chk.check(recs_before == recs_after, "读操作后账本记录数不变（可安全水平 fan-out）");

    // —— 阶段四：写节点经 Arbiter 否决破坏性 execute ——
    chk.section("阶段四：提交主节点经仲裁否决破坏性命令");
    const bad: Action = .{ .id = 0, .action = .execute, .context = "cleanup", .payload = "rm -rf /" };
    const rb = try lib.dispatch(a, io, dir, path, bad, &arb2, &mem2);
    chk.check(rb.route == .commit_leader and !rb.committed, "破坏性 execute 被仲裁否决，未提交");

    // —— 阶段五：确定性重放对账 ——
    chk.section("阶段五：确定性重放对账");
    var state = try lib.rebuildState(a, io, dir, path);
    defer state.deinit();
    chk.note("审计: committed={d} rejected={d} max_id={d} consistent={}", .{
        state.committed, state.rejected, state.max_id, state.isConsistent(),
    });
    chk.check(state.committed == 2, "重放对账：committed=2");
    chk.check(state.rejected == 1, "重放对账：rejected=1");
    chk.check(state.max_id == 3, "重放对账：max_id=3（两写 + 一否决）");
    chk.check(state.isConsistent(), "账本一致（无悬挂 pending）");

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
