//! `nulya ext run` / `ext inspect` / activation's shape default end to end
//! (docs/goals/ext-review.md Lane C, DESIGN §7.3/§7.5/§7.8/§14): the three
//! CLI-surface changes that lane made, proved against the real binary — plus
//! `ext sync --seed` (docs/goals/ext-review-2.md Lane C §2, C3).
//!
//!   - a field-less, prompt-only package now defaults to `on_request`
//!     (DESIGN §7.5): `activate` alone registers it, a plain `session new`
//!     never sees it, and `--with` brings it in explicitly.
//!   - `nulya ext run` no longer applies a manifest's own `timeout_ms` — that
//!     field now bounds only a call reaching the model's tool face (D6). A
//!     slow script tool run through the CLI is unbounded unless the caller
//!     opts in with `--timeout-ms`.
//!   - `nulya ext inspect` answers the STORE, never a draft, for `<id>` and
//!     `<id>@<version>`; a draft is asked for by naming its path instead
//!     (D9).
//!   - `nulya ext sync --seed` is `ext seed` followed by the same sync
//!     (DESIGN §7.2): `--dry-run` plans both steps and writes neither.

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

// ── 1. activation's shape default (DESIGN §7.5) ──────────────────────────────

test "activation shape default: a field-less prompt-only package is registered, not discovered — a plain session skips it, --with brings it in" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A data package (no runtime, no toolchain needed) whose only contribution
    // is a system prompt, with NO `activation` field at all — the exact shape
    // this lane's default rule is about.
    const draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "mode.silent";
    try ws.createDirPath(io, draft ++ std.fs.path.sep_str ++ "prompts");
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "extension.json", .data =
        \\{"schema":"nulya.extension/v2","id":"mode.silent","contributes":{"system_prompts":["prompts/tone.md"]}}
    });
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "tone.md", .data = "SILENT MODE\n" });

    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);

    const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "mode.silent", version });
    defer alloc.free(activated.stdout);
    try std.testing.expectEqual(@as(u8, 0), activated.code);

    // `activate` only REGISTERED it (`.on_request` by shape): a plain session
    // never sees it, exactly as if it had written `"activation":"on_request"`.
    {
        const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(new.stdout);
        try std.testing.expectEqual(@as(u8, 0), new.code);
        const id = std.mem.trim(u8, new.stdout, " \r\n");
        const header = try support.readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") == null);
    }

    // `--with` names it explicitly and it joins THIS session, at the version
    // `activate` pointed at — registering it bought exactly that lookup.
    {
        const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", "mode.silent" });
        defer alloc.free(new.stdout);
        try std.testing.expectEqual(@as(u8, 0), new.code);
        const id = std.mem.trim(u8, new.stdout, " \r\n");
        const header = try support.readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "mode.silent") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, version) != null);
    }
}

// ── 2. `ext run` timeout: none by default, `--timeout-ms` opts in (D6) ──────

/// A host-appropriate script tool that sleeps ~2s before answering — long
/// enough to catch a 1000ms manifest timeout still being enforced by mistake,
/// short enough that the no-timeout case does not slow the suite down.
const snooze_ps1 =
    \\$ErrorActionPreference = 'Stop'
    \\$in = [Console]::In.ReadToEnd()
    \\$id = 'call'
    \\try { $req = $in | ConvertFrom-Json; if ($req.id) { $id = [string]$req.id } } catch {}
    \\Start-Sleep -Seconds 2
    \\$resp = [ordered]@{ jsonrpc = '2.0'; id = $id; result = 'slept 2s' }
    \\[Console]::Out.Write(($resp | ConvertTo-Json -Compress))
    \\
;

const snooze_sh =
    \\#!/bin/sh
    \\req=$(cat)
    \\id=$(printf '%s' "$req" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    \\[ -z "$id" ] && id=call
    \\sleep 2
    \\printf '{"jsonrpc":"2.0","id":"%s","result":"slept 2s"}' "$id"
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

// ── 3. `ext inspect`: version in effect / exact version / draft by path (D9) ─

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
        \\{"schema":"nulya.extension/v2","id":"inspect.demo","activation":"always","contributes":{"system_prompts":["prompts/tone.md"]}}
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
        \\{"schema":"nulya.extension/v2","id":"inspect.demo","activation":"always","contributes":{"system_prompts":["prompts/tone.md","prompts/second.md"]}}
    });
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "second.md", .data = "SECOND\n" });

    // ① still answers the ACTIVE version, unaffected by the draft edit — no
    // draft fallback (D9).
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

// ── 4. `ext sync --seed` (ext-review-2 §2, C3) ───────────────────────────────

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
