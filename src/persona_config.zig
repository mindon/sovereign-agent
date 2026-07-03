//! 配置驱动的可插拔专家（Persona）适配层。
//!
//! 设计哲学：把"每个专家画像"从硬编码在调用方代码里的 `[]const ExpertProfile`
//! 静态数组，改为从 `experts/` 目录下的 **ZON 配置文件**在运行时加载。运维者无需
//! 改动或重编译内核，只要新增/删除一个 `*.zon` 即可增减专家。
//!
//! 分层：
//!   * `ProfileConfig` —— 纯声明式 DTO，用 `std.zon.parse` 安全反序列化（无代码执行、
//!     编译期 schema、未知字段报错）。**结构里根本没有密钥字段**，使"配置注入密钥"
//!     在解析期即不可能。
//!   * `toProfile()` —— 把 DTO 映射为现有 `persona.ExpertProfile`，其中 `reflexes`
//!     **恒为空 `&.{}`**：配置不携带任何代码（函数指针），只靠 seeds/instinct +
//!     内置 L0 安全包络生效，L0 物理防线不可被任何配置绕过。
//!   * `ConfigRegistry` —— 内置 arena，持有解析出的字符串与 profile 数组，
//!     `registry()` 返回现成的 `persona.Registry`，与既有 `switchTo/activate/Session`
//!     完全兼容——下游一行不用改。
//!
//! 零信任红线（内建，不可绕过）：
//!   1. 配置永远不能携带 `api_key` / `base_url`（密钥恒 env-only；schema 无此字段 +
//!      严格模式 → 出现即解析失败）。
//!   2. 敏感度只能升不能降（沿用 `persona.Sensitivity`，无低于 `standard` 的档位）。
//!   3. 配置专家 `reflexes` 恒空，无法引入/削弱行为栈；本能反射仍由 memory 动态提供。
//!   4. `loadDir` 仅扫描 `*.zon`、不跟随软链、按文件名字典序排序 → Registry 顺序稳定、
//!      可重放、审计一致。

