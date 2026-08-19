//! OpenAI-compatible Chat Completions provider.
//!
//! The provider speaks streaming SSE on the wire and normalizes deltas into the
//! core `provider.StreamEvent` shape. A `provider.TurnCollector` accumulates
//! those events into one `ModelTurn`, while an observer can watch the same
//! stream as it arrives.
//!
//! DeepSeek's endpoint speaks this wire with two documented differences
//! (api-docs.deepseek.com, "Thinking Mode"): thinking is on by default and is
//! switched off with `thinking: {type: "disabled"}` rather than an effort value,
//! and the `reasoning_content` of a tool-calling assistant turn MUST be sent back
//! on later requests of the same turn (the API answers 400 without it). Both are
//! handled here — the reasoning as one opaque `reasoning_item` per turn, exactly
//! the mechanism the Anthropic and Codex wires use for their replayable thinking.

const std = @import("std");
const prompt = @import("../prompt.zig");
const provider = @import("../provider.zig");
const tool = @import("../tool.zig");
const wire = @import("wire.zig");

const DEFAULT_BASE_URL = "https://api.openai.com/v1";
const DEFAULT_MODEL = "gpt-4o-mini";

pub const Config = struct {
    api_key: []const u8,
    model: []const u8 = DEFAULT_MODEL,
    base_url: []const u8 = DEFAULT_BASE_URL,
};

/// True for DeepSeek's OpenAI-compatible endpoint, whose thinking switch and
/// reasoning replay differ from OpenAI's own (see the module doc).
pub fn isDeepSeek(base_url: []const u8) bool {
    return std.mem.indexOf(u8, base_url, "deepseek.com") != null;
}

pub const OpenAiProvider = struct {
    alloc: std.mem.Allocator,
    client: std.http.Client,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    deepseek: bool,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, cfg: Config) !OpenAiProvider {
        const api_key = try alloc.dupe(u8, cfg.api_key);
        errdefer alloc.free(api_key);
        const model = try alloc.dupe(u8, cfg.model);
        errdefer alloc.free(model);
        const base_url = try alloc.dupe(u8, cfg.base_url);
        errdefer alloc.free(base_url);

        return .{
            .alloc = alloc,
            .client = .{
                .allocator = alloc,
                .io = io,
                .read_buffer_size = 64 * 1024,
            },
            .api_key = api_key,
            .model = model,
            .base_url = base_url,
            .deepseek = isDeepSeek(cfg.base_url),
        };
    }

    pub fn deinit(self: *OpenAiProvider) void {
        self.client.deinit();
        self.alloc.free(self.api_key);
        self.alloc.free(self.model);
        self.alloc.free(self.base_url);
        self.* = undefined;
    }

    pub fn modelHandle(self: *OpenAiProvider) provider.Model {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "openai-compatible";
    }

    fn modelName(ptr: *anyopaque) []const u8 {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
        return self.model;
    }

    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
        return .{ .thinking_replay = self.deepseek };
    }

    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
        const body = try buildRequestJson(alloc, self.model, self.deepseek, request);
        defer alloc.free(body);

        const url = try endpointUrl(alloc, self.base_url);
        defer alloc.free(url);
        const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
        defer alloc.free(auth);

        var state = SseState.init(alloc, sink);
        defer state.deinit();
        try wire.postSse(&self.client, alloc, .{
            .url = url,
            .body = body,
            .authorization = auth,
            .stall_ms = request.stall_ms,
        }, &state, SseState.onData);

        // `[DONE]` already emitted `done` and stopped the loop; reaching here
        // means the body ended without it.
        if (state.finish) |reason| {
            try state.flushReasoning();
            try sink.emit(.{ .done = reason });
        } else {
            return error.StreamEndedEarly;
        }
    }

    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

pub fn endpointUrl(alloc: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) return alloc.dupe(u8, trimmed);
    return std.fmt.allocPrint(alloc, "{s}/chat/completions", .{trimmed});
}

