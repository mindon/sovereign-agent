//! 网络拓扑与无状态路由 (Stateless Routing Topology)
//!
//! 设计哲学：节点不持有状态，所有状态都在账本 (journal) 里携带 →
//! 可路由、可水平扩展、崩溃可热替换。任何节点拿到账本即可恢复全部状态。
//!
//! 与内核的契合（决定性前提）：
//!   * `rebuildState` 能从 append-only 账本**确定性重建**全部状态——
//!     这正是无状态节点的根基：连 `next_id` 也无需常驻内存，可从账本 `max_id+1` 派生。
//!   * 与 `ActionType.isSensitive` 的读写分流天然对齐：
//!       - read/think（非敏感）→ **只读副本节点**：从重放视图直接服务，**不写账本**，可 fan-out 水平扩展；
//!       - write/execute（敏感）→ **提交主节点**：串行化地落账，保证账本线性。
//!
//! 安全性：节点仅向显式账本文件追加、仅经 Arbiter 物理校验后提交；不执行 shell。

const std = @import("std");
const event = @import("event.zig");
const journal_mod = @import("journal.zig");
const memory_mod = @import("memory.zig");
const arbiter_mod = @import("arbiter.zig");
const agent_mod = @import("agent.zig");
const replay_mod = @import("replay.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

const Action = event.Action;
const Journal = journal_mod.Journal;
const MemoryManager = memory_mod.MemoryManager;
const Arbiter = arbiter_mod.Arbiter;
const AgentContext = agent_mod.AgentContext;
const transact = agent_mod.transact;
const rebuildState = replay_mod.rebuildState;

/// 路由目标节点类型。
pub const Route = enum {
    /// 只读副本：服务 read/think，从账本重放视图派生答案，不可变更账本。
    read_replica,
    /// 提交主节点：服务 write/execute，串行化落账。
    commit_leader,
};

/// 一次无状态调度的结果。
pub const RouteResult = struct {
    route: Route,
    /// 是否成功提交（仅 commit_leader 路径有意义）。
    committed: bool = false,
    /// 本次从账本派生分配的事务 id（read 路径为 0）。
    assigned_id: u64 = 0,
    /// 人类可读说明 / 失败原因（静态字符串）。
    reason: []const u8 = "",
};

/// 纯函数路由：按动作敏感性决定目标节点。
pub fn route(action: Action) Route {
    return if (action.action.isSensitive()) .commit_leader else .read_replica;
}

/// 无状态调度：节点本身不持任何跨请求状态，全部状态来自 `path` 指向的账本。
///
/// * read/think → 只读副本：`rebuildState` 派生当前视图后直接服务（不写账本）；
/// * write/execute → 提交主节点：从账本 `max_id+1` 派生 next_id，
///   现场构造临时 `Journal`/`AgentContext` 走 `transact` 闭环，提交后即销毁——
///   节点不残留任何状态。
pub fn dispatch(
    gpa: Allocator,
    io: Io,
    dir: Dir,
    path: []const u8,
    action_in: Action,
    arb: *Arbiter,
    mem: *MemoryManager,
) !RouteResult {
    switch (route(action_in)) {
        .read_replica => {
            // 只读副本：纯从账本重放派生，不变更账本（可水平 fan-out）。
            var state = try rebuildState(gpa, io, dir, path);
            defer state.deinit();
            return .{
                .route = .read_replica,
                .committed = false,
                .assigned_id = 0,
                .reason = if (state.isConsistent())
                    "read served from replica (ledger consistent)"
                else
                    "read served from replica (ledger inconsistent)",
            };
        },
        .commit_leader => {
            // 关键：next_id 从账本派生，而非节点内存——证明状态在账本不在节点。
            var state = try rebuildState(gpa, io, dir, path);
            const next = state.max_id + 1;
            state.deinit();

            var j = Journal.init(gpa, io, dir, path);
            defer j.deinit();
            try j.ensureFile();

            var ctx: AgentContext = .{
                .gpa = gpa,
                .io = io,
                .dir = dir,
                .journal = &j,
                .memory = mem,
                .arbiter = arb,
                .next_id = next,
            };

            var action = action_in;
            action.id = next; // 由账本派生的 id

            if (transact(&ctx, action)) |_| {
                return .{ .route = .commit_leader, .committed = true, .assigned_id = next, .reason = "committed" };
            } else |err| {
                return .{ .route = .commit_leader, .committed = false, .assigned_id = next, .reason = @errorName(err) };
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "router routes by sensitivity" {
    const w: Action = .{ .id = 0, .action = .write, .context = "f", .payload = "p" };
    const r: Action = .{ .id = 0, .action = .read, .context = "f", .payload = "" };
    const x: Action = .{ .id = 0, .action = .execute, .context = "f", .payload = "p" };
    const th: Action = .{ .id = 0, .action = .think, .context = "f", .payload = "" };
    try testing.expectEqual(Route.commit_leader, route(w));
    try testing.expectEqual(Route.commit_leader, route(x));
    try testing.expectEqual(Route.read_replica, route(r));
    try testing.expectEqual(Route.read_replica, route(th));
}

const RouterHarness = struct {
    t: std.Io.Threaded,
    m: MemoryManager,
    arb: Arbiter,
    path: []const u8,

    fn setup(h: *RouterHarness, path: []const u8) void {
        h.t = std.Io.Threaded.init(testing.allocator, .{});
        const io = h.t.io();
        const dir = Dir.cwd();
        dir.deleteFile(io, path) catch {};
        h.path = path;
        h.m = MemoryManager.init(testing.allocator);
        h.arb = Arbiter.init(io, dir);
    }
    fn teardown(h: *RouterHarness) void {
        const io = h.t.io();
        Dir.cwd().deleteFile(io, h.path) catch {};
        h.m.deinit();
        h.t.deinit();
    }
};

test "stateless nodes derive monotonic ids from the ledger" {
    var h: RouterHarness = undefined;
    h.setup(".test_router_ids.jsonl");
    defer h.teardown();
    const io = h.t.io();
    const dir = Dir.cwd();
    const gpa = testing.allocator;

    // “节点 1”处理第一个写：从空账本派生 id=1。
    const a1: Action = .{ .id = 0, .action = .write, .context = "cfg", .payload = "v1" };
    const r1 = try dispatch(gpa, io, dir, h.path, a1, &h.arb, &h.m);
    try testing.expect(r1.committed);
    try testing.expectEqual(@as(u64, 1), r1.assigned_id);

    // “节点 2”全新、未共享任何内存状态：仍从账本派生 id=2（状态在账本）。
    const a2: Action = .{ .id = 0, .action = .write, .context = "cfg", .payload = "v2" };
    const r2 = try dispatch(gpa, io, dir, h.path, a2, &h.arb, &h.m);
    try testing.expect(r2.committed);
    try testing.expectEqual(@as(u64, 2), r2.assigned_id);

    // 账本重放对账：两次提交、max_id=2、一致。
    var state = try rebuildState(gpa, io, dir, h.path);
    defer state.deinit();
    try testing.expectEqual(@as(usize, 2), state.committed);
    try testing.expectEqual(@as(u64, 2), state.max_id);
    try testing.expect(state.isConsistent());
}

test "read replica serves from rebuilt state without mutating ledger" {
    var h: RouterHarness = undefined;
    h.setup(".test_router_read.jsonl");
    defer h.teardown();
    const io = h.t.io();
    const dir = Dir.cwd();
    const gpa = testing.allocator;

    // 先提交一个写。
    const w: Action = .{ .id = 0, .action = .write, .context = "cfg", .payload = "v1" };
    _ = try dispatch(gpa, io, dir, h.path, w, &h.arb, &h.m);

    var before = try rebuildState(gpa, io, dir, h.path);
    const recs_before = before.total_records;
    before.deinit();

    // 读路径走只读副本：不应改变账本记录数。
    const r: Action = .{ .id = 0, .action = .read, .context = "cfg", .payload = "" };
    const rr = try dispatch(gpa, io, dir, h.path, r, &h.arb, &h.m);
    try testing.expectEqual(Route.read_replica, rr.route);
    try testing.expect(!rr.committed);

    var after = try rebuildState(gpa, io, dir, h.path);
    defer after.deinit();
    try testing.expectEqual(recs_before, after.total_records); // 账本未被读操作变更
}

test "commit leader rejects a dangerous execute via arbiter" {
    var h: RouterHarness = undefined;
    h.setup(".test_router_reject.jsonl");
    defer h.teardown();
    const io = h.t.io();
    const dir = Dir.cwd();
    const gpa = testing.allocator;

    const bad: Action = .{ .id = 0, .action = .execute, .context = "cleanup", .payload = "rm -rf /" };
    const res = try dispatch(gpa, io, dir, h.path, bad, &h.arb, &h.m);
    try testing.expectEqual(Route.commit_leader, res.route);
    try testing.expect(!res.committed);
    // 账本应记录一条 rejected。
    var state = try rebuildState(gpa, io, dir, h.path);
    defer state.deinit();
    try testing.expectEqual(@as(usize, 1), state.rejected);
}
