//! Anthropic Messages API provider.
//!
//! Unlike Chat Completions, this API caches only where it is told to. The
//! projected turn prefix only ever grows, never gets rewritten, so two
//! `cache_control` breakpoints — one after the frozen system blocks, one on
//! the last content block of the last message — cover the whole prefix, and
//! the tail breakpoint moves forward on its own as the ledger is appended to.
//!
//! Also speaks Anthropic-compatible backends (DeepSeek's `/anthropic` endpoint).
//! The only place the two differ is the reasoning dial: first-party models take
//! adaptive thinking guided by `output_config.effort`, compatible backends still
//! take the classic `thinking.budget_tokens`.

const std = @import("std");
const ledger = @import("../ledger.zig");
const prompt = @import("../prompt.zig");
const provider = @import("../provider.zig");
const tool = @import("../tool.zig");
const wire = @import("wire.zig");

const API_VERSION = "2023-06-01";
pub const default_base_url = "https://api.anthropic.com";
pub const default_model = "claude-sonnet-5";

/// The Messages API rejects a request without `max_tokens`, so "uncapped" has to
/// become a number somewhere; it belongs to the wire format, not to config. High
/// enough that no honest answer reaches it, with room left under the ceiling for
/// the largest thinking budget this provider asks for (which is added on top).
const default_max_tokens: u32 = 32_000;

pub const Config = struct {
    api_key: []const u8,
    model: []const u8 = default_model,
    base_url: []const u8 = default_base_url,
};

pub const AnthropicProvider = struct {
    alloc: std.mem.Allocator,
    client: std.http.Client,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    /// True when talking to the first-party API rather than an
    /// Anthropic-compatible backend. Decides the effort wire format and whether
    /// a bearer token is sent alongside `x-api-key`.
    native: bool,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, cfg: Config) !AnthropicProvider {
        const api_key = try alloc.dupe(u8, cfg.api_key);
        errdefer alloc.free(api_key);
        const model = try alloc.dupe(u8, cfg.model);
        errdefer alloc.free(model);
        const base_url = try alloc.dupe(u8, cfg.base_url);
        errdefer alloc.free(base_url);

        return .{
            .alloc = alloc,
            .client = .{ .allocator = alloc, .io = io, .read_buffer_size = 64 * 1024 },
            .api_key = api_key,
            .model = model,
            .base_url = base_url,
            .native = isNative(cfg.base_url),
        };
    }

    pub fn deinit(self: *AnthropicProvider) void {
        self.client.deinit();
        self.alloc.free(self.api_key);
        self.alloc.free(self.model);
        self.alloc.free(self.base_url);
        self.* = undefined;
    }

    pub fn modelHandle(self: *AnthropicProvider) provider.Model {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name(ptr: *anyopaque) []const u8 {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        return if (self.native) "anthropic" else "anthropic-compatible";
    }

    fn modelName(ptr: *anyopaque) []const u8 {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        return self.model;
    }

    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{ .thinking_replay = true };
    }

    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        const body = try buildRequestJson(alloc, self.model, self.native, request);
        defer alloc.free(body);

        const url = try endpointUrl(alloc, self.base_url);
        defer alloc.free(url);

        // Compatible backends (DeepSeek) authenticate with a bearer token; the
        // first-party API rejects a request carrying both, so it gets `x-api-key`
        // alone.
        const auth = if (self.native) null else try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
        defer if (auth) |a| alloc.free(a);

        var state: StreamState = .{ .alloc = alloc, .sink = sink };
        defer state.deinit();
        try wire.postSse(&self.client, alloc, .{
            .url = url,
            .body = body,
            .authorization = auth,
            .stall_ms = request.stall_ms,
            .extra_headers = &.{
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = API_VERSION },
            },
        }, &state, StreamState.onData);

        if (!state.done) return error.StreamEndedEarly;
    }

    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

fn isNative(base_url: []const u8) bool {
    return base_url.len == 0 or std.mem.indexOf(u8, base_url, "anthropic.com") != null;
}