const std = @import("std");
const persona = @import("persona.zig");
const memory = @import("memory.zig");
const llm = @import("llm.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

/// 配置加载错误。`BadConfig` 覆盖一切解析/schema 失败（含未知字段、密钥字段、
/// 非法枚举、类型不符），对调用方呈现单一、稳定的失败面。
pub const ConfigError = error{BadConfig};

/// 种子配置（纯数据）。直接复用 `persona.SeedSpec`——它本身不含任何代码字段，
/// 天然可 ZON 反序列化；别名仅为命名清晰。
pub const SeedConfig = persona.SeedSpec;

/// 角色/模型覆盖配置（纯数据）。直接复用 `persona.LlmOverride`——其字段仅
/// `system_prompt/provider/model`，**刻意不含 api_key/base_url**，从类型层面
/// 杜绝密钥入配置。
pub const LlmConfig = persona.LlmOverride;

/// 专家画像的可反序列化投影：等价于 `persona.ExpertProfile` **去掉 `reflexes`**
/// （反射是函数指针=代码，无法也不应从纯数据配置加载）。
///
/// 所有字段带默认值 → 空 `.{ .name = "x" }` 等价于"标准通用体"。
pub const ProfileConfig = struct {
    name: []const u8,
    description: []const u8 = "",

    // ① 领域知识
    seeds: []const SeedConfig = &.{},

    // ③ 学习/本能超参（默认取 memory 模块常量，保持行为不变）
    learning_rate: f64 = 0.1,
    instinct_promote_successes: u32 = memory.INSTINCT_PROMOTE_SUCCESSES,
    instinct_promote_confidence: f64 = memory.INSTINCT_PROMOTE_CONFIDENCE,
    instinct_damping: f64 = memory.INSTINCT_DAMPING,
    instinct_unlearn_failures: u32 = memory.INSTINCT_UNLEARN_FAILURES,

    // ④ 敏感度（只能升，无低于 standard 的档位）
    sensitivity: persona.Sensitivity = .standard,

    // ⑤ 角色/模型（无密钥字段）
    llm: LlmConfig = .{},

    /// 映射为现有 `ExpertProfile`：`reflexes` 恒空——配置不携带代码，
    /// L0 安全包络与 memory 本能反射仍是最终物理防线。
    pub fn toProfile(self: ProfileConfig) persona.ExpertProfile {
        return .{
            .name = self.name,
            .description = self.description,
            .seeds = self.seeds,
            .reflexes = &.{}, // 零信任：配置无法注入任何反射/代码
            .learning_rate = self.learning_rate,
            .instinct_promote_successes = self.instinct_promote_successes,
            .instinct_promote_confidence = self.instinct_promote_confidence,
            .instinct_damping = self.instinct_damping,
            .instinct_unlearn_failures = self.instinct_unlearn_failures,
            .sensitivity = self.sensitivity,
            .llm = self.llm,
        };
    }
};

/// 一组配置专家的持有者。内置 arena 拥有所有解析出的字符串与 profile 数组，
/// `deinit()` 一次性释放。
///
/// 生命周期：`registry()` 返回的 `persona.Registry` 是对本结构内数组的**借用视图**，
/// 其使用不得超过本 `ConfigRegistry` 的生命周期。
pub const ConfigRegistry = struct {
    arena: std.heap.ArenaAllocator,
    profiles: []persona.ExpertProfile,

    pub fn deinit(self: *ConfigRegistry) void {
        self.arena.deinit();
    }

    /// 暴露为现成的 `persona.Registry`（借用视图）。
    pub fn registry(self: *const ConfigRegistry) persona.Registry {
        return .{ .profiles = self.profiles };
    }

    /// 已加载专家数量。
    pub fn count(self: *const ConfigRegistry) usize {
        return self.profiles.len;
    }
};

/// ZON 解析选项：严格 schema（未知字段报错，防篡改/拼写错误/密钥注入）。
/// `free_on_error=false`：解析进 arena，出错整体丢弃 arena 即可，无需逐字段释放。
const zon_options: std.zon.parse.Options = .{
    .ignore_unknown_fields = false,
    .free_on_error = false,
};

/// 从内联 ZON 字节加载**单个**专家（便于测试/嵌入）。`source` 须以 0 结尾。
pub fn loadBytes(gpa: Allocator, source: [:0]const u8) (ConfigError || Allocator.Error)!ConfigRegistry {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const cfg = std.zon.parse.fromSliceAlloc(ProfileConfig, aa, source, null, zon_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return error.BadConfig,
    };

    const profiles = try aa.alloc(persona.ExpertProfile, 1);
    profiles[0] = cfg.toProfile();
    return .{ .arena = arena, .profiles = profiles };
}

/// 从**单个** `.zon` 文件加载一个专家。
pub fn loadFile(
    gpa: Allocator,
    io: Io,
    dir: Dir,
    path: []const u8,
) (ConfigError || Allocator.Error || anyerror)!ConfigRegistry {
    const src = try dir.readFileAllocOptions(io, path, gpa, .unlimited, .@"1", 0);
    defer gpa.free(src);
    return loadBytes(gpa, src);
}

/// 从**目录**聚合加载：扫描 `dir_path` 下所有 `*.zon`（仅普通文件、不递归、
/// 不跟随软链的目录项），按文件名**字典序排序**后逐个解析，保证 Registry 顺序
/// 确定、可重放。
pub fn loadDir(
    gpa: Allocator,
    io: Io,
    dir: Dir,
    dir_path: []const u8,
) (ConfigError || Allocator.Error || anyerror)!ConfigRegistry {
    var edir = try dir.openDir(io, dir_path, .{ .iterate = true });
    defer edir.close(io);

    // 1) 收集 *.zon 文件名（entry.name 在下次 next() 后失效，须立即 dupe）。
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = edir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }

    // 2) 字典序排序 → 确定性。
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // 3) 逐个解析进共享 arena。
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const profiles = try aa.alloc(persona.ExpertProfile, names.items.len);
    for (names.items, 0..) |name, i| {
        const src = try edir.readFileAllocOptions(io, name, gpa, .unlimited, .@"1", 0);
        defer gpa.free(src);
        const cfg = std.zon.parse.fromSliceAlloc(ProfileConfig, aa, src, null, zon_options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => return error.BadConfig,
        };
        profiles[i] = cfg.toProfile();
    }

    return .{ .arena = arena, .profiles = profiles };
}

// ---------------------------------------------------------------------------
// 能力③：memory → .zon 回写（config ↔ memory 往返闭环）
// ---------------------------------------------------------------------------

/// 从一个已激活/映射的 `ExpertProfile` 抽取**可序列化的元信息**（去掉 `reflexes`
/// 这一函数指针字段），得到一个 `ProfileConfig`。其 `.seeds` 原样带出，但在
/// `exportProfile` 中会被内存演进后的种子覆盖，故此处仅取 name/description/超参/
/// sensitivity/llm 有意义。
///
/// 用途：`switchTo` 后调用方手上有 `*const ExpertProfile`，可直接
/// `exportProfile(gpa, w, metaFromProfile(profile.*), mem, filter)` 完成回写。
pub fn metaFromProfile(p: persona.ExpertProfile) ProfileConfig {
    return .{
        .name = p.name,
        .description = p.description,
        .seeds = &.{}, // 占位；实际以 memory 演进后的种子为准
        .learning_rate = p.learning_rate,
        .instinct_promote_successes = p.instinct_promote_successes,
        .instinct_promote_confidence = p.instinct_promote_confidence,
        .instinct_damping = p.instinct_damping,
        .instinct_unlearn_failures = p.instinct_unlearn_failures,
        .sensitivity = p.sensitivity,
        .llm = p.llm,
    };
}

