//! 专家模式 (Expert Profile / Persona)。
//!
//! 设计哲学：把“专家模式”收敛为**一个声明式结构体 `ExpertProfile`**，一次覆盖
//! 五个维度，并通过 `activate(ctx)` 把它“焊”到现有内核的现成旋钮上——切换专家
//! 就是：换记忆种子 (①领域知识) + 换反射栈 (②禁忌反射) + 调学习/敏感度档位
//! (③④) + 换角色提示 (⑤)。因为**状态在账本、不在节点**，热切换不丢历史。
//!
//! 硬约束（与既有工作一脉相承）：
//!   * 零破坏：`transact` 闭环一行不改；现有断言全绿。
//!   * 零信任不可降级：敏感度档位只能让校验**更严**，L0 安全包络（危险命令/
//!     路径穿越/越权读）永远是最终物理防线，任何专家都**无法关闭**。
//!   * 确定性可审计：切换动作本身作为一条 `think` 事件落账，可被 rebuildState 重放。

const std = @import("std");
const arbiter = @import("arbiter.zig");
const memory = @import("memory.zig");
const agent = @import("agent.zig");
const llm = @import("llm.zig");
const event = @import("event.zig");

const Allocator = std.mem.Allocator;

/// ① 领域知识：专家预置的记忆种子（可预烧录为本能）。
pub const SeedSpec = struct {
    context: []const u8,
    content: []const u8,
    confidence: f64 = 0.5,
    /// true = 激活即置为本能。禁忌型本能请以 "forbid" 开头，
    /// 以便被 `MemoryManager.instinctReflex()` 识别为最高优先级否决反射。
    instinct: bool = false,
};

/// ④ 敏感度档位（只能更严，绝不放松 L0 反射）。
/// 刻意不提供低于 `standard` 的档位——零信任下界不可下调。
pub const Sensitivity = enum {
    /// 现状：仅 write/execute + 越权读 走同步强校验。
    standard,
    /// 保守：所有动作（含 read/think）一律同步强校验。
    conservative,

    /// 映射到 Arbiter.strict_all（是否全量强校验）。
    pub fn strictAll(self: Sensitivity) bool {
        return self == .conservative;
    }
};

/// ⑤ 角色/模型覆盖（由驱动层在构造 LlmClient 时读取，不进入 transact）。
pub const LlmOverride = struct {
    system_prompt: ?[]const u8 = null,
    provider: ?llm.Provider = null,
    model: ?[]const u8 = null,
};

/// 激活前的运行时快照，供 `Session.deinit` 完整还原（热切换回退 / 测试隔离）。
const Snapshot = struct {
    learning_rate: f64,
    instinct_promote_successes: u32,
    instinct_promote_confidence: f64,
    instinct_damping: f64,
    instinct_unlearn_failures: u32,
    reflexes: []const arbiter.Layer,
    strict_all: bool,
};

