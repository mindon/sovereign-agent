//! LLM 接入层：多后端推理客户端。
//!
//! 支持两类后端（Provider）：
//!   * `.ollama` —— 本地 Ollama (`POST {base}/api/chat`)。
//!   * `.openai` —— 任意 **OpenAI 兼容**端点 (`POST {base}/v1/chat/completions`)，
//!                  覆盖 OpenAI / DeepSeek / Groq / Together / vLLM / LM Studio 等。
//!
//! 设计哲学：LLM 是“决策建议者”，不是权威。它读取分层信任的记忆种子与
//! <confidence_stats>，产出一个**结构化决策 (JSON)**；该决策随后被强制
//! 送入 `transact` 闭环（仲裁预校验 -> 落账 -> 执行 -> 提交/回滚）。
//! 即便模型产生幻觉，仲裁层的物理校验仍是最终防线。
//!
//! 安全性：
//!   * 仅通过 std.http.Client 访问**显式配置**的 base_url（默认本地
//!     127.0.0.1:11434），不调用任何 shell（防 RCE）。
//!   * 响应一律用 std.json 安全解析（防不可信反序列化）。
//!   * 决策中的 action 字符串经白名单 enum 映射，非法值直接拒绝。
//!   * **密钥仅来自环境变量**（`LLM_API_KEY` / `OPENAI_API_KEY`），绝不硬编码、
//!     绝不写入日志或账本（Secrets: env-only）。

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

/// 推理后端类型。
pub const Provider = enum {
    ollama,
    openai,

    /// 从字符串解析（大小写需匹配 enum 名）。未知返回 null。
    pub fn fromString(s: []const u8) ?Provider {
        return std.meta.stringToEnum(Provider, s);
    }
};

/// 模型产出的结构化决策。字符串生命周期归调用方传入的 allocator（建议 arena）。
pub const Decision = struct {
    action: ActionType,
    context: []const u8,
    payload: []const u8,
    reason: []const u8,
};

/// 通用 LLM 客户端（provider-aware）。
pub const LlmClient = struct {
    gpa: Allocator,
    http: std.http.Client,
    provider: Provider,
    /// 形如 "http://127.0.0.1:11434" 或 "https://api.openai.com"（无尾斜杠）。
    base_url: []const u8,
    model: []const u8,
    /// 鉴权密钥（仅 OpenAI 兼容后端使用）。来源必须是环境变量，绝不记录到日志。
    api_key: ?[]const u8 = null,

    pub fn init(
        gpa: Allocator,
        io: Io,
        provider: Provider,
        base_url: []const u8,
        model: []const u8,
        api_key: ?[]const u8,
    ) LlmClient {
        return .{
            .gpa = gpa,
            .http = .{ .allocator = gpa, .io = io },
            .provider = provider,
            .base_url = stripTrailingSlash(base_url),
            .model = model,
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *LlmClient) void {
        self.http.deinit();
    }

    /// 发起一次（非流式）对话补全。返回 assistant 消息的 content（调用方释放）。
    /// json_mode=true 时请求结构化 JSON 输出（更适合决策）。
    pub fn chat(
        self: *LlmClient,
        gpa: Allocator,
        system: []const u8,
        user: []const u8,
        json_mode: bool,
    ) ![]u8 {
        const body = switch (self.provider) {
            .ollama => try buildChatBody(gpa, self.model, system, user, json_mode),
            .openai => try buildOpenAiChatBody(gpa, self.model, system, user, json_mode),
        };
        defer gpa.free(body);

        var url_buf: [1024]u8 = undefined;
        const url = try buildChatUrl(&url_buf, self.provider, self.base_url);

        // —— 请求头：content-type 必备；OpenAI 兼容后端附加 Bearer 鉴权 ——
        var headers_buf: [2]std.http.Header = undefined;
        var nheaders: usize = 0;
        headers_buf[nheaders] = .{ .name = "content-type", .value = "application/json" };
        nheaders += 1;

        var auth_value: ?[]u8 = null;
        defer if (auth_value) |v| gpa.free(v);
        if (self.provider == .openai) {
            if (self.api_key) |key| {
                auth_value = try std.fmt.allocPrint(gpa, "Bearer {s}", .{key});
                headers_buf[nheaders] = .{ .name = "authorization", .value = auth_value.? };
                nheaders += 1;
            }
        }

        var resp: std.Io.Writer.Allocating = .init(gpa);
        defer resp.deinit();

        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = headers_buf[0..nheaders],
            .response_writer = &resp.writer,
        });
        if (result.status != .ok) return LlmError.HttpStatus;

        const raw = try resp.toOwnedSlice();
        defer gpa.free(raw);
        return switch (self.provider) {
            .ollama => parseContent(gpa, raw),
            .openai => parseOpenAiContent(gpa, raw),
        };
    }
};

