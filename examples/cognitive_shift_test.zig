//! 测试二：元认知行为改变测试（The Cognitive Shift Test）
//!
//! 猜想：Agent 的行为不是静态的——它会**根据自身经验（置信度反馈）改变决策**。
//! 一颗最初被信任 (trusted) 的种子，在反复导致失败后置信度逐级跌落，最终落入
//! 危险层 (danger)；而一个会读取 `<confidence_stats>`（元认知）的决策大脑，
//! 一旦看到该种子已是 danger，便**不再据其行动**——这就是“元认知行为改变”。
//!
//! 这里用一个**确定性决策大脑**（而非真实 LLM）来隔离并放大该效应，使其完全
//! 可复现：大脑策略 = “只对非 danger 的种子采取行动”。
//!
//! 黑盒断言（仅经由公共接口观测）：
//!   1. 起始：种子为 trusted，大脑选择“行动”。
//!   2. 每次行动都因幻觉被仲裁拦截，置信度**单调下降**（trusted -> medium -> danger）。
//!   3. 种子跌入 danger 后，大脑**改变行为**：拒绝再据其行动（行动次数归零）。
//!   4. 这一认知迁移在 `<confidence_stats>` 中变得可见（被列入 DANGER 名单），
//!      即“元认知”可被反馈进后续 Prompt。
//!   5. 记忆全程保留（非完美记忆：失败计数累积 + 例外标记，不删除）。

const std = @import("std");
const lib = @import("sovereign");
const harness = @import("harness.zig");

const Dir = std.Io.Dir;
const Tier = lib.memory.Tier;

/// 确定性决策大脑：是否根据该种子采取行动。
/// 策略：读取种子的信任层级（元认知），只对**非 danger** 的种子行动。
fn brainWillAct(seed: *const lib.Seed) bool {
    return seed.tier() != .danger;
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    const journal_path = ".example_cognitive_journal.jsonl";
    dir.deleteFile(io, journal_path) catch {};

    var journal = lib.Journal.init(a, io, dir, journal_path);
    defer journal.deinit();
    try journal.ensureFile();

    var memory = lib.MemoryManager.init(a);
    defer memory.deinit();

    var arbiter = lib.Arbiter.init(io, dir);

    var ctx: lib.AgentContext = .{
        .gpa = a,
        .io = io,
        .dir = dir,
        .journal = &journal,
        .memory = &memory,
        .arbiter = &arbiter,
    };

    var chk = harness.Checker.init("测试二 元认知行为改变（The Cognitive Shift Test）");

    // 一颗最初被高度信任、却隐含幻觉断言的种子。
    const seed_id = try memory.addSeed(
        "risky-op",
        "assert_exists=/no/such/__ghost_artifact__",
        0.85,
    );

    // 起始时，该 trusted 种子不应出现在 <confidence_stats> 的 DANGER 名单中。
    {
        const stats0 = try memory.renderConfidenceStats(a);
        defer a.free(stats0);
        const listed = std.mem.indexOf(u8, stats0, "risky-op") != null;
        chk.check(!listed, "起始：trusted 种子未被列入 DANGER（元认知基线）");
    }

    chk.section("逐轮决策：观察“行动 -> 失败 -> 失信 -> 改变行为”");

    var attempts: usize = 0;
    var attempts_after_danger: usize = 0;
    var refused = false;
    var reached_danger = false;
    var first_tier: Tier = undefined;
    var prev_conf: f64 = std.math.inf(f64);
    var monotonic = true;

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        const s = memory.get(seed_id).?;
        const tier_now = s.tier();
        if (round == 0) first_tier = tier_now;
        if (tier_now == .danger) reached_danger = true;

        if (!brainWillAct(s)) {
            // 元认知触发：大脑因该种子已属 danger 而**拒绝**据其行动。
            refused = true;
            if (reached_danger) attempts_after_danger += 0; // 显式表达：danger 后不再行动
            chk.note("第{d}轮: conf={d:.2} tier={s} -> 大脑拒绝行动（元认知避险）", .{
                round + 1, s.confidence, @tagName(tier_now),
            });
            break;
        }

        // 大脑选择行动：提议一个由该种子驱动的写操作（将因幻觉被拦截）。
        chk.note("第{d}轮: conf={d:.2} tier={s} -> 大脑行动（提议写操作）", .{
            round + 1, s.confidence, @tagName(tier_now),
        });
        attempts += 1;
        if (reached_danger) attempts_after_danger += 1;

        const r = ctx.submit(.write, "risky-op", "#!/bin/sh\nexec /no/such/__ghost_artifact__\n");
        chk.check(r == error.VerificationFailed, "  行动被仲裁拦截 (VerificationFailed)");

        const after = memory.get(seed_id).?.confidence;
        if (!(after < prev_conf)) monotonic = false;
        prev_conf = after;
    }

    chk.section("断言：发生了元认知行为改变");
    chk.check(first_tier == .trusted, "起始决策层级为 trusted（大脑最初信任并行动）");
    chk.check(attempts >= 2, "在失信前进行了多轮行动（每轮均被拦截）");
    chk.check(ctx.rejected == attempts, "每次行动都落账为 rejected");
    chk.check(monotonic, "置信度随失败单调下降");
    chk.check(reached_danger, "种子最终跌入 danger 层（认知迁移完成）");
    chk.check(refused, "进入 danger 后大脑改变行为：拒绝再据其行动");
    chk.check(attempts_after_danger == 0, "danger 之后行动次数归零（行为确实改变）");

    chk.section("元认知可见性 + 记忆保全");
    const stats1 = try memory.renderConfidenceStats(a);
    defer a.free(stats1);
    chk.check(
        std.mem.indexOf(u8, stats1, "DANGER") != null and std.mem.indexOf(u8, stats1, "risky-op") != null,
        "迁移后该种子出现在 <confidence_stats> 的 DANGER 名单（可反馈进 Prompt）",
    );
    const s = memory.get(seed_id).?;
    chk.note("终态: conf={d:.2} tier={s} failures={d} exception={?s}", .{
        s.confidence, @tagName(s.tier()), s.failure_count, s.exception,
    });
    chk.check(s.failure_count == attempts, "失败计数累积（经验被记录）");
    chk.check(s.exception != null and memory.get(seed_id) != null, "记忆保留（非完美记忆：不删除，仅修正）");

    dir.deleteFile(io, journal_path) catch {};

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
