//! Extension wire protocol (DESIGN §7.3).
//!
//! The transport is still deliberately dumb and oneshot: the host spawns the
//! extension, writes exactly ONE JSON-RPC request to stdin, reads ONE JSON-RPC
//! response from stdout, and the process exits. No daemon, no streaming, no
//! bidirectional events, no host callbacks. The wire protocol IS the ABI, so
//! extensions need not be written in Zig (DESIGN §7.1).
//!
//!   request   { "jsonrpc":"2.0", "id":"call-17", "method":"tool/call",
//!               "params":{ "name":"web_search", "arguments":{...} } }
//!   success   { "jsonrpc":"2.0", "id":"call-17", "result":{...} }
//!   error     { "jsonrpc":"2.0", "id":"call-17",
//!               "error":{ "code":-32000, "message":"..",
//!                          "data":{ "retryable":true } } }

const std = @import("std");

pub const jsonrpc_version = "2.0";
pub const method_tool_call = "tool/call";

/// Host -> extension for the only v0.1 runtime method. `arguments_json` stays
/// as raw JSON bytes: the host validates that it is an object, then forwards the
/// exact bytes the model produced. The manifest schema is the only truth for the
/// tool-specific argument shape (DESIGN §7.2).
pub const ToolCallRequest = struct {
    id: []const u8,
    method: []const u8 = method_tool_call,
    name: []const u8,
    /// A raw JSON object (or empty, treated as `{}`).
    arguments_json: []const u8,

    /// Serialize to one JSON-RPC request. Caller owns the returned bytes.
    pub fn encode(self: ToolCallRequest, alloc: std.mem.Allocator) ![]u8 {
        const arguments = if (std.mem.trim(u8, self.arguments_json, " \t\r\n").len == 0) "{}" else std.mem.trim(u8, self.arguments_json, " \t\r\n");
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch |err| switch (err) {
            // The parser allocates while validating the arguments object: a host
            // OOM is a resource fault and must not be misreported as malformed
            // arguments.
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgumentsJson,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.ArgumentsNotObject;

        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write(jsonrpc_version);
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("method");
        try jw.write(self.method);
        try jw.objectField("params");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("arguments");
        // Forward the model's JSON verbatim instead of re-parsing/re-emitting it.
        try jw.beginWriteRaw();
        try out.writer.writeAll(arguments);
        jw.endWriteRaw();
        try jw.endObject();
        try jw.endObject();

        return out.toOwnedSlice();
    }
};

pub const ErrorBody = struct {
    code: i64,
    message: []const u8,
    retryable: bool = false,
};

/// Extension -> host, already validated against the JSON-RPC envelope. All
/// slices are owned by the allocator passed to `decodeResponse`; free with
/// `deinit`.
pub const DecodedResponse = struct {
    ok: bool,
    /// Compact JSON of the `result` field on success; `"null"` when absent.
    value_json: []const u8,
    /// Present only when `!ok`.
    err: ?ErrorBody,

    pub fn deinit(self: DecodedResponse, alloc: std.mem.Allocator) void {
        alloc.free(self.value_json);
        if (self.err) |e| alloc.free(e.message);
    }
};

pub const DecodeError = error{
    /// The extension wrote something that is not a valid JSON-RPC response
    /// (garbage, wrong shape, wrong id, missing result/error). An extension
    /// fault: callers fold it into a failed invocation.
    InvalidResponse,
    /// The response is valid JSON but not JSON-RPC 2.0. An extension fault:
    /// callers fold it into a failed invocation.
    UnsupportedVersion,
    /// Surfaced by the allocating JSON writer when compacting `result`; with an
    /// allocating sink this is effectively out-of-memory. A host resource
    /// fault, not an extension fault: callers propagate it.
    WriteFailed,
} || std.mem.Allocator.Error;

/// Parse and validate a response the extension wrote to stdout. Syntax, shape,
/// and version violations (`InvalidResponse`, `UnsupportedVersion`) are
/// extension faults, which the host turns into a normal failed tool result.
/// `WriteFailed` and `OutOfMemory` are host resource faults and propagate
/// unchanged — a host OOM is never misreported as a broken extension.
pub fn decodeResponse(alloc: std.mem.Allocator, expected_id: []const u8, bytes: []const u8) DecodeError!DecodedResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        // The parser allocates while building the Value tree: running out of
        // memory is a host resource fault and must not be folded into
        // InvalidResponse.
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    const jsonrpc = stringField(obj, "jsonrpc") orelse return error.InvalidResponse;
    if (!std.mem.eql(u8, jsonrpc, jsonrpc_version)) return error.UnsupportedVersion;

    const id = stringField(obj, "id") orelse return error.InvalidResponse;
    if (!std.mem.eql(u8, id, expected_id)) return error.InvalidResponse;

    const has_result = obj.get("result") != null;
    const has_error = obj.get("error") != null;
    if (has_result == has_error) return error.InvalidResponse;

    if (has_result) {
        const value_json = try compactValue(alloc, obj.get("result").?);
        return .{ .ok = true, .value_json = value_json, .err = null };
    }

    const err_obj = switch (obj.get("error").?) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const code = switch (err_obj.get("code") orelse return error.InvalidResponse) {
        .integer => |i| i,
        else => return error.InvalidResponse,
    };
    const message = stringField(err_obj, "message") orelse return error.InvalidResponse;
    const retryable = retryableFromData(err_obj.get("data"));
    const message_owned = try alloc.dupe(u8, message);
    // `value_json` is a second, independently owned allocation: if it fails,
    // `message_owned` must still be released — `DecodedResponse.deinit` frees
    // both only when called on a complete value.
    errdefer alloc.free(message_owned);
    const value_json = try alloc.dupe(u8, "null");
    return .{
        .ok = false,
        .value_json = value_json,
        .err = .{ .code = code, .message = message_owned, .retryable = retryable },
    };
}

