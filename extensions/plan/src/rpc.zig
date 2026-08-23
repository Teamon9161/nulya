//! The wire half of `plan`: this call's arguments in on stdin, its answer out
//! on stdout, and the vocabulary the three tools answer in.
//!
//! The wire is `plain` (DESIGN §7.3, contract at the top of
//! `src/extension/protocol.zig`): stdin is the arguments as one JSON object, the
//! tool's name is `NULYA_TOOL` in the environment, and there is no envelope to
//! read or write. Lifted from `extensions/agent/src/rpc.zig` (itself from
//! `extensions/std`), which is the same contract — several tools in one binary
//! dispatched on that name. The copy is deliberate and is not a missing
//! abstraction: a package's `src/` tree is frozen into its own content-addressed
//! version (DESIGN §7.4), so there is no place two packages could share a file
//! from without inventing one.
//!
//! Two shapes of answer, on purpose:
//!   - `text`   → stdout, verbatim, exit 0. `propose` and `todo` answer in the
//!                sentence the model should read; `approve` prints JSON, which a
//!                DRIVER parses — one wire carries both, because stdout is just
//!                bytes.
//!   - `failed` → stderr, then exit 1. The host folds it into a failed tool
//!                result (`ok=false`) whose text is `exit 1` and that message, so
//!                the message IS the teaching text.

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

/// A plan is prose, and prose from a model can be long; the cap is on the wire
/// read rather than on any one field, which `main` then narrows per argument.
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