pub fn endpointUrl(alloc: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/v1/messages")) return alloc.dupe(u8, trimmed);
    return std.fmt.allocPrint(alloc, "{s}/v1/messages", .{trimmed});
}

// ----------------------------------------------------------------- request --

pub fn buildRequestJson(
    alloc: std.mem.Allocator,
    model: []const u8,
    native: bool,
    request: provider.Request,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    const budget = thinkingBudget(native, request.options.effort);
    const max_tokens = (request.options.max_output_tokens orelse default_max_tokens) + budget;

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(model);
    try jw.objectField("max_tokens");
    try jw.write(max_tokens);
    try jw.objectField("stream");
    try jw.write(true);
    try jw.objectField("system");
    try writeSystem(&jw, request.prompt_ir.system_blocks);
    try jw.objectField("messages");
    try writeMessages(&jw, alloc, request.prompt_ir.turns);
    if (request.tools.len != 0) {
        try jw.objectField("tools");
        try writeTools(&jw, request.tools);
    }
    if (request.options.effort) |effort| {
        if (std.mem.eql(u8, effort, "off")) {
            try jw.objectField("thinking");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("disabled");
            try jw.endObject();
        } else if (native) {
            // First-party models dropped the legacy budget field (it 400s) for
            // adaptive thinking guided by an effort level.
            try jw.objectField("thinking");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("adaptive");
            try jw.endObject();
            try jw.objectField("output_config");
            try jw.beginObject();
            try jw.objectField("effort");
            try jw.write(effortLevel(effort));
            try jw.endObject();
        } else {
            try jw.objectField("thinking");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("enabled");
            try jw.objectField("budget_tokens");
            try jw.write(budget);
            try jw.endObject();
        }
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

fn effortLevel(effort: []const u8) []const u8 {
    if (std.mem.eql(u8, effort, "low")) return "low";
    if (std.mem.eql(u8, effort, "medium")) return "medium";
    return "high";
}

/// The legacy budget, and the amount `max_tokens` grows by so the answer itself
/// still fits under the cap. Zero unless the compatible-backend arm is taken.
fn thinkingBudget(native: bool, effort: ?[]const u8) u32 {
    const e = effort orelse return 0;
    if (native or std.mem.eql(u8, e, "off")) return 0;
    if (std.mem.eql(u8, e, "low")) return 4096;
    if (std.mem.eql(u8, e, "medium")) return 12288;
    return 24576;
}

/// The frozen system blocks, with the cache breakpoint on the last one. Tools
/// are cached by the same breakpoint (they precede system in the cache prefix),
/// so one is enough for the whole immutable head of the request.
fn writeSystem(jw: *std.json.Stringify, blocks: []const prompt.SystemBlock) !void {
    try jw.beginArray();
    if (blocks.len == 0) {
        // `system: []` is rejected; an empty composition still needs one block
        // to carry the breakpoint that covers `tools`.
        try writeTextBlock(jw, "", true);
    }
    for (blocks, 0..) |block, i| {
        try writeTextBlock(jw, block.bytes, i + 1 == blocks.len);
    }
    try jw.endArray();
}

fn writeTextBlock(jw: *std.json.Stringify, text: []const u8, cached: bool) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("text");
    try jw.objectField("text");
    try jw.write(text);
    if (cached) try writeCacheControl(jw);
    try jw.endObject();
}

/// An inline image as a content block: this API takes the media type and the
/// base64 as separate fields of a `source`, which is why it does not share the
/// data-URI helper the other two dialects do.
fn writeImageBlock(jw: *std.json.Stringify, img: ledger.Image, cached: bool) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("image");
    try jw.objectField("source");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("base64");
    try jw.objectField("media_type");
    try jw.write(img.media_type);
    try jw.objectField("data");
    try jw.write(img.data);
    try jw.endObject();
    if (cached) try writeCacheControl(jw);
    try jw.endObject();
}

fn writeCacheControl(jw: *std.json.Stringify) !void {
    try jw.objectField("cache_control");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("ephemeral");
    try jw.endObject();
}

