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
const arbiter = @import("arbiter.zig");
const event = @import("event.zig");
const stigmergy = @import("stigmergy.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// 本能烧录阈值：连续成功次数达此值且置信度足够高 → 晋升为本能 (Instinct)。
/// 注：这些 `pub const` 现降级为 `MemoryManager` 同名实例字段的**默认值来源**，
/// 保留于此以维持向后兼容与语义锚点；专家模式 (persona) 可按画像覆盖实例字段。
pub const INSTINCT_PROMOTE_SUCCESSES: u32 = 5;
/// 本能晋升所需的最低置信度。
pub const INSTINCT_PROMOTE_CONFIDENCE: f64 = 0.9;
/// 本能阻尼：本能种子失败时仅以 (learning_rate × 此系数) 衰减，抗灾难性遗忘。
pub const INSTINCT_DAMPING: f64 = 0.25;
/// 解除烧录 (unlearning)：本能连续失败达此次数 → 降级回软记忆。
pub const INSTINCT_UNLEARN_FAILURES: u32 = 3;

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
    /// 连续失败计数（成功即清零）；用于本能解除烧录 (unlearning) 判定。
    consecutive_failures: u32 = 0,
    /// 是否已“烧录”为本能：反复验证的高置信模式，享有抗遗忘阻尼，
    /// 并可作为最高优先级反射注入 Subsumption 行为栈（零 LLM 成本）。
    instinct: bool = false,
    /// 当前环境特异性例外说明（冲突时附加，不删除原记忆）。
    exception: ?[]const u8 = null,

    pub fn tier(self: Seed) Tier {
        if (self.confidence >= 0.7) return .trusted;
        if (self.confidence >= 0.3) return .medium;
        return .danger;
    }
};

/// 回写用的种子投影：与 `persona.SeedSpec` / `persona_config.SeedConfig` **字段同构**，
/// 但刻意定义在本模块内，以避免 `memory → persona` 的循环依赖。ZON 是结构化格式
/// （靠字段名而非具体类型往返），故此投影可被 `std.zon.parse` 原样解析回 `SeedConfig`。
///
/// 仅承载声明式的 4 个字段：运行期统计（success/failure/consecutive_failures/exception）
/// **不导出**——回写产物是"蒸馏后的知识资产"，不是运行时快照（后者归 journal 重放）。
pub const SeedDump = struct {
    context: []const u8,
    content: []const u8,
    confidence: f64,
    instinct: bool,
};

/// LLM 在线蒸馏 (self-distillation) 产出的**待审知识**投影。刻意**不含 `instinct`
/// 字段**：本能（L-1 零成本否决反射）只能靠运行期反复验证烧录或人工 review 晋升，
/// 绝不允许模型一句话就写出一条无条件否决反射（否则幻觉直接变成硬约束）。
///
/// 生命周期归调用方（建议 arena）；由 `MemoryManager.ingestDistilled` 安全注入。
pub const DistilledSeed = struct {
    context: []const u8,
    content: []const u8,
    confidence: f64,
};

