//! 分层信任的记忆管理器 (Trust-based Memory)
//!
//! 设计哲学：非完美记忆。记忆是“启发式种子”，是决策的种子而非绝对事实。
//! 每个种子带有置信度 (0.0 - 1.0)，并随成功/失败反馈自动演进：
//!     C_new = clamp(C_old + reward * learning_rate)
//! 其中 success => reward = +1，failure => reward = -1。
//!
//! 当高置信度记忆与事实冲突时（Open Decision #1）：不删除记忆，而是
//! 标记“当前环境特异性例外 (Contextual Exception)”，保留历史并附加修正因子。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// 反馈结果。
pub const Outcome = enum {
    success,
    failure,

    pub fn reward(self: Outcome) f64 {
        return switch (self) {
            .success => 1.0,
            .failure => -1.0,
        };
    }
};

/// 信任分层。
pub const Tier = enum {
    /// 危险路径：低置信度，Agent 应当对其保持怀疑。
    danger,
    medium,
    /// 可信路径。
    trusted,
};

/// 启发式记忆种子。
pub const Seed = struct {
    id: u64,
    /// 上下文标签（用于按 action.context 检索）。
    context: []const u8,
    /// 记忆内容（提供给 LLM Prompt 的启发式假设）。
    content: []const u8,
    /// 置信度 [0.0, 1.0]。
    confidence: f64,
    success_count: u32 = 0,
    failure_count: u32 = 0,
    /// 当前环境特异性例外说明（冲突时附加，不删除原记忆）。
    exception: ?[]const u8 = null,

    pub fn tier(self: Seed) Tier {
        if (self.confidence >= 0.7) return .trusted;
        if (self.confidence >= 0.3) return .medium;
        return .danger;
    }
};

pub const MemoryManager = struct {
    gpa: Allocator,
    /// 持有种子内部字符串（content/context/exception）的所有权。
    arena: std.heap.ArenaAllocator,
    seeds: std.ArrayList(Seed) = .empty,
    next_id: u64 = 1,
    learning_rate: f64 = 0.1,

    pub fn init(gpa: Allocator) MemoryManager {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *MemoryManager) void {
        self.seeds.deinit(self.gpa);
        self.arena.deinit();
    }

    /// 注入一个记忆种子，返回其 id。
    pub fn addSeed(self: *MemoryManager, context: []const u8, content: []const u8, confidence: f64) !u64 {
        const aa = self.arena.allocator();
        const seed: Seed = .{
            .id = self.next_id,
            .context = try aa.dupe(u8, context),
            .content = try aa.dupe(u8, content),
            .confidence = std.math.clamp(confidence, 0.0, 1.0),
        };
        try self.seeds.append(self.gpa, seed);
        self.next_id += 1;
        return seed.id;
    }

    pub fn get(self: *MemoryManager, id: u64) ?*Seed {
        for (self.seeds.items) |*s| {
            if (s.id == id) return s;
        }
        return null;
    }

    /// 检索与给定上下文匹配的种子 id，按置信度从高到低排序。
    /// 返回值由调用方使用 `gpa` 释放。
    pub fn fetchSeeds(self: *MemoryManager, gpa: Allocator, context: []const u8) ![]u64 {
        var matched: std.ArrayList(Seed) = .empty;
        defer matched.deinit(gpa);
        for (self.seeds.items) |s| {
            if (contextMatches(s.context, context)) {
                try matched.append(gpa, s);
            }
        }
        std.mem.sort(Seed, matched.items, {}, struct {
            fn lessThan(_: void, a: Seed, b: Seed) bool {
                return a.confidence > b.confidence; // 降序
            }
        }.lessThan);

        const ids = try gpa.alloc(u64, matched.items.len);
        for (matched.items, 0..) |s, i| ids[i] = s.id;
        return ids;
    }

    /// 根据成功/失败反馈，更新一组种子的置信度。
    pub fn updateConfidence(self: *MemoryManager, ids: []const u64, outcome: Outcome) void {
        const delta = outcome.reward() * self.learning_rate;
        for (ids) |id| {
            const s = self.get(id) orelse continue;
            s.confidence = std.math.clamp(s.confidence + delta, 0.0, 1.0);
            switch (outcome) {
                .success => s.success_count += 1,
                .failure => s.failure_count += 1,
            }
        }
    }

    /// Open Decision #1：标记环境特异性例外，保留原记忆，附加修正因子。
    /// 这里的“修正因子”体现为：附加例外说明 + 对置信度施加一次性下调。
    pub fn markException(self: *MemoryManager, id: u64, note: []const u8) !void {
        const s = self.get(id) orelse return error.UnknownSeed;
        s.exception = try self.arena.allocator().dupe(u8, note);
        // 冲突点不删除记忆，但降低其在当前环境的可信度（修正因子）。
        s.confidence = std.math.clamp(s.confidence - 0.25, 0.0, 1.0);
    }

    /// 生成提供给 LLM Prompt 的、按权重排序的记忆种子列表。
    /// 由调用方释放返回字符串。
    pub fn renderSeedList(self: *MemoryManager, gpa: Allocator, context: []const u8) ![]u8 {
        const ids = try self.fetchSeeds(gpa, context);
        defer gpa.free(ids);
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.writeAll("<heuristic_seeds>\n");
        for (ids) |id| {
            const s = self.get(id).?;
            try w.writer.print("  [{s} {d:.2}] {s}", .{ @tagName(s.tier()), s.confidence, s.content });
            if (s.exception) |ex| try w.writer.print(" (exception: {s})", .{ex});
            try w.writer.writeByte('\n');
        }
        try w.writer.writeAll("</heuristic_seeds>\n");
        return w.toOwnedSlice();
    }

    /// 第二阶段：生成 <confidence_stats> 模块，让 Agent 实时感知“危险路径”。
    pub fn renderConfidenceStats(self: *MemoryManager, gpa: Allocator) ![]u8 {
        var trusted: usize = 0;
        var medium: usize = 0;
        var danger: usize = 0;
        for (self.seeds.items) |s| {
            switch (s.tier()) {
                .trusted => trusted += 1,
                .medium => medium += 1,
                .danger => danger += 1,
            }
        }
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.print(
            "<confidence_stats trusted=\"{d}\" medium=\"{d}\" danger=\"{d}\">\n",
            .{ trusted, medium, danger },
        );
        for (self.seeds.items) |s| {
            if (s.tier() == .danger) {
                try w.writer.print(
                    "  DANGER seed#{d} conf={d:.2} ctx=\"{s}\": {s}\n",
                    .{ s.id, s.confidence, s.context, s.content },
                );
            }
        }
        try w.writer.writeAll("</confidence_stats>\n");
        return w.toOwnedSlice();
    }
};

