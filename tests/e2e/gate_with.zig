//! Two facts the kernel already holds, stopped from being re-derived.
//!
//! **The gate request carries the frozen declaration**. A call names
//! a tool the way the model sees it; "which package is that" and "does it claim
//! to only read" are answers the composition froze at `session new`. They now
//! ride on the request line as `tool_id` and `readonly`, so nobody who answers
//! the gate has to open a manifest — a derivation that three drivers each wrote
//! separately, and that failed silently in one of them.
//!
//! **A member carries its own tool selection**. `--with <id>:<tool>` is the one
//! way a `surface:"manual"` tool takes a native slot: activating the package
//! does not compose it, and composing it bare does not surface that tool.

const std = @import("std");
const support = @import("support.zig");

const runCli = support.runCli;
const runCliEnvs = support.runCliEnvs;
const runCliStdin = support.runCliStdin;
const runCliStderr = support.runCliStderr;
const extractVersion = support.extractVersion;
const readSessionFile = support.readSessionFile;

const windows = @import("builtin").os.tag == .windows;

/// A script package (so no test here needs a toolchain) declaring one tool, with
/// whatever manifest extras the caller wants. Returns the built version id;
/// caller frees. Nothing is activated.
fn buildScriptPackage(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    id: []const u8,
    tool_name: []const u8,
    /// JSON fragments spliced into the manifest: extra top-level keys, and extra
    /// keys inside the one tool spec. Each begins with its own comma. The tool
    /// is `surface: "manual"` because every test here selects it by name.
    top_extra: []const u8,
    tool_extra: []const u8,
) ![]u8 {
    const entry = if (windows) "src/run.ps1" else "src/run.sh";
    const script_name = if (windows) "run.ps1" else "run.sh";
    // Nothing here looks at the tool's output, so the script only has to exist
    // and exit 0.
    const script_body = if (windows) "[Console]::Out.Write('ok')\n" else "#!/bin/sh\nprintf ok\n";
    const interpreter = if (windows) "powershell" else "sh";

    const draft_rel = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
    defer alloc.free(draft_rel);
    const src_rel = try std.fs.path.join(alloc, &.{ draft_rel, "src" });
    defer alloc.free(src_rel);
    try ws.createDirPath(io, src_rel);
    const script_rel = try std.fs.path.join(alloc, &.{ src_rel, script_name });
    defer alloc.free(script_rel);
    try ws.writeFile(io, .{ .sub_path = script_rel, .data = script_body });

    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}"{s},"runtime":{{"entry":"{s}","interpreter":"{s}"}},"contributes":{{"tools":[{{"name":"{s}","surface":"manual","description":"a tool","input":{{"type":"object"}}{s}}}]}}}}
    , .{ id, top_extra, entry, interpreter, tool_name, tool_extra });
    defer alloc.free(manifest_bytes);
    const manifest_rel = try std.fs.path.join(alloc, &.{ draft_rel, "extension.json" });
    defer alloc.free(manifest_rel);
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });

    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft_rel });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    return extractVersion(alloc, built.stdout);
}

/// The one gate request line in a `--gate --stream` transcript, parsed. Caller
/// owns the returned `std.json.Parsed`.
fn gateRequest(alloc: std.mem.Allocator, stdout: []const u8) !?std.json.Parsed(std.json.Value) {
    var lines = std.mem.tokenizeAny(u8, stdout, "\r\n");
    while (lines.next()) |line| {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        errdefer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                parsed.deinit();
                continue;
            },
        };
        const stream = obj.get("stream") orelse {
            parsed.deinit();
            continue;
        };
        if (stream != .string or !std.mem.eql(u8, stream.string, "gate")) {
            parsed.deinit();
            continue;
        }
        return parsed;
    }
    return null;
}

fn newSession(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const new = try runCli(alloc, io, ws, argv);
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    return alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
}