/// 统一专家画像。全部字段带默认值 → 空 profile 等价于“标准通用体”。
pub const ExpertProfile = struct {
    name: []const u8,
    description: []const u8 = "",

    // ① 领域知识
    seeds: []const SeedSpec = &.{},

    // ② 禁忌反射（注入行为栈最高优先级，先于内置安全包络）
    reflexes: []const arbiter.Layer = &.{},

    // ③ 学习/本能超参（默认值 = 现有 module 常量，保持行为不变）
    learning_rate: f64 = 0.1,
    instinct_promote_successes: u32 = memory.INSTINCT_PROMOTE_SUCCESSES,
    instinct_promote_confidence: f64 = memory.INSTINCT_PROMOTE_CONFIDENCE,
    instinct_damping: f64 = memory.INSTINCT_DAMPING,
    instinct_unlearn_failures: u32 = memory.INSTINCT_UNLEARN_FAILURES,

    // ④ 敏感度
    sensitivity: Sensitivity = .standard,

    // ⑤ 角色/模型
    llm: LlmOverride = .{},

    /// 激活画像：把五维写入运行时，返回 Session 句柄（持有组合反射栈的所有权，
    /// 并支持还原/审计）。
    ///
    /// 行为规约：
    ///   1. 保存现场（供 Session.deinit 还原）。
    ///   2. ③ 写入学习/本能超参。
    ///   3. ① 注入种子；instinct=true 者直接置位。
    ///   4. ② 组合反射 = persona.reflexes ++ memory.instinctReflex()，
    ///      使“专家自带禁忌 + 运行中烧录的本能”共存且持续跟随学习演进。
    ///   5. ④ 敏感度档位（只升不降）。
    ///   6. 审计：切换动作作为一条 committed 的 `think` 事件落账。
    pub fn activate(
        self: *const ExpertProfile,
        gpa: Allocator,
        ctx: *agent.AgentContext,
    ) !Session {
        // 1. 保存现场。
        const snap: Snapshot = .{
            .learning_rate = ctx.memory.learning_rate,
            .instinct_promote_successes = ctx.memory.instinct_promote_successes,
            .instinct_promote_confidence = ctx.memory.instinct_promote_confidence,
            .instinct_damping = ctx.memory.instinct_damping,
            .instinct_unlearn_failures = ctx.memory.instinct_unlearn_failures,
            .reflexes = ctx.arbiter.stack.reflexes,
            .strict_all = ctx.arbiter.strict_all,
        };

        // 2. ③ 学习/本能超参。
        ctx.memory.learning_rate = self.learning_rate;
        ctx.memory.instinct_promote_successes = self.instinct_promote_successes;
        ctx.memory.instinct_promote_confidence = self.instinct_promote_confidence;
        ctx.memory.instinct_damping = self.instinct_damping;
        ctx.memory.instinct_unlearn_failures = self.instinct_unlearn_failures;

        // 3. ① 领域知识：注入种子（instinct=true 者置位）。
        for (self.seeds) |s| {
            const sid = try ctx.memory.addSeed(s.context, s.content, s.confidence);
            if (s.instinct) {
                if (ctx.memory.get(sid)) |seed| seed.instinct = true;
            }
        }

        // 4. ② 组合反射栈 = persona.reflexes ++ [memory.instinctReflex()]。
        //    本能反射始终在栈尾（仍高于内置层），保证“学出来的禁忌”持续生效，
        //    且 instinctReflex 动态查询 memory，无需重激活即可跟随学习演进。
        const n = self.reflexes.len;
        const owned = try gpa.alloc(arbiter.Layer, n + 1);
        errdefer gpa.free(owned);
        for (self.reflexes, 0..) |layer, i| owned[i] = layer;
        owned[n] = ctx.memory.instinctReflex();
        ctx.arbiter.stack.reflexes = owned;

        // 5. ④ 敏感度档位（只升不降）。
        ctx.arbiter.strict_all = self.sensitivity.strictAll();

        // 6. 审计：切换动作落账（非敏感 think 事件，可被 rebuildState 重放追溯）。
        //    payload 携带专家名；不含任何密钥（LlmOverride 不进账本）。
        const audit: event.Action = .{
            .id = ctx.nextId(),
            .action = .think,
            .context = "persona:switch",
            .payload = self.name,
        };
        _ = try ctx.journal.append(audit, .committed);

        return .{
            .gpa = gpa,
            .profile = self,
            .reflexes_owned = owned,
            .snapshot = snap,
        };
    }
};

/// 激活句柄：持有本次激活分配的资源，负责还原与角色提示取用。
///
/// 生命周期说明：`deinit` 会**完整还原**激活前的运行时旋钮（学习/本能超参、
/// 反射栈、敏感度档位），实现无残留热回退。注意：为保留“记忆在账本、可追溯”
/// 的语义，激活时注入的种子采用**叠加式**（不在 deinit 时移除）——这些种子是
/// 专家带来的知识资产，理应沉淀进记忆而非随句柄销毁。
pub const Session = struct {
    gpa: Allocator,
    profile: *const ExpertProfile,
    /// 组合后的反射栈（persona.reflexes ++ 本能反射），由本句柄持有所有权。
    reflexes_owned: []arbiter.Layer,
    /// 激活前快照，供 deinit 还原。
    snapshot: Snapshot,

    /// 还原到激活前的运行时状态（热切换回退 / 测试隔离），并释放组合反射栈。
    pub fn deinit(self: *Session, ctx: *agent.AgentContext) void {
        ctx.memory.learning_rate = self.snapshot.learning_rate;
        ctx.memory.instinct_promote_successes = self.snapshot.instinct_promote_successes;
        ctx.memory.instinct_promote_confidence = self.snapshot.instinct_promote_confidence;
        ctx.memory.instinct_damping = self.snapshot.instinct_damping;
        ctx.memory.instinct_unlearn_failures = self.snapshot.instinct_unlearn_failures;
        ctx.arbiter.stack.reflexes = self.snapshot.reflexes;
        ctx.arbiter.strict_all = self.snapshot.strict_all;
        self.gpa.free(self.reflexes_owned);
        self.reflexes_owned = &.{};
    }

    /// ⑤ 供驱动层取用的角色提示（未覆盖则返回 fallback）。
    pub fn systemPrompt(self: Session, fallback: []const u8) []const u8 {
        return self.profile.llm.system_prompt orelse fallback;
    }

    /// ⑤ 供驱动层取用的模型名（未覆盖则返回 fallback）。
    pub fn model(self: Session, fallback: []const u8) []const u8 {
        return self.profile.llm.model orelse fallback;
    }

    /// ⑤ 供驱动层取用的后端 provider（未覆盖则返回 fallback）。
    pub fn provider(self: Session, fallback: llm.Provider) llm.Provider {
        return self.profile.llm.provider orelse fallback;
    }
};

