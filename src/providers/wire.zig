//! Shared provider wire plumbing (DESIGN §13).
//!
//! Three providers — `openai` (chat/completions), `anthropic` (messages) and
//! `codex` (the ChatGPT-subscription responses endpoint) — speak different JSON
//! dialects over the same transport: one streaming HTTPS POST whose body is SSE.
//! What all three genuinely share lives here: the PromptIR block decoders, the
//! JSON scalar readers, and the POST + SSE loop. A provider file is then only
//! its own wire shape.

const std = @import("std");

// ---------------------------------------------------------------- PromptIR --

/// A `tool_call` block's payload, laid out by `prompt.project` as
/// `id\nname\nargs_json`. Slices borrow the block.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    args_json: []const u8,
};

pub fn parseToolCall(bytes: []const u8) ToolCall {
    const id_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return .{ .id = bytes, .name = "", .args_json = "{}" };
    const rest = bytes[id_end + 1 ..];
    const name_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return .{ .id = bytes[0..id_end], .name = rest, .args_json = "{}" };
    return .{
        .id = bytes[0..id_end],
        .name = rest[0..name_end],
        .args_json = rest[name_end + 1 ..],
    };
}

/// A `tool_result` block's payload: `call_id\nok\noutput`, where `ok` is a bool
/// formatted by `{}`. Slices borrow the block.
pub const ToolResult = struct {
    id: []const u8,
    ok: bool,
    output: []const u8,
};

pub fn parseToolResult(bytes: []const u8) ToolResult {
    const id_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return .{ .id = bytes, .ok = true, .output = "" };
    const rest = bytes[id_end + 1 ..];
    const ok_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return .{ .id = bytes[0..id_end], .ok = isTrue(rest), .output = "" };
    return .{
        .id = bytes[0..id_end],
        .ok = isTrue(rest[0..ok_end]),
        .output = rest[ok_end + 1 ..],
    };
}

fn isTrue(s: []const u8) bool {
    return std.mem.eql(u8, s, "true");
}

/// Write every item of a `reasoning` block (the JSON array a `TurnCollector`
/// joined from the provider's own `reasoning_item`s) as one JSON value each,
/// into whatever array `jw` is currently inside. Both wires that replay
/// reasoning place the items bare — Anthropic as content blocks, Responses as
/// input items — so the splitting is shared; only the surrounding container is
/// the provider's. Items are re-serialized from the parsed value, which keeps
/// key order and is what a signature / encrypted blob is indifferent to.
pub fn writeReasoningItems(jw: *std.json.Stringify, alloc: std.mem.Allocator, block: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, block, .{}) catch return error.CorruptReasoning;
    defer parsed.deinit();
    if (parsed.value != .array) return error.CorruptReasoning;
    for (parsed.value.array.items) |item| try jw.write(item);
}

// ------------------------------------------------------------------- JSON --

pub fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

pub fn string(v: std.json.Value, name: []const u8) ?[]const u8 {
    const child = field(v, name) orelse return null;
    if (child != .string) return null;
    return child.string;
}

