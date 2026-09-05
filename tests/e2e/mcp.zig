//! `extensions/mcp`: one MCP server becomes one generated extension package.
//!
//! The claim under test is that this needs nothing from the kernel. A generator
//! connects to a server ONCE, writes the tool list it is given into a manifest,
//! and `ext build` freezes it — so the version is a hash of that tool face, and
//! a server that changes is a new version somebody activates, never a surprise
//! inside a live session.
//!
//!   - the same server generated twice is the SAME version; one more tool is a
//!     different one, and both stay in the store.
//!   - every generated tool is prefixed, `manual` and `recommended: false`, and
//!     carries the server's own JSON Schema unchanged.
//!   - one call goes the whole way: a session selects the tool, the executor
//!     spawns the frozen package, and the answer is the server's — carrying a
//!     credential the kernel would never have let through the environment.
//!   - installed but NOT configured is one clean failed call naming the file to
//!     write and the manual to read, not a broken host.
//!   - two servers whose tools land on one name fail the session, by name.
//!
//! The server is a fake: a shell script that answers `initialize`, `tools/list`
//! and `tools/call` and nothing else. Nothing here reaches a network.

const std = @import("std");
const support = @import("support.zig");

const composition = support.composition;
const runCli = support.runCli;
const runCliEnv = support.runCliEnv;

const windows = @import("builtin").os.tag == .windows;

/// One tools/list answer, as the fixture serves it.
const one_tool =
    \\[{"name":"echo_it","description":"Say it back.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]
;
const two_tools =
    \\[{"name":"echo_it","description":"Say it back.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}},{"name":"shout_it","description":"Louder.","inputSchema":{"type":"object","properties":{}}}]
;

/// The partner server for the collision: `fake_echo` + `it` lands on the same
/// name as `fake` + `echo_it`.
const partner_tool =
    \\[{"name":"it","description":"Just it.","inputSchema":{"type":"object","properties":{}}}]
;

const token_value = "s3cr3t-from-the-file";

const sh_server =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\  id=`printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p'`
    \\  if [ -z "$id" ]; then continue; fi
    \\  case "$line" in
    \\    *'"method":"initialize"'*)
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}'
    \\      ;;
    \\    *'"method":"tools/list"'*)
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":__TOOLS__}}'
    \\      ;;
    \\    *'"method":"tools/call"'*)
    \\      text=`printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p'`
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"content":[{"type":"text","text":"said '"$text"' token='"$FAKE_TOKEN"'"}],"isError":false}}'
    \\      ;;
    \\  esac
    \\done
    \\
;

const ps1_server =
    \\$ErrorActionPreference = 'Stop'
    \\while ($true) {
    \\  $line = [Console]::In.ReadLine()
    \\  if ($null -eq $line) { break }
    \\  if ($line -notmatch '"id":(\d+)') { continue }
    \\  $id = $Matches[1]
    \\  if ($line -match '"method":"initialize"') {
    \\    [Console]::Out.WriteLine('{"jsonrpc":"2.0","id":' + $id + ',"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}')
    \\  } elseif ($line -match '"method":"tools/list"') {
    \\    [Console]::Out.WriteLine('{"jsonrpc":"2.0","id":' + $id + ',"result":{"tools":__TOOLS__}}')
    \\  } elseif ($line -match '"method":"tools/call"') {
    \\    $text = ''
    \\    if ($line -match '"text":"([^"]*)"') { $text = $Matches[1] }
    \\    [Console]::Out.WriteLine('{"jsonrpc":"2.0","id":' + $id + ',"result":{"content":[{"type":"text","text":"said ' + $text + ' token=' + $env:FAKE_TOKEN + '"}],"isError":false}}')
    \\  }
    \\  [Console]::Out.Flush()
    \\}
    \\
;

/// Write a fake server serving `tools` into the workspace, and return the
/// `mcp_add` arguments that reach it. Caller owns the result.
fn fakeServer(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    stem: []const u8,
    server_name: []const u8,
    tools: []const u8,
    needs_token: bool,
) ![]u8 {
    const template = if (windows) ps1_server else sh_server;
    const size = std.mem.replacementSize(u8, template, "__TOOLS__", tools);
    const body = try alloc.alloc(u8, size);
    defer alloc.free(body);
    _ = std.mem.replace(u8, template, "__TOOLS__", tools, body);
    // `powershell -File` refuses anything that is not `.ps1`.
    const file = try std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, if (windows) ".ps1" else ".sh" });
    defer alloc.free(file);
    try ws.writeFile(io, .{ .sub_path = file, .data = body });

    const abs = try support.absIn(alloc, io, ws, file);
    defer alloc.free(abs);
    // Forward slashes: the path goes inside a JSON string, where a Windows
    // separator would be an escape.
    const path = try support.forwardSlashes(alloc, abs);
    defer alloc.free(path);

    const env_field = if (needs_token) ",\"env\":[\"FAKE_TOKEN\"]" else "";
    return if (windows)
        std.fmt.allocPrint(
            alloc,
            "{{\"name\":\"{s}\",\"command\":\"powershell\",\"args\":[\"-NoProfile\",\"-NonInteractive\",\"-File\",\"{s}\"]{s}}}",
            .{ server_name, path, env_field },
        )
    else
        std.fmt.allocPrint(
            alloc,
            "{{\"name\":\"{s}\",\"command\":\"sh\",\"args\":[\"{s}\"]{s}}}",
            .{ server_name, path, env_field },
        );
}