/// 把内存中**演进后**的种子（可选按 `ctx_filter` 过滤）与给定画像元信息 `meta`
/// 合成一个完整 `ProfileConfig`，并以 ZON 序列化写入 `writer`。
///
/// 产物可被 `loadBytes` / `loadFile` **原样解析**，从而形成
///   `zig-expert.zon → 激活学习(updateConfidence) → exportProfile → zig-expert.zon(v2)`
/// 的往返闭环——把运行期积累（置信度演进、instinct 烧录）沉淀为**可 review、可 git
/// 管理、可共享**的专家资产（能力③）。
///
/// 约定：
///   * `meta.seeds` 被忽略，由 `mem` 中的种子替换；
///   * 学习/本能超参以 `mem` 的当前实例值为准（反映运行期可能的调参）；
///   * `ctx_filter` 非空时仅导出匹配该上下文的种子（按域切分导出，如仅 `zig:std`）；
///   * 采用 `std.zon.stringify` 与解析侧 `std.zon.parse` 严格对称，保证往返一致。
///
/// 零信任红线不受影响：产物仍是纯声明式配置，无 `reflexes`/无密钥字段，重新加载时
/// L0 安全包络与 schema 严格校验照旧生效。
pub fn exportProfile(
    gpa: Allocator,
    writer: *Io.Writer,
    meta: ProfileConfig,
    mem: *memory.MemoryManager,
    ctx_filter: ?[]const u8,
) (Allocator.Error || Io.Writer.Error)!void {
    var seeds: std.ArrayList(SeedConfig) = .empty;
    defer seeds.deinit(gpa);
    for (mem.seeds.items) |s| {
        if (ctx_filter) |f| {
            if (!memory.contextMatches(s.context, f)) continue;
        }
        try seeds.append(gpa, .{
            .context = s.context,
            .content = s.content,
            .confidence = s.confidence,
            .instinct = s.instinct,
        });
    }

    var cfg = meta;
    cfg.seeds = seeds.items;
    cfg.learning_rate = mem.learning_rate;
    cfg.instinct_promote_successes = mem.instinct_promote_successes;
    cfg.instinct_promote_confidence = mem.instinct_promote_confidence;
    cfg.instinct_damping = mem.instinct_damping;
    cfg.instinct_unlearn_failures = mem.instinct_unlearn_failures;

    try std.zon.stringify.serialize(cfg, .{}, writer);
}

// ---------------------------------------------------------------------------
// Tests（纯解析，不依赖网络/目录）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "loadBytes parses a full profile and maps to ExpertProfile with empty reflexes" {
    const src =
        \\.{
        \\    .name = "ops-conservative",
        \\    .description = "cautious SRE",
        \\    .seeds = .{
        \\        .{ .context = "release", .content = "forbid: no release on friday", .confidence = 0.95, .instinct = true },
        \\    },
        \\    .learning_rate = 0.02,
        \\    .sensitivity = .conservative,
        \\    .llm = .{ .system_prompt = "You are a cautious SRE.", .provider = .openai, .model = "gpt-4o-mini" },
        \\}
    ;
    var reg = try loadBytes(testing.allocator, src);
    defer reg.deinit();

    try testing.expectEqual(@as(usize, 1), reg.count());
    const p = reg.profiles[0];
    try testing.expectEqualStrings("ops-conservative", p.name);
    try testing.expectApproxEqAbs(@as(f64, 0.02), p.learning_rate, 1e-9);
    try testing.expectEqual(persona.Sensitivity.conservative, p.sensitivity);
    // reflexes 恒空：配置不携带代码。
    try testing.expectEqual(@as(usize, 0), p.reflexes.len);
    // seeds 正确解析。
    try testing.expectEqual(@as(usize, 1), p.seeds.len);
    try testing.expect(p.seeds[0].instinct);
    try testing.expectEqualStrings("forbid: no release on friday", p.seeds[0].content);
    // ⑤ 覆盖生效。
    try testing.expectEqual(llm.Provider.openai, p.llm.provider.?);
    try testing.expectEqualStrings("gpt-4o-mini", p.llm.model.?);
}