fn retryableFromData(value: ?std.json.Value) bool {
    const data = switch (value orelse return false) {
        .object => |o| o,
        else => return false,
    };
    return switch (data.get("retryable") orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn compactValue(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(value);
    return out.toOwnedSlice();
}

test "tool call request encodes a JSON-RPC tool/call envelope with verbatim arguments" {
    const alloc = std.testing.allocator;
    const req: ToolCallRequest = .{ .id = "call-17", .name = "web_search", .arguments_json = "{\"query\":\"zig\"}" };
    const line = try req.encode(alloc);
    defer alloc.free(line);

    // Round-trips as JSON and preserves every field.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("call-17", obj.get("id").?.string);
    try std.testing.expectEqualStrings("tool/call", obj.get("method").?.string);
    const params = obj.get("params").?.object;
    try std.testing.expectEqualStrings("web_search", params.get("name").?.string);
    try std.testing.expectEqualStrings("zig", params.get("arguments").?.object.get("query").?.string);
}

test "empty arguments become an empty object" {
    const alloc = std.testing.allocator;
    const req: ToolCallRequest = .{ .id = "c1", .name = "t", .arguments_json = "" };
    const line = try req.encode(alloc);
    defer alloc.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"arguments\":{}") != null);
}

test "arguments must be a valid JSON object" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgumentsJson, (ToolCallRequest{ .id = "c1", .name = "t", .arguments_json = "{" }).encode(alloc));
    try std.testing.expectError(error.ArgumentsNotObject, (ToolCallRequest{ .id = "c1", .name = "t", .arguments_json = "[]" }).encode(alloc));
}

test "an encode allocation failure surfaces as OutOfMemory, not InvalidArgumentsJson" {
    // The first allocation inside `encode` is the parser validating the
    // arguments object. A host OOM there must propagate as error.OutOfMemory —
    // folding it into InvalidArgumentsJson would misreport a resource fault as
    // a malformed tool call.
    const alloc = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, (ToolCallRequest{ .id = "c1", .name = "t", .arguments_json = "{}" }).encode(failing.allocator()));
}

test "decode accepts a success response and compacts its result" {
    const alloc = std.testing.allocator;
    const res = try decodeResponse(alloc, "c1", "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"result\":{\"results\":[]}}");
    defer res.deinit(alloc);
    try std.testing.expect(res.ok);
    try std.testing.expect(res.err == null);
    try std.testing.expectEqualStrings("{\"results\":[]}", res.value_json);
}

test "decode accepts an error response" {
    const alloc = std.testing.allocator;
    const res = try decodeResponse(alloc, "c1", "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"error\":{\"code\":-32000,\"message\":\"down\",\"data\":{\"retryable\":true}}}");
    defer res.deinit(alloc);
    try std.testing.expect(!res.ok);
    try std.testing.expectEqual(@as(i64, -32000), res.err.?.code);
    try std.testing.expectEqualStrings("down", res.err.?.message);
    try std.testing.expect(res.err.?.retryable);
}

test "decode rejects garbage, wrong version, missing result/error, and wrong id" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidResponse, decodeResponse(alloc, "c1", "not json"));
    try std.testing.expectError(error.UnsupportedVersion, decodeResponse(alloc, "c1", "{\"jsonrpc\":\"1.0\",\"id\":\"c1\",\"result\":null}"));
    try std.testing.expectError(error.InvalidResponse, decodeResponse(alloc, "c1", "{\"jsonrpc\":\"2.0\",\"id\":\"c1\"}"));
    try std.testing.expectError(error.InvalidResponse, decodeResponse(alloc, "c1", "{\"jsonrpc\":\"2.0\",\"id\":\"other\",\"result\":null}"));
    try std.testing.expectError(error.InvalidResponse, decodeResponse(alloc, "c1", "{\"jsonrpc\":\"2.0\",\"result\":null}"));
}

test "a parser allocation failure surfaces as OutOfMemory, not InvalidResponse" {
    // The first allocation inside `decodeResponse` is the JSON parser building
    // the Value tree. A host OOM there is a host resource fault and must
    // propagate as error.OutOfMemory — folding it into InvalidResponse would
    // misreport a broken host as a broken extension.
    const alloc = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, decodeResponse(failing.allocator(), "c1", "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"result\":{}}"));
}
