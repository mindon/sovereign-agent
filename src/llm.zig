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
const memory = @import("memory.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ActionType = event.ActionType;

/// 蒸馏产出的种子投影（复用 `memory.DistilledSeed`：context/content/confidence，
/// **无 instinct 字段**——本能绝不能由模型直接写出）。别名仅为在本模块内命名清晰。
pub const DistilledSeed = memory.DistilledSeed;

pub const LlmError = error{
    HttpStatus,
    BadResponse,
    BadDecision,
    UnknownAction,
    BadDistillation,
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

    /// **在线自蒸馏 (self-distillation)**：让 LLM 把一段原始知识文本 `raw_text` 蒸馏成
    /// 结构化启发式种子（JSON），供 `memory.ingestDistilled` **零信任**安全注入。
    ///
    /// 契约（强制 JSON 对象输出）：`{"seeds":[{"context":"...","content":"...","confidence":0.x}, ...]}`
    ///   * `content` 是一条**简洁、可验证**的启发式假设（非全文摘录）；
    ///   * `confidence ∈ [0, 0.5]`：蒸馏产物是"待审知识"，天然低信任；
    ///   * 输出**不含** instinct/forbid 反射——本能只能靠运行期验证或人工 review 烧录。
    ///
    /// 内存：`gpa` 用于 HTTP 传输期临时分配（内部释放）；返回的种子字符串分配在 `arena`
    /// 上（leaky，随 arena 释放）。安全性：只访问显式配置的 `base_url`，不发起任意外联、
    /// 不执行 shell；喂给本函数的 `raw_text` 应由调用方在白名单内抓取（防 SSRF）。
    pub fn distill(
        self: *LlmClient,
        gpa: Allocator,
        arena: Allocator,
        domain: []const u8,
        raw_text: []const u8,
    ) ![]const DistilledSeed {
        var up: std.Io.Writer.Allocating = .init(gpa);
        defer up.deinit();
        try up.writer.print(
            "DOMAIN: {s}\n\nRAW KNOWLEDGE (distill heuristics from the text below; do not invent facts):\n{s}",
            .{ domain, raw_text },
        );

        const content = try self.chat(gpa, DISTILL_SYSTEM_PROMPT, up.writer.buffered(), true);
        defer gpa.free(content);
        return parseDistilled(arena, content);
    }
};

/// 自蒸馏系统提示词：约束模型只输出结构化、低信任、可验证的启发式种子。
pub const DISTILL_SYSTEM_PROMPT =
    \\You are a KNOWLEDGE DISTILLER for a zero-trust autonomous agent's memory.
    \\Read the raw knowledge text and distill it into a small set of concise,
    \\independently VERIFIABLE heuristic seeds. Do NOT copy long passages; do NOT
    \\invent facts not supported by the text.
    \\
    \\Reply with STRICTLY a single JSON object (no markdown, no prose):
    \\{"seeds":[{"context":"<short domain tag>","content":"<one verifiable heuristic>","confidence":<0.0-0.5>}, ...]}
    \\
    \\Hard rules:
    \\  - Each "content" is ONE actionable, testable assumption (not a summary).
    \\  - "confidence" MUST be between 0.0 and 0.5: distilled knowledge is UNTRUSTED
    \\    until verified at runtime; never claim high confidence.
    \\  - NEVER output instincts, reflexes, or unconditional "forbid/veto" rules:
    \\    those are earned only by repeated runtime success or human review.
    \\  - Prefer 3-8 seeds. If the text yields nothing useful, return {"seeds":[]}.
;

/// 解析模型输出的蒸馏 JSON（`{"seeds":[...]}`）。种子字符串分配在传入的 `arena`
/// 上（leaky）。安全：`ignore_unknown_fields=true` 容忍模型多吐字段（含它若擅自
/// 添加的 instinct 字段——本投影根本不含该字段，会被安全忽略，绝不会被注入）。
pub fn parseDistilled(arena: Allocator, content: []const u8) ![]const DistilledSeed {
    const Raw = struct {
        seeds: []const DistilledSeed,
    };
    const raw = std.json.parseFromSliceLeaky(Raw, arena, content, .{ .ignore_unknown_fields = true }) catch
        return LlmError.BadDistillation;
    return raw.seeds;
}

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

test "parseDistilled extracts seeds and ignores model-injected instinct field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 模型擅自塞了 "instinct":true —— 投影无此字段，被安全忽略（绝不会被注入为本能）。
    const content =
        \\{"seeds":[
        \\  {"context":"zig:build","content":"installArtifact required for outputs","confidence":0.4},
        \\  {"context":"zig:std","content":"use std.mem.eql for byte compare","confidence":0.3,"instinct":true}
        \\]}
    ;
    const seeds = try parseDistilled(arena.allocator(), content);
    try testing.expectEqual(@as(usize, 2), seeds.len);
    try testing.expectEqualStrings("zig:build", seeds[0].context);
    try testing.expectApproxEqAbs(@as(f64, 0.4), seeds[0].confidence, 1e-9);
    try testing.expectEqualStrings("use std.mem.eql for byte compare", seeds[1].content);
}

test "parseDistilled tolerates empty seed set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const seeds = try parseDistilled(arena.allocator(), "{\"seeds\":[]}");
    try testing.expectEqual(@as(usize, 0), seeds.len);
}

test "parseDistilled rejects malformed JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(LlmError.BadDistillation, parseDistilled(arena.allocator(), "not json"));
}

test "distilled seeds are safely injected as non-instinct, low-confidence memory" {
    // 端到端（纯本地、无网络）：parseDistilled → ingestDistilled 的零信任约束。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const content =
        \\{"seeds":[
        \\  {"context":"build","content":"prefer release=safe","confidence":0.9},
        \\  {"context":"deploy","content":"forbid: never deploy on friday","confidence":1.0}
        \\]}
    ;
    const seeds = try parseDistilled(arena.allocator(), content);

    var mem = memory.MemoryManager.init(testing.allocator);
    defer mem.deinit();
    const n = try mem.ingestDistilled("zig", seeds, 0.5);
    try testing.expectEqual(@as(usize, 2), n);
    // 零信任红线：无论模型给出多高置信度或 forbid 字样，注入后均为非本能、置信度受限。
    try testing.expect(!mem.hasInstincts());
    for (mem.seeds.items) |s| {
        try testing.expect(!s.instinct);
        try testing.expect(s.confidence <= 0.5 + 1e-9);
    }
}
