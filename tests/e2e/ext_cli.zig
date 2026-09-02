//! Membership / `ext run` / `ext inspect` / `ext sync --seed` on the real binary.
//!
//!   - a package joins a session by one of two routes: config's
//!     `[extensions] with` (standing, and the project layer may write it) or
//!     `session new --with` (one session). Without one of the two, `activate`
//!     says which version `<id>` means and composes nothing.
//!   - `session new --bare` reads no standing layer at all.
//!   - a member whose `current` is broken fails the session by name; a broken
//!     package nobody asked for is skipped.
//!   - `nulya ext run` no longer applies a manifest's own `timeout_ms` — that
//!     field now bounds only a call reaching the model's tool face. A slow
//!     script tool run through the CLI is unbounded unless the caller opts in
//!     with `--timeout-ms`.
//!   - `nulya ext inspect` answers the STORE, never a draft, for `<id>` and
//!     `<id>@<version>`; a draft is asked for by naming its path instead.
//!   - `nulya ext sync --seed` is `ext seed` followed by the same sync:
//!     `--dry-run` plans both steps and writes neither.

const std = @import("std");
const support = @import("support.zig");

const extractVersion = support.extractVersion;
const runCli = support.runCli;
const runCliStderr = support.runCliStderr;

/// The absolute path of the binary under test, or a skip — same shape as
/// `e2e/cli.zig`'s helper.
fn nulyaExe(alloc: std.mem.Allocator, host_env: *const std.process.Environ.Map) ![]u8 {
    const rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    return std.fs.path.resolve(alloc, &.{rel});
}

// ── 1. membership: only a NAME composes a package ─────────────

/// Build and activate a data package whose only contribution is a system
/// prompt (no runtime, so no toolchain is needed). Returns its version id;
/// caller owns it.
fn promptPackage(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    id: []const u8,
    body: []const u8,
) ![]u8 {
    const draft = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
    defer alloc.free(draft);
    const prompts = try std.fs.path.join(alloc, &.{ draft, "prompts" });
    defer alloc.free(prompts);
    try ws.createDirPath(io, prompts);

    const manifest = try std.fmt.allocPrint(
        alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","contributes":{{"system_prompts":["prompts/tone.md"]}}}}
    ,
        .{id},
    );
    defer alloc.free(manifest);
    const manifest_path = try std.fs.path.join(alloc, &.{ draft, "extension.json" });
    defer alloc.free(manifest_path);
    try ws.writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
    const tone_path = try std.fs.path.join(alloc, &.{ prompts, "tone.md" });
    defer alloc.free(tone_path);
    try ws.writeFile(io, .{ .sub_path = tone_path, .data = body });

    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    errdefer alloc.free(version);

    const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", id, version });
    defer alloc.free(activated.stdout);
    try std.testing.expectEqual(@as(u8, 0), activated.code);
    return version;
}

/// A script package declaring one tool (so no toolchain is needed), built but
/// not activated. Returns its version id; caller owns it.
fn scriptPackage(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    id: []const u8,
    tool_name: []const u8,
) ![]u8 {
    const windows = @import("builtin").os.tag == .windows;
    const entry = if (windows) "src/run.ps1" else "src/run.sh";
    const script_name = if (windows) "run.ps1" else "run.sh";
    // Nothing here calls the tool, so the script only has to exist. Its surface
    // is `manual` because every caller here PINS it, and only a `manual` tool
    // takes a pin.
    const script_body = if (windows) "[Console]::Out.Write('ok')\n" else "#!/bin/sh\nprintf ok\n";
    const interpreter = if (windows) "powershell" else "sh";

    const draft = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
    defer alloc.free(draft);
    const src = try std.fs.path.join(alloc, &.{ draft, "src" });
    defer alloc.free(src);
    try ws.createDirPath(io, src);
    const script = try std.fs.path.join(alloc, &.{ src, script_name });
    defer alloc.free(script);
    try ws.writeFile(io, .{ .sub_path = script, .data = script_body });

    const manifest = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","runtime":{{"entry":"{s}","interpreter":"{s}"}},"contributes":{{"tools":[{{"name":"{s}","surface":"manual","description":"a tool","input":{{"type":"object"}}}}]}}}}
    , .{ id, entry, interpreter, tool_name });
    defer alloc.free(manifest);
    const manifest_path = try std.fs.path.join(alloc, &.{ draft, "extension.json" });
    defer alloc.free(manifest_path);
    try ws.writeFile(io, .{ .sub_path = manifest_path, .data = manifest });

    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    return extractVersion(alloc, built.stdout);
}