const Role = enum { user, assistant };

/// Which message role a turn belongs to. Tool results and notes are user-side
/// content on this API — there is no mid-conversation system role.
fn roleOf(turn: prompt.Turn) Role {
    return switch (turn) {
        .user_text, .tool_results, .note => .user,
        .assistant => .assistant,
    };
}

/// Consecutive same-role turns become ONE message: that is what a batched
/// `tool_results` turn is on this wire, and it keeps roles alternating.
fn writeMessages(jw: *std.json.Stringify, alloc: std.mem.Allocator, turns: []const prompt.Turn) !void {
    try jw.beginArray();
    var i: usize = 0;
    while (i < turns.len) {
        const role = roleOf(turns[i]);
        var end = i;
        while (end < turns.len and roleOf(turns[end]) == role) : (end += 1) {}
        try writeMessage(jw, alloc, role, turns[i..end], end == turns.len);
        i = end;
    }
    try jw.endArray();
}

fn writeMessage(jw: *std.json.Stringify, alloc: std.mem.Allocator, role: Role, run: []const prompt.Turn, last: bool) !void {
    // The moving cache breakpoint sits on the final content block of the final
    // message, so every request extends the cached prefix by exactly the turns
    // appended since the last one. Counted rather than indexed: one turn writes
    // as many content blocks as it has parts.
    const eligible = cacheableBlocks(run);
    const breakpoint: ?usize = if (last and eligible != 0) eligible - 1 else null;
    var seen: usize = 0;

    try jw.beginObject();
    try jw.objectField("role");
    try jw.write(@tagName(role));
    try jw.objectField("content");
    try jw.beginArray();
    for (run) |turn| switch (turn) {
        .user_text => |u| {
            // Text first, then the images inlined with it. An image-only turn
            // writes NO text block: this API rejects an empty one, and
            // `session append --image` with nothing said is a legal turn.
            // `cacheableBlocks` counts by the same rule — the two must agree
            // or the moving breakpoint lands on the wrong block.
            if (u.text.len != 0 or u.images.len == 0) try writeTextBlock(jw, u.text, takes(breakpoint, &seen));
            for (u.images) |img| try writeImageBlock(jw, img, takes(breakpoint, &seen));
        },
        .note => |text| try writeTextBlock(jw, text, takes(breakpoint, &seen)),
        .assistant => |as| {
            // The turn's `thinking` / `redacted_thinking` blocks, exactly as this
            // API streamed them (signature included). They must lead the
            // assistant message that carries the `tool_use` they preceded — with
            // thinking on, the API rejects a tool-use turn whose thinking was
            // dropped — so replaying them is what makes a tool loop legal here,
            // not only what keeps the model's reasoning continuous.
            if (as.reasoning.len != 0) try wire.writeReasoningItems(jw, alloc, as.reasoning);
            // An assistant turn that only issued tool calls has no text block;
            // `content: []` would be rejected, so the calls carry the message.
            if (as.text.len != 0) try writeTextBlock(jw, as.text, takes(breakpoint, &seen));
            for (as.calls) |call| {
                const cached = takes(breakpoint, &seen);
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("tool_use");
                try jw.objectField("id");
                try jw.write(call.id);
                try jw.objectField("name");
                try jw.write(call.tool);
                try jw.objectField("input");
                try wire.writeRaw(jw, call.args_json);
                if (cached) try writeCacheControl(jw);
                try jw.endObject();
            }
        },
        .tool_results => |results| for (results) |result| {
            const cached = takes(breakpoint, &seen);
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("tool_result");
            try jw.objectField("tool_use_id");
            try jw.write(result.call_id);
            try jw.objectField("content");
            try jw.write(result.output);
            if (!result.ok) {
                try jw.objectField("is_error");
                try jw.write(true);
            }
            if (cached) try writeCacheControl(jw);
            try jw.endObject();
        },
    };
    // A pure-empty assistant turn (no text, no calls) would leave `content: []`,
    // which the API rejects; give it a body rather than dropping the turn, so
    // the projection and the wire history stay one-to-one. Replayed thinking
    // blocks are a body of their own, so a thinking-only turn needs none. Such a
    // run has no cacheable block, hence no breakpoint to place here either.
    if (eligible == 0 and !hasReasoning(run)) try writeTextBlock(jw, "", false);
    try jw.endArray();
    try jw.endObject();
}

