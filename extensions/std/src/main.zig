//! `std` — the file and search tools a coding session reaches for first, as one
//! extension outside the kernel.
//!
//! Six tools in one binary — `read`, `write`, `append`, `edit`, `grep`,
//! `glob` — dispatched here on `NULYA_TOOL`, ported from tcode's tool crate.
//! DEFAULT-OFF: this ships with the repo but a user who wants it must build,
//! activate, and name the tools they want on a session's member list.
//!
//! A tool sees only its arguments, a sanitized environment and the working
//! directory. The one thing these tools remember between calls — what the
//! model has already read, so `read` can say "unchanged" and `write` can
//! refuse to overwrite the unseen — lives on disk in this session's scratch
//! directory (`freshness.zig`), keyed by `NULYA_SESSION_ID`.

const std = @import("std");
const rpc = @import("rpc.zig");

const read = @import("read.zig");
const write = @import("write.zig");
const append = @import("append.zig");
const edit = @import("edit.zig");
const grep = @import("grep.zig");
const glob = @import("glob.zig");

/// On the `plain` wire stderr IS the failure message the model reads, so
/// nothing may write there but `rpc.answer`. The vendored regex engine
/// logs its parse diagnostic through `std.log`, which would otherwise arrive
/// above the teaching text — a library's debug line, in the sentence a model is
/// meant to act on. Discarded rather than routed somewhere: this binary has no
/// second output, and what a refusal should say is already said by hand.
pub const std_options: std.Options = .{ .logFn = discardLog };

fn discardLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

/// `std.process.Init` rather than a bare `main()`: the io it hands over carries
/// the real process environment, which is where `NULYA_TOOL` and
/// `NULYA_SESSION_ID` live.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: individual frees would be noise.
    const alloc = init.arena.allocator();

    const name = init.environ_map.get("NULYA_TOOL") orelse "";
    const arguments = rpc.readArguments(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try rpc.answer(io, .{ .failed = "std expects this call's arguments as one JSON object on stdin" }),
    };

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const ctx: rpc.Ctx = .{
        .alloc = alloc,
        .io = io,
        .cwd = cwd_buf[0..cwd_len],
        .env = init.environ_map,
        .session_id = sessionId(init.environ_map),
    };

    // Host faults (out of memory, an unreadable working directory) surface as
    // Zig errors and are folded into a refusal here, so every path still ends
    // in exactly one answer.
    const outcome = dispatch(&ctx, name, arguments) catch |err| rpc.Outcome{
        .failed = try std.fmt.allocPrint(alloc, "{s} could not run: {s}", .{ name, @errorName(err) }),
    };
    try rpc.answer(io, outcome);
}

fn dispatch(ctx: *const rpc.Ctx, name: []const u8, arguments: std.json.ObjectMap) !rpc.Outcome {
    const Tool = struct { name: []const u8, run: *const fn (*const rpc.Ctx, std.json.ObjectMap) anyerror!rpc.Outcome };
    const tools = [_]Tool{
        .{ .name = "read", .run = read.run },
        .{ .name = "write", .run = write.run },
        .{ .name = "append", .run = append.run },
        .{ .name = "edit", .run = edit.run },
        .{ .name = "grep", .run = grep.run },
        .{ .name = "glob", .run = glob.run },
    };
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t.run(ctx, arguments);
    }
    return rpc.refuse(ctx.alloc, "std has no tool named '{s}' (it has read, write, append, edit, grep, glob)", .{name});
}

/// The session this call runs in, from the id `session step` publishes to
/// everything it runs; null outside a session.
///
/// The ID, not the stem of `NULYA_SESSION`: what the freshness journal needs is
/// an identity to key itself by, and a session whose workspace lives on another
/// machine has one there while the session FILE does not exist over there at
/// all. Asking for the path would have made these six tools silently gateless in
/// exactly the sessions they were moved to serve.
fn sessionId(env: *const std.process.Environ.Map) ?[]const u8 {
    const id = env.get("NULYA_SESSION_ID") orelse return null;
    return if (id.len == 0) null else id;
}

test {
    // `zig build test` reaches every module's tests through this root, and
    // analyzes `main` / `dispatch` themselves so a compile error in the entry
    // point cannot hide until `nulya ext build`.
    std.testing.refAllDecls(@This());
    _ = rpc;
    _ = read;
    _ = write;
    _ = append;
    _ = edit;
    _ = grep;
    _ = glob;
    _ = @import("freshness.zig");
    _ = @import("text.zig");
    _ = @import("walk.zig");
    _ = @import("regex.zig");
    _ = @import("vendor/mvzr.zig");
    _ = @import("vendor/globpat.zig");
    _ = @import("vendor/ignore.zig");
}