/// The header of a session created with `extra` appended to `session new`, or
/// null when creation was refused. Caller owns the bytes.
fn newSessionHeader(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    extra: []const []const u8,
) !?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    try argv.appendSlice(alloc, extra);

    const new = try runCli(alloc, io, ws, argv.items);
    defer alloc.free(new.stdout);
    if (new.code != 0) return null;
    return try support.readSessionFile(alloc, io, ws, std.mem.trim(u8, new.stdout, " \r\n"));
}

test "a built and activated prompt package joins no session until `[extensions] with` or --with names it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const version = try promptPackage(alloc, io, ws, exe_abs, "mode.silent", "SILENT MODE\n");
    defer alloc.free(version);

    // Built and activated, and that composes nothing at all: `current` says
    // which version `mode.silent` means, not that any session gets it.
    {
        const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{})).?;
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") == null);
    }

    // `--with` names it for one session, at the version `current` points at.
    {
        const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{ "--with", "mode.silent" })).?;
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, version) != null);
    }

    // The standing form says it once, for every session opened here — and the
    // PROJECT layer may write it (`mergeProject`): unlike `extensions.paths` it
    // can only select among packages this machine already holds and trusts, so
    // a checkout cannot use it to introduce code.
    try ws.createDirPath(io, ".nulya");
    try ws.writeFile(io, .{
        .sub_path = ".nulya" ++ std.fs.path.sep_str ++ "config.toml",
        .data = "[extensions]\nwith = [\"mode.silent\"]\n",
    });
    {
        const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{})).?;
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, version) != null);
    }

    // …and `--bare` composes from its own flags alone, so the same workspace
    // opens a session without it.
    {
        const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{"--bare"})).?;
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") == null);
    }
}

test "--bare ignores the standing member list; a --with on the command line still composes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A script tool package, so a selection has something to name, plus a
    // prompt-only one for the bare-member half.
    const tool_version = try scriptPackage(alloc, io, ws, exe_abs, "face", "look");
    defer alloc.free(tool_version);
    const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "face", tool_version });
    defer alloc.free(activated.stdout);
    try std.testing.expectEqual(@as(u8, 0), activated.code);
    const mode_version = try promptPackage(alloc, io, ws, exe_abs, "mode.silent", "SILENT MODE\n");
    defer alloc.free(mode_version);

    // The standing list, in the project layer, carrying both spellings: a bare
    // member and one with a tool selection.
    try ws.createDirPath(io, ".nulya");
    try ws.writeFile(io, .{
        .sub_path = ".nulya" ++ std.fs.path.sep_str ++ "config.toml",
        .data =
        \\[extensions]
        \\with = ["mode.silent", "face:look"]
        \\
        ,
    });

    // Without `--bare`, both entries compose.
    {
        const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{})).?;
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "ext:face/look") != null);
    }

    // With it, the tool face is `shell` alone and nothing is a member: this is
    // the composition a delegated sub-agent gets, whose whole capability list is
    // its own definition (`extensions/agent`).
    {
        const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{"--bare"})).?;
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") == null);
        try std.testing.expect(std.mem.indexOf(u8, header, "ext:face/look") == null);
        try std.testing.expect(std.mem.indexOf(u8, header, "face") == null);
    }

    // `--bare` subtracts only the CONFIG half: argv still composes.
    {
        const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{ "--bare", "--with", "face:look" })).?;
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "ext:face/look") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, tool_version) != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") == null);
    }
}

test "ext activate composes nothing, and says which member line would" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A package of `surface: manual` tools: the case where membership alone is
    // not enough, so the hint has to spell the selection out.
    const version = try scriptPackage(alloc, io, ws, exe_abs, "face", "look");
    defer alloc.free(version);

    const argv = [_][]const u8{ exe_abs, "ext", "activate", "face", version };
    const on = try runCli(alloc, io, ws, &argv);
    defer alloc.free(on.stdout);
    try std.testing.expectEqual(@as(u8, 0), on.code);

    const said = try runCliStderr(alloc, io, ws, &argv, &.{});
    defer alloc.free(said);
    for ([_][]const u8{ "[extensions] with", "--with face:look" }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, said, needle) != null) catch |err| {
            std.debug.print("activate never says '{s}':\n{s}\n", .{ needle, said });
            return err;
        };
    }

    // And activating really did compose nothing.
    const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{})).?;
    defer alloc.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "\"active\":[]") != null);
}