pub const MemoryManager = struct {
    gpa: Allocator,
    /// 持有种子内部字符串（content/context/exception）的所有权。
    arena: std.heap.ArenaAllocator,
    seeds: std.ArrayList(Seed) = .empty,
    next_id: u64 = 1,
    learning_rate: f64 = 0.1,
    // —— 本能生命周期超参（实例字段，默认取模块常量，可被专家画像 persona 覆盖）——
    /// 连续成功次数达此值且置信度足够高 → 晋升为本能。
    instinct_promote_successes: u32 = INSTINCT_PROMOTE_SUCCESSES,
    /// 本能晋升所需的最低置信度。
    instinct_promote_confidence: f64 = INSTINCT_PROMOTE_CONFIDENCE,
    /// 本能阻尼：本能失败时以 (learning_rate × 此系数) 衰减。
    instinct_damping: f64 = INSTINCT_DAMPING,
    /// 本能连续失败达此次数 → 解除烧录，回归软记忆。
    instinct_unlearn_failures: u32 = INSTINCT_UNLEARN_FAILURES,

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

    /// 安全注入 LLM 在线蒸馏 (self-distillation) 产出的种子——**零信任**：
    ///   * 置信度一律 clamp 到 `[0, max_confidence]`（建议上限 0.5，落入 danger/medium
    ///     tier）：蒸馏产物是"待审知识"，天然低信任、需运行期验证或人工升级；
    ///   * `instinct` **恒为 false**（`addSeed` 默认即 false）：本能只能靠反复成功
    ///     烧录或人工 review 晋升，绝不能让模型一句话写成无条件否决反射；
    ///   * 按 `domain` 打上下文标签（若 seed.context 未含 domain 则前缀 `domain:`），
    ///     便于 `dumpSeedsZon`/`exportProfile` 按域切分导出、人工 `git diff` 审阅升级。
    ///
    /// 空内容的种子被跳过。返回实际注入的种子数。注意：本函数只负责"安全落库"，
    /// 蒸馏产物应经 `exportProfile` 回写 `.zon` → 人工 PR 才算升级为正式专家资产
    /// （与既有冷更新工作流一致），不应直接进离线确定性重放黑盒。
    pub fn ingestDistilled(
        self: *MemoryManager,
        domain: []const u8,
        seeds: []const DistilledSeed,
        max_confidence: f64,
    ) !usize {
        const cap = std.math.clamp(max_confidence, 0.0, 1.0);
        var n: usize = 0;
        for (seeds) |s| {
            if (s.content.len == 0) continue;
            const conf = std.math.clamp(s.confidence, 0.0, cap);

            // 按域打标签：domain 为空或已被 seed.context 覆盖则原样用，否则前缀 domain。
            var tagged: ?[]u8 = null;
            defer if (tagged) |t| self.gpa.free(t);
            const ctx = blk: {
                if (domain.len == 0) break :blk s.context;
                if (contextMatches(domain, s.context)) break :blk s.context;
                tagged = try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ domain, s.context });
                break :blk tagged.?;
            };

            _ = try self.addSeed(ctx, s.content, conf); // instinct 默认 false（零信任）
            n += 1;
        }
        return n;
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

    /// Stigmergy 融合检索：在内存软置信度基础上，叠加**环境信息素**（实测足迹）后排序。
    /// 同一记忆若在环境中反复被验证成功，其排序会被环境足迹抬升（去中心化协同）。
    /// `w` 为记忆软置信度权重（0..1），其余权重归环境实测；返回 id 由调用方释放。
    pub fn fetchSeedsBlended(
        self: *MemoryManager,
        gpa: Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        field: *const stigmergy.Stigmergy,
        context: []const u8,
        now: i64,
        w: f64,
    ) ![]u64 {
        const Scored = struct { id: u64, score: f64 };
        var list: std.ArrayList(Scored) = .empty;
        defer list.deinit(gpa);
        for (self.seeds.items) |s| {
            if (!contextMatches(s.context, context)) continue;
            // 信息素按种子内容（策略身份）寻址，使同 context 的不同策略可被环境区分。
            const strength = field.sense(io, dir, s.content, now) catch 0.0;
            try list.append(gpa, .{ .id = s.id, .score = stigmergy.blend(s.confidence, strength, w) });
        }
        std.mem.sort(Scored, list.items, {}, struct {
            fn lessThan(_: void, a: Scored, b: Scored) bool {
                return a.score > b.score; // 降序
            }
        }.lessThan);
        const ids = try gpa.alloc(u64, list.items.len);
        for (list.items, 0..) |x, i| ids[i] = x.id;
        return ids;
    }

    /// 根据成功/失败反馈，更新一组种子的置信度，并驱动本能 (Instinct) 生命周期：
    ///   * 成功：置信度按 learning_rate 上升；连续失败清零；达标自动**烧录为本能**；
    ///   * 失败：本能种子按阻尼系数缓慢衰减（抗灾难性遗忘），连续失败达阈值则**解除烧录**；
    ///           非本能种子按原 learning_rate 衰减。
    pub fn updateConfidence(self: *MemoryManager, ids: []const u64, outcome: Outcome) void {
        for (ids) |id| {
            const s = self.get(id) orelse continue;
            switch (outcome) {
                .success => {
                    s.confidence = std.math.clamp(s.confidence + self.learning_rate, 0.0, 1.0);
                    s.success_count += 1;
                    s.consecutive_failures = 0;
                    // 自动烧录：反复验证的高置信模式晋升为本能。
                    if (!s.instinct and
                        s.success_count >= self.instinct_promote_successes and
                        s.confidence >= self.instinct_promote_confidence)
                    {
                        s.instinct = true;
                    }
                },
                .failure => {
                    // 本能享有阻尼：单次失败不足以撼动，需连续多次才解锁。
                    const rate = if (s.instinct) self.learning_rate * self.instinct_damping else self.learning_rate;
                    s.confidence = std.math.clamp(s.confidence - rate, 0.0, 1.0);
                    s.failure_count += 1;
                    s.consecutive_failures += 1;
                    // 解除烧录 (unlearning)：环境确已变化，本能降级回软记忆。
                    if (s.instinct and s.consecutive_failures >= self.instinct_unlearn_failures) {
                        s.instinct = false;
                    }
                },
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
        var instincts: usize = 0;
        for (self.seeds.items) |s| {
            switch (s.tier()) {
                .trusted => trusted += 1,
                .medium => medium += 1,
                .danger => danger += 1,
            }
            if (s.instinct) instincts += 1;
        }
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.print(
            "<confidence_stats trusted=\"{d}\" medium=\"{d}\" danger=\"{d}\" instinct=\"{d}\">\n",
            .{ trusted, medium, danger, instincts },
        );
        for (self.seeds.items) |s| {
            if (s.instinct) {
                try w.writer.print(
                    "  INSTINCT seed#{d} conf={d:.2} ctx=\"{s}\": {s}\n",
                    .{ s.id, s.confidence, s.context, s.content },
                );
            }
        }
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

    /// 当前是否存在已烧录的本能。
    pub fn hasInstincts(self: *MemoryManager) bool {
        for (self.seeds.items) |s| {
            if (s.instinct) return true;
        }
        return false;
    }

    /// 将已烧录的本能暴露为 Subsumption 行为栈的**最高优先级反射层**。
    ///
    /// 最小约定：本能种子内容以 `forbid` 开头者，对命中其 context 的写/执行操作
    /// 直接否决——这是从经验中“烧录”出的禁忌反射，零 LLM 成本、毫秒级、绝对优先。
    /// 用法：`arb.stack.reflexes = &.{ mem.instinctReflex() };`
    pub fn instinctReflex(self: *MemoryManager) arbiter.Layer {
        return .{ .name = "L-1:instinct", .ctx = @ptrCast(self), .check = instinctCheck };
    }

    /// 能力③（积累回写）内核原语：把（可选按 `ctx_filter` 过滤的）**演进后**种子
    /// 序列化为 ZON 数组值（`.{ .{ ... }, ... }`）写入 `writer`。
    ///
    /// 用途：运行中 `updateConfidence` 把置信度演进、把反复验证的 seed 烧录为 instinct，
    /// 这些"积累"原本只活在内存/journal；本函数把它们回写为**可 review / 可 git 管理 /
    /// 可移植**的声明式资产，与既有"确定性重放"哲学互补（回写产物可与 journal 重放交叉校验）。
    ///
    /// 采用 `std.zon.stringify`（浮点以 `{d}` 最短可往返表示、字符串标准转义），与
    /// `persona_config` 的 `std.zon.parse` 对称，保证 load→learn→dump→reload 往返一致。
    /// `ctx_filter` 非空时按域切分导出（如仅导出 `zig:std` 域）。
    pub fn dumpSeedsZon(self: *MemoryManager, writer: *Writer, ctx_filter: ?[]const u8) !void {
        var list: std.ArrayList(SeedDump) = .empty;
        defer list.deinit(self.gpa);
        for (self.seeds.items) |s| {
            if (ctx_filter) |f| {
                if (!contextMatches(s.context, f)) continue;
            }
            try list.append(self.gpa, .{
                .context = s.context,
                .content = s.content,
                .confidence = s.confidence,
                .instinct = s.instinct,
            });
        }
        try std.zon.stringify.serialize(list.items, .{}, writer);
    }
};

fn instinctCheck(
    ctx: *anyopaque,
    io: std.Io,
    dir: std.Io.Dir,
    action: event.Action,
    seeds: []const arbiter.SeedClaim,
) anyerror!?arbiter.Verdict {
    _ = io;
    _ = dir;
    _ = seeds;
    const self: *MemoryManager = @ptrCast(@alignCast(ctx));
    // 仅对敏感（写/执行）操作施加禁忌反射；读/思考不拦。
    if (!action.action.isSensitive()) return null;
    for (self.seeds.items) |s| {
        if (!s.instinct) continue;
        if (!std.mem.startsWith(u8, s.content, "forbid")) continue;
        if (contextMatches(s.context, action.context)) {
            return arbiter.Verdict{
                .ok = false,
                .reason = "instinct: learned forbidden pattern (burned-in reflex)",
                .conflict_seed = s.id,
            };
        }
    }
    return null;
}

/// 上下文匹配：精确相等或子串包含（启发式）。
pub fn contextMatches(seed_ctx: []const u8, query: []const u8) bool {
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

// —— Instinct（持续学习 / 本能烧录）——

test "instinct: repeated success burns a seed into instinct" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const id = try m.addSeed("deploy", "use atomic rename", 0.5);
    var ids = [_]u64{id};
    try testing.expect(!m.get(id).?.instinct);
    // 5 次成功：confidence 0.5→1.0，success_count=5 → 达标烧录。
    var i: usize = 0;
    while (i < INSTINCT_PROMOTE_SUCCESSES) : (i += 1) m.updateConfidence(&ids, .success);
    try testing.expect(m.get(id).?.instinct);
    try testing.expect(m.hasInstincts());
}

test "instinct: damping resists catastrophic forgetting on single failure" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const id = try m.addSeed("deploy", "use atomic rename", 0.9);
    var ids = [_]u64{id};
    var i: usize = 0;
    while (i < INSTINCT_PROMOTE_SUCCESSES) : (i += 1) m.updateConfidence(&ids, .success);
    try testing.expect(m.get(id).?.instinct);
    const before = m.get(id).?.confidence; // 1.0
    // 单次失败：本能仅以阻尼系数衰减（0.1*0.25=0.025），远小于普通 0.1。
    m.updateConfidence(&ids, .failure);
    const after = m.get(id).?.confidence;
    try testing.expectApproxEqAbs(before - 0.025, after, 1e-9);
    try testing.expect(m.get(id).?.instinct); // 仍是本能
}

test "instinct: consecutive failures unlearn the instinct" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const id = try m.addSeed("deploy", "use atomic rename", 0.9);
    var ids = [_]u64{id};
    var i: usize = 0;
    while (i < INSTINCT_PROMOTE_SUCCESSES) : (i += 1) m.updateConfidence(&ids, .success);
    try testing.expect(m.get(id).?.instinct);
    // 连续失败达阈值 → 解除烧录，回归软记忆。
    var f: usize = 0;
    while (f < INSTINCT_UNLEARN_FAILURES) : (f += 1) m.updateConfidence(&ids, .failure);
    try testing.expect(!m.get(id).?.instinct);
    try testing.expect(!m.hasInstincts());
}

