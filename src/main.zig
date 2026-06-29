//! Sovereign-Agent —— 基于确定性账本与分层信任的自治 Agent 底层架构。
//!
//! 本 Main Loop 演示完整闭环：
//!   1. 注入分层信任的记忆种子；
//!   2. 强制所有工具调用经由 `transact`（检索 -> 仲裁 -> 落账 -> 执行 -> 提交/回滚）；
//!   3. 触发一次“记忆-事实冲突”，演示 Contextual Exception；
//!   4. 通过 `rebuildState()` 从账本确定性地重建状态并审计一致性。

const std = @import("std");
const lib = @import("root.zig");

const Action = lib.Action;
const Dir = std.Io.Dir;

/// 演示用执行器：在工作目录的沙箱子目录内写文件，支持回滚（删除）。
const FileExecutor = struct {
    sandbox: []const u8,

    fn doFn(ctx: *anyopaque, io: std.Io, dir: Dir, action: Action) anyerror!bool {
        const self: *FileExecutor = @ptrCast(@alignCast(ctx));
        // action.context 作为沙箱内的相对文件名。
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.sandbox, action.context });
        var file = try dir.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, action.payload);
        return true;
    }

    fn undoFn(ctx: *anyopaque, io: std.Io, dir: Dir, action: Action) anyerror!void {
        const self: *FileExecutor = @ptrCast(@alignCast(ctx));
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.sandbox, action.context }) catch return;
        dir.deleteFile(io, path) catch {};
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = Dir.cwd();

    const sandbox = ".sovereign_sandbox";
    const journal_path = ".sovereign_journal.jsonl";

    // 全新演示：清理上一轮产物。
    dir.deleteFile(io, journal_path) catch {};
    dir.createDirPath(io, sandbox) catch {};

    // —— 组装核心模块 ——
    var journal = lib.Journal.init(a, io, dir, journal_path);
    defer journal.deinit();
    try journal.ensureFile();

    var memory = lib.MemoryManager.init(a);
    defer memory.deinit();

    var arbiter = lib.Arbiter.init(io, dir);

    var executor = FileExecutor{ .sandbox = sandbox };

    var ctx: lib.AgentContext = .{
        .gpa = a,
        .io = io,
        .dir = dir,
        .journal = &journal,
        .memory = &memory,
        .arbiter = &arbiter,
        .executor = .{ .ctx = @ptrCast(&executor), .doFn = FileExecutor.doFn, .undoFn = FileExecutor.undoFn },
        .verbose = true,
    };

    // —— 注入分层信任的记忆种子 ——
    _ = try memory.addSeed("config.json", "this project uses JSONC config", 0.75);
    _ = try memory.addSeed("notes.txt", "free-form notes are safe to append", 0.55);
    // 一条“危险”的高置信度幻觉记忆：断言一个并不存在的文件。
    const halluc = try memory.addSeed("deploy.sh", "assert_exists=__ghost_binary__.bin", 0.9);

    std.debug.print("\n=== Sovereign-Agent 演示开始 ===\n\n", .{});

    // —— Main Loop：所有工具调用必须经由 transact ——

    std.debug.print("[1] 合法写入 config.json\n", .{});
    try ctx.submit(.write, "config.json", "{\"mode\":\"safe\"}");

    std.debug.print("[2] 合法追加 notes.txt\n", .{});
    try ctx.submit(.write, "notes.txt", "remember: ledger is append-only");

    std.debug.print("[3] 只读检索（异步预校验，不阻塞）\n", .{});
    try ctx.submit(.read, "config.json", "lookup mode");

    std.debug.print("[4] 触发记忆-事实冲突（防幻觉）\n", .{});
    ctx.submit(.write, "deploy.sh", "rm -rf /") catch |err| {
        std.debug.print("    -> 被仲裁拒绝: {s}\n", .{@errorName(err)});
    };

    std.debug.print("[5] 非法负载（畸形 JSON）被拒绝\n", .{});
    ctx.submit(.write, "config.json", "{bad json") catch |err| {
        std.debug.print("    -> 被仲裁拒绝: {s}\n", .{@errorName(err)});
    };

    // —— 置信度演进可视化 ——
    std.debug.print("\n--- confidence_stats（第二阶段）---\n", .{});
    const stats = try memory.renderConfidenceStats(a);
    defer a.free(stats);
    std.debug.print("{s}", .{stats});

    std.debug.print("被标记为环境特异性例外的幻觉种子 #{d}: exception={?s}, conf={d:.2}\n\n", .{
        halluc,
        memory.get(halluc).?.exception,
        memory.get(halluc).?.confidence,
    });

    // —— 确定性重放与审计（第三阶段）——
    std.debug.print("--- 确定性重放 rebuildState() ---\n", .{});
    var state = try lib.rebuildState(a, io, dir, journal_path);
    defer state.deinit();
    const audit = try state.renderAudit(a);
    defer a.free(audit);
    std.debug.print("{s}", .{audit});

    std.debug.print("\n统计：committed={d} rejected={d} (账本一致性={})\n", .{
        ctx.committed, ctx.rejected, state.isConsistent(),
    });
    std.debug.print("\n=== 演示结束（账本文件: {s}）===\n", .{journal_path});
}

test {
    // 聚合所有模块的单元测试。
    std.testing.refAllDecls(lib);
}