test "ext sync --activate activates every draft it builds" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    for ([_][]const u8{ "mode.kong", "plain.one" }) |id| {
        const draft = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
        defer alloc.free(draft);
        const prompts = try std.fs.path.join(alloc, &.{ draft, "prompts" });
        defer alloc.free(prompts);
        try ws.createDirPath(io, prompts);
        const manifest = try std.fmt.allocPrint(
            alloc,
            \\{{"schema":"nulya.extension/v2","id":"{s}","contributes":{{"system_prompts":["prompts/tone.md"]}}}}
        ,
            .{id},
        );
        defer alloc.free(manifest);
        const manifest_path = try std.fs.path.join(alloc, &.{ draft, "extension.json" });
        defer alloc.free(manifest_path);
        try ws.writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
        const tone_path = try std.fs.path.join(alloc, &.{ prompts, "tone.md" });
        defer alloc.free(tone_path);
        try ws.writeFile(io, .{ .sub_path = tone_path, .data = "TONE\n" });
    }

    const synced = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "sync", "--activate" });
    defer alloc.free(synced.stdout);
    try std.testing.expectEqual(@as(u8, 0), synced.code);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, synced.stdout, "-> current"));

    // Activated is still not composed: neither id reaches a fresh session.
    const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{})).?;
    defer alloc.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "mode.kong") == null);
    try std.testing.expect(std.mem.indexOf(u8, header, "plain.one") == null);
}

test "a word outside a closed manifest vocabulary is refused before anything is built" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // `surface` is a closed vocabulary. A typo must be named, not read as the
    // default — and the three words it USED to be spelled with are outside it
    // now, so a package written against the old vocabulary is refused rather
    // than silently meaning something else.
    for ([_]struct { id: []const u8, body: []const u8, err: []const u8 }{
        .{ .id = "old.pin", .body =
        \\{"schema":"nulya.extension/v2","id":"old.pin","runtime":{"entry":"src/run.sh","interpreter":"sh"},"contributes":{"tools":[{"name":"t","surface":"pin","input":{}}]}}
        , .err = "InvalidSurface" },
        .{ .id = "old.with", .body =
        \\{"schema":"nulya.extension/v2","id":"old.with","runtime":{"entry":"src/run.sh","interpreter":"sh"},"contributes":{"tools":[{"name":"t","surface":"with","input":{}}]}}
        , .err = "InvalidSurface" },
        .{ .id = "old.driver", .body =
        \\{"schema":"nulya.extension/v2","id":"old.driver","runtime":{"entry":"src/run.sh","interpreter":"sh"},"contributes":{"tools":[{"name":"t","surface":"driver","input":{}}]}}
        , .err = "InvalidSurface" },
    }) |bad| {
        const draft = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", bad.id });
        defer alloc.free(draft);
        const prompts = try std.fs.path.join(alloc, &.{ draft, "prompts" });
        defer alloc.free(prompts);
        try ws.createDirPath(io, prompts);
        const src = try std.fs.path.join(alloc, &.{ draft, "src" });
        defer alloc.free(src);
        try ws.createDirPath(io, src);
        const script = try std.fs.path.join(alloc, &.{ src, "run.sh" });
        defer alloc.free(script);
        try ws.writeFile(io, .{ .sub_path = script, .data = "#!/bin/sh\nprintf ok\n" });
        const manifest_path = try std.fs.path.join(alloc, &.{ draft, "extension.json" });
        defer alloc.free(manifest_path);
        try ws.writeFile(io, .{ .sub_path = manifest_path, .data = bad.body });
        const tone_path = try std.fs.path.join(alloc, &.{ prompts, "tone.md" });
        defer alloc.free(tone_path);
        try ws.writeFile(io, .{ .sub_path = tone_path, .data = "TONE\n" });

        const argv = [_][]const u8{ exe_abs, "ext", "build", draft };
        const refused = try runCli(alloc, io, ws, &argv);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        const said = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(said);
        std.testing.expect(std.mem.indexOf(u8, said, bad.err) != null) catch |err| {
            std.debug.print("`ext build {s}` never says {s}:\n{s}\n", .{ bad.id, bad.err, said });
            return err;
        };
        // Nothing was written: a refused draft leaves no version behind.
        const versions = try std.fs.path.join(alloc, &.{ draft, "versions" });
        defer alloc.free(versions);
        try std.testing.expectError(error.FileNotFound, ws.access(io, versions, .{}));
    }
}

