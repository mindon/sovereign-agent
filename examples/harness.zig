//! 黑盒测试微框架（examples 共用）。
//!
//! 这些 example 把 Sovereign-Agent 当作**黑盒**：只经由 `root.zig` 导出的
//! 公共接口（MemoryManager / Arbiter / AgentContext / transact / rebuildState）
//! 驱动并断言可观测行为，不触碰任何内部实现，也**不依赖网络**——因此完全
//! 确定性、CI 友好。
//!
//! `Checker` 收集断言通过/失败计数，最终 `report()` 返回进程退出码
//! （0 = 全过；非 0 = 有失败），让每个 example 同时充当一个可在 CI 中
//! gating 的黑盒测试。

const std = @import("std");

pub const Checker = struct {
    title: []const u8,
    passed: usize = 0,
    failed: usize = 0,

    pub fn init(title: []const u8) Checker {
        std.debug.print("\n================ {s} ================\n", .{title});
        return .{ .title = title };
    }

    /// 断言一个条件，打印 PASS/FAIL 并计数。
    pub fn check(self: *Checker, cond: bool, label: []const u8) void {
        if (cond) {
            self.passed += 1;
            std.debug.print("  [PASS] {s}\n", .{label});
        } else {
            self.failed += 1;
            std.debug.print("  [FAIL] {s}\n", .{label});
        }
    }

    /// 仅打印一行说明（不计入断言）。
    pub fn note(_: *Checker, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("  · " ++ fmt ++ "\n", args);
    }

    pub fn section(_: *Checker, name: []const u8) void {
        std.debug.print("\n--- {s} ---\n", .{name});
    }

    /// 汇总并返回进程退出码（0=全部通过）。
    pub fn report(self: *Checker) u8 {
        std.debug.print(
            "\n---- 结果: {s} —— 通过 {d}，失败 {d} ----\n",
            .{ self.title, self.passed, self.failed },
        );
        if (self.failed == 0) {
            std.debug.print("==> 黑盒测试通过 (PASS)\n", .{});
            return 0;
        }
        std.debug.print("==> 黑盒测试失败 (FAIL)\n", .{});
        return 1;
    }
};

/// 浮点近似相等（容差）。
pub fn approx(a: f64, b: f64, tol: f64) bool {
    return @abs(a - b) <= tol;
}