/// 上下文匹配：精确相等或子串包含（启发式）。
fn contextMatches(seed_ctx: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, seed_ctx, query)) return true;
    if (query.len == 0 or seed_ctx.len == 0) return false;
    return std.mem.indexOf(u8, query, seed_ctx) != null or
        std.mem.indexOf(u8, seed_ctx, query) != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "confidence update follows C_new = C_old + reward*lr" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const id = try m.addSeed("build", "use zig build", 0.5);
    var ids = [_]u64{id};
    m.updateConfidence(&ids, .success);
    try testing.expectApproxEqAbs(@as(f64, 0.6), m.get(id).?.confidence, 1e-9);
    m.updateConfidence(&ids, .failure);
    try testing.expectApproxEqAbs(@as(f64, 0.5), m.get(id).?.confidence, 1e-9);
    try testing.expectEqual(@as(u32, 1), m.get(id).?.success_count);
    try testing.expectEqual(@as(u32, 1), m.get(id).?.failure_count);
}

test "confidence clamped to [0,1]" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const id = try m.addSeed("x", "y", 0.95);
    var ids = [_]u64{id};
    var i: usize = 0;
    while (i < 10) : (i += 1) m.updateConfidence(&ids, .success);
    try testing.expectEqual(@as(f64, 1.0), m.get(id).?.confidence);
}

test "fetchSeeds sorted by confidence desc and context-filtered" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    _ = try m.addSeed("build", "low", 0.2);
    _ = try m.addSeed("build", "high", 0.9);
    _ = try m.addSeed("network", "unrelated", 0.99);

    const ids = try m.fetchSeeds(testing.allocator, "build");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    // 第一个应是高置信度
    try testing.expectApproxEqAbs(@as(f64, 0.9), m.get(ids[0]).?.confidence, 1e-9);
}

test "markException keeps memory but lowers confidence" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const id = try m.addSeed("path", "file exists", 0.8);
    try m.markException(id, "not present in this env");
    try testing.expect(m.get(id).?.exception != null);
    try testing.expectApproxEqAbs(@as(f64, 0.55), m.get(id).?.confidence, 1e-9);
}

test "tier classification" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const a = try m.addSeed("c", "x", 0.1);
    const b = try m.addSeed("c", "x", 0.5);
    const c = try m.addSeed("c", "x", 0.8);
    try testing.expectEqual(Tier.danger, m.get(a).?.tier());
    try testing.expectEqual(Tier.medium, m.get(b).?.tier());
    try testing.expectEqual(Tier.trusted, m.get(c).?.tier());
}
