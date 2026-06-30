//! 环境计算 (Stigmergy) —— 环境本身充当数据库与状态机。
//!
//! 设计哲学：不靠中央内存协同，而是把“足迹”写进环境（信息素 pheromone），
//! 后来者读环境感知前者，实现去中心化的间接协同（蚂蚁信息素隐喻）。
//!
//! 与内核的契合：
//!   * `journal.jsonl` 是 append-only 的“环境真相源”，Arbiter 的物理 Probe 已是“读环境”；
//!     本模块补上**反向写信息素**与**时间衰减**，让足迹随环境变化自然淡出——
//!     这天然契合 Contextual Exception：环境变了，旧足迹自动衰减，而非删除记忆。
//!   * 信息素强度可与记忆软置信度融合（见 `blend`），供 `fetchSeedsBlended` 排序。
//!
//! 安全性：信息素以**扁平文件名**存于工作目录（context 经 `sanitize` 净化，
//! 非 [A-Za-z0-9._-] 一律替换为 '_'，'/' 被消除），不拼接路径、不可穿越；
//! 不执行任何 shell。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

/// 基于文件系统的信息素场。强度随时间按半衰期指数衰减。
pub const Stigmergy = struct {
    gpa: Allocator,
    /// 信息素文件名前缀（扁平存于工作目录，不建子目录、不拼路径）。
    prefix: []const u8 = ".sovereign.phero.",
    /// 半衰期（秒）：经过该时长后强度衰减为一半。
    half_life_s: i64 = 3600,

    pub fn init(gpa: Allocator) Stigmergy {
        return .{ .gpa = gpa };
    }

    /// 构造某 context 的信息素文件名（净化后写入 buf，返回切片）。
    fn buildPath(self: Stigmergy, buf: []u8, context: []const u8) ![]const u8 {
        const suffix = ".phero";
        if (self.prefix.len + context.len + suffix.len > buf.len) return error.NameTooLong;
        var i: usize = 0;
        for (self.prefix) |c| {
            buf[i] = c;
            i += 1;
        }
        for (context) |c| {
            buf[i] = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_';
            i += 1;
        }
        for (suffix) |c| {
            buf[i] = c;
            i += 1;
        }
        return buf[0..i];
    }

    /// 感知：读取某 context 的当前信息素强度（按 now 衰减）。不存在则返回 0。
    pub fn sense(self: Stigmergy, io: Io, dir: Dir, context: []const u8, now: i64) !f64 {
        var pbuf: [512]u8 = undefined;
        const path = try self.buildPath(&pbuf, context);

        const data = dir.readFileAlloc(io, path, self.gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return 0.0,
            else => return err,
        };
        defer self.gpa.free(data);

        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const s_str = it.next() orelse return 0.0;
        const ts_str = it.next() orelse return 0.0;
        const strength = std.fmt.parseFloat(f64, s_str) catch return 0.0;
        const ts = std.fmt.parseInt(i64, ts_str, 10) catch return 0.0;

        const dt = now - ts;
        if (dt <= 0) return strength;
        const factor = std.math.pow(
            f64,
            0.5,
            @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(self.half_life_s)),
        );
        return strength * factor;
    }

    /// 留下足迹：在 context 上叠加强度（先把现有强度衰减到 now，再叠加 delta）。
    /// 成功足迹用正 delta，失败/危险足迹可用负 delta。
    pub fn deposit(self: Stigmergy, io: Io, dir: Dir, context: []const u8, delta: f64, now: i64) !void {
        const cur = try self.sense(io, dir, context, now);
        const next = cur + delta;

        var pbuf: [512]u8 = undefined;
        const path = try self.buildPath(&pbuf, context);

        var file = try dir.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var wbuf: [128]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        const w = &fw.interface;
        try w.print("{d:.10} {d}\n", .{ next, now });
        try w.flush();
    }

    /// 清除某 context 的信息素（测试/重置用）。
    pub fn clear(self: Stigmergy, io: Io, dir: Dir, context: []const u8) void {
        var pbuf: [512]u8 = undefined;
        const path = self.buildPath(&pbuf, context) catch return;
        dir.deleteFile(io, path) catch {};
    }
};