test "a draft that declares a file it cannot freeze is answered with a sentence, not a stack trace" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A system prompt that is not valid UTF-8 would otherwise reach a session,
    // where every step is a 400 out of the provider and nothing on screen says
    // why. The build is where the AUTHOR is standing, so the build is where it
    // is said — and `ext sync` has always said it, so the only question here is
    // whether this verb does too.
    for ([_]struct { id: []const u8, bytes: ?[]const u8 }{
        .{ .id = "bad.utf8", .bytes = "tone \xff\xfe\n" },
        .{ .id = "bad.absent", .bytes = null },
    }) |bad| {
        const draft = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", bad.id });
        defer alloc.free(draft);
        const prompts = try std.fs.path.join(alloc, &.{ draft, "prompts" });
        defer alloc.free(prompts);
        try ws.createDirPath(io, prompts);
        const manifest_body = try std.fmt.allocPrint(
            alloc,
            "{{\"schema\":\"nulya.extension/v2\",\"id\":\"{s}\",\"contributes\":{{\"system_prompts\":[\"prompts/tone.md\"]}}}}",
            .{bad.id},
        );
        defer alloc.free(manifest_body);
        const manifest_path = try std.fs.path.join(alloc, &.{ draft, "extension.json" });
        defer alloc.free(manifest_path);
        try ws.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_body });
        if (bad.bytes) |bytes| {
            const tone_path = try std.fs.path.join(alloc, &.{ prompts, "tone.md" });
            defer alloc.free(tone_path);
            try ws.writeFile(io, .{ .sub_path = tone_path, .data = bytes });
        }

        const argv = [_][]const u8{ exe_abs, "ext", "build", draft };
        const refused = try runCli(alloc, io, ws, &argv);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        const said = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(said);
        std.testing.expect(std.mem.indexOf(u8, said, "ext build:") != null) catch |err| {
            std.debug.print("`ext build {s}` said:\n{s}\n", .{ bad.id, said });
            return err;
        };
        // The whole point: no compiler-shaped answer to an author-shaped fault.
        std.testing.expect(std.mem.indexOf(u8, said, ".zig:") == null) catch |err| {
            std.debug.print("`ext build {s}` traced instead of answering:\n{s}\n", .{ bad.id, said });
            return err;
        };
        const versions = try std.fs.path.join(alloc, &.{ draft, "versions" });
        defer alloc.free(versions);
        try std.testing.expectError(error.FileNotFound, ws.access(io, versions, .{}));
    }
}

test "--with <id> onto a broken current names the version and refuses the session" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const version = try promptPackage(alloc, io, ws, exe_abs, "mode.silent", "SILENT MODE\n");
    defer alloc.free(version);

    // Corrupt the seal of the version `current` points at.
    const seal = try std.fs.path.join(alloc, &.{ support.store_rel, "mode.silent", "versions", version, "seal.json" });
    defer alloc.free(seal);
    try ws.writeFile(io, .{ .sub_path = seal, .data = "{}" });

    // Naming it fails, and the stderr names WHICH version is broken and the two
    // ways back — an error code alone would not say which of a store's packages
    // to repair.
    const argv = [_][]const u8{ exe_abs, "session", "new", "--profile", "scripted", "--with", "mode.silent" };
    {
        const refused = try runCli(alloc, io, ws, &argv);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expectEqualStrings("", refused.stdout); // refusals are stderr
    }
    const said = try runCliStderr(alloc, io, ws, &argv, &.{});
    defer alloc.free(said);
    for ([_][]const u8{ "mode.silent", version, "ext activate mode.silent", "--with mode.silent@" }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, said, needle) != null) catch |err| {
            std.debug.print("refusal never mentions '{s}':\n{s}\n", .{ needle, said });
            return err;
        };
    }

    // Not naming it composes fine — a broken package in the store was never on
    // its own a reason a session could not start.
    {
        const header = (try newSessionHeader(alloc, io, ws, exe_abs, &.{})).?;
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") == null);
    }
}

/// The frozen `extension.json` of `id@version` in the store. Caller owns it.
fn frozenManifestPath(alloc: std.mem.Allocator, id: []const u8, version: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ support.store_rel, id, "versions", version, "extension.json" });
}

