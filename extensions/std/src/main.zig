//! `std` — the file and search tools a coding session reaches for first, as one
//! extension outside the kernel.
//!
//! **What it is.** Six tools in one binary — `read`, `write`, `append`, `edit`,
//! `grep`, `glob` — dispatched here on `NULYA_TOOL`. Their
//! behaviour is ported from tcode's tool crate, error text and numbers
//! included: an error is written FOR the model (what went wrong, how to succeed
//! next call), a small read is widened, a big one paginates itself, `write`
//! will not clobber a file the model has not seen, `edit` replaces an exact
//! unique string and teaches when it cannot, `grep` is smart-case with a
//! per-file cap, `glob` sorts by mtime. See docs/goals/std.md for the contract.
//!
//! **Why an extension and not builtins.** nulya has no "std tool" layer: a tool
//! that is always in front of every model costs a `max_tools` slot and prefix
//! tokens in every session, whether or not it is used. This ships with the repo,
//! DEFAULT-OFF; a user who wants it builds it (`nulya ext build extensions/std
//! --user`), activates it, and pins the tools they want in `[registry]
//! pinned_native_tools` (`ext:std/read`, …). The id `std` is a name, not a rank.
//!
//! **Why compiled Zig.** A regex engine, a gitignore-aware walker and the
//! whitespace-normalising fallbacks `edit` needs — none of which a shell script
//! carries. And one version id across both shell dialects: a manifest holds one
//! `interpreter`, so a script version would be a `.sh` and a `.ps1` of the same
//! six tools that could never share a content-addressed version.
//!
//! **State.** A tool sees only its arguments, a sanitized environment and the
//! working directory. The one thing these tools remember between calls — what
//! the model has already read, so `read` can say "unchanged" and `write` can
//! refuse to overwrite the unseen — lives on disk in this session's scratch
//! directory (`.nulya/scratch/<session>/std-freshness.jsonl`, `freshness.zig`),
//! keyed by `NULYA_SESSION`. Outside a session there is no such file and no gate.

const std = @import("std");
const rpc = @import("rpc.zig");

const read = @import("read.zig");
const write = @import("write.zig");
const append = @import("append.zig");
const edit = @import("edit.zig");
const grep = @import("grep.zig");
const glob = @import("glob.zig");

/// On the `plain` wire stderr IS the failure message the model reads (DESIGN
/// §7.3), so nothing may write there but `rpc.answer`. The vendored regex engine
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
/// the real process environment, which is where `NULYA_TOOL` and `NULYA_SESSION`
/// live.
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

/// The session this call runs in, from the file path `session step` puts in the
/// environment of everything it runs; null outside a session or when the value
/// names no file.
fn sessionId(env: *const std.process.Environ.Map) ?[]const u8 {
    const session_path = env.get("NULYA_SESSION") orelse return null;
    const stem = std.fs.path.stem(session_path);
    return if (stem.len == 0) null else stem;
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
