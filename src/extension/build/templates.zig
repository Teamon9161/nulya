//! Scaffolding templates for `nulya ext init` (DESIGN §7.1, §7.2, §7.5).
//!
//! Two scaffolds, one wire — `plain` (`manifest.Wire.plain`), the default: the
//! model's arguments arrive on stdin as one JSON object, and whatever the
//! process prints to stdout IS the result the model sees, no envelope, no id
//! to echo. `nulya ext api protocol` documents the other wire, `jsonrpc`.
//!
//!   default   a SCRIPT extension — `src/run.sh` and `src/run.ps1`, three
//!             lines each, selected per host by the manifest's per-OS `entry`
//!             / `interpreter`. No compiler, no JSON parser needed at all.
//!   `--zig`   a compiled Zig extension, for when a compiled runtime has been
//!             measured to be needed. Same wire — `plain` is not tied to
//!             scripts, it is just the wire that needs the least ceremony.
//!
//! Both are real, buildable, runnable extensions the moment they are written.
//! That is what makes "the second tool is created by Nulya itself" a running
//! demonstration rather than a diagram.
//!
//! `permissions` is in neither, and no longer in the schema either: it was a
//! claimed footprint the kernel parsed and never read (DESIGN §9), and a
//! template is copied far more often than it is read, so an empty declaration
//! nobody enforces would have propagated as ceremony.

const std = @import("std");

/// A minimal but complete extension entry point on the `plain` wire. Single-file
/// so `zig build-exe src/main.zig` compiles it with no build.zig (DESIGN §7.3,
/// §10).
pub const main_zig =
    \\//! A generated Nulya extension (`plain` wire, oneshot).
    \\//! stdin is this call's arguments as one JSON object (`{}` when there are
    \\//! none) — the exact bytes the model produced. Whatever this prints to
    \\//! stdout IS the result the model sees, verbatim; exit 0 for success. An
    \\//! error path looks like this instead: write to stderr, then
    \\//! `std.process.exit(1)` (a non-zero exit is a FAILED call, its text made
    \\//! from `exit <code>` plus stderr — DESIGN §7.3, `nulya ext api protocol`).
    \\const std = @import("std");
    \\
    \\/// `std.process.Init` rather than a bare `main()`: the io it hands over
    \\/// carries the REAL process environment, so any child this extension spawns
    \\/// inherits it. A hand-rolled `std.Io.Threaded.init(gpa, .{})` defaults its
    \\/// environ to EMPTY — no PATH, no HOME, no API key — and that failure stays
    \\/// invisible until something is actually spawned. `init.environ_map` is the
    \\/// environment itself, when a child needs it named.
    \\pub fn main(init: std.process.Init) !void {
    \\    const alloc = init.gpa;
    \\    const io = init.io;
    \\
    \\    // Read the whole request from stdin: this call's arguments as one JSON
    \\    // object.
    \\    var in_buf: [4096]u8 = undefined;
    \\    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    \\    const args_json = try reader.interface.allocRemaining(alloc, .limited(1 << 20));
    \\    defer alloc.free(args_json);
    \\
    \\    var name: []const u8 = "world";
    \\    const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch null;
    \\    defer if (parsed) |p| p.deinit();
    \\    if (parsed) |p| switch (p.value) {
    \\        .object => |o| if (o.get("name")) |v| switch (v) {
    \\            .string => |s| name = s,
    \\            else => {},
    \\        },
    \\        else => {},
    \\    };
    \\
    \\    var out: std.Io.Writer.Allocating = .init(alloc);
    \\    defer out.deinit();
    \\    try out.writer.print("hello from a Nulya-built extension, name={s}\n", .{name});
    \\    try std.Io.File.stdout().writeStreamingAll(io, out.writer.buffered());
    \\}
    \\
;

/// A real acceptance case (DESIGN §12): input the model/user can inspect, and
/// the expected shape of a successful response — the `plain` wire: `request`
/// is the arguments object, `expect.stdout` is the exact text the model would
/// read back.
pub const example_test_json =
    \\{
    \\  "request": { "arguments": { "name": "world" } },
    \\  "expect": { "stdout": "hello from a Nulya-built extension, name=world\n" }
    \\}
    \\
;

/// The generated PowerShell entry for the `plain` wire: read one argument out of
/// the environment, print one line. Frozen and run as-is — no compilation
/// (DESIGN §7.1). Caller owns the returned bytes.
///
/// `[Console]::Out.Write` rather than `Write-Output`: stdout IS the result the
/// model sees, so the script decides its own trailing newline instead of a
/// cmdlet deciding it per platform.
pub fn scriptPs1(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\# stdin is this call's arguments as JSON; each simple argument is also NULYA_ARG_<key>.
        \\$name = if ($env:NULYA_ARG_name) {{ $env:NULYA_ARG_name }} else {{ 'world' }}
        \\[Console]::Out.Write("hello from {s}, name=$name`n")
        \\
    , .{id});
}

/// The generated POSIX sh entry for the `plain` wire. Caller owns the bytes.
pub fn scriptSh(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\# stdin is this call's arguments as JSON; each simple argument is also NULYA_ARG_<key>.
        \\printf 'hello from {s}, name=%s\n' "${{NULYA_ARG_name:-world}}"
        \\
    , .{id});
}

/// Render `extension.json` for a SCRIPT extension on the `plain` wire: one entry
/// and one interpreter per OS, so a single content-addressed version runs on
/// every platform (DESIGN §7.1). Caller owns the returned bytes.
pub fn scriptManifestJson(alloc: std.mem.Allocator, id: []const u8, tool: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "{s}",
        \\  "runtime": {{
        \\    "entry": {{ "windows": "src/run.ps1", "default": "src/run.sh" }},
        \\    "interpreter": {{ "windows": "powershell", "default": "sh" }},
        \\    "wire": "plain"
        \\  }},
        \\  "contributes": {{
        \\    "tools": [{{
        \\      "name": "{s}",
        \\      "description": "A generated Nulya script extension tool.",
        \\      "input": {{ "type": "object", "properties": {{ "name": {{ "type": "string" }} }} }}
        \\    }}]
        \\  }}
        \\}}
        \\
    , .{ id, tool });
}

/// Render `extension.json` for a compiled `--zig` extension: the `plain` wire,
/// same as the script scaffold — a compiled runtime is a different `entry`
/// prefix, not a different way of talking (DESIGN §7.1). Caller owns the
/// returned bytes.
pub fn manifestJson(alloc: std.mem.Allocator, id: []const u8, tool: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "{s}",
        \\  "runtime": {{ "entry": "bin/{s}", "wire": "plain" }},
        \\  "contributes": {{
        \\    "tools": [{{
        \\      "name": "{s}",
        \\      "description": "A generated Nulya extension tool.",
        \\      "input": {{ "type": "object", "properties": {{ "name": {{ "type": "string" }} }} }}
        \\    }}],
        \\    "skills": []
        \\  }}
        \\}}
        \\
    , .{ id, id, tool });
}