pub fn uint(v: std.json.Value, name: []const u8) u64 {
    const child = field(v, name) orelse return 0;
    return switch (child) {
        .integer => |i| if (i >= 0) @intCast(i) else 0,
        .float => |f| if (f >= 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

/// Splice an already-serialized JSON document (a tool's `input_schema`) into the
/// stream without reparsing it.
pub fn writeRaw(jw: *std.json.Stringify, raw: []const u8) !void {
    try jw.beginWriteRaw();
    try jw.writer.writeAll(raw);
    jw.endWriteRaw();
}

// ------------------------------------------------------------------- HTTP --

pub const Post = struct {
    url: []const u8,
    body: []const u8,
    /// Full `Authorization` header value (e.g. `Bearer sk-…`); null omits it.
    authorization: ?[]const u8 = null,
    /// Provider-specific headers (`x-api-key`, `anthropic-version`, …).
    extra_headers: []const std.http.Header = &.{},
};

pub const HttpError = error{
    /// 401: the caller may be able to refresh a credential and retry once.
    Unauthorized,
    /// Any other non-2xx. The response body is printed as a diagnostic.
    ApiError,
};

/// POST `p` and hand every SSE `data:` payload to `onData`, stopping when it
/// returns true (the stream's own terminator) or the body ends.
///
/// SSE lines are accumulated into a growable buffer rather than the reader's
/// fixed transfer buffer: one `data:` line can carry a whole response object
/// (Codex's `response.completed`), far past any fixed line limit.
pub fn postSse(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    p: Post,
    ctx: anytype,
    comptime onData: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) !void {
    const uri = try std.Uri.parse(p.url);
    var req = try client.request(.POST, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (p.authorization) |a| .{ .override = a } else .default,
            .content_type = .{ .override = "application/json" },
            // Avoid gzip/deflate here so the SSE parser can read directly.
            .accept_encoding = .omit,
        },
        .extra_headers = p.extra_headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = p.body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(p.body);
    try body_writer.end();
    try req.connection.?.flush();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    if (response.head.status.class() != .success) return reportStatus(alloc, response.head.status, reader);

    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    while (true) {
        line.clearRetainingCapacity();
        _ = try reader.streamDelimiterEnding(&line.writer, '\n');
        // Documented contract: at end of stream nothing is left buffered;
        // otherwise the next byte is the delimiter we just stopped at.
        const at_end = reader.bufferedLen() == 0;
        if (!at_end) reader.toss(1);

        const text = std.mem.trimEnd(u8, line.written(), "\r");
        if (std.mem.startsWith(u8, text, "data:")) {
            const data = std.mem.trim(u8, text[5..], " ");
            // `event:` lines are ignored on purpose: every dialect we speak also
            // carries its event name inside the payload (`type` / `choices`).
            if (data.len != 0 and try onData(ctx, data)) return;
        }
        if (at_end) break;
    }
}

/// POST `p` and return the whole response body (caller owns). Used for the small
/// non-streaming calls a provider needs around its stream, such as the Codex
/// OAuth token refresh.
pub fn postJson(client: *std.http.Client, alloc: std.mem.Allocator, p: Post) ![]u8 {
    const uri = try std.Uri.parse(p.url);
    var req = try client.request(.POST, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (p.authorization) |a| .{ .override = a } else .default,
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
        },
        .extra_headers = p.extra_headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = p.body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(p.body);
    try body_writer.end();
    try req.connection.?.flush();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    if (response.head.status.class() != .success) return reportStatus(alloc, response.head.status, reader);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    _ = try reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

fn reportStatus(alloc: std.mem.Allocator, status: std.http.Status, reader: *std.Io.Reader) HttpError {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    _ = reader.streamRemaining(&body.writer) catch {};
    std.debug.print("provider API error {d}: {s}\n", .{ @intFromEnum(status), body.written() });
    return if (status == .unauthorized) error.Unauthorized else error.ApiError;
}

test "reasoning items are spliced back one value each, in order" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginArray();
    try jw.write("head");
    try writeReasoningItems(&jw, alloc, "[{\"type\":\"thinking\",\"thinking\":\"a\",\"signature\":\"s\"},{\"type\":\"redacted_thinking\",\"data\":\"d\"}]");
    try jw.write("tail");
    try jw.endArray();
    try std.testing.expectEqualStrings(
        "[\"head\",{\"type\":\"thinking\",\"thinking\":\"a\",\"signature\":\"s\"},{\"type\":\"redacted_thinking\",\"data\":\"d\"},\"tail\"]",
        out.written(),
    );

    var junk: std.Io.Writer.Allocating = .init(alloc);
    defer junk.deinit();
    var jw2: std.json.Stringify = .{ .writer = &junk.writer };
    try jw2.beginArray();
    try std.testing.expectError(error.CorruptReasoning, writeReasoningItems(&jw2, alloc, "{\"not\":\"an array\"}"));
}

test "tool call and tool result blocks decode back to their fields" {
    const call = parseToolCall("c1\nshell\n{\"command\":\"echo hi\"}");
    try std.testing.expectEqualStrings("c1", call.id);
    try std.testing.expectEqualStrings("shell", call.name);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", call.args_json);

    const ok = parseToolResult("c1\ntrue\nhi there");
    try std.testing.expectEqualStrings("c1", ok.id);
    try std.testing.expect(ok.ok);
    try std.testing.expectEqualStrings("hi there", ok.output);

    // A failed call must surface as `is_error` on the providers that have it.
    const failed = parseToolResult("c2\nfalse\nboom\nsecond line");
    try std.testing.expect(!failed.ok);
    try std.testing.expectEqualStrings("boom\nsecond line", failed.output);
}