/// Whether the content block about to be written is the one carrying the
/// breakpoint, advancing the position as it answers.
fn takes(breakpoint: ?usize, seen: *usize) bool {
    defer seen.* += 1;
    return breakpoint != null and breakpoint.? == seen.*;
}

fn hasReasoning(run: []const prompt.Turn) bool {
    for (run) |turn| switch (turn) {
        .assistant => |as| if (as.reasoning.len != 0) return true,
        else => {},
    };
    return false;
}

/// How many content blocks of `run` can carry the cache breakpoint: an empty
/// assistant text emits no block at all, and thinking blocks are replayed
/// verbatim (no `cache_control` is spliced into them), so neither counts.
fn cacheableBlocks(run: []const prompt.Turn) usize {
    var n: usize = 0;
    for (run) |turn| switch (turn) {
        // Same rule as `writeMessage`: no text block for an image-only turn,
        // one cacheable block per image (an image block takes `cache_control`).
        .user_text => |u| {
            if (u.text.len != 0 or u.images.len == 0) n += 1;
            n += u.images.len;
        },
        .note => n += 1,
        .assistant => |as| {
            if (as.text.len != 0) n += 1;
            n += as.calls.len;
        },
        .tool_results => |results| n += results.len,
    };
    return n;
}

fn writeTools(jw: *std.json.Stringify, tools: []const tool.ToolDefinition) !void {
    try jw.beginArray();
    for (tools) |def| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(def.name);
        try jw.objectField("description");
        try jw.write(def.description);
        try jw.objectField("input_schema");
        try wire.writeRaw(jw, def.input_schema);
        try jw.endObject();
    }
    try jw.endArray();
}

// ------------------------------------------------------------------ stream --

