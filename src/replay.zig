//! 确定性重放与审计 (Deterministic Replay & Audit)
//!
//! 设计哲学：状态不可变 + 可审计。通过读取 append-only 的 `journal.jsonl`，
//! 从初始空状态按 id 折叠（保留每个事务的最新状态），即可确定性地重建当前状态，
//! 并验证账本一致性（不存在悬挂的 pending 事务）。

const std = @import("std");
const event = @import("event.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

const Event = event.Event;
const ActionType = event.ActionType;
const EventStatus = event.EventStatus;

/// 重建后的状态视图。
pub const StateView = struct {
    arena: std.heap.ArenaAllocator,
    /// 每个事务 id 的最新事件（折叠结果即“当前状态”）。
    latest: std.AutoHashMapUnmanaged(u64, Event) = .empty,
    /// 账本中读取到的原始记录总行数。
    total_records: usize = 0,
    committed: usize = 0,
    rejected: usize = 0,
    pending: usize = 0,
    max_id: u64 = 0,

    pub fn deinit(self: *StateView) void {
        self.latest.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    /// 账本一致性：所有事务都已到达终态（无悬挂 pending）。
    pub fn isConsistent(self: *const StateView) bool {
        return self.pending == 0;
    }

    /// 生成人类可读的审计报告（调用方释放）。
    pub fn renderAudit(self: *StateView, gpa: Allocator) ![]u8 {
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.print(
            \\<audit>
            \\  records_total : {d}
            \\  transactions  : {d}
            \\  committed     : {d}
            \\  rejected      : {d}
            \\  pending       : {d}
            \\  max_id        : {d}
            \\  consistent    : {}
            \\</audit>
            \\
        , .{
            self.total_records,
            self.latest.count(),
            self.committed,
            self.rejected,
            self.pending,
            self.max_id,
            self.isConsistent(),
        });
        return w.toOwnedSlice();
    }
};

/// 与 JSONL 行一一对应的解析结构。
const Record = struct {
    id: u64,
    timestamp: i64,
    action: ActionType,
    payload: []const u8,
    seed_ref: ?u64,
    status: EventStatus,
};

/// 从账本文件确定性地重建状态。
pub fn rebuildState(gpa: Allocator, io: Io, dir: Dir, path: []const u8) !StateView {
    var state: StateView = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer state.deinit();
    const aa = state.arena.allocator();

    const data = dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return state, // 空账本 = 初始状态
        else => return err,
    };
    defer gpa.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        state.total_records += 1;

        const parsed = std.json.parseFromSlice(Record, gpa, line, .{}) catch {
            return error.CorruptJournal;
        };
        defer parsed.deinit();
        const r = parsed.value;

        // 折叠：保留每个 id 的最新记录（payload 复制进 arena 以延长生命周期）。
        const ev: Event = .{
            .id = r.id,
            .timestamp = r.timestamp,
            .action = r.action,
            .payload = try aa.dupe(u8, r.payload),
            .seed_ref = r.seed_ref,
            .status = r.status,
        };
        try state.latest.put(gpa, r.id, ev);
        if (r.id > state.max_id) state.max_id = r.id;
    }

    // 依据折叠后的最终状态统计。
    var vit = state.latest.valueIterator();
    while (vit.next()) |ev| {
        switch (ev.status) {
            .committed => state.committed += 1,
            .rejected => state.rejected += 1,
            .pending => state.pending += 1,
        }
    }
    return state;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Journal = @import("journal.zig").Journal;
const Action = event.Action;

test "rebuildState folds latest status per id" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = Dir.cwd();
    const path = ".test_replay_fold.jsonl";
    dir.deleteFile(io, path) catch {};

    var j = Journal.init(testing.allocator, io, dir, path);
    try j.ensureFile();
    const a1: Action = .{ .id = 1, .action = .write, .context = "c", .payload = "p1" };
    _ = try j.append(a1, .pending);
    try j.commit(1); // id=1 终态 committed
    const a2: Action = .{ .id = 2, .action = .write, .context = "c", .payload = "p2" };
    _ = try j.append(a2, .pending);
    try j.reject(2); // id=2 终态 rejected
    j.deinit();

    var state = try rebuildState(testing.allocator, io, dir, path);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 4), state.total_records); // 2 pending + commit + reject
    try testing.expectEqual(@as(usize, 2), state.latest.count());
    try testing.expectEqual(@as(usize, 1), state.committed);
    try testing.expectEqual(@as(usize, 1), state.rejected);
    try testing.expectEqual(@as(usize, 0), state.pending);
    try testing.expect(state.isConsistent());
    try testing.expectEqual(EventStatus.committed, state.latest.get(1).?.status);
    try testing.expectEqual(EventStatus.rejected, state.latest.get(2).?.status);

    dir.deleteFile(io, path) catch {};
}

test "dangling pending detected as inconsistent" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = Dir.cwd();
    const path = ".test_replay_pending.jsonl";
    dir.deleteFile(io, path) catch {};

    var j = Journal.init(testing.allocator, io, dir, path);
    try j.ensureFile();
    const a1: Action = .{ .id = 1, .action = .write, .context = "c", .payload = "p1" };
    _ = try j.append(a1, .pending); // 不提交
    j.deinit();

    var state = try rebuildState(testing.allocator, io, dir, path);
    defer state.deinit();
    try testing.expectEqual(@as(usize, 1), state.pending);
    try testing.expect(!state.isConsistent());

    dir.deleteFile(io, path) catch {};
}

test "missing journal yields empty initial state" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = Dir.cwd();
    const path = ".test_replay_missing.jsonl";
    dir.deleteFile(io, path) catch {};

    var state = try rebuildState(testing.allocator, io, dir, path);
    defer state.deinit();
    try testing.expectEqual(@as(usize, 0), state.total_records);
    try testing.expect(state.isConsistent());
}