test "instinct: a success resets consecutive-failure streak" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const id = try m.addSeed("deploy", "x", 0.9);
    var ids = [_]u64{id};
    var i: usize = 0;
    while (i < INSTINCT_PROMOTE_SUCCESSES) : (i += 1) m.updateConfidence(&ids, .success);
    m.updateConfidence(&ids, .failure);
    m.updateConfidence(&ids, .failure); // 2 次连败（未达 3）
    m.updateConfidence(&ids, .success); // 清零连败
    try testing.expectEqual(@as(u32, 0), m.get(id).?.consecutive_failures);
    try testing.expect(m.get(id).?.instinct); // 未被解除
}

test "stigmergy blend reorders seeds by environmental footprint" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = std.Io.Dir.cwd();

    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    // 两个同上下文种子：a 软置信度更高，b 更低。
    const a = try m.addSeed("deploy", "strategy-A", 0.6);
    const b = try m.addSeed("deploy", "strategy-B", 0.5);

    var field = stigmergy.Stigmergy.init(testing.allocator);
    field.clear(io, dir, "strategy-A");
    field.clear(io, dir, "strategy-B");
    defer field.clear(io, dir, "strategy-A");
    defer field.clear(io, dir, "strategy-B");

    // 纯软置信度：a 在前。
    const plain = try m.fetchSeeds(testing.allocator, "deploy");
    defer testing.allocator.free(plain);
    try testing.expectEqual(a, plain[0]);

    // 环境中 strategy-B 反复被验证成功（强足迹）→ 融合后 b 反超 a。
    try field.deposit(io, dir, "strategy-B", 5.0, 1000);
    const blended = try m.fetchSeedsBlended(testing.allocator, io, dir, &field, "deploy", 1000, 0.5);
    defer testing.allocator.free(blended);
    try testing.expectEqual(@as(usize, 2), blended.len);
    try testing.expectEqual(b, blended[0]);
}