/// Usage arrives in two events: `message_start` carries the input and cache
/// counters, `message_delta` the output count (and, on newer API versions, a
/// partial repeat of the rest). This merges instead of replacing — otherwise
/// the cache-read counter would be zeroed by the final event.
pub const StreamState = struct {
    alloc: std.mem.Allocator,
    sink: provider.EventSink,
    usage: provider.Usage = .{},
    stop: provider.StopReason = .end_turn,
    started: bool = false,
    done: bool = false,
    /// The `thinking` block currently streaming, if any. Its text and signature
    /// arrive as deltas and the block is only whole at `content_block_stop`,
    /// which is when it is emitted as one `reasoning_item` for replay.
    thinking: ?Thinking = null,

    const Thinking = struct {
        text: std.Io.Writer.Allocating,
        signature: std.Io.Writer.Allocating,
    };

    pub fn deinit(self: *StreamState) void {
        self.dropThinking();
        self.* = undefined;
    }

    fn dropThinking(self: *StreamState) void {
        if (self.thinking) |*t| {
            t.text.deinit();
            t.signature.deinit();
            self.thinking = null;
        }
    }

    pub fn onData(self: *StreamState, data: []const u8) anyerror!bool {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, data, .{});
        defer parsed.deinit();
        const root = parsed.value;
        const kind = wire.string(root, "type") orelse return false;

        if (std.mem.eql(u8, kind, "message_start")) {
            if (!self.started) {
                self.started = true;
                try self.sink.emit(.started);
            }
            if (wire.field(root, "message")) |message| {
                if (wire.field(message, "usage")) |u| try self.mergeUsage(u);
            }
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            const block = wire.field(root, "content_block") orelse return false;
            const bt = wire.string(block, "type") orelse return false;
            if (std.mem.eql(u8, bt, "tool_use")) {
                try self.sink.emit(.{ .tool_use_start = .{
                    .index = @intCast(wire.uint(root, "index")),
                    .id = wire.string(block, "id") orelse "",
                    .name = wire.string(block, "name") orelse "",
                } });
            } else if (std.mem.eql(u8, bt, "thinking")) {
                self.dropThinking();
                self.thinking = .{ .text = .init(self.alloc), .signature = .init(self.alloc) };
                if (wire.string(block, "thinking")) |t| try self.thinking.?.text.writer.writeAll(t);
            } else if (std.mem.eql(u8, bt, "redacted_thinking")) {
                // Arrives whole: opaque bytes the API asks to get back verbatim.
                try self.emitReasoningItem(block);
            }
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const index: usize = @intCast(wire.uint(root, "index"));
            const delta = wire.field(root, "delta") orelse return false;
            const dt = wire.string(delta, "type") orelse return false;
            if (std.mem.eql(u8, dt, "text_delta")) {
                if (wire.string(delta, "text")) |t| try self.sink.emit(.{ .text_delta = t });
            } else if (std.mem.eql(u8, dt, "thinking_delta")) {
                if (wire.string(delta, "thinking")) |t| {
                    try self.sink.emit(.{ .thinking_delta = t });
                    if (self.thinking) |*think| try think.text.writer.writeAll(t);
                }
            } else if (std.mem.eql(u8, dt, "signature_delta")) {
                if (wire.string(delta, "signature")) |s| {
                    if (self.thinking) |*think| try think.signature.writer.writeAll(s);
                }
            } else if (std.mem.eql(u8, dt, "input_json_delta")) {
                if (wire.string(delta, "partial_json")) |f| {
                    try self.sink.emit(.{ .tool_use_input_delta = .{ .index = index, .fragment = f } });
                }
            }
        } else if (std.mem.eql(u8, kind, "content_block_stop")) {
            if (self.thinking) |*think| {
                defer self.dropThinking();
                // The block exactly as the API defines it, so it replays as-is.
                // With `display: omitted` the text is empty and the signature is
                // still what makes the block valid.
                const item = try std.json.Stringify.valueAlloc(self.alloc, .{
                    .type = "thinking",
                    .thinking = think.text.written(),
                    .signature = think.signature.written(),
                }, .{});
                defer self.alloc.free(item);
                try self.sink.emit(.{ .reasoning_item = item });
            }
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            if (wire.field(root, "delta")) |delta| {
                if (wire.string(delta, "stop_reason")) |s| self.stop = stopReasonFrom(s);
            }
            if (wire.field(root, "usage")) |u| try self.mergeUsage(u);
        } else if (std.mem.eql(u8, kind, "message_stop")) {
            self.done = true;
            try self.sink.emit(.{ .done = self.stop });
            return true;
        } else if (std.mem.eql(u8, kind, "error")) {
            const err = wire.field(root, "error") orelse root;
            std.debug.print("anthropic stream error: {s}\n", .{wire.string(err, "message") orelse data});
            // A 529 that arrives after the head is already 200 comes as an
            // in-stream `overloaded_error`; it is the same transient fault.
            if (std.mem.eql(u8, wire.string(err, "type") orelse "", "overloaded_error")) return error.ServerError;
            return error.AnthropicStreamError;
        }
        return false;
    }

    fn emitReasoningItem(self: *StreamState, block: std.json.Value) !void {
        const item = try std.json.Stringify.valueAlloc(self.alloc, block, .{});
        defer self.alloc.free(item);
        try self.sink.emit(.{ .reasoning_item = item });
    }

    fn mergeUsage(self: *StreamState, u: std.json.Value) !void {
        // `input_tokens` here already excludes both cache counters, which is
        // exactly what `provider.Usage.input_tokens` means.
        setIfNonZero(&self.usage.input_tokens, wire.uint(u, "input_tokens"));
        setIfNonZero(&self.usage.output_tokens, wire.uint(u, "output_tokens"));
        setIfNonZero(&self.usage.cache_read_tokens, wire.uint(u, "cache_read_input_tokens"));
        setIfNonZero(&self.usage.cache_write_tokens, wire.uint(u, "cache_creation_input_tokens"));
        try self.sink.emit(.{ .usage = self.usage });
    }
};

