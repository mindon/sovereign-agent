//! 事件存储系统 (Journal System)
//!
//! 采用不可变的 append-only JSONL 事件流。每一次状态迁移
//! （pending -> committed / rejected）都作为一条新的事件记录被追加写入，
//! 历史永不被覆盖。当前状态 = 对账本按 id 折叠后保留最新状态。
//!
//! 安全性：仅向工作目录下的固定账本文件追加写入；不执行任何 shell。

const std = @import("std");
const event = @import("event.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const Action = event.Action;
const Event = event.Event;
const EventStatus = event.EventStatus;

pub const Journal = struct {
    gpa: Allocator,
    /// 用于持有 pending 事件 payload 的拷贝，生命周期与 Journal 一致。
    arena: std.heap.ArenaAllocator,
    io: Io,
    dir: Dir,
    path: []const u8,
    /// 内存中维护的“待提交事件”视图，便于 commit(id)/reject(id) 重建完整记录。
    pending: std.AutoHashMapUnmanaged(u64, Event) = .empty,
    /// 已落账（任意状态）的事件计数，仅用于统计。
    appended: u64 = 0,

    pub fn init(gpa: Allocator, io: Io, dir: Dir, path: []const u8) Journal {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .io = io,
            .dir = dir,
            .path = path,
        };
    }

    pub fn deinit(self: *Journal) void {
        self.pending.deinit(self.gpa);
        self.arena.deinit();
    }

    /// 确保账本文件存在（不存在则创建，存在则保留内容，不截断）。
    pub fn ensureFile(self: *Journal) !void {
        var file = try self.dir.createFile(self.io, self.path, .{ .truncate = false, .read = true });
        file.close(self.io);
    }

    /// 低层：向账本追加一行 JSON 事件记录。
    fn writeLine(self: *Journal, ev: Event) !void {
        var file = try self.dir.createFile(self.io, self.path, .{ .truncate = false, .read = true });
        defer file.close(self.io);
        const end = try file.length(self.io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &buf);
        fw.pos = end;
        const w = &fw.interface;
        try ev.writeJson(w);
        try w.writeByte('\n');
        try w.flush();
        self.appended += 1;
    }

    /// 追加一条事件记录（来自 Action）。返回事件 id。
    pub fn append(self: *Journal, action: Action, status: EventStatus) !u64 {
        const ts = std.Io.Timestamp.now(self.io, .real).toSeconds();
        var ev = Event.fromAction(action, status, ts);
        // pending 事件需在内存留存其 payload 副本，供后续 commit/reject 复用。
        const owned_payload = try self.arena.allocator().dupe(u8, action.payload);
        ev.payload = owned_payload;
        try self.writeLine(ev);
        if (status == .pending) {
            try self.pending.put(self.gpa, ev.id, ev);
        }
        return ev.id;
    }

    /// 将某 pending 事件提交（pending -> committed）：追加一条 committed 记录。
    pub fn commit(self: *Journal, id: u64) !void {
        try self.transition(id, .committed);
    }

    /// 将某 pending 事件拒绝（pending -> rejected）：追加一条 rejected 记录。
    pub fn reject(self: *Journal, id: u64) !void {
        try self.transition(id, .rejected);
    }

    fn transition(self: *Journal, id: u64, status: EventStatus) !void {
        const entry = self.pending.get(id) orelse return error.UnknownEvent;
        var ev = entry;
        ev.status = status;
        ev.timestamp = std.Io.Timestamp.now(self.io, .real).toSeconds();
        try self.writeLine(ev);
        _ = self.pending.remove(id);
    }

    /// 直接追加一条已构造好的事件记录（用于测试 / 外部注入）。
    pub fn record(self: *Journal, ev: Event) !void {
        try self.writeLine(ev);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "append then commit writes two lines, pending cleared" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = Dir.cwd();

    const path = ".test_journal_commit.jsonl";
    dir.deleteFile(io, path) catch {};

    var j = Journal.init(testing.allocator, io, dir, path);
    defer j.deinit();
    try j.ensureFile();

    const a: Action = .{ .id = 1, .action = .write, .context = "f.txt", .payload = "data", .seed_ref = 5 };
    const id = try j.append(a, .pending);
    try testing.expectEqual(@as(u64, 1), id);
    try testing.expect(j.pending.contains(1));
    try j.commit(1);
    try testing.expect(!j.pending.contains(1));

    const data = try dir.readFileAlloc(io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(data);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |l| {
        if (l.len != 0) lines += 1;
    }
    try testing.expectEqual(@as(usize, 2), lines);
    try testing.expect(std.mem.indexOf(u8, data, "\"status\":\"committed\"") != null);

    dir.deleteFile(io, path) catch {};
}

test "reject unknown event errors" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = Dir.cwd();
    const path = ".test_journal_reject.jsonl";
    dir.deleteFile(io, path) catch {};

    var j = Journal.init(testing.allocator, io, dir, path);
    defer j.deinit();
    try j.ensureFile();

    try testing.expectError(error.UnknownEvent, j.reject(999));
    dir.deleteFile(io, path) catch {};
}