test "dumpSeedsZon emits evolved seeds as parseable ZON (with ctx filter)" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const a = try m.addSeed("zig:build", "installArtifact required for outputs", 0.8);
    _ = try m.addSeed("zig:std:mem", "prefer std.mem.eql for byte compare", 0.7);
    _ = try m.addSeed("network", "unrelated seed", 0.5);
    // 让 a 演进：一次成功 → 0.9。
    var ids = [_]u64{a};
    m.updateConfidence(&ids, .success);

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    // 仅导出 zig 域（zig:build + zig:std:mem），排除 network。
    try m.dumpSeedsZon(&w.writer, "zig");
    const out = w.written();

    // 结构性检查：演进后的置信度与内容都在，network 被过滤掉。
    try testing.expect(std.mem.indexOf(u8, out, "installArtifact required for outputs") != null);
    try testing.expect(std.mem.indexOf(u8, out, "prefer std.mem.eql for byte compare") != null);
    try testing.expect(std.mem.indexOf(u8, out, "unrelated seed") == null);
    try testing.expect(std.mem.indexOf(u8, out, "0.9") != null); // a 演进后置信度

    // 可被 std.zon.parse 原样解析回 []SeedDump（往返自洽）。
    const src = try testing.allocator.allocSentinel(u8, out.len, 0);
    defer testing.allocator.free(src);
    @memcpy(src, out);
    const parsed = try std.zon.parse.fromSliceAlloc([]SeedDump, testing.allocator, src, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);
    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectApproxEqAbs(@as(f64, 0.9), parsed[0].confidence, 1e-9);
}

