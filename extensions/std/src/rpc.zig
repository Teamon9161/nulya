//! The wire half of `std`: this call's arguments in on stdin, its answer out on
//! stdout, and the small vocabulary every tool answers in.
//!
//! The wire (DESIGN §7.3, contract at the top of `src/extension/protocol.zig`):
//! stdin is the arguments as one JSON object, the tool's name is `NULYA_TOOL` in
//! the environment, and there is no envelope to read or write. A tool never
//! touches stdio itself: `main.zig` reads, dispatches on that name, and prints
//! whatever `Outcome` comes back.
//!
//! Two shapes of answer, on purpose:
//!   - `text`   → stdout, verbatim, exit 0. The host hands those bytes to the
//!                model unchanged, so a file's contents or a search listing
//!                arrive as plain text — the same way a builtin's output would.
//!   - `failed` → stderr, then exit 1. The host folds it into a failed tool
//!                result (`ok=false`, and the usage journal records it so),
//!                shown as `exit 1` followed by that message. The message IS the
//!                teaching text: what went wrong and how to succeed next call.
//!
//! One shape for every failure, deliberately: a missing argument, an unknown
//! tool name and a file that is not there all reach the model as one sentence.
//! The error codes these used to carry reached it as a number nobody read.

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
    /// `NULYA_SESSION_ID` when this call runs inside a session (the kernel
    /// publishes it to every child of `session step`; `ext run` from a shell in
    /// a session inherits it). Null outside a session — then there is no
    /// per-session state (no freshness, no gates).
    session_id: ?[]const u8,

    /// Resolve a model-supplied path against `cwd`. Returned slice is owned by
    /// `alloc`.
    pub fn resolve(self: *const Ctx, path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(path)) return try self.alloc.dupe(u8, path);
        return try std.fs.path.resolve(self.alloc, &.{ self.cwd, path });
    }
};

pub const Outcome = union(enum) {
    /// The tool's answer, printed to stdout exactly as it stands.
    text: []const u8,
    /// The teaching message, written to stderr before `exit 1`.
    failed: []const u8,
};

/// A refusal with a formatted teaching message: what went wrong, and what would
/// work next call.
pub fn refuse(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .failed = try std.fmt.allocPrint(alloc, fmt, args) };
}

/// The largest request this process will read. `write` carries a whole file in
/// `content`, so this is generous; the model-side limit is the provider's, not
/// ours.
pub const max_request_bytes: usize = 16 << 20;

pub const ReadError = error{NotAnObject};

/// Read this call's arguments from stdin: one JSON object, the exact bytes the
/// model produced (`{}` when it sent none). The host already checked that shape
/// before spawning, so `NotAnObject` means somebody ran this binary by hand.
pub fn readArguments(alloc: std.mem.Allocator, io: std.Io) !std.json.ObjectMap {
    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const raw = try reader.interface.allocRemaining(alloc, .limited(max_request_bytes));

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAnObject,
    };
    return switch (parsed) {
        .object => |o| o,
        else => error.NotAnObject,
    };
}

/// Print the answer and end the process the way the wire reads it: stdout and 0,
/// or stderr and 1. The one place either happens, so no tool can invent a third
/// way to be finished.
pub fn answer(io: std.Io, outcome: Outcome) !noreturn {
    switch (outcome) {
        // Verbatim: no trailing newline is added, because these bytes ARE the
        // result and a tool that wants one prints it itself.
        .text => |text| {
            try std.Io.File.stdout().writeStreamingAll(io, text);
            std.process.exit(0);
        },
        .failed => |message| {
            try std.Io.File.stderr().writeStreamingAll(io, message);
            try std.Io.File.stderr().writeStreamingAll(io, "\n");
            std.process.exit(1);
        },
    }
}

// ---------------------------------------------------------------- arguments

pub fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// A required string argument, or the refusal that names it.
pub const StringArg = union(enum) { ok: []const u8, failed: Outcome };

pub fn requireString(alloc: std.mem.Allocator, args: std.json.ObjectMap, key: []const u8) !StringArg {
    return switch (args.get(key) orelse return .{ .failed = try refuse(alloc, "missing required parameter: {s}", .{key}) }) {
        .string => |s| .{ .ok = s },
        else => .{ .failed = try refuse(alloc, "{s} must be a string", .{key}) },
    };
}

/// An optional non-negative integer argument. `null` / absent → null; anything
/// that is not a non-negative integer → `error.BadType` (the caller turns it
/// into a refusal naming the field).
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
    // test happens to call: `readArguments` / `answer` are otherwise only
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