pub fn buildRequestJson(
    alloc: std.mem.Allocator,
    model: []const u8,
    deepseek: bool,
    request: provider.Request,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(model);
    try jw.objectField("stream");
    try jw.write(true);
    try jw.objectField("stream_options");
    try jw.beginObject();
    try jw.objectField("include_usage");
    try jw.write(true);
    try jw.endObject();
    // No `max_tokens` unless asked: the endpoint's own output limit is the right
    // default for a chat turn, and on backends that think by default the
    // reasoning is spent against the same cap.
    if (request.options.max_output_tokens) |max| {
        try jw.objectField("max_tokens");
        try jw.write(max);
    }
    // `off` is not an effort level on this wire: DeepSeek (thinking on by
    // default) takes an explicit `thinking` switch, everyone else gets nothing.
    // Any other level is the standard `reasoning_effort` dial.
    if (request.options.effort) |effort| {
        if (std.mem.eql(u8, effort, "off")) {
            if (deepseek) {
                try jw.objectField("thinking");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("disabled");
                try jw.endObject();
            }
        } else {
            try jw.objectField("reasoning_effort");
            try jw.write(effort);
        }
    }
    try jw.objectField("messages");
    try writeMessages(alloc, &jw, request.prompt_ir);
    if (request.tools.len != 0) {
        try jw.objectField("tools");
        try writeTools(&jw, request.tools);
        try jw.objectField("parallel_tool_calls");
        try jw.write(true);
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

fn writeMessages(alloc: std.mem.Allocator, jw: *std.json.Stringify, ir: *const prompt.PromptIR) !void {
    try jw.beginArray();
    for (ir.system_blocks) |block| {
        try writeRoleContentMessage(jw, "system", block.bytes);
    }
    for (ir.turns) |turn| switch (turn) {
        .user_text => |u| try writeUserMessage(alloc, jw, u),
        // One turn, one assistant message: text, this turn's reasoning and its
        // calls all belong to it.
        .assistant => |as| try writeAssistantMessage(alloc, jw, as),
        // A batch is one turn but one `role: "tool"` message per result — that
        // is simply how this wire spells it.
        .tool_results => |results| for (results) |result| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("tool");
            try jw.objectField("tool_call_id");
            try jw.write(result.call_id);
            try jw.objectField("content");
            try jw.write(result.output);
            try jw.endObject();
        },
        // A capability announcement (DESIGN §5.3): an out-of-band system
        // message the model reads to learn it can now shell out to a new
        // extension. Appended, so it never disturbs the cached prefix.
        .capability_note => |text| try writeRoleContentMessage(jw, "system", text),
        // A finished background task (DESIGN §3.1) does NOT follow it into the
        // system role: this text carries the output of an arbitrary process, and
        // the system role is the one place the model is entitled to read as the
        // harness speaking. `user` is what the other two wires already give it.
        .task_finished => |text| try writeRoleContentMessage(jw, "user", text),
    };
    try jw.endArray();
}

/// A user turn. WITHOUT images it is the plain-string form this endpoint has
/// always been sent — byte for byte, because that string is the implicit prefix
/// cache's key material and a turn that carries no picture must not move it.
/// With images it becomes the parts array, which is the only shape that can
/// carry one.
fn writeUserMessage(alloc: std.mem.Allocator, jw: *std.json.Stringify, u: prompt.Turn.UserText) !void {
    if (u.images.len == 0) return writeRoleContentMessage(jw, "user", u.text);
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("user");
    try jw.objectField("content");
    try jw.beginArray();
    // An image-only turn writes no text part rather than an empty one.
    if (u.text.len != 0) {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("text");
        try jw.objectField("text");
        try jw.write(u.text);
        try jw.endObject();
    }
    for (u.images) |img| {
        const uri = try wire.dataUri(alloc, img.media_type, img.data);
        defer alloc.free(uri);
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("image_url");
        try jw.objectField("image_url");
        try jw.beginObject();
        try jw.objectField("url");
        try jw.write(uri);
        try jw.endObject();
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeRoleContentMessage(jw: *std.json.Stringify, role: []const u8, content: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write(role);
    try jw.objectField("content");
    try jw.write(content);
    try jw.endObject();
}

fn writeAssistantMessage(alloc: std.mem.Allocator, jw: *std.json.Stringify, as: prompt.Turn.Assistant) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("assistant");
    try jw.objectField("content");
    if (as.text.len == 0 and as.calls.len != 0) {
        try jw.write(null);
    } else {
        try jw.write(as.text);
    }
    if (as.calls.len != 0) {
        // DeepSeek requires the CoT of a tool-calling turn on every later
        // request of that turn (400 otherwise) and ignores it elsewhere, so it
        // rides only on messages that carry tool_calls. Only this wire produces
        // `reasoning_content` items, so reasoning of another shape (a session
        // that ran on a different provider) contributes nothing.
        if (as.reasoning.len != 0) {
            const text = try joinReasoningContent(alloc, as.reasoning);
            defer alloc.free(text);
            if (text.len != 0) {
                try jw.objectField("reasoning_content");
                try jw.write(text);
            }
        }
        try jw.objectField("tool_calls");
        try jw.beginArray();
        for (as.calls) |call| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(call.id);
            try jw.objectField("type");
            try jw.write("function");
            try jw.objectField("function");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(call.tool);
            try jw.objectField("arguments");
            try jw.write(call.args_json);
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.endObject();
}

fn writeTools(jw: *std.json.Stringify, tools: []const tool.ToolDefinition) !void {
    try jw.beginArray();
    for (tools) |def| {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("function");
        try jw.objectField("function");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(def.name);
        try jw.objectField("description");
        try jw.write(def.description);
        try jw.objectField("parameters");
        try wire.writeRaw(jw, def.input_schema);
        try jw.endObject();
        try jw.endObject();
    }
    try jw.endArray();
}

/// The reasoning item this wire keeps for replay: the turn's whole
/// `reasoning_content` as one object, so `writeAssistantMessage` can hand it
/// back verbatim under the same field name. Opaque to the kernel like every
/// other provider's item; only this file reads it.
const reasoning_field = "reasoning_content";

/// Per-stream SSE state. Chat Completions has no explicit terminator other than
/// `[DONE]`, so the finish reason seen on the last chunk is carried here in case
/// the connection ends without one; the turn's `reasoning_content` deltas
/// accumulate here and leave as ONE `reasoning_item` right before `done`.
pub const SseState = struct {
    alloc: std.mem.Allocator,
    sink: provider.EventSink,
    finish: ?provider.StopReason = null,
    started: bool = false,
    reasoning: std.Io.Writer.Allocating,

    pub fn init(alloc: std.mem.Allocator, sink: provider.EventSink) SseState {
        return .{ .alloc = alloc, .sink = sink, .reasoning = .init(alloc) };
    }

    pub fn deinit(self: *SseState) void {
        self.reasoning.deinit();
        self.* = undefined;
    }

    fn onData(self: *SseState, data: []const u8) anyerror!bool {
        if (!self.started) {
            self.started = true;
            try self.sink.emit(.started);
        }
        return processSseData(self, data);
    }

    /// Emit the accumulated reasoning as one item (and forget it). A no-op when
    /// the model did not think aloud, so on non-reasoning endpoints the turn's
    /// `reasoning` stays empty.
    pub fn flushReasoning(self: *SseState) !void {
        const text = self.reasoning.written();
        if (text.len == 0) return;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField(reasoning_field);
        try jw.write(text);
        try jw.endObject();
        try self.sink.emit(.{ .reasoning_item = out.written() });
        self.reasoning.clearRetainingCapacity();
    }
};

pub fn processSseData(state: *SseState, data: []const u8) !bool {
    const alloc = state.alloc;
    const sink = state.sink;
    if (std.mem.eql(u8, data, "[DONE]")) {
        try state.flushReasoning();
        try sink.emit(.{ .done = state.finish orelse .end_turn });
        return true;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.OpenAiBadSse;

    if (wire.field(root, "usage")) |usage| {
        if (usage == .object) try sink.emit(.{ .usage = usageFrom(usage) });
    }

    const choices = wire.field(root, "choices") orelse return false;
    if (choices != .array or choices.array.items.len == 0) return false;
    const choice = choices.array.items[0];
    if (choice != .object) return error.OpenAiBadSse;

    if (wire.string(choice, "finish_reason")) |reason| {
        state.finish = stopReasonFrom(reason);
    }

    const delta = wire.field(choice, "delta") orelse return false;
    if (delta != .object) return error.OpenAiBadSse;

    if (wire.string(delta, "content")) |content| {
        if (content.len != 0) try sink.emit(.{ .text_delta = content });
    }
    if (wire.string(delta, reasoning_field)) |thinking| {
        if (thinking.len != 0) {
            // Display now, and keep for the turn's replayable item.
            try sink.emit(.{ .thinking_delta = thinking });
            try state.reasoning.writer.writeAll(thinking);
        }
    }
    if (wire.field(delta, "tool_calls")) |calls| {
        if (calls != .array) return error.OpenAiBadSse;
        for (calls.array.items) |call| try emitToolCallDelta(call, sink);
    }

    return false;
}

/// Concatenate the `reasoning_content` of every item in a turn's `reasoning`
/// (a JSON array; see `SseState.flushReasoning`). Items of another shape — from
/// a provider that is not this wire — contribute nothing. Caller owns the result.
fn joinReasoningContent(alloc: std.mem.Allocator, reasoning: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, reasoning, .{}) catch return out.toOwnedSlice();
    defer parsed.deinit();
    if (parsed.value != .array) return out.toOwnedSlice();
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        if (wire.string(item, reasoning_field)) |text| try out.writer.writeAll(text);
    }
    return out.toOwnedSlice();
}

fn emitToolCallDelta(call: std.json.Value, sink: provider.EventSink) !void {
    if (call != .object) return error.OpenAiBadSse;
    const index = if (wire.field(call, "index")) |v|
        if (v == .integer and v.integer >= 0) @as(usize, @intCast(v.integer)) else 0
    else
        0;

    var id: []const u8 = "";
    if (wire.string(call, "id")) |s| id = s;

    var name: []const u8 = "";
    var args: []const u8 = "";
    if (wire.field(call, "function")) |function| {
        if (function != .object) return error.OpenAiBadSse;
        if (wire.string(function, "name")) |s| name = s;
        if (wire.string(function, "arguments")) |s| args = s;
    }

    if (id.len != 0 or name.len != 0) {
        try sink.emit(.{ .tool_use_start = .{ .index = index, .id = id, .name = name } });
    }
    if (args.len != 0) {
        try sink.emit(.{ .tool_use_input_delta = .{ .index = index, .fragment = args } });
    }
}

fn usageFrom(v: std.json.Value) provider.Usage {
    const prompt_tokens = wire.uint(v, "prompt_tokens");
    const completion_tokens = wire.uint(v, "completion_tokens");
    var cached: u64 = 0;
    if (wire.field(v, "prompt_tokens_details")) |details| {
        if (details == .object) cached = wire.uint(details, "cached_tokens");
    }
    if (cached == 0) cached = wire.uint(v, "prompt_cache_hit_tokens");
    return .{
        .input_tokens = prompt_tokens -| cached,
        .output_tokens = completion_tokens,
        .cache_read_tokens = cached,
        .cache_write_tokens = 0,
    };
}

fn stopReasonFrom(s: []const u8) provider.StopReason {
    if (std.mem.eql(u8, s, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, s, "stop")) return .end_turn;
    if (std.mem.eql(u8, s, "length")) return .max_tokens;
    return .other;
}

test "endpoint URL appends chat completions path once" {
    const alloc = std.testing.allocator;
    const a = try endpointUrl(alloc, "https://api.openai.com/v1/");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", a);

    const b = try endpointUrl(alloc, "https://example.test/v1/chat/completions");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("https://example.test/v1/chat/completions", b);
}

test "request JSON serializes streaming prompt turns and tools" {
    const alloc = std.testing.allocator;
    var l = @import("../ledger.zig").Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hello" } });
    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);

    const defs = [_]tool.ToolDefinition{.{
        .id = "builtin.shell",
        .name = "shell",
        .description = "run shell",
        .input_schema = "{\"type\":\"object\"}",
    }};
    const body = try buildRequestJson(alloc, "test-model", false, .{
        .prompt_ir = &ir,
        .tools = &defs,
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"test-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"}") != null);
}

test "SSE parser extracts streamed text tool calls usage and done" {
    const alloc = std.testing.allocator;
    var collector = provider.TurnCollector.init(alloc);
    defer collector.deinit();
    var state = SseState.init(alloc, collector.sink());
    defer state.deinit();

    try std.testing.expect(!try processSseData(&state,
        \\{"choices":[{"delta":{"content":"run"},"finish_reason":null}]}
    ));
    try std.testing.expect(!try processSseData(&state,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"shell","arguments":"{\"command\":"}}]},"finish_reason":null}]}
    ));
    try std.testing.expect(!try processSseData(&state,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"echo hi\"}"}}]},"finish_reason":"tool_calls"}]}
    ));
    try std.testing.expect(!try processSseData(&state,
        \\{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}
    ));
    try std.testing.expect(try processSseData(&state, "[DONE]"));

    const turn = try collector.finish();
    defer turn.deinit(alloc);
    try std.testing.expectEqualStrings("run", turn.text);
    // No reasoning_content on the wire → no reasoning item at all.
    try std.testing.expectEqualStrings("", turn.reasoning);
    try std.testing.expectEqual(@as(usize, 1), turn.calls.len);
    try std.testing.expectEqualStrings("call_1", turn.calls[0].id);
    try std.testing.expectEqualStrings("shell", turn.calls[0].tool);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", turn.calls[0].args_json);
    // Usage now survives the collector into the ModelTurn (DESIGN §1 measurability).
    try std.testing.expectEqual(@as(u64, 20), turn.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 80), turn.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 5), turn.usage.output_tokens);
    try std.testing.expectEqual(provider.StopReason.tool_use, turn.stop_reason);
}