test "dumpSeedsZon on empty selection yields empty tuple" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    _ = try m.addSeed("a", "x", 0.5);
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    try m.dumpSeedsZon(&w.writer, "no-such-context");
    try testing.expectEqualStrings(".{}", w.written());
}

test "ingestDistilled clamps confidence, forces non-instinct, and tags by domain" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();

    const distilled = [_]DistilledSeed{
        // 模型给出过高置信度，应被 clamp 到 max_confidence（0.5）→ medium tier。
        .{ .context = "build", .content = "prefer zig build --release=safe", .confidence = 0.95 },
        // 已含 domain 前缀 → 不重复打标签。
        .{ .context = "zig:std", .content = "use std.mem.eql for byte compare", .confidence = 0.2 },
        // 空内容 → 跳过。
        .{ .context = "noise", .content = "", .confidence = 0.4 },
        // 即便模型想写 forbid，也只是软记忆（instinct=false），不会成为否决反射。
        .{ .context = "deploy", .content = "forbid: never deploy on friday", .confidence = 1.0 },
    };

    const n = try m.ingestDistilled("zig", &distilled, 0.5);
    try testing.expectEqual(@as(usize, 3), n); // 空内容被跳过
    try testing.expectEqual(@as(usize, 3), m.seeds.items.len);

    // 零信任红线：注入的种子一律非本能，且置信度不超过上限。
    for (m.seeds.items) |s| {
        try testing.expect(!s.instinct);
        try testing.expect(s.confidence <= 0.5 + 1e-9);
    }
    try testing.expect(!m.hasInstincts());

    // 第一条被 clamp 到 0.5（medium），且 context 被前缀为 "zig:build"。
    const build_ids = try m.fetchSeeds(testing.allocator, "zig:build");
    defer testing.allocator.free(build_ids);
    try testing.expectEqual(@as(usize, 1), build_ids.len);
    try testing.expectApproxEqAbs(@as(f64, 0.5), m.get(build_ids[0]).?.confidence, 1e-9);
    try testing.expectEqualStrings("zig:build", m.get(build_ids[0]).?.context);

    // 已含 domain 的 context 不被重复前缀（仍是 "zig:std"，非 "zig:zig:std"）。
    const std_ids = try m.fetchSeeds(testing.allocator, "zig:std");
    defer testing.allocator.free(std_ids);
    try testing.expect(std_ids.len >= 1);
    try testing.expectEqualStrings("zig:std", m.get(std_ids[0]).?.context);
}

