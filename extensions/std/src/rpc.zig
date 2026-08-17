//! The wire half of `std`: one JSON-RPC `tool/call` in on stdin, one response
//! out on stdout, and the small vocabulary every tool answers in.
//!
//! Lifted from `extensions/handoff` (the same request/response contract) so the
//! five tools here share one reader, one writer and one `Outcome` instead of
//! five copies. A tool never touches stdio itself: `main.zig` reads, dispatches
//! on `params.name`, and writes whatever `Outcome` comes back.
//!
//! Two shapes of answer, on purpose:
//!   - `text`   → `"result": "<text>"`. The host hands a STRING result to the
//!                model verbatim, so a file's contents or a search listing arrive
//!                as plain text — the same way a builtin's output would.
//!   - `failed` → `"error": {code, message}`. The host folds it into a failed
//!                tool result (`ok=false`, and the usage journal records it so),
//!                shown as `extension error [<code>]: <message>`. The message IS
//!                the teaching text: what went wrong and how to succeed next call.
//! Codes: -32602 when the arguments themselves are missing or mistyped, -32601
//! for a tool name this binary does not implement, -32000 for everything the
//! tool refused or could not do (file not found, an unread file being
//! overwritten, an invalid regex, …).

const std = @import("std");

/// What one call knows about the world (DESIGN §7.6: arguments, a sanitized
/// environment, and the working directory — nothing else).
pub const Ctx = struct {
    /// One arena for the whole process; a call reads a few files and prints
    /// one response, so nothing is freed individually.
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Absolute working directory of this process; relative tool paths resolve
    /// against it.
    cwd: []const u8,
    env: *const std.process.Environ.Map,
    /// The stem of `NULYA_SESSION` when this call runs inside a session (the
    /// kernel sets that variable for every child of `session step`; `ext run`
    /// from a shell in a session inherits it). Null outside a session — then
    /// there is no per-session state (no freshness, no gates).
    session_id: ?[]const u8,

    /// Resolve a model-supplied path against `cwd`. Returned slice is owned by
    /// `alloc`.
    pub fn resolve(self: *const Ctx, path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(path)) return try self.alloc.dupe(u8, path);
        return try std.fs.path.resolve(self.alloc, &.{ self.cwd, path });
    }
};

pub const Fail = struct { code: i64, message: []const u8 };

pub const Outcome = union(enum) {
    text: []const u8,
    failed: Fail,
};

pub const code_invalid_params: i64 = -32602;
pub const code_unknown_tool: i64 = -32601;
pub const code_refused: i64 = -32000;

/// A refusal with a formatted teaching message (`-32000`).
pub fn refuse(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .failed = .{ .code = code_refused, .message = try std.fmt.allocPrint(alloc, fmt, args) } };
}

/// A bad-arguments answer (`-32602`): the model sent something the schema does
/// not allow, and the message says which field and what would be accepted.
pub fn invalidParams(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .failed = .{ .code = code_invalid_params, .message = try std.fmt.allocPrint(alloc, fmt, args) } };
}

/// One decoded `tool/call`. `arguments` borrows the parsed JSON tree, which
/// lives in the arena.
pub const Request = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.ObjectMap,
};

/// The host sends a string id and requires it back unchanged; until a request
/// is decoded, this is what any error is addressed to.
pub const fallback_id = "call";

/// The largest request this process will read. `write` carries a whole file in
/// `content`, so this is generous; the model-side limit is the provider's, not
/// ours.
pub const max_request_bytes: usize = 16 << 20;

pub const ReadError = error{ NotJsonRpc, NotAnObject, NoArguments };