test "gate: the request line carries the stable tool id and the frozen readonly claim" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // ── an extension tool that declares itself read-only ────────────────────
    //
    // Its model-facing NAME is `handoff` for one reason: that is the only
    // non-`shell` name the offline stand-in ever calls, so it is what lets a
    // real `session step --gate` be asked about an extension tool at all. The
    // call is denied, so the script itself never runs.
    const version = try buildScriptPackage(alloc, io, ws, exe_abs, "probe", "handoff", "", ",\"readonly\":true");
    defer alloc.free(version);
    const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "probe", version });
    defer alloc.free(activated.stdout);
    try std.testing.expectEqual(@as(u8, 0), activated.code);

    const readonly_id = try newSession(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", "probe:handoff" });
    defer alloc.free(readonly_id);
    {
        const ap = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", readonly_id, "go" });
        defer alloc.free(ap.stdout);
        try std.testing.expectEqual(@as(u8, 0), ap.code);
    }
    {
        const run = try runCliStdin(
            alloc,
            io,
            ws,
            &.{ exe_abs, "session", "step", readonly_id, "--max-steps", "1", "--stream", "--gate" },
            "deny not this time\n",
            &.{.{ .key = "NULYA_SCRIPTED_MODE", .value = "handoff" }},
        );
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);

        const parsed = (try gateRequest(alloc, run.stdout)) orelse return error.NoGateRequest;
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("request", obj.get("event").?.string);
        // The name the model used…
        try std.testing.expectEqualStrings("handoff", obj.get("tool").?.string);
        // …the stable id the gate and the usage journal use, which the name
        // alone could never give…
        try std.testing.expectEqualStrings("ext:probe/handoff", obj.get("tool_id").?.string);
        // …and the package's own claim, frozen with the version.
        try std.testing.expectEqual(true, obj.get("readonly").?.bool);
    }

    // ── the builtin: an id, and no claim about itself ───────────────────────
    const shell_id = try newSession(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(shell_id);
    {
        const ap = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", shell_id, "go" });
        defer alloc.free(ap.stdout);
        try std.testing.expectEqual(@as(u8, 0), ap.code);
    }
    {
        const run = try runCliStdin(
            alloc,
            io,
            ws,
            &.{ exe_abs, "session", "step", shell_id, "--max-steps", "1", "--stream", "--gate" },
            "allow\n",
            &.{.{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" }},
        );
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);

        const parsed = (try gateRequest(alloc, run.stdout)) orelse return error.NoGateRequest;
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("shell", obj.get("tool").?.string);
        try std.testing.expectEqualStrings("builtin.shell", obj.get("tool_id").?.string);
        // `null`, not `false`: the kernel is not a package and makes no claim —
        // and a driver that reads silence as "read-only" would be reading one.
        try std.testing.expect(obj.get("readonly").? == .null);
        // The arguments are still the model's own bytes, unchanged.
        try std.testing.expect(std.mem.indexOf(u8, obj.get("args").?.string, "echo hello-from-nulya") != null);
    }
}

test "with: activating a package does not compose it, and a bare member does not surface its manual tool" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Activated, which says only that `optin` means this version — and named by
    // neither `[extensions] with` nor `--with`.
    const version = try buildScriptPackage(alloc, io, ws, exe_abs, "optin", "look", "", "");
    defer alloc.free(version);
    {
        const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "optin", version });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
    }

    // Activated is not composed: a plain session has no member at all.
    {
        const plain = try newSession(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(plain);
        const header = try readSessionFile(alloc, io, ws, plain);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"active\":[]") != null);
    }

    const member = try std.fmt.allocPrint(alloc, "\"id\":\"optin\",\"version\":\"{s}\"", .{version});
    defer alloc.free(member);

    // A bare member freezes the version and contributes everything the package
    // declares — but `look` is `surface: manual`, so the face stays empty.
    {
        const bare = try newSession(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", "optin" });
        defer alloc.free(bare);
        const header = try readSessionFile(alloc, io, ws, bare);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, member) != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"native_tools\":[]") != null);
    }

    // Naming the tool is what puts it there.
    {
        const selected = try newSession(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", "optin:look" });
        defer alloc.free(selected);
        const header = try readSessionFile(alloc, io, ws, selected);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, member) != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "ext:optin/look") != null);
    }
}

test "with: a member with no current refuses and names it; a tool the version never declared refuses too" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Built here, never activated: there is a version to name, so the way out is
    // to name it — and the sentence has to say so.
    const version = try buildScriptPackage(alloc, io, ws, exe_abs, "shy", "peek", "", "");
    defer alloc.free(version);
    {
        const argv = [_][]const u8{ exe_abs, "session", "new", "--profile", "scripted", "--with", "shy:peek" };
        const refused = try runCli(alloc, io, ws, &argv);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expectEqualStrings("", refused.stdout); // refusals are stderr

        const said = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(said);
        try std.testing.expect(std.mem.indexOf(u8, said, "no such built version") != null);
        // The member is named back, with both ways out.
        try std.testing.expect(std.mem.indexOf(u8, said, "shy:peek") != null);
        try std.testing.expect(std.mem.indexOf(u8, said, "--with <id>@<version>") != null);
        try std.testing.expect(std.mem.indexOf(u8, said, "nulya ext activate") != null);
    }

    // Naming the version is the way in, and the selection then resolves.
    const with_ref = try std.fmt.allocPrint(alloc, "shy@{s}:peek", .{version});
    defer alloc.free(with_ref);
    {
        const id = try newSession(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", with_ref });
        defer alloc.free(id);
        const header = try readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "ext:shy/peek") != null);
    }

    // A tool this version does not declare fails the session rather than
    // starting one quietly missing what it was asked for.
    {
        const bad_ref = try std.fmt.allocPrint(alloc, "shy@{s}:nope", .{version});
        defer alloc.free(bad_ref);
        const argv = [_][]const u8{ exe_abs, "session", "new", "--profile", "scripted", "--with", bad_ref };
        const refused = try runCli(alloc, io, ws, &argv);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        const said = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(said);
        try std.testing.expect(std.mem.indexOf(u8, said, "does not declare") != null);
        try std.testing.expect(std.mem.indexOf(u8, said, "nope") != null);
    }
}