fn setIfNonZero(slot: *u64, value: u64) void {
    if (value != 0) slot.* = value;
}

fn stopReasonFrom(s: []const u8) provider.StopReason {
    if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, s, "end_turn") or std.mem.eql(u8, s, "stop_sequence")) return .end_turn;
    if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
    return .other;
}

// ------------------------------------------------------------------- tests --

fn testRequestJson(alloc: std.mem.Allocator, l: *ledger.Ledger, native: bool, effort: ?[]const u8) ![]u8 {
    const sys = [_]prompt.SystemBlock{.{ .source = "kernel", .bytes = "system base" }};
    const ir = try prompt.projectWithSystem(alloc, &sys, l.view());
    defer ir.deinit(alloc);
    const defs = [_]tool.ToolDefinition{.{
        .id = "builtin.shell",
        .name = "shell",
        .description = "run shell",
        .input_schema = "{\"type\":\"object\"}",
    }};
    return buildRequestJson(alloc, "test-model", native, .{
        .prompt_ir = &ir,
        .tools = &defs,
        .options = .{ .effort = effort },
    });
}

test "endpoint URL appends the messages path once" {
    const alloc = std.testing.allocator;
    const a = try endpointUrl(alloc, "https://api.anthropic.com/");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", a);

    const b = try endpointUrl(alloc, "https://api.deepseek.com/anthropic");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("https://api.deepseek.com/anthropic/v1/messages", b);

    try std.testing.expect(isNative("https://api.anthropic.com"));
    try std.testing.expect(!isNative("https://api.deepseek.com/anthropic"));
}

test "cache breakpoints sit after system and on the last content block" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hello" } });

    const body = try testRequestJson(alloc, &l, true, null);
    defer alloc.free(body);

    // Exactly two: the immutable head (tools + system) and the moving tail.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"cache_control\""));
    const system_bp = std.mem.indexOf(u8, body, "\"cache_control\"").?;
    const messages = std.mem.indexOf(u8, body, "\"messages\"").?;
    try std.testing.expect(system_bp < messages);
    // The tail breakpoint is on the last message's last content block.
    try std.testing.expect(std.mem.lastIndexOf(u8, body, "\"cache_control\"").? > messages);
}

test "the tail breakpoint follows the appended turn, and a batch is one user message" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hello" } });
    try l.append(.{ .assistant = .{ .text = "", .calls = &.{
        .{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"a\"}" },
        .{ .id = "c2", .tool = "shell", .args_json = "{\"command\":\"b\"}" },
    } } });
    try l.append(.{ .tool_results = &.{
        .{ .call_id = "c1", .ok = true, .output = "A" },
        .{ .call_id = "c2", .ok = false, .output = "B" },
    } });

    const body = try testRequestJson(alloc, &l, true, null);
    defer alloc.free(body);

    // user / assistant / user: the two results share one message, and the
    // text-less assistant turn is carried by its tool_use blocks alone.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"role\":\"user\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\"role\":\"assistant\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"type\":\"tool_result\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\"is_error\":true"));
    // Still two breakpoints, and the tail one moved onto the newest block.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"cache_control\""));
    const last_result = std.mem.lastIndexOf(u8, body, "\"tool_use_id\":\"c2\"").?;
    try std.testing.expect(std.mem.lastIndexOf(u8, body, "\"cache_control\"").? > last_result);
}

test "effort maps to adaptive thinking natively and to a budget on compatible backends" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hi" } });

    const none = try testRequestJson(alloc, &l, true, null);
    defer alloc.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "\"thinking\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, none, "\"max_tokens\":32000") != null);

    const off = try testRequestJson(alloc, &l, false, "off");
    defer alloc.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, "\"thinking\":{\"type\":\"disabled\"}") != null);

    const native = try testRequestJson(alloc, &l, true, "medium");
    defer alloc.free(native);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"thinking\":{\"type\":\"adaptive\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"output_config\":{\"effort\":\"medium\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"max_tokens\":32000") != null);

    const compat = try testRequestJson(alloc, &l, false, "medium");
    defer alloc.free(compat);
    try std.testing.expect(std.mem.indexOf(u8, compat, "\"budget_tokens\":12288") != null);
    // The budget is added on top so the answer still fits under the cap.
    try std.testing.expect(std.mem.indexOf(u8, compat, "\"max_tokens\":44288") != null);
}