/// 命名注册表：按名切换、枚举可用专家。profile 由代码内声明或可信配置提供。
pub const Registry = struct {
    profiles: []const ExpertProfile,

    /// 按名查找画像；未找到返回 null。
    pub fn find(self: Registry, name: []const u8) ?*const ExpertProfile {
        for (self.profiles) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// 按名切换：找到即激活并返回 Session；未知专家返回 error.UnknownPersona。
    pub fn switchTo(
        self: Registry,
        gpa: Allocator,
        ctx: *agent.AgentContext,
        name: []const u8,
    ) !Session {
        const p = self.find(name) orelse return error.UnknownPersona;
        return p.activate(gpa, ctx);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Dir = std.Io.Dir;
const Io = std.Io;
const Action = event.Action;
const Verdict = arbiter.Verdict;
const SeedClaim = arbiter.SeedClaim;

/// 一条专家自带的禁忌反射：永不写入含 "prod" 的上下文（最高优先级）。
const NoProd = struct {
    fn check(_: *anyopaque, _: Io, _: Dir, action: Action, _: []const SeedClaim) anyerror!?Verdict {
        if (action.action == .write and std.mem.indexOf(u8, action.context, "prod") != null)
            return Verdict{ .ok = false, .reason = "persona: never write prod" };
        return null;
    }
};

const TestEnv = struct {
    t: std.Io.Threaded,
    j: @import("journal.zig").Journal,
    m: memory.MemoryManager,
    arb: arbiter.Arbiter,
    ctx: agent.AgentContext,
    path: []const u8,

    fn setup(e: *TestEnv, path: []const u8) void {
        e.t = std.Io.Threaded.init(testing.allocator, .{});
        const io = e.t.io();
        const dir = Dir.cwd();
        dir.deleteFile(io, path) catch {};
        e.path = path;
        e.j = @import("journal.zig").Journal.init(testing.allocator, io, dir, path);
        e.m = memory.MemoryManager.init(testing.allocator);
        e.arb = arbiter.Arbiter.init(io, dir);
        e.ctx = .{
            .gpa = testing.allocator,
            .io = io,
            .dir = dir,
            .journal = &e.j,
            .memory = &e.m,
            .arbiter = &e.arb,
        };
    }

    fn teardown(e: *TestEnv) void {
        const io = e.t.io();
        const dir = Dir.cwd();
        e.j.deinit();
        e.m.deinit();
        dir.deleteFile(io, e.path) catch {};
        e.t.deinit();
    }
};

fn dummyLayer() [1]arbiter.Layer {
    // 无状态反射：ctx 未用，给个稳定占位。
    return .{arbiter.Layer{ .name = "persona:no-prod", .ctx = undefined, .check = NoProd.check }};
}

test "persona activate applies knobs, reflexes, sensitivity and audits" {
    var e: TestEnv = undefined;
    e.setup(".test_persona_activate.jsonl");
    defer e.teardown();
    try e.j.ensureFile();

    const reflexes = dummyLayer();
    const profile: ExpertProfile = .{
        .name = "ops-conservative",
        .seeds = &.{
            .{ .context = "release", .content = "forbid: no release on friday", .confidence = 0.95, .instinct = true },
        },
        .reflexes = &reflexes,
        .learning_rate = 0.02,
        .sensitivity = .conservative,
        .llm = .{ .system_prompt = "You are a cautious SRE." },
    };

    var sess = try profile.activate(testing.allocator, &e.ctx);
    defer sess.deinit(&e.ctx);

    // ③ 学习超参已应用。
    try testing.expectApproxEqAbs(@as(f64, 0.02), e.m.learning_rate, 1e-9);
    // ④ 敏感度：保守档 → strict_all。
    try testing.expect(e.arb.strict_all);
    // ⑤ 角色提示覆盖生效。
    try testing.expectEqualStrings("You are a cautious SRE.", sess.systemPrompt("fallback"));

    // ② 专家自带禁忌反射：写 prod 被否决，归因专家层。
    const prod: Action = .{ .id = 1, .action = .write, .context = "prod-cfg", .payload = "{\"k\":1}" };
    try testing.expect(!try e.arb.verify(prod, &.{}));
    try testing.expectEqualStrings("persona:no-prod", e.arb.last.layer);

    // ①+② 预烧录本能：写 release 被组合栈中的本能反射否决，归因 L-1:instinct。
    const rel: Action = .{ .id = 2, .action = .write, .context = "release", .payload = "go" };
    try testing.expect(!try e.arb.verify(rel, &.{}));
    try testing.expectEqualStrings("L-1:instinct", e.arb.last.layer);

    // 审计：账本含一条 persona:switch 的 think committed 事件。
    const data = try Dir.cwd().readFileAlloc(e.t.io(), e.path, testing.allocator, .unlimited);
    defer testing.allocator.free(data);
    try testing.expect(std.mem.indexOf(u8, data, "\"action\":\"think\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "ops-conservative") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"status\":\"committed\"") != null);
}

test "persona Session.deinit fully restores runtime knobs" {
    var e: TestEnv = undefined;
    e.setup(".test_persona_restore.jsonl");
    defer e.teardown();
    try e.j.ensureFile();

    const lr0 = e.m.learning_rate;
    const strict0 = e.arb.strict_all;
    const reflexes0 = e.arb.stack.reflexes;

    const profile: ExpertProfile = .{ .name = "temp", .learning_rate = 0.9, .sensitivity = .conservative };
    var sess = try profile.activate(testing.allocator, &e.ctx);
    try testing.expect(e.arb.strict_all);
    sess.deinit(&e.ctx);

    try testing.expectApproxEqAbs(lr0, e.m.learning_rate, 1e-9);
    try testing.expectEqual(strict0, e.arb.strict_all);
    try testing.expectEqual(reflexes0.len, e.arb.stack.reflexes.len);
}

test "persona Registry find + switchTo + unknown" {
    var e: TestEnv = undefined;
    e.setup(".test_persona_registry.jsonl");
    defer e.teardown();
    try e.j.ensureFile();

    const profiles = [_]ExpertProfile{
        .{ .name = "generalist" },
        .{ .name = "ops-conservative", .sensitivity = .conservative },
    };
    const reg: Registry = .{ .profiles = &profiles };

    try testing.expect(reg.find("generalist") != null);
    try testing.expect(reg.find("nope") == null);

    var sess = try reg.switchTo(testing.allocator, &e.ctx, "ops-conservative");
    defer sess.deinit(&e.ctx);
    try testing.expect(e.arb.strict_all);

    try testing.expectError(error.UnknownPersona, reg.switchTo(testing.allocator, &e.ctx, "ghost"));
}

test "empty persona is a no-op standard generalist" {
    var e: TestEnv = undefined;
    e.setup(".test_persona_empty.jsonl");
    defer e.teardown();
    try e.j.ensureFile();

    const profile: ExpertProfile = .{ .name = "generalist" };
    var sess = try profile.activate(testing.allocator, &e.ctx);
    defer sess.deinit(&e.ctx);

    // 空画像：不升敏感度、learning_rate 维持默认。
    try testing.expect(!e.arb.strict_all);
    try testing.expectApproxEqAbs(@as(f64, 0.1), e.m.learning_rate, 1e-9);
    // 组合栈仅含本能反射一层。
    try testing.expectEqual(@as(usize, 1), e.arb.stack.reflexes.len);
}
