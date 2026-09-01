//! The wire half of `agent`: this call's arguments in on stdin, its answer out on
//! stdout, and the vocabulary the four tools answer in.
//!
//! The contract is at the top of `src/extension/protocol.zig`: stdin is the
//! arguments as one JSON object, the tool's name is `NULYA_TOOL` in the
//! environment, and there is no envelope to read or write.
//!
//! Two shapes of answer:
//!   - `text`   → stdout, verbatim, exit 0. `agent`'s receipt and `run`'s report
//!                reach the model as the sentences they are; `render` and `list`
//!                print JSON a DRIVER parses. One wire carries both, because
//!                stdout is just bytes.
//!   - `failed` → stderr, then exit 1. The host folds it into a failed tool
//!                result whose text is `exit 1` and that message, so the message
//!                IS the teaching text.

const std = @import("std");

pub const Outcome = union(enum) {
    /// The tool's answer — prose for a model, JSON for a driver — printed to
    /// stdout exactly as it stands.
    text: []const u8,
    /// The teaching message, written to stderr before `exit 1`.
    failed: []const u8,
};

/// A refusal with a formatted teaching message: what went wrong, and what would
/// work next call.
pub fn refuse(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .failed = try std.fmt.allocPrint(alloc, fmt, args) };
}

/// A task text can be long, so the cap is on the wire read rather than on any
/// one field.
pub const max_request_bytes: usize = 4 << 20;

pub const ReadError = error{NotAnObject};

/// Read this call's arguments from stdin: one JSON object, the exact bytes the
/// caller produced (`{}` when it sent none). The host already checked that shape
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
        // result.
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

pub fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// One argument, trimmed. Whitespace-only is empty: a model that sent `"  "`
/// did not answer the question.
pub fn trimmedField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const raw = stringField(obj, key) orelse return "";
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// A boolean argument that may also arrive as the STRING `"true"`: `ext run --arg
/// k=v` has no types, and this tool is called that way by a background task as
/// well as by a model.
pub fn boolField(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true"),
        else => false,
    };
}

/// A positive integer argument, in either of the same two spellings.
pub fn intField(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    return switch (obj.get(key) orelse return null) {
        .integer => |i| if (i > 0) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
}