test "ingestDistilled with empty domain keeps raw context and honors max_confidence=0" {
    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const distilled = [_]DistilledSeed{
        .{ .context = "topic", .content = "some heuristic", .confidence = 0.9 },
    };
    // max_confidence=0 → 一切蒸馏知识都落到最不可信区（confidence=0，danger）。
    _ = try m.ingestDistilled("", &distilled, 0.0);
    try testing.expectEqual(@as(usize, 1), m.seeds.items.len);
    try testing.expectEqualStrings("topic", m.seeds.items[0].context);
    try testing.expectApproxEqAbs(@as(f64, 0.0), m.seeds.items[0].confidence, 1e-9);
    try testing.expectEqual(Tier.danger, m.seeds.items[0].tier());
}

test "instinct reflex vetoes forbidden pattern via behavior stack" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = std.Io.Dir.cwd();

    var m = MemoryManager.init(testing.allocator);
    defer m.deinit();
    const id = try m.addSeed("prod-deploy", "forbid: never auto-deploy to prod", 0.95);
    // 手动置为本能（模拟已烧录）。
    m.get(id).?.instinct = true;

    var stack: arbiter.BehaviorStack = .{};
    const layers = [_]arbiter.Layer{m.instinctReflex()};
    stack.reflexes = &layers;

    // 命中禁忌 context 的写操作被本能反射否决。
    const bad: event.Action = .{ .id = 1, .action = .write, .context = "prod-deploy", .payload = "go" };
    const v1 = try stack.evaluate(io, dir, bad, &.{});
    try testing.expect(!v1.ok);
    try testing.expectEqual(@as(?u64, id), v1.conflict_seed);
    try testing.expectEqualStrings("L-1:instinct", v1.layer);

    // 不相关 context 不受影响。
    const ok: event.Action = .{ .id = 2, .action = .write, .context = "notes.md", .payload = "hello" };
    const v2 = try stack.evaluate(io, dir, ok, &.{});
    try testing.expect(v2.ok);
}
