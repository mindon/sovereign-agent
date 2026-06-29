//! Agent 驱动核心：AgentContext 与事务接口 `transact`。
//!
//! 强约束（确定性约束）：所有工具调用都必须经由 `transact`，从而保证
//!   检索种子 -> 仲裁预校验 -> 落账(pending) -> 执行 -> 提交/回滚
//! 这一闭环对每一次副作用都成立，不存在“绕过账本”的旁路。

const std = @import("std");
const event = @import("event.zig");
const journal_mod = @import("journal.zig");
const memory_mod = @import("memory.zig");
const arbiter_mod = @import("arbiter.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

const Action = event.Action;
const ActionType = event.ActionType;
const Journal = journal_mod.Journal;
const MemoryManager = memory_mod.MemoryManager;
const Outcome = memory_mod.Outcome;
const Arbiter = arbiter_mod.Arbiter;
const SeedClaim = arbiter_mod.SeedClaim;

pub const TransactError = error{
    VerificationFailed,
    ExecutionFailed,
} || Allocator.Error || anyerror;

/// 可插拔执行器：真正产生副作用的地方（写文件、调用工具…）。
/// do 返回是否成功；undo 用于回滚（仅在 do 之后被调用）。
pub const Executor = struct {
    ctx: *anyopaque,
    doFn: *const fn (ctx: *anyopaque, io: Io, dir: Dir, action: Action) anyerror!bool,
    undoFn: *const fn (ctx: *anyopaque, io: Io, dir: Dir, action: Action) anyerror!void,

    pub fn do(self: Executor, io: Io, dir: Dir, action: Action) !bool {
        return self.doFn(self.ctx, io, dir, action);
    }
    pub fn undo(self: Executor, io: Io, dir: Dir, action: Action) !void {
        return self.undoFn(self.ctx, io, dir, action);
    }
};

pub const AgentContext = struct {
    gpa: Allocator,
    io: Io,
    dir: Dir,
    journal: *Journal,
    memory: *MemoryManager,
    arbiter: *Arbiter,
    executor: ?Executor = null,
    next_id: u64 = 1,
    verbose: bool = false,

    // 统计
    committed: usize = 0,
    rejected: usize = 0,

    pub fn nextId(self: *AgentContext) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn log(self: *AgentContext, comptime fmt: []const u8, args: anytype) void {
        if (self.verbose) std.debug.print(fmt, args);
    }

    /// 执行动作的副作用。读/思考默认成功；写/执行委托给 executor。
    pub fn execute(self: *AgentContext, action: Action) !bool {
        switch (action.action) {
            .read, .think => return true,
            .write, .execute => {
                if (self.executor) |ex| return ex.do(self.io, self.dir, action);
                return true; // 无执行器时视为无副作用的成功
            },
        }
    }

    /// 回滚：撤销已执行的副作用。
    pub fn rollback(self: *AgentContext, action: Action) !void {
        if (self.executor) |ex| try ex.undo(self.io, self.dir, action);
    }

    /// 便捷封装：自动分配 id 并提交事务。
    pub fn submit(self: *AgentContext, action_type: ActionType, context: []const u8, payload: []const u8) !void {
        const a: Action = .{
            .id = self.nextId(),
            .action = action_type,
            .context = context,
            .payload = payload,
        };
        return transact(self, a);
    }
};

/// 由记忆种子 id 构造仲裁所需的断言视图。调用方负责释放返回切片。
fn buildClaims(ctx: *AgentContext, ids: []const u64) ![]SeedClaim {
    const claims = try ctx.gpa.alloc(SeedClaim, ids.len);
    for (ids, 0..) |id, i| {
        const s = ctx.memory.get(id).?;
        claims[i] = .{ .id = s.id, .confidence = s.confidence, .content = s.content };
    }
    return claims;
}

/// 核心事务接口。
pub fn transact(ctx: *AgentContext, action_in: Action) TransactError!void {
    var action = action_in;
    if (action.id == 0) action.id = ctx.nextId();

    // 1. 检索启发式种子（按置信度排序）。
    const seed_ids = try ctx.memory.fetchSeeds(ctx.gpa, action.context);
    defer ctx.gpa.free(seed_ids);
    // 将主导种子写入事件（若调用方未显式指定）。
    if (action.seed_ref == null and seed_ids.len > 0) action.seed_ref = seed_ids[0];

    const claims = try buildClaims(ctx, seed_ids);
    defer ctx.gpa.free(claims);

    // 2. 预校验（防幻觉探测）。
    if (!try ctx.arbiter.verify(action, claims)) {
        _ = try ctx.journal.append(action, .rejected);
        // 若是记忆-事实冲突：保留记忆，标记环境特异性例外（Open Decision #1）。
        if (ctx.arbiter.last.conflict_seed) |sid| {
            ctx.memory.markException(sid, ctx.arbiter.last.reason) catch {};
        }
        ctx.memory.updateConfidence(seed_ids, .failure);
        ctx.rejected += 1;
        ctx.log("[REJECT] #{d} {s} ctx={s}: {s}\n", .{ action.id, @tagName(action.action), action.context, ctx.arbiter.last.reason });
        return error.VerificationFailed;
    }

    // 3. 落账(pending) -> 执行 -> 提交/回滚。
    _ = try ctx.journal.append(action, .pending);
    const ok = ctx.execute(action) catch false;
    if (ok) {
        try ctx.journal.commit(action.id);
        ctx.memory.updateConfidence(seed_ids, .success);
        ctx.committed += 1;
        ctx.log("[COMMIT] #{d} {s} ctx={s}\n", .{ action.id, @tagName(action.action), action.context });
    } else {
        ctx.rollback(action) catch {};
        try ctx.journal.reject(action.id);
        ctx.memory.updateConfidence(seed_ids, .failure);
        ctx.rejected += 1;
        ctx.log("[ROLLBACK] #{d} {s} ctx={s}\n", .{ action.id, @tagName(action.action), action.context });
        return error.ExecutionFailed;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestHarness = struct {
    t: std.Io.Threaded,
    j: Journal,
    m: MemoryManager,
    arb: Arbiter,
    ctx: AgentContext,
    path: []const u8,

    fn setup(h: *TestHarness, path: []const u8) void {
        h.t = std.Io.Threaded.init(testing.allocator, .{});
        const io = h.t.io();
        const dir = Dir.cwd();
        dir.deleteFile(io, path) catch {};
        h.path = path;
        h.j = Journal.init(testing.allocator, io, dir, path);
        h.m = MemoryManager.init(testing.allocator);
        h.arb = Arbiter.init(io, dir);
        h.ctx = .{
            .gpa = testing.allocator,
            .io = io,
            .dir = dir,
            .journal = &h.j,
            .memory = &h.m,
            .arbiter = &h.arb,
        };
    }

    fn teardown(h: *TestHarness) void {
        const io = h.t.io();
        const dir = Dir.cwd();
        h.j.deinit();
        h.m.deinit();
        dir.deleteFile(io, h.path) catch {};
        h.t.deinit();
    }
};

test "transact commits a valid write and updates confidence up" {
    var h: TestHarness = undefined;
    h.setup(".test_tx_commit.jsonl");
    defer h.teardown();
    try h.j.ensureFile();

    const sid = try h.m.addSeed("cfg", "prefer atomic writes", 0.5);
    try h.ctx.submit(.write, "cfg", "valid-content");
    try testing.expectEqual(@as(usize, 1), h.ctx.committed);
    // 成功后置信度提升 0.1
    try testing.expectApproxEqAbs(@as(f64, 0.6), h.m.get(sid).?.confidence, 1e-9);
}

test "transact rejects on verification failure (empty payload)" {
    var h: TestHarness = undefined;
    h.setup(".test_tx_reject.jsonl");
    defer h.teardown();
    try h.j.ensureFile();

    const a: Action = .{ .id = 1, .action = .write, .context = "cfg", .payload = "" };
    try testing.expectError(error.VerificationFailed, transact(&h.ctx, a));
    try testing.expectEqual(@as(usize, 1), h.ctx.rejected);
}

test "anti-hallucination conflict marks contextual exception, keeps memory" {
    var h: TestHarness = undefined;
    h.setup(".test_tx_conflict.jsonl");
    defer h.teardown();
    try h.j.ensureFile();

    const sid = try h.m.addSeed("deploy", "assert_exists=__missing_path__.zzz", 0.9);
    const a: Action = .{ .id = 1, .action = .write, .context = "deploy", .payload = "do it" };
    try testing.expectError(error.VerificationFailed, transact(&h.ctx, a));
    // 记忆未删除，但被标记例外且置信度下调
    try testing.expect(h.m.get(sid).?.exception != null);
    try testing.expect(h.m.get(sid).?.confidence < 0.9);
}

test "rollback path on execution failure" {
    var h: TestHarness = undefined;
    h.setup(".test_tx_rollback.jsonl");
    defer h.teardown();
    try h.j.ensureFile();

    const Failing = struct {
        fn doFn(_: *anyopaque, _: Io, _: Dir, _: Action) anyerror!bool {
            return false; // 强制执行失败
        }
        fn undoFn(_: *anyopaque, _: Io, _: Dir, _: Action) anyerror!void {}
    };
    var dummy: u8 = 0;
    h.ctx.executor = .{ .ctx = @ptrCast(&dummy), .doFn = Failing.doFn, .undoFn = Failing.undoFn };

    const a: Action = .{ .id = 1, .action = .write, .context = "x", .payload = "p" };
    try testing.expectError(error.ExecutionFailed, transact(&h.ctx, a));
    try testing.expectEqual(@as(usize, 1), h.ctx.rejected);
}
