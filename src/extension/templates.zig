//! Scaffolding templates for `nulya ext init` (DESIGN §7.2, §7.5).
//!
//! The generated extension is a real, buildable, runnable oneshot extension: it
//! reads one JSON-RPC request on stdin and writes one JSON-RPC response on
//! stdout. This is what makes "the third tool is created by Nulya itself" a
//! running demonstration rather than a diagram.

const std = @import("std");

/// A minimal but complete extension entry point. Single-file so
/// `zig build-exe src/main.zig` compiles it with no build.zig (DESIGN §7.3, §10).
pub const main_zig =
    \\//! A generated Nulya extension (JSON-RPC 2.0, oneshot).
    \\//! Reads one request JSON on stdin, writes one response JSON on stdout.
    \\const std = @import("std");
    \\
    \\pub fn main() !void {
    \\    var gpa: std.heap.DebugAllocator(.{}) = .init;
    \\    defer _ = gpa.deinit();
    \\    const alloc = gpa.allocator();
    \\
    \\    var threaded: std.Io.Threaded = .init(alloc, .{});
    \\    defer threaded.deinit();
    \\    const io = threaded.io();
    \\
    \\    // Read the whole request from stdin.
    \\    var in_buf: [4096]u8 = undefined;
    \\    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    \\    const request = try reader.interface.allocRemaining(alloc, .limited(1 << 20));
    \\    defer alloc.free(request);
    \\
    \\    // Best-effort: echo back the request id if present. The host currently
    \\    // sends string ids; a handwritten extension may support numeric ids too.
    \\    var id: []const u8 = "";
    \\    const parsed = std.json.parseFromSlice(std.json.Value, alloc, request, .{}) catch null;
    \\    defer if (parsed) |p| p.deinit();
    \\    if (parsed) |p| switch (p.value) {
    \\        .object => |o| if (o.get("id")) |v| switch (v) {
    \\            .string => |s| {
    \\                id = s;
    \\            },
    \\            else => {},
    \\        },
    \\        else => {},
    \\    };
    \\
    \\    // Build the success response.
    \\    var out: std.Io.Writer.Allocating = .init(alloc);
    \\    defer out.deinit();
    \\    var jw: std.json.Stringify = .{ .writer = &out.writer };
    \\    try jw.beginObject();
    \\    try jw.objectField("jsonrpc");
    \\    try jw.write("2.0");
    \\    try jw.objectField("id");
    \\    try jw.write(id);
    \\    try jw.objectField("result");
    \\    try jw.beginObject();
    \\    try jw.objectField("greeting");
    \\    try jw.write("hello from a Nulya-built extension");
    \\    try jw.endObject();
    \\    try jw.endObject();
    \\
    \\    try std.Io.File.stdout().writeStreamingAll(io, out.writer.buffered());
    \\}
    \\
;

/// A real acceptance case (DESIGN §12): input the model/user can inspect, and
/// the expected shape of a successful response.
pub const example_test_json =
    \\{
    \\  "request": { "method": "tool/call", "params": { "name": "greet", "arguments": {} } },
    \\  "expect": { "result": {} }
    \\}
    \\
;

/// A generated PowerShell script extension entry (JSON-RPC 2.0, oneshot): read
/// one request on stdin, write one response on stdout. Frozen and run as-is — no
/// compilation (DESIGN §7.1).
pub const script_ps1 =
    \\$ErrorActionPreference = 'Stop'
    \\$in = [Console]::In.ReadToEnd()
    \\$id = 'call'
    \\try { $req = $in | ConvertFrom-Json; if ($req.id) { $id = [string]$req.id } } catch {}
    \\$resp = [ordered]@{ jsonrpc = '2.0'; id = $id; result = [ordered]@{ greeting = 'hello from a Nulya script extension' } }
    \\[Console]::Out.Write(($resp | ConvertTo-Json -Compress))
    \\
;

/// A generated POSIX sh script extension entry (JSON-RPC 2.0, oneshot).
pub const script_sh =
    \\#!/bin/sh
    \\req=$(cat)
    \\id=$(printf '%s' "$req" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    \\[ -z "$id" ] && id=call
    \\printf '{"jsonrpc":"2.0","id":"%s","result":{"greeting":"hello from a Nulya script extension"}}' "$id"
    \\
;

/// Render `extension.json` for a SCRIPT extension: a `runtime.entry` under `src/`
/// plus an interpreter, no build step. Caller owns the returned bytes.
pub fn scriptManifestJson(alloc: std.mem.Allocator, id: []const u8, tool: []const u8, entry: []const u8, interpreter: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "{s}",
        \\  "runtime": {{ "entry": "{s}", "interpreter": "{s}" }},
        \\  "contributes": {{
        \\    "tools": [{{
        \\      "name": "{s}",
        \\      "description": "A generated Nulya script extension tool.",
        \\      "input": {{ "type": "object", "properties": {{}} }}
        \\    }}]
        \\  }},
        \\  "permissions": {{ "fs": [], "network": [], "process": [] }}
        \\}}
        \\
    , .{ id, entry, interpreter, tool });
}

/// Render `extension.json` for `id`/`tool`. Caller owns the returned bytes.
pub fn manifestJson(alloc: std.mem.Allocator, id: []const u8, tool: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "{s}",
        \\  "runtime": {{ "entry": "bin/{s}" }},
        \\  "contributes": {{
        \\    "tools": [{{
        \\      "name": "{s}",
        \\      "description": "A generated Nulya extension tool.",
        \\      "input": {{ "type": "object", "properties": {{}} }}
        \\    }}],
        \\    "skills": []
        \\  }},
        \\  "permissions": {{ "fs": [], "network": [], "process": [] }}
        \\}}
        \\
    , .{ id, id, tool });
}