test "DeepSeek: effort off disables thinking, other levels are reasoning_effort, OpenAI proper gets nothing for off" {
    const alloc = std.testing.allocator;
    var l = @import("../ledger.zig").Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hi" } });
    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);

    const off = try buildRequestJson(alloc, "deepseek-v4-flash", true, .{ .prompt_ir = &ir, .tools = &.{}, .options = .{ .effort = "off" } });
    defer alloc.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, off, "reasoning_effort") == null);

    const high = try buildRequestJson(alloc, "deepseek-v4-flash", true, .{ .prompt_ir = &ir, .tools = &.{}, .options = .{ .effort = "high" } });
    defer alloc.free(high);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"thinking\"") == null);

    // An absent effort is the server default (thinking on) — nothing is sent.
    const auto = try buildRequestJson(alloc, "deepseek-v4-flash", true, .{ .prompt_ir = &ir, .tools = &.{} });
    defer alloc.free(auto);
    try std.testing.expect(std.mem.indexOf(u8, auto, "\"thinking\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, auto, "reasoning_effort") == null);

    // OpenAI's own endpoint has no `thinking` switch: `off` sends nothing.
    const openai_off = try buildRequestJson(alloc, "gpt-x", false, .{ .prompt_ir = &ir, .tools = &.{}, .options = .{ .effort = "off" } });
    defer alloc.free(openai_off);
    try std.testing.expect(std.mem.indexOf(u8, openai_off, "\"thinking\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, openai_off, "reasoning_effort") == null);

    try std.testing.expect(isDeepSeek("https://api.deepseek.com"));
    try std.testing.expect(!isDeepSeek("https://api.openai.com/v1"));
}

test "DeepSeek: a tool-calling turn's reasoning_content is kept as one item and replayed on that assistant message" {
    const alloc = std.testing.allocator;
    var collector = provider.TurnCollector.init(alloc);
    defer collector.deinit();
    var state = SseState.init(alloc, collector.sink());
    defer state.deinit();

    // The CoT streams in pieces before the call; the item is emitted whole at [DONE].
    _ = try processSseData(&state,
        \\{"choices":[{"delta":{"reasoning_content":"I should "},"finish_reason":null}]}
    );
    _ = try processSseData(&state,
        \\{"choices":[{"delta":{"reasoning_content":"run ls."},"finish_reason":null}]}
    );
    _ = try processSseData(&state,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls\"}"}}]},"finish_reason":"tool_calls"}]}
    );
    try std.testing.expect(try processSseData(&state, "[DONE]"));

    const turn = try collector.finish();
    defer turn.deinit(alloc);
    try std.testing.expectEqualStrings("[{\"reasoning_content\":\"I should run ls.\"}]", turn.reasoning);
    try std.testing.expectEqual(@as(usize, 1), turn.calls.len);

    // Ledger → projection → request: the assistant message carries it back,
    // ahead of its tool_calls, and the tool result follows as usual.
    var l = @import("../ledger.zig").Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "list files" } });
    try l.append(.{ .assistant = .{ .reasoning = turn.reasoning, .text = turn.text, .calls = turn.calls } });
    try l.append(.{ .tool_results = &.{.{ .call_id = "call_1", .ok = true, .output = "a.txt" }} });
    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);
    const body = try buildRequestJson(alloc, "deepseek-v4-flash", true, .{ .prompt_ir = &ir, .tools = &.{} });
    defer alloc.free(body);
    const reasoning_at = std.mem.indexOf(u8, body, "\"reasoning_content\":\"I should run ls.\"") orelse return error.ReasoningNotReplayed;
    const calls_at = std.mem.indexOf(u8, body, "\"tool_calls\":[").?;
    const result_at = std.mem.indexOf(u8, body, "\"role\":\"tool\"").?;
    try std.testing.expect(reasoning_at < calls_at and calls_at < result_at);
    // The raw item array never leaks onto the wire.
    try std.testing.expect(std.mem.indexOf(u8, body, "[{\"reasoning_content\"") == null);
}