test "SSE events collect into a turn and cache metrics survive the final usage event" {
    const alloc = std.testing.allocator;
    var collector = provider.TurnCollector.init(alloc);
    defer collector.deinit();
    var state: StreamState = .{ .alloc = alloc, .sink = collector.sink() };

    try std.testing.expect(!try state.onData(
        \\{"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":800,"cache_creation_input_tokens":40}}}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"run"}}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"c1","name":"shell"}}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"echo hi\"}"}}
    ));
    // The closing usage event reports only output tokens; the cache counters
    // from message_start must not be lost.
    try std.testing.expect(!try state.onData(
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}
    ));
    try std.testing.expect(try state.onData(
        \\{"type":"message_stop"}
    ));

    const turn = try collector.finish();
    defer turn.deinit(alloc);
    try std.testing.expectEqualStrings("run", turn.text);
    try std.testing.expectEqual(@as(usize, 1), turn.calls.len);
    try std.testing.expectEqualStrings("c1", turn.calls[0].id);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", turn.calls[0].args_json);
    try std.testing.expectEqual(@as(u64, 12), turn.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 800), turn.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 40), turn.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 7), turn.usage.output_tokens);
    try std.testing.expectEqual(provider.StopReason.tool_use, turn.stop_reason);
}

test "thinking blocks are collected whole and replayed verbatim ahead of the turn's tool_use" {
    const alloc = std.testing.allocator;

    // Stream: a thinking block (text + signature in deltas), a redacted one, a
    // tool call. The two thinking blocks come out as complete items.
    var collector = provider.TurnCollector.init(alloc);
    defer collector.deinit();
    var state: StreamState = .{ .alloc = alloc, .sink = collector.sink() };
    defer state.deinit();
    const events = [_][]const u8{
        \\{"type":"message_start","message":{"usage":{"input_tokens":5}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"let me "}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"see"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"c2ln"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"ZGF0YQ=="}}
        ,
        \\{"type":"content_block_stop","index":1}
        ,
        \\{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"c1","name":"shell"}}
        ,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls\"}"}}
        ,
        \\{"type":"content_block_stop","index":2}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}
        ,
    };
    for (events) |e| try std.testing.expect(!try state.onData(e));
    try std.testing.expect(try state.onData("{\"type\":\"message_stop\"}"));

    const turn = try collector.finish();
    defer turn.deinit(alloc);
    try std.testing.expectEqualStrings(
        "[{\"type\":\"thinking\",\"thinking\":\"let me see\",\"signature\":\"c2ln\"},{\"type\":\"redacted_thinking\",\"data\":\"ZGF0YQ==\"}]",
        turn.reasoning,
    );
    try std.testing.expectEqualStrings("", turn.text);
    try std.testing.expectEqual(@as(usize, 1), turn.calls.len);

    // Replay: the ledger's assistant event carries the items, and the request
    // puts them first in the assistant message, before the tool_use — the shape
    // the API demands when thinking is enabled. The tail breakpoint stays on
    // the last real content block, never on a thinking block.
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hello" } });
    try l.append(.{ .assistant = .{ .reasoning = turn.reasoning, .text = turn.text, .calls = turn.calls } });
    try l.append(.{ .tool_results = &.{.{ .call_id = "c1", .ok = true, .output = "a b" }} });
    const body = try testRequestJson(alloc, &l, true, "high");
    defer alloc.free(body);

    const think = std.mem.indexOf(u8, body, "{\"type\":\"thinking\",\"thinking\":\"let me see\",\"signature\":\"c2ln\"}").?;
    const redacted = std.mem.indexOf(u8, body, "{\"type\":\"redacted_thinking\",\"data\":\"ZGF0YQ==\"}").?;
    const tool_use = std.mem.indexOf(u8, body, "\"type\":\"tool_use\"").?;
    try std.testing.expect(think < redacted and redacted < tool_use);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\"role\":\"assistant\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"cache_control\""));
    // No empty text block was invented: the thinking blocks and the call are the body.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"\"") == null);
}