test "editing a frozen manifest breaks its seal rather than changing what a session gets" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A composed member, edited under the session's feet: the frozen bytes are
    // what a version IS, so an edit is a broken seal and a named refusal, never
    // a quietly different composition.
    const version = try promptPackage(alloc, io, ws, exe_abs, "mode.kong", "KONG MODE\n");
    defer alloc.free(version);
    {
        const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "mode.kong", version });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
    }
    const kong_manifest = try frozenManifestPath(alloc, "mode.kong", version);
    defer alloc.free(kong_manifest);
    try ws.writeFile(io, .{ .sub_path = kong_manifest, .data =
    \\{"schema":"nulya.extension/v2","id":"mode.kong","contributes":{"system_prompts":["prompts/tone.md"],"skills":[]}}
    });

    const argv = [_][]const u8{ exe_abs, "session", "new", "--profile", "scripted", "--with", "mode.kong" };
    const refused = try runCli(alloc, io, ws, &argv);
    defer alloc.free(refused.stdout);
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    const said = try runCliStderr(alloc, io, ws, &argv, &.{});
    defer alloc.free(said);
    for ([_][]const u8{ "mode.kong", version }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, said, needle) != null) catch |err| {
            std.debug.print("refusal never mentions '{s}':\n{s}\n", .{ needle, said });
            return err;
        };
    }
}

// ── 2. `ext run` timeout: none by default, `--timeout-ms` opts in ──────

/// A host-appropriate script tool that sleeps ~2s before answering — long
/// enough to catch a 1000ms manifest timeout still being enforced by mistake,
/// short enough that the no-timeout case does not slow the suite down.
const snooze_ps1 =
    \\$ErrorActionPreference = 'Stop'
    \\$in = [Console]::In.ReadToEnd()
    \\Start-Sleep -Seconds 2
    \\[Console]::Out.Write('slept 2s')
    \\
;

const snooze_sh =
    \\#!/bin/sh
    \\cat >/dev/null
    \\sleep 2
    \\printf 'slept 2s'
    \\
;

test "ext run: a manifest timeout_ms is a bound for the model face only — the CLI path is unbounded unless --timeout-ms says otherwise" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const windows = @import("builtin").os.tag == .windows;
    const entry = if (windows) "src/run.ps1" else "src/run.sh";
    const interpreter = if (windows) "powershell" else "sh";
    const script_name = if (windows) "run.ps1" else "run.sh";
    const script_body = if (windows) snooze_ps1 else snooze_sh;

    const draft_rel = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "slow.tool";
    const src_rel = draft_rel ++ std.fs.path.sep_str ++ "src";
    try ws.createDirPath(io, src_rel);
    const script_rel = try std.fs.path.join(alloc, &.{ src_rel, script_name });
    defer alloc.free(script_rel);
    try ws.writeFile(io, .{ .sub_path = script_rel, .data = script_body });

    // The tool's OWN `timeout_ms` (1000ms) is well short of the 2s the script
    // actually sleeps — a manifest declaration that would kill this call if
    // `ext run` still enforced it the way a natively pinned call does.
    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"slow.tool","runtime":{{"entry":"{s}","interpreter":"{s}"}},"contributes":{{"tools":[{{"name":"snooze","input":{{"type":"object","properties":{{}}}},"timeout_ms":1000}}]}}}}
    , .{ entry, interpreter });
    defer alloc.free(manifest_bytes);
    const manifest_rel = try std.fs.path.join(alloc, &.{ draft_rel, "extension.json" });
    defer alloc.free(manifest_rel);
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });

    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft_rel });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    // Nothing is activated: `ext run <id>@<version>` names the built version
    // directly, which is how a driver calls a tool it never put on `current`.
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);
    const ref = try std.fmt.allocPrint(alloc, "slow.tool@{s}", .{version});
    defer alloc.free(ref);

    // No `--timeout-ms`: the manifest's 1000ms cap does not reach this path,
    // so the 2s sleep completes and the call succeeds.
    {
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "snooze", "{}" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "slept 2s") != null);
    }

    // `--timeout-ms 500`: now the caller opted into a bound, well under the
    // 2s the script sleeps, and the call is cut off.
    {
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "snooze", "{}", "--timeout-ms", "500" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "timed out") != null);
    }
}

// ── 3. `ext inspect`: version in effect / exact version / draft by path ─

