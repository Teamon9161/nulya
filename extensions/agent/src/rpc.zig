//! The wire half of `agent`: one JSON-RPC `tool/call` in on stdin, one response
//! out on stdout, and the vocabulary the three tools answer in.
//!
//! Lifted from `extensions/std/src/rpc.zig` (itself lifted from
//! `extensions/handoff`), which is the same contract — three tools in one binary
//! dispatched on `params.name`. The one addition is `json`: `materialize` is
//! read by a DRIVER rather than by a model, and a driver wants an object it can
//! parse, not a sentence (the same split `extensions/compact` makes).
//!
//! Three shapes of answer, on purpose:
//!   - `text`   → `"result": "<text>"`. The host hands a STRING result to the
//!                model verbatim (DESIGN §7.3), so `agent`'s receipt and `run`'s
//!                report arrive as plain text.
//!   - `json`   → `"result": <object>`, already serialised by the caller. What
//!                `ext run` prints, and what the TUI parses.
//!   - `failed` → `"error": {code, message}`. The host folds it into a failed
//!                tool result (`ok=false`), shown as `extension error [<code>]:
//!                <message>` — so the message IS the teaching text.

const std = @import("std");

pub const Fail = struct { code: i64, message: []const u8 };

pub const Outcome = union(enum) {
    text: []const u8,
    /// Raw JSON, written into `result` as-is.
    json: []const u8,
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

/// One decoded `tool/call`. `arguments` borrows the parsed JSON tree.
pub const Request = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.ObjectMap,
};

pub const fallback_id = "call";

pub const max_request_bytes: usize = 4 << 20;

pub const ReadError = error{ NotJsonRpc, NotAnObject, NoArguments };

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
        .json => |raw| {
            try jw.objectField("result");
            // Through the stringifier's own raw hatch, not straight at the
            // writer: bytes written behind its back leave it believing no value
            // was emitted, and the next `endObject` then trips its state check.
            try jw.beginWriteRaw();
            try out.writer.writeAll(raw);
            jw.endWriteRaw();
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

/// A boolean argument that may also arrive as the STRING `"true"` — `ext run
/// --arg k=v` has no types, and this tool is called that way by a background
/// task as well as by a model.
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