/// 向后兼容别名：原 Ollama 专用客户端，保留四参 init 签名。
pub const OllamaClient = struct {
    inner: LlmClient,

    pub fn init(gpa: Allocator, io: Io, base_url: []const u8, model: []const u8) OllamaClient {
        return .{ .inner = LlmClient.init(gpa, io, .ollama, base_url, model, null) };
    }

    pub fn deinit(self: *OllamaClient) void {
        self.inner.deinit();
    }

    pub fn chat(
        self: *OllamaClient,
        gpa: Allocator,
        system: []const u8,
        user: []const u8,
        json_mode: bool,
    ) ![]u8 {
        return self.inner.chat(gpa, system, user, json_mode);
    }
};

/// 从环境变量装配的运行配置。所有字符串生命周期归内部 arena（deinit 释放）。
///
/// 识别的环境变量：
///   LLM_PROVIDER  : "ollama" | "openai"（默认 ollama）
///   LLM_BASE_URL  : 端点根（缺省按 provider 取默认；兼容旧 OLLAMA_BASE_URL）
///   LLM_MODEL     : 模型名（缺省按 provider 取默认；兼容旧 OLLAMA_MODEL）
///   LLM_API_KEY / OPENAI_API_KEY : 鉴权密钥（仅 openai；env-only）
pub const EnvConfig = struct {
    arena: std.heap.ArenaAllocator,
    provider: Provider,
    base_url: []const u8,
    model: []const u8,
    api_key: ?[]const u8,

    /// 从进程环境变量映射装配配置。`env` 即 `std.process.Init.environ_map`
    /// （由运行时在 main 入口解析提供）。env 派生值会被复制进本结构的 arena。
    pub fn load(gpa: Allocator, env: *const std.process.Environ.Map) !EnvConfig {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const provider: Provider = blk: {
            if (env.get("LLM_PROVIDER")) |v| break :blk Provider.fromString(v) orelse .ollama;
            break :blk .ollama;
        };

        const base_url = try pick(aa, env.get("LLM_BASE_URL") orelse env.get("OLLAMA_BASE_URL"), defaultBaseUrl(provider));
        const model = try pick(aa, env.get("LLM_MODEL") orelse env.get("OLLAMA_MODEL"), defaultModel(provider));

        // 密钥仅来自环境变量（env-only）。
        const api_key: ?[]const u8 = if (env.get("LLM_API_KEY") orelse env.get("OPENAI_API_KEY")) |k|
            try aa.dupe(u8, k)
        else
            null;

        return .{
            .arena = arena,
            .provider = provider,
            .base_url = base_url,
            .model = model,
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *EnvConfig) void {
        self.arena.deinit();
    }

    /// 用本配置构造一个 LlmClient（借用本配置持有的字符串，勿在 deinit 后使用）。
    pub fn client(self: *const EnvConfig, gpa: Allocator, io: Io) LlmClient {
        return LlmClient.init(gpa, io, self.provider, self.base_url, self.model, self.api_key);
    }
};

/// 有值则复制进 arena，否则返回静态默认（默认值具静态生命周期，无需复制）。
fn pick(aa: Allocator, opt: ?[]const u8, default: []const u8) ![]const u8 {
    if (opt) |v| return try aa.dupe(u8, v);
    return default;
}

fn defaultBaseUrl(p: Provider) []const u8 {
    return switch (p) {
        .ollama => "http://127.0.0.1:11434",
        .openai => "https://api.openai.com",
    };
}

fn defaultModel(p: Provider) []const u8 {
    return switch (p) {
        .ollama => "gemma4:latest",
        .openai => "gpt-4o-mini",
    };
}

fn stripTrailingSlash(s: []const u8) []const u8 {
    if (s.len > 1 and s[s.len - 1] == '/') return s[0 .. s.len - 1];
    return s;
}

/// 按 provider 拼装对话补全 URL（写入调用方提供的缓冲区）。
/// 对 OpenAI 兼容端点做容错：已含 `/chat/completions` 或以 `/v1` 结尾时不重复追加。
pub fn buildChatUrl(buf: []u8, provider: Provider, base_url: []const u8) ![]const u8 {
    return switch (provider) {
        .ollama => std.fmt.bufPrint(buf, "{s}/api/chat", .{base_url}),
        .openai => blk: {
            if (std.mem.endsWith(u8, base_url, "/chat/completions"))
                break :blk std.fmt.bufPrint(buf, "{s}", .{base_url});
            if (std.mem.endsWith(u8, base_url, "/v1"))
                break :blk std.fmt.bufPrint(buf, "{s}/chat/completions", .{base_url});
            break :blk std.fmt.bufPrint(buf, "{s}/v1/chat/completions", .{base_url});
        },
    };
}

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

/// 构造 OpenAI 兼容 /v1/chat/completions 的请求体 JSON（temperature=0）。
pub fn buildOpenAiChatBody(
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
    try iw.writeAll("\",\"temperature\":0,\"stream\":false,");
    if (json_mode) try iw.writeAll("\"response_format\":{\"type\":\"json_object\"},");
    try iw.writeAll("\"messages\":[{\"role\":\"system\",\"content\":\"");
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

/// 从 OpenAI 兼容响应中安全提取 choices[0].message.content（调用方释放）。
pub fn parseOpenAiContent(gpa: Allocator, body: []const u8) ![]u8 {
    const Resp = struct {
        choices: []const struct {
            message: struct { content: []const u8 },
        },
    };
    var parsed = std.json.parseFromSlice(Resp, gpa, body, .{ .ignore_unknown_fields = true }) catch
        return LlmError.BadResponse;
    defer parsed.deinit();
    if (parsed.value.choices.len == 0) return LlmError.BadResponse;
    return gpa.dupe(u8, parsed.value.choices[0].message.content);
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
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gemma4:latest\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"format\":\"json\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "be \\\"safe\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "do x\\n") != null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
}

test "buildChatBody omits format when json_mode=false" {
    const body = try buildChatBody(testing.allocator, "m", "s", "u", false);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"format\"") == null);
}