test "ext inspect: bare id answers the version in effect with no draft fallback, <id>@<version> answers exactly that version, and a path answers the draft" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "inspect.demo";
    try ws.createDirPath(io, draft ++ std.fs.path.sep_str ++ "prompts");
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "extension.json", .data =
        \\{"schema":"nulya.extension/v2","id":"inspect.demo","contributes":{"system_prompts":["prompts/tone.md"]}}
    });
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "tone.md", .data = "ORIGINAL\n" });

    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const v1 = try extractVersion(alloc, built.stdout);
    defer alloc.free(v1);
    const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "inspect.demo", v1 });
    defer alloc.free(activated.stdout);
    try std.testing.expectEqual(@as(u8, 0), activated.code);

    // ① Bare id: the version IN EFFECT — right now, v1.
    {
        const inspected = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "inspect", "inspect.demo" });
        defer alloc.free(inspected.stdout);
        try std.testing.expectEqual(@as(u8, 0), inspected.code);
        // The frozen manifest's bytes, not a line about them: the version id is
        // in the path that was asked, and the content is what tells v1 apart.
        try std.testing.expect(std.mem.indexOf(u8, inspected.stdout, "prompts/tone.md") != null);
    }

    // Edit the DRAFT's manifest without rebuilding, so the version in effect
    // and the draft on disk diverge TEXTUALLY — a second system prompt this
    // draft names but v1 never saw.
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "extension.json", .data =
        \\{"schema":"nulya.extension/v2","id":"inspect.demo","contributes":{"system_prompts":["prompts/tone.md","prompts/second.md"]}}
    });
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "second.md", .data = "SECOND\n" });

    // ① still answers the ACTIVE version, unaffected by the draft edit — no
    // draft fallback.
    {
        const inspected = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "inspect", "inspect.demo" });
        defer alloc.free(inspected.stdout);
        try std.testing.expectEqual(@as(u8, 0), inspected.code);
        // The frozen manifest's bytes, not a line about them: the version id is
        // in the path that was asked, and the content is what tells v1 apart.
        try std.testing.expect(std.mem.indexOf(u8, inspected.stdout, "prompts/tone.md") != null);
        try std.testing.expect(std.mem.indexOf(u8, inspected.stdout, "second.md") == null);
    }

    // ② `<id>@<version>` answers exactly that built version — same content as
    // ①, and just as unaffected by the draft edit.
    {
        const ref = try std.fmt.allocPrint(alloc, "inspect.demo@{s}", .{v1});
        defer alloc.free(ref);
        const inspected = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "inspect", ref });
        defer alloc.free(inspected.stdout);
        try std.testing.expectEqual(@as(u8, 0), inspected.code);
        try std.testing.expect(std.mem.indexOf(u8, inspected.stdout, "prompts/tone.md") != null);
        try std.testing.expect(std.mem.indexOf(u8, inspected.stdout, "second.md") == null);
    }

    // ③ A path — this argument names the draft's directory directly — answers
    // the DRAFT, unbuilt and unfrozen: the edit is visible here and nowhere
    // else, exactly what `ext build` would freeze next.
    {
        const inspected = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "inspect", draft });
        defer alloc.free(inspected.stdout);
        try std.testing.expectEqual(@as(u8, 0), inspected.code);
        try std.testing.expect(std.mem.indexOf(u8, inspected.stdout, "second.md") != null);
    }

    // No active version at all is a named refusal, not a silent nothing.
    {
        const stderr = try runCliStderr(alloc, io, ws, &.{ exe_abs, "ext", "inspect", "nope.demo" }, &.{});
        defer alloc.free(stderr);
        try std.testing.expect(std.mem.indexOf(u8, stderr, "no active version of 'nope.demo'") != null);
    }
    {
        const inspected = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "inspect", "nope.demo" });
        defer alloc.free(inspected.stdout);
        try std.testing.expectEqual(@as(u8, 1), inspected.code);
    }
}

// ── 4. `ext sync --seed` ──────────────────────────────────────────────────────

test "ext sync --seed --dry-run: a seed plan for the bundled drafts, on a root that does not exist yet, writes nothing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Nothing at all in the workspace store yet — not even the root directory.
    try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{}));

    const synced = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "sync", "--seed", "--dry-run" });
    defer alloc.free(synced.stdout);
    try std.testing.expectEqual(@as(u8, 0), synced.code);

    // The seed half of the plan: every bundled draft this binary ships would be
    // written, and dry-run says so in the same words `ext seed --dry-run` does.
    try std.testing.expect(std.mem.indexOf(u8, synced.stdout, "would seed") != null);
    try std.testing.expect(std.mem.indexOf(u8, synced.stdout, "seeded, ") != null);

    // The sync half of the plan runs right after, over what seed would have
    // written — and since nothing was actually written, it still finds no
    // drafts to build.
    try std.testing.expect(std.mem.indexOf(u8, synced.stdout, "no drafts in") != null);

    // Neither half of a dry-run may leave a mark: the root directory itself
    // must not exist afterward.
    try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{}));
}
