//! The wire half of `mcp`: this call's arguments in on stdin, its answer out
//! on stdout, and the vocabulary every tool here answers in.
//!
//! The wire is `plain` (contract at the top of `src/extension/protocol.zig`):
//! stdin is the arguments as one JSON object, the tool's name is `NULYA_TOOL`
//! in the environment, and there is no envelope to read or write. A package's
//! `src/` tree is frozen into its own content-addressed version, so there is
//! no place two packages could share this module from without inventing one
//! — this is a deliberate copy of `extensions/plan/src/rpc.zig`.
//!
//! Two shapes of answer: `text` → stdout, verbatim, exit 0; `failed` → stderr,
//! then exit 1 (the host folds it into a failed tool result whose text is
//! `exit 1` and that message). A generated server package OWNS its stderr, so
//! nothing the MCP server writes there reaches this stream unquoted.

const std = @import("std");

pub const Outcome = union(enum) {
    /// The tool's answer — prose for a model, a listing for a driver — printed
    /// to stdout exactly as it stands.
    text: []const u8,
    /// The teaching message, written to stderr before `exit 1`.
    failed: []const u8,
};

/// A refusal with a formatted teaching message: what went wrong, and what would
/// work next call.
pub fn refuse(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .failed = try std.fmt.allocPrint(alloc, fmt, args) };
}

/// An MCP tool's arguments are whatever its own schema says, and a server may
/// take a document; the cap is on the wire read rather than on any one field.
pub const max_request_bytes: usize = 4 << 20;

pub const ReadError = error{NotAnObject} || std.mem.Allocator.Error;

/// This call's arguments as they arrived: one JSON object, the exact bytes the
/// caller produced (`{}` when it sent none). Kept as bytes because one of them
/// is forwarded to an MCP server verbatim — the schema the model wrote against
/// is the server's, so nothing here is in a position to reshape it.
pub fn readRaw(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const raw = try reader.interface.allocRemaining(alloc, .limited(max_request_bytes));
    return if (std.mem.trim(u8, raw, " \t\r\n").len == 0) "{}" else raw;
}

/// The same bytes as an object. The host already checked that shape before
/// spawning, so `NotAnObject` means somebody ran this binary by hand.
pub fn asObject(alloc: std.mem.Allocator, raw: []const u8) ReadError!std.json.ObjectMap {
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

/// One argument, trimmed. Whitespace-only is empty: a caller that sent `"  "`
/// did not answer the question.
pub fn trimmedField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const raw = stringField(obj, key) orelse return "";
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// An array-of-strings argument. A non-array, or an element that is not a
/// string, yields an empty list rather than half a list: a command line
/// assembled from some of its words is worse than none.
pub fn stringListField(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = obj.get(key) orelse return &.{};
    const items = switch (value) {
        .array => |a| a.items,
        else => return &.{},
    };
    var out = try alloc.alloc([]const u8, items.len);
    for (items, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |s| s,
            else => return &.{},
        };
    }
    return out;
}