const Harness = struct {
    exe: []u8,
    zig: []u8,
    /// The activated `mcp` version, so `skill list` and `ext run mcp` resolve.
    version: []u8,

    fn deinit(self: Harness, alloc: std.mem.Allocator) void {
        alloc.free(self.exe);
        alloc.free(self.zig);
        alloc.free(self.version);
    }
};

/// Build the repo's own `extensions/mcp` into this workspace's store and point
/// `current` at it — activated, but a member of nothing.
fn install(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir) !Harness {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const zig = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const exe = try std.fs.path.resolve(alloc, &.{exe_rel});
    errdefer alloc.free(exe);

    const ref = try support.buildBundled(alloc, io, ws, exe, "mcp");
    defer alloc.free(ref);
    const at = std.mem.indexOfScalar(u8, ref, '@') orelse return error.TestUnexpectedResult;
    const version = try alloc.dupe(u8, ref[at + 1 ..]);
    errdefer alloc.free(version);
    try support.activateInStore(alloc, io, ws, "mcp", version);

    // The zig this suite was built with, since `mcp_add` shells out to
    // `nulya ext build` and a generated package is compiled.
    return .{ .exe = exe, .zig = try alloc.dupe(u8, zig), .version = version };
}

/// `mcp_add` with those arguments. Returns the built version id; caller owns it.
fn addServer(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    h: Harness,
    arguments: []const u8,
) ![]u8 {
    const added = try runCliEnv(alloc, io, ws, &.{ h.exe, "ext", "run", "mcp", "mcp_add", arguments }, "NULYA_ZIG", h.zig);
    defer alloc.free(added.stdout);
    if (added.code != 0) {
        std.debug.print("mcp_add failed:\n{s}\n", .{added.stdout});
        return error.TestUnexpectedResult;
    }
    return support.extractVersion(alloc, added.stdout);
}

/// The generated draft's manifest, as text. Caller owns it.
fn draftManifest(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8) ![]u8 {
    const path = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id, "extension.json" });
    defer alloc.free(path);
    return ws.readFileAlloc(io, path, alloc, .unlimited);
}

/// One tool call through the real executor chain, with real arguments — the
/// shape `support.callNative` has, plus the arguments a fixed `{}` cannot carry.
fn callWith(
    alloc: std.mem.Allocator,
    io: std.Io,
    t: support.tool.Tool,
    ws_path: []const u8,
    store_path: []const u8,
    args_json: []const u8,
) !support.tool.RawToolResult {
    var lenv = try support.environment.LocalEnvironment.init(alloc, io, .{ .extension_store = store_path });
    defer lenv.deinit();
    return t.executor.call(alloc, .{
        .args_json = args_json,
        .ctx = .{ .environment = lenv.environment(), .cwd = ws_path },
    });
}

test "mcp: a generated package is the hash of the server's tool face, and every tool is prefixed and off by default" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const h = try install(alloc, io, ws);
    defer h.deinit(alloc);

    const one = try fakeServer(alloc, io, ws, "fake", "fake", one_tool, false);
    defer alloc.free(one);

    const first = try addServer(alloc, io, ws, h, one);
    defer alloc.free(first);

    // The same server again: the snapshot is identical, so the version is, and
    // the store already holds it. That is the whole content-addressing claim.
    const again = try addServer(alloc, io, ws, h, one);
    defer alloc.free(again);
    try std.testing.expectEqualStrings(first, again);

    // What the model would be offered, if somebody named it.
    const manifest = try draftManifest(alloc, io, ws, "mcp.fake");
    defer alloc.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"fake_echo_it\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"surface\": \"manual\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"recommended\": false") != null);
    // The server's own schema, not a re-modelled one.
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"required\":[\"text\"]") != null);

    // One more tool on the server is a DIFFERENT version, and the old one stays
    // where it is: rolling back is activating it again.
    const two = try fakeServer(alloc, io, ws, "fake", "fake", two_tools, false);
    defer alloc.free(two);
    const grown = try addServer(alloc, io, ws, h, two);
    defer alloc.free(grown);
    try std.testing.expect(!std.mem.eql(u8, first, grown));

    var store = try support.openStore(alloc, io, ws);
    defer store.close(io);
    for ([_][]const u8{ first, grown }) |version| {
        const rel = try std.fs.path.join(alloc, &.{ "mcp.fake", "versions", version, "extension.json" });
        defer alloc.free(rel);
        const frozen = try store.readFileAlloc(io, rel, alloc, .unlimited);
        defer alloc.free(frozen);
        try std.testing.expect(std.mem.indexOf(u8, frozen, "\"fake_echo_it\"") != null);
    }
}

