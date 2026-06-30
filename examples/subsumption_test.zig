//! 黑盒测试四：包容式行为栈 (The Subsumption Test)
//!
//! 猜想：仲裁不再是单层校验，而是一个**分层反射栈**（Brooks 包容架构）：
//! 低层反射（安全/资源）优先级最高、可抢占高层（启发式/规划）。
//! 关键论断——**即便上层 LLM 规划完全失控，确定性的低层反射仍是物理保命防线**，
//! 且绝大多数危险/越界操作**毫秒级被否决、无需触达模型**。
//!
//! 黑盒断言（仅经由公共接口 Arbiter.verify / Verdict.layer 观测）：
//!   1. L0 安全包络：破坏性命令被反射否决，裁决归因 "L0:safety-envelope"。
//!   2. L1 资源约束：超预算负载被反射否决，裁决归因 "L1:resource"。
//!   3. L2 记忆启发式：畸形 JSON 被否决，裁决归因 "L2:heuristic"。
//!   4. 注入的本能反射优先级最高：抢占内置层，裁决归因到本能层名。
//!   5. 干净操作放行，裁决归因 "default"（全部行为层通过）。

const std = @import("std");
const lib = @import("sovereign");
const harness = @import("harness.zig");

const Dir = std.Io.Dir;
const Io = std.Io;
const Action = lib.Action;
const Verdict = lib.Verdict;
const SeedClaim = lib.arbiter.SeedClaim;

/// 一条“烧录”出来的本能反射：永不写入任何 production 上下文（最高优先级）。
const NoProd = struct {
    fn check(_: *anyopaque, _: Io, _: Dir, action: Action, _: []const SeedClaim) anyerror!?Verdict {
        if (action.action == .write and std.mem.indexOf(u8, action.context, "production") != null)
            return Verdict{ .ok = false, .reason = "instinct: never write production" };
        return null; // 否则弃权，交由内置层
    }
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    var arb = lib.Arbiter.init(io, dir);

    var chk = harness.Checker.init("测试四 包容式行为栈（The Subsumption Test）");

    // —— L0 安全包络反射：危险命令，不依赖 LLM、毫秒级、绝对优先 ——
    chk.section("Layer 0：安全包络反射（破坏性命令）");
    const danger: Action = .{ .id = 1, .action = .execute, .context = "cleanup", .payload = "rm -rf /" };
    chk.check(!try arb.verify(danger, &.{}), "破坏性命令 rm -rf / 被反射否决");
    chk.note("裁决层=\"{s}\" reason=\"{s}\"", .{ arb.last.layer, arb.last.reason });
    chk.check(std.mem.eql(u8, arb.last.layer, "L0:safety-envelope"), "裁决归因到 L0:safety-envelope");

    // —— L1 资源约束反射：超出负载预算 ——
    chk.section("Layer 1：资源约束反射（超预算负载）");
    const big = try a.alloc(u8, lib.arbiter.MAX_PAYLOAD_BYTES + 1);
    defer a.free(big);
    @memset(big, 'a'); // 纯字母：不触发 L0 的穿越/危险命令，自然下沉到 L1
    const oversized: Action = .{ .id = 2, .action = .write, .context = "blob", .payload = big };
    chk.check(!try arb.verify(oversized, &.{}), "超预算负载被反射否决");
    chk.note("裁决层=\"{s}\"", .{arb.last.layer});
    chk.check(std.mem.eql(u8, arb.last.layer, "L1:resource"), "裁决归因到 L1:resource");

    // —— L2 记忆启发式：畸形 JSON（最慢、最低优先级） ——
    chk.section("Layer 2：记忆启发式校验（畸形 JSON）");
    const bad_json: Action = .{ .id = 3, .action = .write, .context = "config.json", .payload = "{not valid" };
    chk.check(!try arb.verify(bad_json, &.{}), "畸形 JSON 被启发式层否决");
    chk.note("裁决层=\"{s}\"", .{arb.last.layer});
    chk.check(std.mem.eql(u8, arb.last.layer, "L2:heuristic"), "裁决归因到 L2:heuristic");

    // —— 注入本能反射：优先级高于全部内置层，抢占裁决 ——
    chk.section("本能反射抢占：注入层先于内置安全包络");
    var dummy: u8 = 0;
    const layers = [_]lib.Layer{.{ .name = "instinct:no-prod", .ctx = @ptrCast(&dummy), .check = NoProd.check }};
    arb.stack.reflexes = &layers;
    // 这是一个本会通过全部内置层的“干净”写，但被烧录的本能反射抢占否决。
    const prod_write: Action = .{ .id = 4, .action = .write, .context = "production.cfg", .payload = "{\"ok\":1}" };
    chk.check(!try arb.verify(prod_write, &.{}), "写 production 被注入的本能反射否决");
    chk.note("裁决层=\"{s}\" reason=\"{s}\"", .{ arb.last.layer, arb.last.reason });
    chk.check(std.mem.eql(u8, arb.last.layer, "instinct:no-prod"), "裁决归因到最高优先级本能层");
    arb.stack.reflexes = &.{}; // 复位

    // —— 干净操作：全部行为层放行 ——
    chk.section("干净操作：穿过所有层，default 放行");
    const clean: Action = .{ .id = 5, .action = .write, .context = "notes.md", .payload = "hello world" };
    chk.check(try arb.verify(clean, &.{}), "合法写入被放行（无误杀）");
    chk.check(std.mem.eql(u8, arb.last.layer, "default"), "裁决归因到 default（全部层通过）");

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
