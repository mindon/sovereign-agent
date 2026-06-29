//! LLM 接入层：Ollama 本地推理客户端（/api/chat）。
//!
//! 设计哲学：LLM 是“决策建议者”，不是权威。它读取分层信任的记忆种子与
//! <confidence_stats>，产出一个**结构化决策 (JSON)**；该决策随后被强制
//! 送入 `transact` 闭环（仲裁预校验 -> 落账 -> 执行 -> 提交/回滚）。
//! 即便模型产生幻觉，仲裁层的物理校验仍是最终防线。
//!
//! 安全性：
//!   * 仅通过 std.http.Client 访问显式配置的 base_url（默认 127.0.0.1:11434），
//!     不调用任何 shell（防 RCE）。
//!   * 响应一律用 std.json 安全解析（防不可信反序列化）。
//!   * 决策中的 action 字符串经白名单 enum 映射，非法值直接拒绝。

const std = @import("std");
const event = @import("event.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ActionType = event.ActionType;

pub const LlmError = error{
    HttpStatus,
    BadResponse,
    BadDecision,
    UnknownAction,
};

/// 模型产出的结构化决策。字符串生命周期归调用方传入的 allocator（建议 arena）。
pub const Decision = struct {
    action: ActionType,
    context: []const u8,
    payload: []const u8,
    reason: []const u8,
};

/// Ollama 本地客户端。
pub const OllamaClient = struct {
    gpa: Allocator,
    http: std.http.Client,
    /// 形如 "http://127.0.0.1:11434"（无尾斜杠）。
    base_url: []const u8,
    model: []const u8,

    pub fn init(gpa: Allocator, io: Io, base_url: []const u8, model: []const u8) OllamaClient {
        return .{
            .gpa = gpa,
            .http = .{ .allocator = gpa, .io = io },
            .base_url = base_url,
            .model = model,
        };
    }

    pub fn deinit(self: *OllamaClient) void {
        self.http.deinit();
    }

    /// 调用 /api/chat（非流式）。返回 assistant 消息的 content（调用方释放）。
    /// json_mode=true 时令 Ollama 以 JSON 模式输出（更适合结构化决策）。
    pub fn chat(
        self: *OllamaClient,
        gpa: Allocator,
        system: []const u8,
        user: []const u8,
        json_mode: bool,
    ) ![]u8 {
        const body = try buildChatBody(gpa, self.model, system, user, json_mode);
        defer gpa.free(body);

        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{self.base_url});

        var resp: std.Io.Writer.Allocating = .init(gpa);
        defer resp.deinit();

        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .response_writer = &resp.writer,
        });
        if (result.status != .ok) return LlmError.HttpStatus;

        const raw = try resp.toOwnedSlice();
        defer gpa.free(raw);
        return parseContent(gpa, raw);
    }
};

/// 构造 Ollama /api/chat 的请求体 JSON（temperature=0 以追求确定性）。
pub fn buildChatBody(
    gpa: Allocator,
    model: []const u8,
    system: []const u8,
    user: []const u8,
    json_mode: bool,
) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    const iw = &w.writer;

    try iw.writeAll("{\"model\":\"");
    try event.writeJsonEscaped(iw, model);
    try iw.writeAll("\",\"stream\":false,");
    if (json_mode) try iw.writeAll("\"format\":\"json\",");
    try iw.writeAll("\"options\":{\"temperature\":0},\"messages\":[");
    try iw.writeAll("{\"role\":\"system\",\"content\":\"");
    try event.writeJsonEscaped(iw, system);
    try iw.writeAll("\"},{\"role\":\"user\",\"content\":\"");
    try event.writeJsonEscaped(iw, user);
    try iw.writeAll("\"}]}");

    return w.toOwnedSlice();
}

/// 从 Ollama 非流式响应中安全提取 message.content（调用方释放）。
pub fn parseContent(gpa: Allocator, body: []const u8) ![]u8 {
    const Resp = struct {
        message: struct { content: []const u8 },
    };
    var parsed = std.json.parseFromSlice(Resp, gpa, body, .{ .ignore_unknown_fields = true }) catch
        return LlmError.BadResponse;
    defer parsed.deinit();
    return gpa.dupe(u8, parsed.value.message.content);
}

/// 解析模型输出的结构化决策 JSON。字符串分配在传入的 arena 上。
/// 期望形如：{"action":"write","context":"config.json","payload":"...","reason":"..."}
pub fn parseDecision(arena: Allocator, content: []const u8) !Decision {
    const Raw = struct {
        action: []const u8,
        context: []const u8,
        payload: []const u8,
        reason: ?[]const u8 = null,
    };
    const raw = std.json.parseFromSliceLeaky(Raw, arena, content, .{ .ignore_unknown_fields = true }) catch
        return LlmError.BadDecision;
    const at = std.meta.stringToEnum(ActionType, raw.action) orelse return LlmError.UnknownAction;
    return .{
        .action = at,
        .context = raw.context,
        .payload = raw.payload,
        .reason = raw.reason orelse "",
    };
}

// ---------------------------------------------------------------------------
// Tests（纯函数，不依赖网络）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "buildChatBody emits valid escaped JSON with json_mode" {
    const body = try buildChatBody(testing.allocator, "gemma4:latest", "be \"safe\"", "do x\n", true);
    defer testing.allocator.free(body);
    // 形似 JSON 且字段齐全
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gemma4:latest\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"format\":\"json\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "be \\\"safe\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "do x\\n") != null);
    // 整体可被 JSON 解析器接受
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
}

test "buildChatBody omits format when json_mode=false" {
    const body = try buildChatBody(testing.allocator, "m", "s", "u", false);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"format\"") == null);
}

test "parseContent extracts message.content ignoring unknown fields" {
    const sample =
        \\{"model":"gemma4:latest","created_at":"2026-06-29T00:00:00Z","message":{"role":"assistant","content":"hello world"},"done":true,"total_duration":123}
    ;
    const content = try parseContent(testing.allocator, sample);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "parseDecision maps action string to enum and reads fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const content =
        \\{"action":"write","context":"config.json","payload":"{\"mode\":\"safe\"}","reason":"init config"}
    ;
    const d = try parseDecision(arena.allocator(), content);
    try testing.expectEqual(ActionType.write, d.action);
    try testing.expectEqualStrings("config.json", d.context);
    try testing.expectEqualStrings("init config", d.reason);
    try testing.expect(std.mem.indexOf(u8, d.payload, "safe") != null);
}

test "parseDecision rejects unknown action" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const content =
        \\{"action":"nuke","context":"x","payload":"y"}
    ;
    try testing.expectError(LlmError.UnknownAction, parseDecision(arena.allocator(), content));
}

test "parseDecision tolerates missing reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const content =
        \\{"action":"read","context":"a","payload":"b"}
    ;
    const d = try parseDecision(arena.allocator(), content);
    try testing.expectEqual(ActionType.read, d.action);
    try testing.expectEqualStrings("", d.reason);
}