test "loadBytes: minimal profile uses defaults (a no-op generalist)" {
    const src =
        \\.{ .name = "generalist" }
    ;
    var reg = try loadBytes(testing.allocator, src);
    defer reg.deinit();

    const p = reg.profiles[0];
    try testing.expectEqualStrings("generalist", p.name);
    try testing.expectEqual(persona.Sensitivity.standard, p.sensitivity);
    try testing.expectApproxEqAbs(@as(f64, 0.1), p.learning_rate, 1e-9);
    try testing.expectEqual(@as(usize, 0), p.seeds.len);
    try testing.expect(p.llm.system_prompt == null);
}

test "loadBytes: unknown field is rejected (strict schema)" {
    const src =
        \\.{ .name = "x", .totally_unknown = 42 }
    ;
    try testing.expectError(error.BadConfig, loadBytes(testing.allocator, src));
}

test "loadBytes: api_key anywhere is rejected (secrets are env-only)" {
    // 顶层注入密钥。
    const top =
        \\.{ .name = "x", .api_key = "sk-should-never-parse" }
    ;
    try testing.expectError(error.BadConfig, loadBytes(testing.allocator, top));

    // 藏进 llm 子结构。
    const nested =
        \\.{ .name = "x", .llm = .{ .api_key = "sk-nope", .base_url = "http://10.0.0.1" } }
    ;
    try testing.expectError(error.BadConfig, loadBytes(testing.allocator, nested));
}

test "loadBytes: unknown sensitivity enum is rejected (cannot downgrade below standard)" {
    // 不存在 .relaxed/.off 等更低档位 → 解析失败，无法削弱零信任下界。
    const src =
        \\.{ .name = "x", .sensitivity = .relaxed }
    ;
    try testing.expectError(error.BadConfig, loadBytes(testing.allocator, src));
}

test "exportProfile round-trips memory back into a parseable ProfileConfig" {
    // 1) 从 ZON 载入一个专家（含 2 条种子）。
    const src =
        \\.{
        \\    .name = "zig-expert",
        \\    .description = "distilled",
        \\    .seeds = .{
        \\        .{ .context = "zig:build", .content = "installArtifact required", .confidence = 0.6 },
        \\        .{ .context = "zig:langref", .content = "forbid: usingnamespace removed", .confidence = 0.9, .instinct = true },
        \\    },
        \\    .learning_rate = 0.05,
        \\    .llm = .{ .system_prompt = "You are a Zig master." },
        \\}
    ;
    var reg = try loadBytes(testing.allocator, src);
    defer reg.deinit();
    const p0 = reg.profiles[0];

    // 2) 把种子注入 memory 并"学习"：让第 1 条成功一次（0.6 → 0.65）。
    var mem = memory.MemoryManager.init(testing.allocator);
    defer mem.deinit();
    mem.learning_rate = p0.learning_rate;
    var first_id: u64 = 0;
    for (p0.seeds, 0..) |s, i| {
        const id = try mem.addSeed(s.context, s.content, s.confidence);
        if (i == 0) first_id = id;
        if (s.instinct) if (mem.get(id)) |seed| {
            seed.instinct = true;
        };
    }
    var ids = [_]u64{first_id};
    mem.updateConfidence(&ids, .success);

    // 3) 回写为完整 ProfileConfig ZON。
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    try exportProfile(testing.allocator, &w.writer, metaFromProfile(p0), &mem, null);
    const written = w.written();
    const dumped = try testing.allocator.allocSentinel(u8, written.len, 0);
    defer testing.allocator.free(dumped);
    @memcpy(dumped, written);

    // 4) 重新加载 → 与演进后的 memory 状态一致（往返一致性）。
    var reg2 = try loadBytes(testing.allocator, dumped);
    defer reg2.deinit();
    const p1 = reg2.profiles[0];

    try testing.expectEqualStrings("zig-expert", p1.name);
    try testing.expectEqualStrings("distilled", p1.description);
    try testing.expectApproxEqAbs(@as(f64, 0.05), p1.learning_rate, 1e-9);
    try testing.expectEqualStrings("You are a Zig master.", p1.llm.system_prompt.?);
    try testing.expectEqual(@as(usize, 2), p1.seeds.len);
    // 演进后的置信度被持久化：0.6 + 0.05 = 0.65。
    try testing.expectEqualStrings("zig:build", p1.seeds[0].context);
    try testing.expectApproxEqAbs(@as(f64, 0.65), p1.seeds[0].confidence, 1e-9);
    // instinct 标志与 forbid 内容原样保留。
    try testing.expect(p1.seeds[1].instinct);
    try testing.expectEqualStrings("forbid: usingnamespace removed", p1.seeds[1].content);
}
