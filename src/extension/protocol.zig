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
//!             { "jsonrpc":"2.0", "id":"call-17", "result":"plain text…" }
//!   error     { "jsonrpc":"2.0", "id":"call-17",
//!               "error":{ "code":-32000, "message":"..",
//!                          "data":{ "retryable":true } } }
//!
//! `result` is any JSON value. A STRING result is the tool's text output and
//! reaches the model verbatim (a file's contents, a search listing) — exactly as
//! a builtin's output would; anything else is structured data and is handed on
//! as compact JSON. Without this a tool that returns text would show the model
//! an escaped JSON string, paid for on every call.

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
};

/// Extension -> host, already validated against the JSON-RPC envelope. The
/// owning slice is freed with `deinit`.
pub const DecodedResponse = union(enum) {
    /// The `result` field as the model will see it: a string result is that
    /// string's bytes verbatim; any other JSON value is compacted to JSON.
    result: []const u8,
    extension_error: ErrorBody,

    pub fn deinit(self: DecodedResponse, alloc: std.mem.Allocator) void {
        switch (self) {
            .result => |bytes| alloc.free(bytes),
            .extension_error => |err| alloc.free(err.message),
        }
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
        return .{
            .result = switch (obj.get("result").?) {
                // Text output: the bytes themselves, not a quoted-and-escaped JSON
                // string literal (see the module doc).
                .string => |text| try alloc.dupe(u8, text),
                else => |value| try compactValue(alloc, value),
            },
        };
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
    return .{ .extension_error = .{
        .code = code,
        .message = try alloc.dupe(u8, message),
    } };
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
    switch (res) {
        .result => |json| try std.testing.expectEqualStrings("{\"results\":[]}", json),
        .extension_error => unreachable,
    }
}

test "decode hands a string result over verbatim — newlines, quotes and non-ASCII unescaped, no surrounding quotes" {
    const alloc = std.testing.allocator;
    const res = try decodeResponse(alloc, "c1", "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"result\":\"line 1\\nsay \\\"hi\\\" \\u2014 done\\n\"}");
    defer res.deinit(alloc);
    switch (res) {
        .result => |text| try std.testing.expectEqualStrings("line 1\nsay \"hi\" \u{2014} done\n", text),
        .extension_error => unreachable,
    }
    // Only a top-level string is text; a string nested in an object stays JSON.
    const nested = try decodeResponse(alloc, "c1", "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"result\":{\"text\":\"a\\nb\"}}");
    defer nested.deinit(alloc);
    try std.testing.expectEqualStrings("{\"text\":\"a\\nb\"}", nested.result);
    // And the other scalars are still JSON, so `null` / numbers round-trip as such.
    const scalar = try decodeResponse(alloc, "c1", "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"result\":42}");
    defer scalar.deinit(alloc);
    try std.testing.expectEqualStrings("42", scalar.result);
}

test "decode accepts an error response" {
    const alloc = std.testing.allocator;
    const res = try decodeResponse(alloc, "c1", "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"error\":{\"code\":-32000,\"message\":\"down\"}}");
    defer res.deinit(alloc);
    switch (res) {
        .result => unreachable,
        .extension_error => |err| {
            try std.testing.expectEqual(@as(i64, -32000), err.code);
            try std.testing.expectEqualStrings("down", err.message);
        },
    }
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