test "buildOpenAiChatBody emits valid JSON with response_format" {
    const body = try buildOpenAiChatBody(testing.allocator, "gpt-4o-mini", "sys", "usr", true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o-mini\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"response_format\":{\"type\":\"json_object\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
}

test "buildOpenAiChatBody omits response_format when json_mode=false" {
    const body = try buildOpenAiChatBody(testing.allocator, "m", "s", "u", false);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "response_format") == null);
}

test "buildChatUrl per provider and OpenAI variants" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "http://127.0.0.1:11434/api/chat",
        try buildChatUrl(&buf, .ollama, "http://127.0.0.1:11434"),
    );
    try testing.expectEqualStrings(
        "https://api.openai.com/v1/chat/completions",
        try buildChatUrl(&buf, .openai, "https://api.openai.com"),
    );
    // 已以 /v1 结尾：只补 /chat/completions
    try testing.expectEqualStrings(
        "https://api.groq.com/openai/v1/chat/completions",
        try buildChatUrl(&buf, .openai, "https://api.groq.com/openai/v1"),
    );
    // 已是完整路径：原样返回
    try testing.expectEqualStrings(
        "https://x.example/v1/chat/completions",
        try buildChatUrl(&buf, .openai, "https://x.example/v1/chat/completions"),
    );
}

test "Provider.fromString maps known and rejects unknown" {
    try testing.expectEqual(Provider.ollama, Provider.fromString("ollama").?);
    try testing.expectEqual(Provider.openai, Provider.fromString("openai").?);
    try testing.expect(Provider.fromString("anthropic") == null);
}

test "parseContent extracts message.content ignoring unknown fields" {
    const sample =
        \\{"model":"gemma4:latest","created_at":"2026-06-29T00:00:00Z","message":{"role":"assistant","content":"hello world"},"done":true,"total_duration":123}
    ;
    const content = try parseContent(testing.allocator, sample);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "parseOpenAiContent extracts choices[0].message.content" {
    const sample =
        \\{"id":"chatcmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"hi there"},"finish_reason":"stop"}],"usage":{"total_tokens":5}}
    ;
    const content = try parseOpenAiContent(testing.allocator, sample);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hi there", content);
}

test "parseOpenAiContent rejects empty choices" {
    const sample =
        \\{"choices":[]}
    ;
    try testing.expectError(LlmError.BadResponse, parseOpenAiContent(testing.allocator, sample));
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