test "a note is a user text block the moving breakpoint can land on" {
    const alloc = std.testing.allocator;

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "build it" } });
    try l.append(.{ .assistant = .{ .text = "started", .calls = &.{} } });
    try l.append(.{ .note = .{
        .source = ledger.note_source_task,
        .text = "[background task s-1/t3 finished] zig build test · exit 0",
        .meta = "{\"task\":\"s-1/t3\",\"exit_code\":0}",
    } });
    const body = try testRequestJson(alloc, &l, true, null);
    defer alloc.free(body);

    // User side on this wire: there is no mid-conversation system role here to
    // put it in.
    const report_at = std.mem.indexOf(u8, body, "[background task s-1/t3 finished]").?;
    const last_user_at = std.mem.lastIndexOf(u8, body, "\"role\":\"user\"").?;
    try std.testing.expect(last_user_at < report_at);

    // `cacheableBlocks` counted it, so the moving breakpoint sits on it — the
    // last block of the last message — and there are still exactly two.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"cache_control\""));
    try std.testing.expect(std.mem.lastIndexOf(u8, body, "\"cache_control\"").? > report_at);
}

test "an image is a source block that can take the moving breakpoint; a turn without one is unchanged" {
    const alloc = std.testing.allocator;

    var plain = ledger.Ledger.init(alloc);
    defer plain.deinit();
    try plain.append(.{ .user_text = .{ .text = "hello" } });
    const plain_body = try testRequestJson(alloc, &plain, true, null);
    defer alloc.free(plain_body);
    // The whole user message, byte for byte as it was before images existed.
    try std.testing.expect(std.mem.indexOf(u8, plain_body, "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\",\"cache_control\":{\"type\":\"ephemeral\"}}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_body, "\"type\":\"image\"") == null);

    var shot = ledger.Ledger.init(alloc);
    defer shot.deinit();
    try shot.append(.{ .user_text = .{
        .text = "what is this",
        .images = &.{.{ .media_type = "image/png", .data = "iVBORw0=" }},
    } });
    const body = try testRequestJson(alloc, &shot, true, null);
    defer alloc.free(body);

    // Text block, then the image as a base64 source block — and the turn is
    // still ONE message.
    const text_at = std.mem.indexOf(u8, body, "\"type\":\"text\",\"text\":\"what is this\"").?;
    const image_at = std.mem.indexOf(u8, body, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"iVBORw0=\"}").?;
    try std.testing.expect(text_at < image_at);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\"role\":\"user\""));

    // `cacheableBlocks` and `writeMessage` agree: the turn grew from one block
    // to two, so the moving breakpoint is on the IMAGE, the last block of the
    // last message — still exactly two breakpoints in the request.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"cache_control\""));
    try std.testing.expect(std.mem.lastIndexOf(u8, body, "\"cache_control\"").? > image_at);

    // An image-only turn writes no text block at all (this API rejects an empty
    // one), and the breakpoint still lands on the last block written.
    var bare = ledger.Ledger.init(alloc);
    defer bare.deinit();
    try bare.append(.{ .user_text = .{ .text = "", .images = &.{.{ .media_type = "image/jpeg", .data = "/9j/" }} } });
    const bare_body = try testRequestJson(alloc, &bare, true, null);
    defer alloc.free(bare_body);
    try std.testing.expect(std.mem.indexOf(u8, bare_body, "\"type\":\"text\",\"text\":\"\"") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bare_body, "\"cache_control\""));
    const bare_image_at = std.mem.indexOf(u8, bare_body, "\"type\":\"image\"").?;
    try std.testing.expect(std.mem.lastIndexOf(u8, bare_body, "\"cache_control\"").? > bare_image_at);
}
