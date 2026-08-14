//! Extension wire protocol (DESIGN §7.3).
//!
//! v1 is deliberately dumb and oneshot: the host spawns the extension, writes
//! exactly ONE request JSON to stdin, reads ONE response JSON from stdout, and
//! the process exits. No daemon, no streaming, no bidirectional events, no host
//! callbacks. The wire protocol IS the ABI, so extensions need not be written in
//! Zig (DESIGN §7.1).
//!
//!   request   { "v":1, "id":"call-17", "tool":"web_search", "args":{...} }
//!   success   { "v":1, "id":"call-17", "ok":true,  "value":{...} }
//!   error     { "v":1, "id":"call-17", "ok":false, "error":{ "code":"..",
//!                                                    "message":"..", "retryable":true } }

const std = @import("std");

/// Wire protocol version. Bumped only on a breaking envelope change.
pub const version: u32 = 1;

/// Host -> extension. `args_json` stays as raw JSON bytes: the host forwards
/// exactly what the model produced and never interprets the tool's argument
/// shape — the manifest schema is the only truth (DESIGN §7.2).
pub const Request = struct {
    id: []const u8,
    tool: []const u8,
    /// A raw JSON object (or empty, treated as `{}`).
    args_json: []const u8,

    /// Serialize to a single request line. Caller owns the returned bytes.
    pub fn encode(self: Request, alloc: std.mem.Allocator) ![]u8 {
        const args = if (std.mem.trim(u8, self.args_json, " \t\r\n").len == 0) "{}" else self.args_json;

        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };

        try jw.beginObject();
        try jw.objectField("v");
        try jw.write(version);
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("tool");
        try jw.write(self.tool);
        try jw.objectField("args");
        // Forward the model's JSON verbatim instead of re-parsing/re-emitting it.
        try jw.beginWriteRaw();
        try out.writer.writeAll(args);
        jw.endWriteRaw();
        try jw.endObject();

        return out.toOwnedSlice();
    }
};

pub const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
    retryable: bool = false,
};

/// Extension -> host, already validated against the v1 envelope. All slices are
/// owned by the allocator passed to `decodeResponse`; free with `deinit`.
pub const DecodedResponse = struct {
    ok: bool,
    /// Compact JSON of the `value` field on success; `"null"` when absent.
    value_json: []const u8,
    /// Present only when `!ok`.
    err: ?ErrorBody,

    pub fn deinit(self: DecodedResponse, alloc: std.mem.Allocator) void {
        alloc.free(self.value_json);
        if (self.err) |e| {
            alloc.free(e.code);
            alloc.free(e.message);
        }
    }
};

pub const DecodeError = error{
    InvalidResponse,
    UnsupportedVersion,
    /// Surfaced by the allocating JSON writer when compacting `value`; with an
    /// allocating sink this is effectively out-of-memory.
    WriteFailed,
} || std.mem.Allocator.Error;

/// Parse and validate a response the extension wrote to stdout. Malformed
/// output (crash, garbage, wrong version) becomes a typed error the host turns
/// into a normal failed tool result — a broken extension never crashes the host.
pub fn decodeResponse(alloc: std.mem.Allocator, bytes: []const u8) DecodeError!DecodedResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.InvalidResponse;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    if (obj.get("v")) |v| {
        const n = switch (v) {
            .integer => |i| i,
            else => return error.InvalidResponse,
        };
        if (n != version) return error.UnsupportedVersion;
    }

    const ok = switch (obj.get("ok") orelse return error.InvalidResponse) {
        .bool => |b| b,
        else => return error.InvalidResponse,
    };

    if (ok) {
        const value_json = try compactValue(alloc, obj.get("value") orelse std.json.Value{ .null = {} });
        return .{ .ok = true, .value_json = value_json, .err = null };
    }

    const err_obj = switch (obj.get("error") orelse return error.InvalidResponse) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const code = stringField(err_obj, "code") orelse return error.InvalidResponse;
    const message = stringField(err_obj, "message") orelse "";
    const retryable = switch (err_obj.get("retryable") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    const code_owned = try alloc.dupe(u8, code);
    errdefer alloc.free(code_owned);
    const message_owned = try alloc.dupe(u8, message);
    return .{
        .ok = false,
        .value_json = try alloc.dupe(u8, "null"),
        .err = .{ .code = code_owned, .message = message_owned, .retryable = retryable },
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

test "request encodes a valid oneshot envelope with verbatim args" {
    const alloc = std.testing.allocator;
    const req: Request = .{ .id = "call-17", .tool = "web_search", .args_json = "{\"query\":\"zig\"}" };
    const line = try req.encode(alloc);
    defer alloc.free(line);

    // Round-trips as JSON and preserves every field.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), obj.get("v").?.integer);
    try std.testing.expectEqualStrings("call-17", obj.get("id").?.string);
    try std.testing.expectEqualStrings("web_search", obj.get("tool").?.string);
    try std.testing.expectEqualStrings("zig", obj.get("args").?.object.get("query").?.string);
}

test "empty args become an empty object" {
    const alloc = std.testing.allocator;
    const req: Request = .{ .id = "c1", .tool = "t", .args_json = "" };
    const line = try req.encode(alloc);
    defer alloc.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"args\":{}") != null);
}

test "decode accepts a success response and compacts its value" {
    const alloc = std.testing.allocator;
    const res = try decodeResponse(alloc, "{\"v\":1,\"id\":\"c1\",\"ok\":true,\"value\":{\"results\":[]}}");
    defer res.deinit(alloc);
    try std.testing.expect(res.ok);
    try std.testing.expect(res.err == null);
    try std.testing.expectEqualStrings("{\"results\":[]}", res.value_json);
}

test "decode accepts an error response" {
    const alloc = std.testing.allocator;
    const res = try decodeResponse(alloc, "{\"v\":1,\"id\":\"c1\",\"ok\":false,\"error\":{\"code\":\"NETWORK_ERROR\",\"message\":\"down\",\"retryable\":true}}");
    defer res.deinit(alloc);
    try std.testing.expect(!res.ok);
    try std.testing.expectEqualStrings("NETWORK_ERROR", res.err.?.code);
    try std.testing.expectEqualStrings("down", res.err.?.message);
    try std.testing.expect(res.err.?.retryable);
}

test "decode rejects garbage, wrong version, and missing ok" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidResponse, decodeResponse(alloc, "not json"));
    try std.testing.expectError(error.UnsupportedVersion, decodeResponse(alloc, "{\"v\":2,\"ok\":true}"));
    try std.testing.expectError(error.InvalidResponse, decodeResponse(alloc, "{\"v\":1,\"id\":\"c1\"}"));
}