test "reasoning without tool calls, or of another provider's shape, is not replayed" {
    const alloc = std.testing.allocator;
    var l = @import("../ledger.zig").Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "q" } });
    // A text-only turn: DeepSeek ignores its CoT on later turns, so it stays home.
    try l.append(.{ .assistant = .{ .reasoning = "[{\"reasoning_content\":\"private\"}]", .text = "answer", .calls = &.{} } });
    try l.append(.{ .user_text = .{ .text = "again" } });
    // A tool-calling turn whose reasoning came from an Anthropic-shaped item.
    try l.append(.{ .assistant = .{
        .reasoning = "[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"sig\"}]",
        .text = "",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{}" }},
    } });
    try l.append(.{ .tool_results = &.{.{ .call_id = "c1", .ok = true, .output = "" }} });
    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);
    const body = try buildRequestJson(alloc, "deepseek-v4-flash", true, .{ .prompt_ir = &ir, .tools = &.{} });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_content") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "plan") == null);
}

test "request JSON serializes system blocks before ledger turns" {
    const alloc = std.testing.allocator;
    var l = @import("../ledger.zig").Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hello" } });
    const sys = [_]prompt.SystemBlock{.{ .source = "kernel", .bytes = "system base" }};
    const ir = try prompt.projectWithSystem(alloc, &sys, l.view());
    defer ir.deinit(alloc);

    const body = try buildRequestJson(alloc, "test-model", false, .{
        .prompt_ir = &ir,
        .tools = &.{},
    });
    defer alloc.free(body);

    const system_pos = std.mem.indexOf(u8, body, "\"role\":\"system\"") orelse return error.MissingSystemMessage;
    const user_pos = std.mem.indexOf(u8, body, "\"role\":\"user\"") orelse return error.MissingUserMessage;
    try std.testing.expect(system_pos < user_pos);
    try std.testing.expect(std.mem.indexOf(u8, body, "system base") != null);
}

