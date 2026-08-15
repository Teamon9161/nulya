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

    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));
        const body = try buildRequestJson(alloc, self.model, request);
        defer alloc.free(body);

        const url = try endpointUrl(alloc, self.base_url);
        defer alloc.free(url);
        const uri = try std.Uri.parse(url);
        const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
        defer alloc.free(auth);

        var req = try self.client.request(.POST, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .{ .override = auth },
                .content_type = .{ .override = "application/json" },
                // Avoid gzip/deflate here so the SSE parser can read directly.
                .accept_encoding = .omit,
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        if (response.head.status.class() != .success) {
            var transfer_buffer: [1024]u8 = undefined;
            const reader = response.reader(&transfer_buffer);
            var error_body: std.Io.Writer.Allocating = .init(alloc);
            defer error_body.deinit();
            _ = reader.streamRemaining(&error_body.writer) catch {};
            std.debug.print("OpenAI-compatible API error {d}: {s}\n", .{ @intFromEnum(response.head.status), error_body.written() });
            return error.OpenAiApiError;
        }

        try sink.emit(.started);
        var transfer_buffer: [1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var finish: ?provider.StopReason = null;
        while (try reader.takeDelimiter('\n')) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0 or line[0] == ':') continue;
            if (!std.mem.startsWith(u8, line, "data:")) continue;
            const data = std.mem.trim(u8, line[5..], " ");
            if (try processSseData(alloc, data, sink, &finish)) return;
        }
        if (finish) |reason| {
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
                const result = parseToolResultBlock(block.bytes);
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
            const call = parseToolCallBlock(call_block.bytes);
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
        try writeRawJson(jw, def.input_schema);
        try jw.endObject();
        try jw.endObject();
    }
    try jw.endArray();
}

fn writeRawJson(jw: *std.json.Stringify, raw: []const u8) !void {
    try jw.beginWriteRaw();
    try jw.writer.writeAll(raw);
    jw.endWriteRaw();
}

const ParsedToolCall = struct {
    id: []const u8,
    name: []const u8,
    args_json: []const u8,
};

fn parseToolCallBlock(bytes: []const u8) ParsedToolCall {
    const id_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return .{ .id = bytes, .name = "", .args_json = "{}" };
    const rest = bytes[id_end + 1 ..];
    const name_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return .{ .id = bytes[0..id_end], .name = rest, .args_json = "{}" };
    return .{
        .id = bytes[0..id_end],
        .name = rest[0..name_end],
        .args_json = rest[name_end + 1 ..],
    };
}

const ParsedToolResult = struct {
    id: []const u8,
    ok: []const u8,
    output: []const u8,
};

fn parseToolResultBlock(bytes: []const u8) ParsedToolResult {
    const id_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return .{ .id = bytes, .ok = "", .output = "" };
    const rest = bytes[id_end + 1 ..];
    const ok_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return .{ .id = bytes[0..id_end], .ok = rest, .output = "" };
    return .{
        .id = bytes[0..id_end],
        .ok = rest[0..ok_end],
        .output = rest[ok_end + 1 ..],
    };
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

    if (valueField(root, "usage")) |usage| {
        if (usage == .object) try sink.emit(.{ .usage = usageFrom(usage) });
    }

    const choices = valueField(root, "choices") orelse return false;
    if (choices != .array or choices.array.items.len == 0) return false;
    const choice = choices.array.items[0];
    if (choice != .object) return error.OpenAiBadSse;

    if (valueString(choice, "finish_reason")) |reason| {
        finish.* = stopReasonFrom(reason);
    }

    const delta = valueField(choice, "delta") orelse return false;
    if (delta != .object) return error.OpenAiBadSse;

    if (valueString(delta, "content")) |content| {
        if (content.len != 0) try sink.emit(.{ .text_delta = content });
    }
    if (valueString(delta, "reasoning_content")) |thinking| {
        if (thinking.len != 0) try sink.emit(.{ .thinking_delta = thinking });
    }
    if (valueField(delta, "tool_calls")) |calls| {
        if (calls != .array) return error.OpenAiBadSse;
        for (calls.array.items) |call| try emitToolCallDelta(call, sink);
    }

    return false;
}

fn emitToolCallDelta(call: std.json.Value, sink: provider.EventSink) !void {
    if (call != .object) return error.OpenAiBadSse;
    const index = if (valueField(call, "index")) |v|
        if (v == .integer and v.integer >= 0) @as(usize, @intCast(v.integer)) else 0
    else
        0;

    var id: []const u8 = "";
    if (valueString(call, "id")) |s| id = s;

    var name: []const u8 = "";
    var args: []const u8 = "";
    if (valueField(call, "function")) |function| {
        if (function != .object) return error.OpenAiBadSse;
        if (valueString(function, "name")) |s| name = s;
        if (valueString(function, "arguments")) |s| args = s;
    }

    if (id.len != 0 or name.len != 0) {
        try sink.emit(.{ .tool_use_start = .{ .index = index, .id = id, .name = name } });
    }
    if (args.len != 0) {
        try sink.emit(.{ .tool_use_input_delta = .{ .index = index, .fragment = args } });
    }
}

fn usageFrom(v: std.json.Value) provider.Usage {
    const prompt_tokens = intField(v, "prompt_tokens");
    const completion_tokens = intField(v, "completion_tokens");
    var cached: u64 = 0;
    if (valueField(v, "prompt_tokens_details")) |details| {
        if (details == .object) cached = intField(details, "cached_tokens");
    }
    if (cached == 0) cached = intField(v, "prompt_cache_hit_tokens");
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

fn intField(v: std.json.Value, field: []const u8) u64 {
    const child = valueField(v, field) orelse return 0;
    return switch (child) {
        .integer => |i| if (i >= 0) @intCast(i) else 0,
        .float => |f| if (f >= 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn valueField(v: std.json.Value, field: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(field);
}

fn valueString(v: std.json.Value, field: []const u8) ?[]const u8 {
    const child = valueField(v, field) orelse return null;
    if (child != .string) return null;
    return child.string;
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
