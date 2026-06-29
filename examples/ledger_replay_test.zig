//! 测试三：金融级确定性重放测试（Ledger Replay Test）
//!
//! 猜想：账本是**不可变、可审计、确定性可重放**的——给定同一份 append-only
//! 账本，任意次数、任意时刻的 `rebuildState()` 都折叠出**完全一致**的状态与审计
//! 结论；任何对账本行的篡改/损坏都会被检出；账本只增不改，且增长后的重放依旧
//! 确定。这正是“金融级”的核心：可复现、可对账、防篡改。
//!
//! 黑盒断言（仅经由公共接口观测）：
//!   1. 同一账本两次独立重放，审计报告**逐字节一致**（确定性）。
//!   2. 折叠结果与执行期计数一致（committed/rejected/一致性/max_id）。
//!   3. 逐事务（按 id）终态在两次重放间完全相同。
//!   4. 篡改/损坏的账本行被 `rebuildState` 检出为 error.CorruptJournal（防篡改）。
//!   5. 账本只增不改：追加新事务后重放反映增长，且重复重放仍然确定。

const std = @import("std");
const lib = @import("sovereign");
const harness = @import("harness.zig");

const Dir = std.Io.Dir;

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    const journal_path = ".example_ledger_journal.jsonl";
    const tamper_path = ".example_ledger_tamper.jsonl";
    dir.deleteFile(io, journal_path) catch {};
    dir.deleteFile(io, tamper_path) catch {};

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

    var chk = harness.Checker.init("测试三 金融级确定性重放（Ledger Replay Test）");

    // —— 构造一段混合事务流（3 提交 + 2 拒绝），全程离线、无网络 ——
    chk.section("构造账本：3 提交 + 2 拒绝");
    try ctx.submit(.write, "config.json", "{\"port\":8080,\"host\":\"0.0.0.0\"}"); // commit
    try ctx.submit(.write, "notes.txt", "ledger is append-only"); // commit
    ctx.submit(.write, "config.json", "{bad json") catch {}; // reject: 畸形 JSON
    ctx.submit(.execute, "cleanup", "rm -rf / --no-preserve-root") catch {}; // reject: 危险命令
    try ctx.submit(.write, "app.json", "{\"feature\":true}"); // commit
    chk.note("执行期计数: committed={d} rejected={d}", .{ ctx.committed, ctx.rejected });

    // —— 断言 1：两次独立重放，审计逐字节一致 ——
    chk.section("断言：确定性重放（逐字节一致）");
    var state1 = try lib.rebuildState(a, io, dir, journal_path);
    defer state1.deinit();
    var state2 = try lib.rebuildState(a, io, dir, journal_path);
    defer state2.deinit();

    const audit1 = try state1.renderAudit(a);
    defer a.free(audit1);
    const audit2 = try state2.renderAudit(a);
    defer a.free(audit2);
    chk.check(std.mem.eql(u8, audit1, audit2), "两次重放的审计报告逐字节一致");

    // —— 断言 2：折叠结果与执行期计数一致 ——
    chk.section("断言：折叠结果与执行期对账一致");
    chk.note("审计:\n{s}", .{audit1});
    chk.check(state1.committed == 3, "committed = 3");
    chk.check(state1.rejected == 2, "rejected = 2");
    chk.check(state1.pending == 0 and state1.isConsistent(), "无悬挂 pending，账本一致");
    chk.check(state1.max_id == 5, "max_id = 5");
    chk.check(state1.committed == ctx.committed and state1.rejected == ctx.rejected, "重放计数 == 执行期计数（对账）");

    // —— 断言 3：逐事务终态在两次重放间完全相同 ——
    chk.section("断言：逐事务终态可复现");
    var per_id_equal = true;
    var id: u64 = 1;
    while (id <= state1.max_id) : (id += 1) {
        const s1 = state1.latest.get(id);
        const s2 = state2.latest.get(id);
        if (s1 == null or s2 == null or s1.?.status != s2.?.status) per_id_equal = false;
    }
    chk.check(state1.max_id == state2.max_id and state1.total_records == state2.total_records, "记录数与 max_id 一致");
    chk.check(per_id_equal, "每个事务 id 的终态在两次重放间相同");

    // —— 断言 4：篡改/损坏检出（防篡改）——
    chk.section("断言：篡改检出（防篡改）");
    {
        const good = try dir.readFileAlloc(io, journal_path, a, .unlimited);
        defer a.free(good);
        var f = try dir.createFile(io, tamper_path, .{ .truncate = true });
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var fw = f.writer(io, &buf);
        const w = &fw.interface;
        try w.writeAll(good);
        try w.writeAll("{ tampered : not valid json }\n"); // 注入一行损坏记录
        try w.flush();
    }
    if (lib.rebuildState(a, io, dir, tamper_path)) |st| {
        var bad = st;
        bad.deinit();
        chk.check(false, "损坏账本本应被拒绝（却成功重放）");
    } else |err| {
        chk.check(err == error.CorruptJournal, "损坏的账本行被检出为 CorruptJournal");
    }

    // —— 断言 5：只增不改 + 增长后仍确定 ——
    chk.section("断言：append-only 增长后重放仍确定");
    try ctx.submit(.write, "extra.json", "{\"ok\":true}"); // 追加一笔提交
    var grown1 = try lib.rebuildState(a, io, dir, journal_path);
    defer grown1.deinit();
    var grown2 = try lib.rebuildState(a, io, dir, journal_path);
    defer grown2.deinit();
    const ga1 = try grown1.renderAudit(a);
    defer a.free(ga1);
    const ga2 = try grown2.renderAudit(a);
    defer a.free(ga2);
    chk.check(grown1.committed == 4 and grown1.max_id == 6, "增长后 committed=4, max_id=6");
    chk.check(grown1.isConsistent(), "增长后账本仍一致");
    chk.check(std.mem.eql(u8, ga1, ga2), "增长后重复重放仍逐字节一致");
    chk.check(!std.mem.eql(u8, ga1, audit1), "增长前后审计不同（确实反映了 append）");

    dir.deleteFile(io, journal_path) catch {};
    dir.deleteFile(io, tamper_path) catch {};

    const code = chk.report();
    if (code != 0) std.process.exit(code);
}