/// 把无界的信息素强度归一为 [0,1) 的“环境实测置信度”。
pub fn envConfidence(strength: f64) f64 {
    if (strength <= 0.0) return 0.0;
    return 1.0 - @exp(-strength);
}

/// 融合：记忆软置信度 × 环境实测置信度。w 为记忆权重（0..1）。
pub fn blend(seed_conf: f64, strength: f64, w: f64) f64 {
    const env = envConfidence(strength);
    return std.math.clamp(w * seed_conf + (1.0 - w) * env, 0.0, 1.0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "deposit then immediate sense returns full strength" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = Dir.cwd();

    var field = Stigmergy.init(testing.allocator);
    const ctx = "build:unit-stig-1";
    field.clear(io, dir, ctx);
    defer field.clear(io, dir, ctx);

    try field.deposit(io, dir, ctx, 1.0, 1000);
    const s = try field.sense(io, dir, ctx, 1000); // dt=0，无衰减
    try testing.expectApproxEqAbs(@as(f64, 1.0), s, 1e-6);
}

test "strength decays by half over one half-life" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = Dir.cwd();

    var field = Stigmergy.init(testing.allocator);
    field.half_life_s = 100;
    const ctx = "build:unit-stig-2";
    field.clear(io, dir, ctx);
    defer field.clear(io, dir, ctx);

    try field.deposit(io, dir, ctx, 2.0, 0);
    const s = try field.sense(io, dir, ctx, 100); // 经过一个半衰期
    try testing.expectApproxEqAbs(@as(f64, 1.0), s, 1e-6);
}

test "deposit accumulates on top of decayed value" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = Dir.cwd();

    var field = Stigmergy.init(testing.allocator);
    field.half_life_s = 100;
    const ctx = "build:unit-stig-3";
    field.clear(io, dir, ctx);
    defer field.clear(io, dir, ctx);

    try field.deposit(io, dir, ctx, 2.0, 0);
    try field.deposit(io, dir, ctx, 1.0, 100); // 衰减到 1.0 再叠加 1.0 = 2.0
    const s = try field.sense(io, dir, ctx, 100);
    try testing.expectApproxEqAbs(@as(f64, 2.0), s, 1e-6);
}

test "sense of unknown context is zero" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = Dir.cwd();
    var field = Stigmergy.init(testing.allocator);
    const s = try field.sense(io, dir, "build:never-deposited-xyz", 0);
    try testing.expectEqual(@as(f64, 0.0), s);
}

test "envConfidence and blend are monotonic & bounded" {
    try testing.expectEqual(@as(f64, 0.0), envConfidence(0.0));
    try testing.expect(envConfidence(1.0) > 0.0 and envConfidence(1.0) < 1.0);
    try testing.expect(envConfidence(5.0) > envConfidence(1.0));
    // 环境强足迹抬升融合分数。
    const low = blend(0.5, 0.0, 0.5);
    const high = blend(0.5, 5.0, 0.5);
    try testing.expect(high > low);
    try testing.expect(high <= 1.0 and low >= 0.0);
}

test "buildPath sanitizes traversal-ish characters" {
    var field = Stigmergy.init(testing.allocator);
    var buf: [512]u8 = undefined;
    const p = try field.buildPath(&buf, "../etc/passwd");
    // '/' 被消除，不可能形成路径穿越；保留扁平文件名。
    try testing.expect(std.mem.indexOf(u8, p, "/") == null);
    try testing.expect(std.mem.startsWith(u8, p, ".sovereign.phero."));
    try testing.expect(std.mem.endsWith(u8, p, ".phero"));
}