test "a finished background task is a user message here, not a system one like a capability note" {
    const alloc = std.testing.allocator;
    const L = @import("../ledger.zig").Ledger;

    var l = L.init(alloc);
    defer l.deinit();
    try l.append(.{ .capability_note = .{ .id = "demo", .version = "v-a", .text = "note text" } });
    try l.append(.{ .task_finished = .{ .task = "s-1/t3", .exit_code = 0, .text = "task text" } });
    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);
    const body = try buildRequestJson(alloc, "test-model", false, .{ .prompt_ir = &ir, .tools = &.{} });
    defer alloc.free(body);

    // The note keeps the system role it has always had — the kernel wrote every
    // byte of it. The task report carries an arbitrary process's output, so it
    // goes where the other two wires already put it: the user role.
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"system\",\"content\":\"note text\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"user\",\"content\":\"task text\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"system\",\"content\":\"task text\"}") == null);
}

test "an image turn becomes a parts array; a turn without one keeps the plain-string body byte for byte" {
    const alloc = std.testing.allocator;
    const L = @import("../ledger.zig").Ledger;

    // The shape this endpoint has always been sent, captured from a ledger that
    // knows nothing about images.
    var plain = L.init(alloc);
    defer plain.deinit();
    try plain.append(.{ .user_text = .{ .text = "hello" } });
    const plain_ir = try prompt.project(alloc, plain.view());
    defer plain_ir.deinit(alloc);
    const plain_body = try buildRequestJson(alloc, "test-model", false, .{ .prompt_ir = &plain_ir, .tools = &.{} });
    defer alloc.free(plain_body);
    // Not merely "contains": the whole user message is the pre-image bytes, so
    // the implicit prefix cache sees the same key material it always did.
    try std.testing.expect(std.mem.indexOf(u8, plain_body, "{\"role\":\"user\",\"content\":\"hello\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_body, "image_url") == null);

    var shot = L.init(alloc);
    defer shot.deinit();
    try shot.append(.{ .user_text = .{
        .text = "what is this",
        .images = &.{.{ .media_type = "image/png", .data = "iVBORw0=" }},
    } });
    const shot_ir = try prompt.project(alloc, shot.view());
    defer shot_ir.deinit(alloc);
    const shot_body = try buildRequestJson(alloc, "test-model", false, .{ .prompt_ir = &shot_ir, .tools = &.{} });
    defer alloc.free(shot_body);
    try std.testing.expect(std.mem.indexOf(u8, shot_body, "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"what is this\"}," ++
        "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,iVBORw0=\"}}]}") != null);

    // An image with nothing said about it writes no empty text part.
    var bare = L.init(alloc);
    defer bare.deinit();
    try bare.append(.{ .user_text = .{ .text = "", .images = &.{.{ .media_type = "image/jpeg", .data = "/9j/" }} } });
    const bare_ir = try prompt.project(alloc, bare.view());
    defer bare_ir.deinit(alloc);
    const bare_body = try buildRequestJson(alloc, "test-model", false, .{ .prompt_ir = &bare_ir, .tools = &.{} });
    defer alloc.free(bare_body);
    try std.testing.expect(std.mem.indexOf(u8, bare_body, "{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,/9j/\"}}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare_body, "\"type\":\"text\"") == null);
}
