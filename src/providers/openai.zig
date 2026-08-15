//! OpenAI-compatible Chat Completions provider.
//!
//! The provider speaks streaming SSE on the wire and normalizes deltas into the
//! core `provider.StreamEvent` shape. `provider.Model.step` can still collect
//! those events into one `ModelTurn`, while a future TUI can subscribe to the
//! same stream directly.

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

pub const OpenAiProvider = struct {
    alloc: std.mem.Allocator,
    client: std.http.Client,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,

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
        _ = ptr;
        return .{
            .parallel_tool_calls = true,
            .cached_token_metrics = true,
        };
    }

    /// Per-stream SSE state. Chat Completions has no explicit terminator other
    /// than `[DONE]`, so the finish reason seen on the last chunk is carried
    /// here in case the connection ends without one.
    const StreamState = struct {
        alloc: std.mem.Allocator,
        sink: provider.EventSink,
        finish: ?provider.StopReason = null,
        started: bool = false,

        fn onData(self: *StreamState, data: []const u8) anyerror!bool {
            if (!self.started) {
                self.started = true;
                try self.sink.emit(.started);
            }
            return processSseData(self.alloc, data, self.sink, &self.finish);
        }
    };

    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
        const body = try buildRequestJson(alloc, self.model, request);
        defer alloc.free(body);

        const url = try endpointUrl(alloc, self.base_url);
        defer alloc.free(url);
        const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
        defer alloc.free(auth);

        var state: StreamState = .{ .alloc = alloc, .sink = sink };
        try wire.postSse(&self.client, alloc, .{
            .url = url,
            .body = body,
            .authorization = auth,
        }, &state, StreamState.onData);

        // `[DONE]` already emitted `done` and stopped the loop; reaching here
        // means the body ended without it.
        if (state.finish) |reason| {
            try sink.emit(.{ .done = reason });
        } else {
            return error.OpenAiStreamEndedEarly;
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
    if (request.options.max_output_tokens) |max| {
        try jw.objectField("max_tokens");
        try jw.write(max);
    }
    if (request.options.effort) |effort| {
        try jw.objectField("reasoning_effort");
        try jw.write(effort);
    }
    try jw.objectField("messages");
    try writeMessages(&jw, request.prompt_ir);
    if (request.tools.len != 0) {
        try jw.objectField("tools");
        try writeTools(&jw, request.tools);
        try jw.objectField("parallel_tool_calls");
        try jw.write(true);
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

fn writeMessages(jw: *std.json.Stringify, ir: *const prompt.PromptIR) !void {
    try jw.beginArray();
    for (ir.system_blocks) |block| {
        try writeRoleContentMessage(jw, "system", block.bytes);
    }
    var i: usize = 0;
    while (i < ir.stable_blocks.len) {
        const block = ir.stable_blocks[i];
        switch (block.kind) {
            .user_text => {
                try writeRoleContentMessage(jw, "user", block.bytes);
                i += 1;
            },
            // Chat Completions has no replayable reasoning (`reasoning_content`
            // is output-only on the endpoints that have it), and this provider
            // never emits `reasoning_item`; a block here comes from a session
            // whose model did, and it is not for this wire. Skipped, not sent.
            .reasoning => i += 1,
            .assistant_text => {
                const start = i + 1;
                var end = start;
                while (end < ir.stable_blocks.len and ir.stable_blocks[end].kind == .tool_call) : (end += 1) {}
                try writeAssistantMessage(jw, block.bytes, ir.stable_blocks[start..end]);
                i = end;
            },
            // `project()` always emits an assistant_text block before any
            // tool_call blocks, so the `.assistant_text` arm above consumes them.
            // A tool_call at top level would mean the projection invariant broke.
            .tool_call => unreachable,
            .tool_result => {
                const result = wire.parseToolResult(block.bytes);
                try jw.beginObject();
                try jw.objectField("role");
                try jw.write("tool");
                try jw.objectField("tool_call_id");
                try jw.write(result.id);
                try jw.objectField("content");
                try jw.write(result.output);
                try jw.endObject();
                i += 1;
            },
            // A capability announcement (DESIGN §5.3): an out-of-band system
            // message the model reads to learn it can now shell out to a new
            // extension. Appended, so it never disturbs the cached prefix.
            .capability_note => {
                try writeRoleContentMessage(jw, "system", block.bytes);
                i += 1;
            },
        }
    }
    try jw.endArray();
}

fn writeRoleContentMessage(jw: *std.json.Stringify, role: []const u8, content: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write(role);
    try jw.objectField("content");
    try jw.write(content);
    try jw.endObject();
}

fn writeAssistantMessage(jw: *std.json.Stringify, content: []const u8, calls: []const prompt.StableBlock) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("assistant");
    try jw.objectField("content");
    if (content.len == 0 and calls.len != 0) {
        try jw.write(null);
    } else {
        try jw.write(content);
    }
    if (calls.len != 0) {
        try jw.objectField("tool_calls");
        try jw.beginArray();
        for (calls) |call_block| {
            const call = wire.parseToolCall(call_block.bytes);
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(call.id);
            try jw.objectField("type");
            try jw.write("function");
            try jw.objectField("function");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(call.name);
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

pub fn processSseData(
    alloc: std.mem.Allocator,
    data: []const u8,
    sink: provider.EventSink,
    finish: *?provider.StopReason,
) !bool {
    if (std.mem.eql(u8, data, "[DONE]")) {
        try sink.emit(.{ .done = finish.* orelse .end_turn });
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
        finish.* = stopReasonFrom(reason);
    }

    const delta = wire.field(choice, "delta") orelse return false;
    if (delta != .object) return error.OpenAiBadSse;

    if (wire.string(delta, "content")) |content| {
        if (content.len != 0) try sink.emit(.{ .text_delta = content });
    }
    if (wire.string(delta, "reasoning_content")) |thinking| {
        if (thinking.len != 0) try sink.emit(.{ .thinking_delta = thinking });
    }
    if (wire.field(delta, "tool_calls")) |calls| {
        if (calls != .array) return error.OpenAiBadSse;
        for (calls.array.items) |call| try emitToolCallDelta(call, sink);
    }

    return false;
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

test "request JSON serializes streaming prompt blocks and tools" {
    const alloc = std.testing.allocator;
    var l = @import("../ledger.zig").Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "hello" });
    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);

    const defs = [_]tool.ToolDefinition{.{
        .id = "builtin.shell",
        .name = "shell",
        .description = "run shell",
        .input_schema = "{\"type\":\"object\"}",
    }};
    const body = try buildRequestJson(alloc, "test-model", .{
        .prompt_ir = &ir,
        .tools = &defs,
        .generation = 0,
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
    const sink = collector.sink();
    var finish: ?provider.StopReason = null;

    try std.testing.expect(!try processSseData(alloc,
        \\{"choices":[{"delta":{"content":"run"},"finish_reason":null}]}
    , sink, &finish));
    try std.testing.expect(!try processSseData(alloc,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"shell","arguments":"{\"command\":"}}]},"finish_reason":null}]}
    , sink, &finish));
    try std.testing.expect(!try processSseData(alloc,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"echo hi\"}"}}]},"finish_reason":"tool_calls"}]}
    , sink, &finish));
    try std.testing.expect(!try processSseData(alloc,
        \\{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}
    , sink, &finish));
    try std.testing.expect(try processSseData(alloc, "[DONE]", sink, &finish));

    const turn = try collector.finish();
    defer turn.deinit(alloc);
    try std.testing.expectEqualStrings("run", turn.text);
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

test "request JSON serializes system blocks before stable ledger blocks" {
    const alloc = std.testing.allocator;
    var l = @import("../ledger.zig").Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "hello" });
    const sys = [_]prompt.SystemBlock{.{ .source = "kernel", .bytes = "system base" }};
    const ir = try prompt.projectWithSystem(alloc, &sys, l.view());
    defer ir.deinit(alloc);

    const body = try buildRequestJson(alloc, "test-model", .{
        .prompt_ir = &ir,
        .tools = &.{},
        .generation = 0,
    });
    defer alloc.free(body);

    const system_pos = std.mem.indexOf(u8, body, "\"role\":\"system\"") orelse return error.MissingSystemMessage;
    const user_pos = std.mem.indexOf(u8, body, "\"role\":\"user\"") orelse return error.MissingUserMessage;
    try std.testing.expect(system_pos < user_pos);
    try std.testing.expect(std.mem.indexOf(u8, body, "system base") != null);
}
