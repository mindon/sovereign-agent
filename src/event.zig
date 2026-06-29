//! 事件模型 (Event Sourcing 核心数据结构)
//!
//! 设计哲学：状态不可变。每一次 Agent 的决策都被编码为一条不可变的事件记录，
//! 以 JSONL 形式追加写入账本，支持确定性重放与审计。

const std = @import("std");
const Writer = std.Io.Writer;

/// 动作类型：读 / 写 / 执行 / 思考
pub const ActionType = enum {
    read,
    write,
    execute,
    think,

    /// 是否为敏感操作（写 / 改 / 执行）。
    /// 敏感操作必须经过仲裁层的强校验（同步 Pre-Check）。
    pub fn isSensitive(self: ActionType) bool {
        return switch (self) {
            .write, .execute => true,
            .read, .think => false,
        };
    }
};

/// 事件状态：待定 / 已提交 / 已拒绝
pub const EventStatus = enum {
    pending,
    committed,
    rejected,
};

/// Action：Agent 想要执行的一次操作意图（尚未落账）。
pub const Action = struct {
    /// 全局单调递增 id，由 AgentContext 分配。
    id: u64,
    action: ActionType,
    /// 用于检索启发式种子的上下文标签（如目标文件、主题）。
    context: []const u8,
    /// 操作负载（命令、内容、目标等）。
    payload: []const u8,
    /// 关联的启发式种子 id（驱动该决策的主要记忆）。
    seed_ref: ?u64 = null,
};

/// Event：落账后的不可变事件记录。
pub const Event = struct {
    id: u64,
    timestamp: i64,
    action: ActionType,
    payload: []const u8,
    seed_ref: ?u64,
    status: EventStatus,

    /// 从一个 Action + 状态构造事件（timestamp 取当前时间）。
    pub fn fromAction(action: Action, status: EventStatus, ts: i64) Event {
        return .{
            .id = action.id,
            .timestamp = ts,
            .action = action.action,
            .payload = action.payload,
            .seed_ref = action.seed_ref,
            .status = status,
        };
    }

    /// 将事件序列化为一行 JSON（不含换行）。
    pub fn writeJson(self: Event, w: *Writer) Writer.Error!void {
        try w.print(
            "{{\"id\":{d},\"timestamp\":{d},\"action\":\"{s}\",\"payload\":\"",
            .{ self.id, self.timestamp, @tagName(self.action) },
        );
        try writeJsonEscaped(w, self.payload);
        try w.writeAll("\",\"seed_ref\":");
        if (self.seed_ref) |ref| {
            try w.print("{d}", .{ref});
        } else {
            try w.writeAll("null");
        }
        try w.print(",\"status\":\"{s}\"}}", .{@tagName(self.status)});
    }
};

/// 将字符串以 JSON 安全方式转义后写出（不含外围引号）。
pub fn writeJsonEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

test "event json round-trippable shape" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ev: Event = .{
        .id = 7,
        .timestamp = 1000,
        .action = .write,
        .payload = "hello \"world\"\n",
        .seed_ref = 3,
        .status = .pending,
    };
    try ev.writeJson(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"action\":\"write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"world\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"seed_ref\":3") != null);
}

test "null seed_ref serialization" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ev: Event = .{
        .id = 1,
        .timestamp = 0,
        .action = .think,
        .payload = "x",
        .seed_ref = null,
        .status = .committed,
    };
    try ev.writeJson(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"seed_ref\":null") != null);
}