test "mcp: a generated tool answers on the model's face with a secret the environment would never have carried, and refuses cleanly without it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const host_dialect = try support.hostDialect(alloc, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const h = try install(alloc, io, ws);
    defer h.deinit(alloc);

    // `FAKE_TOKEN` is exactly the shape the host strips out of an extension's
    // environment, which is why the value travels in a file this package reads
    // rather than in the environment it inherits.
    try ws.createDirPath(io, ".nulya" ++ std.fs.path.sep_str ++ "mcp");
    const config_rel = ".nulya" ++ std.fs.path.sep_str ++ "mcp" ++ std.fs.path.sep_str ++ "fake.json";
    try ws.writeFile(io, .{
        .sub_path = config_rel,
        .data = "{\"env\": {\"FAKE_TOKEN\": \"" ++ token_value ++ "\"}}",
    });

    const arguments = try fakeServer(alloc, io, ws, "fake", "fake", one_tool, true);
    defer alloc.free(arguments);
    const version = try addServer(alloc, io, ws, h, arguments);
    defer alloc.free(version);
    try support.activateInStore(alloc, io, ws, "mcp.fake", version);

    // The manual is findable while `mcp` wears nothing: a `reference` skill is
    // in the catalogue of this machine, never in a session's prompt.
    const skills = try runCli(alloc, io, ws, &.{ h.exe, "skill", "list" });
    defer alloc.free(skills.stdout);
    try std.testing.expectEqual(@as(u8, 0), skills.code);
    const skill_ref = try std.fmt.allocPrint(alloc, "ext:mcp@{s}/mcp", .{h.version});
    defer alloc.free(skill_ref);
    try std.testing.expect(std.mem.indexOf(u8, skills.stdout, skill_ref) != null);
    try std.testing.expect(std.mem.indexOf(u8, skills.stdout, "reference") != null);

    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    const store_path = try support.storePath(alloc, io, ws);
    defer alloc.free(store_path);

    var comp = try composition.SessionComposition.init(alloc, io, ws_path, support.store_rel, host_dialect, .{
        .with = &.{.{ .id = "mcp.fake", .tools = .{ .named = &.{"fake_echo_it"} } }},
    });
    defer comp.deinit(alloc);
    const echo = comp.tools.lookup("fake_echo_it") orelse return error.TestUnexpectedResult;

    {
        const result = try callWith(alloc, io, echo, ws_path, store_path, "{\"text\":\"ping\"}");
        defer alloc.free(result.output);
        try std.testing.expect(result.ok);
        // The arguments reached the server untouched, and so did the credential.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "said ping") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, token_value) != null);
    }

    // Installed, activated, on the face — and not configured. One failed call
    // that says which file to write and where the format is written down.
    try ws.deleteFile(io, config_rel);
    {
        const result = try callWith(alloc, io, echo, ws_path, store_path, "{\"text\":\"ping\"}");
        defer alloc.free(result.output);
        try std.testing.expect(!result.ok);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "FAKE_TOKEN") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "fake.json") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "ext:mcp@") != null);
    }
}

test "mcp: two servers whose tools land on one name fail the session rather than shadowing each other" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const h = try install(alloc, io, ws);
    defer h.deinit(alloc);

    // Prefixing keeps two servers' `search` apart, but it cannot make collisions
    // impossible: `fake` + `echo_it` and `fake_echo` + `it` are both
    // `fake_echo_it`. What matters is that the kernel refuses rather than
    // quietly serving one of them.
    const left = try fakeServer(alloc, io, ws, "left", "fake", one_tool, false);
    defer alloc.free(left);
    const left_version = try addServer(alloc, io, ws, h, left);
    defer alloc.free(left_version);
    try support.activateInStore(alloc, io, ws, "mcp.fake", left_version);

    const right = try fakeServer(alloc, io, ws, "right", "fake_echo", partner_tool, false);
    defer alloc.free(right);
    const right_version = try addServer(alloc, io, ws, h, right);
    defer alloc.free(right_version);
    try support.activateInStore(alloc, io, ws, "mcp.fake_echo", right_version);

    const argv = [_][]const u8{
        h.exe,       "session",
        "new",       "--bare",
        "--profile", "scripted",
        "--with",    "mcp.fake:fake_echo_it",
        "--with",    "mcp.fake_echo:fake_echo_it",
    };
    const created = try runCli(alloc, io, ws, &argv);
    defer alloc.free(created.stdout);
    try std.testing.expect(created.code != 0);

    // …and it says which refusal this is. Rejections are on stderr, which the
    // exit code alone cannot carry, so the same command is asked twice.
    const said = try support.runCliStderr(alloc, io, ws, &argv, &.{});
    defer alloc.free(said);
    try std.testing.expect(std.mem.indexOf(u8, said, "DuplicateToolName") != null);
}