/// Read and decode the single request on stdin. On a malformed request the
/// caller answers with `fallback_id`.
pub fn readRequest(alloc: std.mem.Allocator, io: std.Io) !Request {
    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const raw = try reader.interface.allocRemaining(alloc, .limited(max_request_bytes));

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJsonRpc,
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    const id = stringField(obj, "id") orelse fallback_id;
    const params = switch (obj.get("params") orelse return error.NoArguments) {
        .object => |o| o,
        else => return error.NoArguments,
    };
    const name = stringField(params, "name") orelse return error.NoArguments;
    const arguments = switch (params.get("arguments") orelse std.json.Value{ .object = .empty }) {
        .object => |o| o,
        else => return error.NoArguments,
    };
    return .{ .id = id, .name = name, .arguments = arguments };
}

/// One JSON-RPC response on stdout — the whole runtime contract.
pub fn writeResponse(alloc: std.mem.Allocator, io: std.Io, id: []const u8, outcome: Outcome) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try jw.write(id);
    switch (outcome) {
        .text => |text| {
            try jw.objectField("result");
            try jw.write(text);
        },
        .failed => |failed| {
            try jw.objectField("error");
            try jw.beginObject();
            try jw.objectField("code");
            try jw.write(failed.code);
            try jw.objectField("message");
            try jw.write(failed.message);
            try jw.endObject();
        },
    }
    try jw.endObject();

    try std.Io.File.stdout().writeStreamingAll(io, out.writer.buffered());
}

// ---------------------------------------------------------------- arguments

pub fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// A required string argument, or the `-32602` that names it.
pub const StringArg = union(enum) { ok: []const u8, failed: Outcome };

pub fn requireString(alloc: std.mem.Allocator, args: std.json.ObjectMap, key: []const u8) !StringArg {
    return switch (args.get(key) orelse return .{ .failed = try invalidParams(alloc, "missing required parameter: {s}", .{key}) }) {
        .string => |s| .{ .ok = s },
        else => .{ .failed = try invalidParams(alloc, "{s} must be a string", .{key}) },
    };
}

/// An optional non-negative integer argument. `null` / absent → null; anything
/// that is not a non-negative integer → `error.BadType` (the caller turns it
/// into a `-32602` naming the field).
pub fn optionalUnsigned(args: std.json.ObjectMap, key: []const u8) error{BadType}!?u64 {
    return switch (args.get(key) orelse return null) {
        .null => null,
        .integer => |i| if (i < 0) error.BadType else @intCast(i),
        else => error.BadType,
    };
}

/// An optional boolean argument; absent / null → `default`.
pub fn optionalBool(args: std.json.ObjectMap, key: []const u8, default: bool) error{BadType}!bool {
    return switch (args.get(key) orelse return default) {
        .null => default,
        .bool => |b| b,
        else => error.BadType,
    };
}

test {
    // Analyze every public function under `zig build test`, not only the ones a
    // test happens to call: `readRequest` / `writeResponse` are otherwise only
    // reached from `main`, which the test build never references.
    std.testing.refAllDecls(@This());
}

test "optional arguments: absent and null read as defaults, wrong types are BadType" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"n\":3,\"z\":null,\"neg\":-1,\"s\":\"x\",\"b\":true}", .{});
    defer parsed.deinit();
    const args = parsed.value.object;
    try std.testing.expectEqual(@as(?u64, 3), try optionalUnsigned(args, "n"));
    try std.testing.expectEqual(@as(?u64, null), try optionalUnsigned(args, "z"));
    try std.testing.expectEqual(@as(?u64, null), try optionalUnsigned(args, "absent"));
    try std.testing.expectError(error.BadType, optionalUnsigned(args, "neg"));
    try std.testing.expectError(error.BadType, optionalUnsigned(args, "s"));
    try std.testing.expect(try optionalBool(args, "b", false));
    try std.testing.expect(!try optionalBool(args, "absent", false));
    try std.testing.expectError(error.BadType, optionalBool(args, "s", false));
}

test "a text outcome is written as a JSON string result and a failure as an error object" {
    // Exercised through the same encoder `writeResponse` uses, minus stdout.
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write("a\nb");
    try std.testing.expectEqualStrings("\"a\\nb\"", out.writer.buffered());
}
