//! `--env remote:…`: the workspace lives on another machine.
//!
//! What is pinned here is what a mistake would make invisible:
//!
//!   1. the spec and the workspace are FROZEN in the header, and a bad one
//!      creates nothing (the `--prompt` / missing-credential discipline);
//!   2. a command really does travel the channel and come back;
//!   3. cancelling a step kills the command's process tree ON THE FAR SIDE —
//!      the guarantee the exec target could not make;
//!   4. no host secret reaches a command the agent runs;
//!   5. a session frozen onto a machine that does not answer refuses, and never
//!      falls back to running here;
//!   6. a spill lands on the machine whose files the model can open, at the very
//!      path its footer names (Phase 2);
//!   7. an extension tool runs on the far machine, against the far workspace —
//!      so `read` and `shell` finally answer about the same repository;
//!   8. an extension version pushed over the channel is validated against its
//!      own seal ON THAT MACHINE before it becomes a version anyone can use,
//!      and pushing one that is already there does nothing (Phase 3);
//!   9. which BUILD of a package serves a remote session is decided once, at
//!      creation, and a package with no build for that machine stops creation
//!      instead of failing later (`exec_version`);
//!  10. the workspace store on THAT machine is gated there the way one here is
//! gated here — a checkout cannot shadow a pushed version, and
//!      the refusal is one failed call, not a dead channel;
//!  11. a background task runs on that machine and its report still arrives here
//!      as the one thing a driver knows how to read — a report note drained
//!      at a step boundary — delivered exactly once however often it is asked
//!      for, killable across the channel, and honestly `unreachable` when that
//!      machine will not answer (Phase 4).

const std = @import("std");
const builtin = @import("builtin");
const support = @import("support.zig");

const remote = support.remote;
const environment = support.environment;
const emit = support.emit;
const integrity = support.integrity;
const launch = support.launch;
const protocol = support.remote_protocol;
const templates = support.templates;

const runCli = support.runCli;
const runCliEnv = support.runCliEnv;
const runCliStderr = support.runCliStderr;
const readSessionFile = support.readSessionFile;

/// What `NULYA_SCRIPTED_MODE=finish`'s one `shell` call prints. Spelled out
/// rather than imported, like `e2e/exec_env.zig` does: this is about observable
/// output, not a shared constant.
const local_marker = "hello-from-nulya";

/// The two probes `build.zig` puts in this group's environment (see there): one
/// secret-shaped, one not.
const secret_probe = "NULYA_REMOTE_PROBE_API_KEY";
const plain_probe = "NULYA_REMOTE_PROBE";

fn envVar(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const v = host_env.get(name) orelse return null;
    return try alloc.dupe(u8, v);
}

fn nulyaExe(alloc: std.mem.Allocator) ![]u8 {
    const rel = (try envVar(alloc, "NULYA_EXE")) orelse return error.SkipZigTest;
    defer alloc.free(rel);
    return std.fs.path.resolve(alloc, &.{rel});
}

/// A `remote:exec:` spec pointing at `exe`, with `extra` appended as further
/// argv words. `exec:` has no quoting by design (`remote.launcherArgv`), so a
/// path with a space cannot be spelled — say so and skip rather than fail with
/// something that looks like a protocol bug.
fn execSpec(alloc: std.mem.Allocator, exe: []const u8, extra: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, exe, ' ') != null) return error.SkipZigTest;
    if (extra.len == 0) return std.fmt.allocPrint(alloc, "remote:exec:{s}", .{exe});
    return std.fmt.allocPrint(alloc, "remote:exec:{s} {s}", .{ exe, extra });
}

fn fakeSpec(alloc: std.mem.Allocator, mode: []const u8) ![]u8 {
    const fake = (try envVar(alloc, "NULYA_FAKE_REMOTE")) orelse return error.SkipZigTest;
    defer alloc.free(fake);
    const abs = try std.fs.path.resolve(alloc, &.{fake});
    defer alloc.free(abs);
    return execSpec(alloc, abs, mode);
}

fn absOf(io: std.Io, dir: std.Io.Dir, buf: *[std.fs.max_path_bytes]u8) ![]u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

/// The one `tool_results` line of a `session step`'s JSONL — where a command's
/// OUTPUT is. The assistant event above it merely quotes the command.
fn toolResultsLine(stdout: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"kind\":\"tool_results\"") != null) return line;
    }
    return null;
}

// ── the session boundary ────────────────────────────────────────────────────

test "a remote session freezes which machine and which directory; a bad spec creates nothing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // ① A spelling from neither family. The message has to carry BOTH
    // vocabularies — there is no other place to learn them — and leave nothing
    // behind.
    {
        const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "remote:podman:x" }, &.{});
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "remote:ssh:<destination>") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/sessions", .{}));
    }

    // ② `--workspace` on a session whose workspace does not move is refused
    // rather than frozen as a field nothing reads.
    {
        const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--workspace", "/srv/app" }, &.{});
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "--workspace") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/sessions", .{}));
    }

    // ③ Both halves of "where does this run" are frozen, and the read-only
    // projection reports them: which machine, and which directory on it.
    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", "/srv/app" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    const header = try readSessionFile(alloc, io, ws, id);
    defer alloc.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "\"remote_workspace\":\"/srv/app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "remote:exec:") != null);

    const listed = try runCli(alloc, io, ws, &.{ exe, "session", "list", "--json" });
    defer alloc.free(listed.stdout);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"remote_workspace\":\"/srv/app\"") != null);
}

test "a remote session's command travels the channel and comes back" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec });
    defer alloc.free(new.stdout);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    const step = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "finish");
    defer alloc.free(step.stdout);
    const results = toolResultsLine(step.stdout) orelse return error.NoToolResults;
    // The agent ran it and the output came back through the frames — the whole
    // Phase 1 path in one assertion.
    try std.testing.expect(std.mem.indexOf(u8, results, local_marker) != null);
}

test "a session frozen onto a machine that does not answer refuses, and runs nothing here" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A launcher that cannot start: the spec is well formed, so `session new`
    // accepts it — reachability is answered at the first step, loudly.
    const nowhere = try execSpec(alloc, exe, "");
    defer alloc.free(nowhere);
    const bad = try std.fmt.allocPrint(alloc, "{s}-does-not-exist", .{nowhere});
    defer alloc.free(bad);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", bad });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    const step = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "finish");
    defer alloc.free(step.stdout);
    // Whatever the failure was, the one thing that must NOT have happened is
    // the command running on this host. A silent fallback would look like
    // success in every other way.
    try std.testing.expect(std.mem.indexOf(u8, step.stdout, local_marker) == null);
}

test "a peer speaking another protocol version is named, not guessed at" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try fakeSpec(alloc, "version");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const err = try runCliStderr(alloc, io, tmp.dir, &.{ exe, "remote", "check", "--env", spec }, &.{});
    defer alloc.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "protocol") != null);
}

// ── the two host verbs ──────────────────────────────────────────────────────

test "remote check and remote ls answer from the other side" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try ws.createDir(io, "sub", .default_dir);
    try ws.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });

    const check = try runCli(alloc, io, ws, &.{ exe, "remote", "check", "--env", spec, "--json" });
    defer alloc.free(check.stdout);
    try std.testing.expectEqual(@as(u8, 0), check.code);
    // It reports the machine that answered, not this process's own idea of one.
    try std.testing.expect(std.mem.indexOf(u8, check.stdout, "\"os\":\"" ++ @tagName(builtin.os.tag) ++ "\"") != null);

    // A listing is exact: names and kinds, not a parsed `ls`.
    const listed = try runCli(alloc, io, ws, &.{ exe, "remote", "ls", "--env", spec, "--json" });
    defer alloc.free(listed.stdout);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "{\"name\":\"sub\",\"dir\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "{\"name\":\"a.txt\",\"dir\":false}") != null);

    // A directory that is not there is a refusal, with a non-zero exit: a
    // browser has to be able to tell "empty" from "gone".
    const missing = try runCliStderr(alloc, io, ws, &.{ exe, "remote", "ls", "--env", spec, "nope" }, &.{});
    defer alloc.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "nope") != null);
}

// ── the channel itself, in process ──────────────────────────────────────────

fn threadedIo(alloc: std.mem.Allocator) std.Io.Threaded {
    return .init(alloc, .{});
}

fn markerExists(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    dir.access(io, name, .{}) catch return false;
    return true;
}

fn runShellCall(env: environment.Environment, alloc: std.mem.Allocator, req: environment.ShellRequest) anyerror!environment.ShellOutcome {
    return env.runShell(alloc, req);
}

test "cancelling a remote step kills the command's process tree on the far side" {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far = try absOf(io, tmp.dir, &abs_buf);

    var renv = try remote.RemoteEnvironment.connect(alloc, io, .{
        .spec = spec,
        // The agent runs the command HERE — which is also how this test knows
        // the frozen workspace, not the caller's cwd, is what reaches the far
        // side (the markers appear in this directory, not in the test's).
        .workspace = far,
        .version = "e2e",
    });
    defer renv.deinit();

    // Announce, sleep, then would announce again. The second marker never
    // appearing is the proof that the kill reached the far process rather than
    // the host merely giving up on it.
    const command = switch (renv.environment().dialect()) {
        .bash => "touch started; sleep 3; touch done",
        .powershell => "New-Item started -ItemType File -Force > $null; Start-Sleep -Seconds 3; New-Item done -ItemType File -Force > $null",
    };

    var fut = io.async(runShellCall, .{
        renv.environment(), alloc, environment.ShellRequest{ .command = command, .cwd = ".", .max_output_bytes = 1 << 20, .timeout_ms = 60_000 },
    });

    // Wait until the far command has actually started. The bound only exists so
    // a broken spawn fails instead of hanging; a loaded machine gets far more
    // room than it will ever need, and an idle run pays nothing for it.
    var waited: usize = 0;
    while (waited < 1500) : (waited += 1) {
        if (markerExists(io, tmp.dir, "started")) break;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    try std.testing.expect(markerExists(io, tmp.dir, "started"));

    if (fut.cancel(io)) |ok| {
        ok.deinit(alloc);
        return error.TestExpectedCancellation;
    } else |err| try std.testing.expectEqual(error.Canceled, err);

    // Comfortably past the far command's own sleep: its second step never ran.
    var elapsed: usize = 0;
    while (elapsed < 250) : (elapsed += 1) {
        try std.testing.expect(!markerExists(io, tmp.dir, "done"));
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
}

test "one channel serves many commands in a row" {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var renv = try remote.RemoteEnvironment.connect(alloc, io, .{ .spec = spec, .version = "e2e" });
    defer renv.deinit();

    // A step runs a whole batch of tool calls, and a session runs many steps
    // through one channel. The mid-command control watch is cancelled at the end
    // of EVERY command, so "the channel still works afterwards" is the property
    // that makes the second call in a batch possible at all.
    for (0..3) |i| {
        const command = switch (renv.environment().dialect()) {
            .bash => "echo round",
            .powershell => "Write-Output round",
        };
        errdefer std.debug.print("round {d} of the same channel failed\n", .{i});
        const outcome = try renv.environment().runShell(alloc, .{ .command = command, .cwd = ".", .max_output_bytes = 1 << 20, .timeout_ms = 30_000 });
        defer outcome.deinit(alloc);
        try std.testing.expectEqual(@as(u8, 0), outcome.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "round") != null);
    }
}

test "no host secret reaches a command the agent runs" {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const secret = (try envVar(alloc, secret_probe)) orelse return error.SkipZigTest;
    defer alloc.free(secret);
    const plain = (try envVar(alloc, plain_probe)) orelse return error.SkipZigTest;
    defer alloc.free(plain);

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var renv = try remote.RemoteEnvironment.connect(alloc, io, .{ .spec = spec, .version = "e2e" });
    defer renv.deinit();

    const command = switch (renv.environment().dialect()) {
        .bash => "echo \"[$" ++ secret_probe ++ "][$" ++ plain_probe ++ "]\"",
        .powershell => "Write-Output \"[$env:" ++ secret_probe ++ "][$env:" ++ plain_probe ++ "]\"",
    };
    const outcome = try renv.environment().runShell(alloc, .{ .command = command, .cwd = ".", .max_output_bytes = 1 << 20, .timeout_ms = 30_000 });
    defer outcome.deinit(alloc);

    // The secret-shaped name is gone by the time the command reads it…
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, secret) == null);
    // …and an ordinary variable is not, which is what makes the line above a
    // statement about the denylist rather than about a broken environment.
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, plain) != null);
}

test "a peer that stops talking, writes half a frame, or lies about a length is a lost channel" {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    for ([_][]const u8{ "die", "halfframe", "liar" }) |mode| {
        const spec = try fakeSpec(alloc, mode);
        defer alloc.free(spec);
        var renv = try remote.RemoteEnvironment.connect(alloc, io, .{ .spec = spec, .version = "e2e" });
        defer renv.deinit();
        // All three are the same answer on purpose: the channel is no longer
        // this protocol, and what the command did over there is unknown. None
        // of them may come back as an exit code.
        try std.testing.expectError(
            error.RemoteChannelLost,
            renv.environment().runShell(alloc, .{ .command = "echo hi", .cwd = ".", .max_output_bytes = 1 << 20, .timeout_ms = 30_000 }),
        );
    }
}

test "a peer that never answers is a stall, not a wait forever" {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const spec = try fakeSpec(alloc, "silent");
    defer alloc.free(spec);

    // Shrinking the bound is the only way to OBSERVE the guard rather than wait
    // it out — which is exactly why it is a parameter (`remote.Bounds`).
    try std.testing.expectError(error.RemoteChannelStalled, remote.RemoteEnvironment.connect(alloc, io, .{
        .spec = spec,
        .version = "e2e",
        .bounds = .{ .control_ms = 500, .reply_grace_ms = 500 },
    }));
}

// ── the spill follows the workspace ─────────────────────────────────────────

test "a spill lands in the far workspace, at the path its footer names, and nowhere here" {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    // "The other machine's workspace" — a directory that is not this process's
    // cwd, which is what makes "here" and "there" distinguishable at all.
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &abs_buf);

    var renv = try remote.RemoteEnvironment.connect(alloc, io, .{
        .spec = spec,
        .workspace = far_abs,
        .version = "e2e",
    });
    defer renv.deinit();

    // A line over the budget: the smallest thing that makes `emit` spill, so the
    // test is about WHERE the file goes rather than about moving a lot of bytes.
    const raw = "x" ** 400;
    const out = try emit.emit(
        alloc,
        renv.environment().fileSink(),
        raw,
        "shell",
        7,
        0,
        ".nulya/scratch/s-remote-spill",
        .{ .max_line_bytes = 40 },
    );
    defer out.deinit(alloc);

    const path = out.spill_path orelse return error.NoSpill;
    // The footer the MODEL reads names it, and that is the only string used to
    // find it below: where the bytes went and where the reader is sent are one
    // fact, which is the whole point of the fourth verb.
    try std.testing.expect(std.mem.indexOf(u8, out.text, path) != null);

    const there = try far.dir.readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(there);
    try std.testing.expectEqualStrings(raw, there);

    // …and nothing was written under the harness's own workspace. Before the
    // spill followed the workspace this was the ONLY place the file existed,
    // and the footer pointed the model at a machine it could not reach.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
}

test "put-file creates the directories the path names" {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &abs_buf);

    var renv = try remote.RemoteEnvironment.connect(alloc, io, .{ .spec = spec, .workspace = far_abs, .version = "e2e" });
    defer renv.deinit();

    // A spill path is several levels deep and none of them exist on a fresh
    // machine, so "creates the parents" is part of the verb, not of its callers.
    try renv.environment().putWorkspaceFile(".nulya/scratch/s-x/tool-output/deep.txt", "bytes");
    const back = try far.dir.readFileAlloc(io, ".nulya/scratch/s-x/tool-output/deep.txt", alloc, .unlimited);
    defer alloc.free(back);
    try std.testing.expectEqualStrings("bytes", back);
}

// ── pushing an extension version ────────────────────────────────────────────
//
// The far machine has to be a DIFFERENT machine in the one respect this is
// about: its user store. Offline the far side is this same binary over a pipe
// inheriting the harness's environment, so these tests go through
// `tests/remote_home.zig`, a transport that adds `NULYA_HOME` and then spawns
// the real nulya — otherwise "the far store" and "this store" would be one
// directory.

/// A spec whose agent has `home` as its own nulya home.
fn homedSpec(alloc: std.mem.Allocator, exe: []const u8, home: []const u8) ![]u8 {
    const wrapper_rel = (try envVar(alloc, "NULYA_REMOTE_HOME_EXE")) orelse return error.SkipZigTest;
    defer alloc.free(wrapper_rel);
    const wrapper = try std.fs.path.resolve(alloc, &.{wrapper_rel});
    defer alloc.free(wrapper);
    const extra = try std.fmt.allocPrint(alloc, "{s} {s}", .{ home, exe });
    defer alloc.free(extra);
    return execSpec(alloc, wrapper, extra);
}

/// The extension store of a nulya whose home is `home`, asked of the same
/// function the agent itself will use — so the test looks where the product
/// looks rather than where the test author remembers the layout being.
fn userStoreOf(alloc: std.mem.Allocator, home: []const u8) ![]u8 {
    var map = try std.testing.environ.createMap(alloc);
    defer map.deinit();
    try map.put("NULYA_HOME", home);
    const path = try launch.storePath(alloc, &map);
    if (path.len == 0) {
        alloc.free(path);
        return error.SkipZigTest;
    }
    return path;
}

/// A compiled extension built into `ws`'s workspace store — the thing worth
/// pushing, because it has a `bin/` and therefore a mode to carry. Compiled at
/// most once per checkout (the suite's shared prebuilt cache).
fn pushable(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8) ![]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const manifest_bytes = try templates.manifestJson(alloc, id, "greet");
    defer alloc.free(manifest_bytes);
    return support.installPrebuilt(alloc, io, ws, zig_exe, id, manifest_bytes, support.plain_main_zig);
}

/// "That machine's home": a directory that is neither this workspace's store
/// nor the developer's real one. Returns the absolute path, in `buf`.
fn farHome(io: std.Io, ws: std.Io.Dir, buf: *[std.fs.max_path_bytes]u8) ![]u8 {
    try ws.createDirPath(io, "far-home");
    var dir = try ws.openDir(io, "far-home", .{});
    defer dir.close(io);
    return absOf(io, dir, buf);
}

test "a pushed version lands in the far machine's own store, and pushing it again does nothing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "pushed";
    const version = try pushable(alloc, io, ws, id);
    defer alloc.free(version);
    const ref = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ id, version });
    defer alloc.free(ref);

    var far_home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_home = try farHome(io, ws, &far_home_buf);
    const spec = try homedSpec(alloc, exe, far_home);
    defer alloc.free(spec);

    const pushed = try runCli(alloc, io, ws, &.{ exe, "ext", "push", ref, "--env", spec });
    defer alloc.free(pushed.stdout);
    try std.testing.expectEqual(@as(u8, 0), pushed.code);

    // It is there, and it is that version — proved the way every other consumer
    // of a store proves it, against the seal.
    const far_store = try userStoreOf(alloc, far_home);
    defer alloc.free(far_store);
    var far_root = try std.Io.Dir.openDirAbsolute(io, far_store, .{ .iterate = true });
    defer far_root.close(io);
    const version_rel = try std.fs.path.join(alloc, &.{ id, "versions", version });
    defer alloc.free(version_rel);
    try integrity.validateVersionDir(alloc, io, far_root, version_rel, version, id, .sealed);

    // A marker INSIDE the installed version, which no push writes and the seal
    // does not cover. A second push that re-sent the tree would stage a fresh
    // directory and rename it over this one, so the marker surviving IS the
    // no-op — not a sentence claiming one.
    const marker = try std.fs.path.join(alloc, &.{ version_rel, "pushed-once" });
    defer alloc.free(marker);
    try far_root.writeFile(io, .{ .sub_path = marker, .data = "x" });

    const again = try runCli(alloc, io, ws, &.{ exe, "ext", "push", ref, "--env", spec });
    defer alloc.free(again.stdout);
    try std.testing.expectEqual(@as(u8, 0), again.code);
    try far_root.access(io, marker, .{});

    // An exec target keeps this machine's store, so there is nothing over there
    // to push into — and the copy must not happen silently into our own.
    const wrong = try runCliStderr(alloc, io, ws, &.{ exe, "ext", "push", ref, "--env", "ssh:me@box" }, &.{});
    defer alloc.free(wrong);
    try std.testing.expect(std.mem.indexOf(u8, wrong, "ssh:me@box") != null);
}

test "a version that does not arrive intact never becomes visible over there" {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "pushed";
    const version = try pushable(alloc, io, ws, id);
    defer alloc.free(version);

    var far_home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_home = try farHome(io, ws, &far_home_buf);
    const spec = try homedSpec(alloc, exe, far_home);
    defer alloc.free(spec);

    // The frames are driven by hand, because `ext push` validates its own copy
    // before sending: the only way to ask "does the FAR side check?" is to be a
    // host that sends bytes it should not have.
    var ch = try remote.Channel.connect(alloc, io, try remote.parseSpec(spec), "e2e", .default);
    defer ch.deinit();

    const stat = try ch.controlRound(.{ .op = protocol.Op.store_stat.wire(), .id = id, .version = version }, "");
    try std.testing.expect(stat.ok and !stat.held);

    const version_rel = try std.fs.path.join(alloc, &.{ support.store_rel, id, "versions", version });
    defer alloc.free(version_rel);
    var src = try ws.openDir(io, version_rel, .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try integrity.canonicalRel(alloc, entry.path);
        defer alloc.free(rel);
        const bytes = try src.readFileAlloc(io, entry.path, alloc, .unlimited);
        defer alloc.free(bytes);
        // One file arrives altered — the shape a truncated transfer, a mangled
        // copy and a tampering host all produce.
        const send = if (std.mem.eql(u8, rel, "extension.json")) bytes[0 .. bytes.len - 1] else bytes;
        const put = try ch.controlRound(.{ .op = protocol.Op.store_put.wire(), .path = rel, .bytes = send.len }, send);
        try std.testing.expect(put.ok);
    }

    // The commit is where the far side does its own checking, and it refuses.
    const commit = try ch.controlRound(.{ .op = protocol.Op.store_commit.wire() }, "");
    try std.testing.expect(!commit.ok);

    // And nothing half-installed is left behind: no version directory at all,
    // which is what keeps a failed push from becoming a broken extension some
    // later session over there composes.
    const far_store = try userStoreOf(alloc, far_home);
    defer alloc.free(far_store);
    var far_root = try std.Io.Dir.openDirAbsolute(io, far_store, .{ .iterate = true });
    defer far_root.close(io);
    const far_version_rel = try std.fs.path.join(alloc, &.{ id, "versions", version });
    defer alloc.free(far_version_rel);
    try std.testing.expectError(error.FileNotFound, far_root.access(io, far_version_rel, .{}));
}

// ── what is not moved yet ───────────────────────────────────────────────────

test "a version the far machine does not hold is a failed call pointing at push, not a dead step" {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    // A workspace of its own, empty. Not this process's cwd: that is the nulya
    // checkout, whose `.nulya/extensions` is an untrusted store over there, and
    // the agent refuses those before it looks for a version at all — a true
    // answer, but a different one than this test is about.
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    var renv = try remote.RemoteEnvironment.connect(alloc, io, .{ .spec = spec, .workspace = far_abs, .version = "e2e" });
    defer renv.deinit();

    // Nothing was pushed, so the agent cannot run this. The answer is a FAILED
    // CALL — exit code plus the far side's own sentence — so it reaches the
    // model through the path every failed extension call already uses, and the
    // step goes on. A host error here would take the conversation down for
    // something one `nulya ext push` fixes.
    const ext = try renv.environment().runExtension(alloc, .{
        .id = "nowhere",
        .version = "v-000000000000000000000000",
        .tool = "t",
        .cwd = ".",
        .request_json = "{}",
        .max_output_bytes = 1 << 20,
    });
    defer ext.deinit(alloc);
    try std.testing.expect(ext.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, ext.stderr, "ext push") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext.stderr, "nowhere") != null);

    // A background task needs a session to report INTO, and this environment was
    // built without one — the same refusal a local environment gives, from the
    // same missing thing rather than from a phase that has not landed.
    try std.testing.expectError(
        error.NoDurableSession,
        renv.environment().startShellTask(alloc, .{ .command = "echo hi", .cwd = "." }),
    );
}

// ── the extension runs over there ───────────────────────────────────────────

/// The bundled `std`, built into `ws`'s workspace store (compiled at most once
/// per checkout by the suite's shared cache) and activated, so a `--with std:read` can
/// reach it. Returns its version; caller frees.
fn installStd(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe: []const u8) ![]u8 {
    const version = try support.stageBundled(alloc, io, ws, "std");
    errdefer alloc.free(version);
    const activated = try runCli(alloc, io, ws, &.{ exe, "ext", "activate", "std", version });
    defer alloc.free(activated.stdout);
    if (activated.code != 0) return error.ActivateFailed;
    return version;
}

/// …and delivered to the machine `spec` names.
fn pushStd(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe: []const u8, spec: []const u8) ![]u8 {
    const version = try installStd(alloc, io, ws, exe);
    errdefer alloc.free(version);
    const ref = try std.fmt.allocPrint(alloc, "std@{s}", .{version});
    defer alloc.free(ref);
    const pushed = try runCli(alloc, io, ws, &.{ exe, "ext", "push", ref, "--env", spec });
    defer alloc.free(pushed.stdout);
    if (pushed.code != 0) return error.PushFailed;
    return version;
}

test "an extension tool reads the FAR workspace, and keeps its per-session state there" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Two sentinels with the SAME name and different bodies: one here, one over
    // there. Which body comes back is the whole question this phase answers —
    // before it, `ext:std/read` was a process on this machine reading this
    // machine's files while `shell` read the other one's.
    try ws.writeFile(io, .{ .sub_path = launch.ScriptedProvider.read_target, .data = "host-side sentinel\n" });
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    try far.dir.writeFile(io, .{ .sub_path = launch.ScriptedProvider.read_target, .data = "far-side sentinel\n" });
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    // The agent gets a home of its own, so "the far store" really is a second
    // store and the push below is not a copy into the directory it came from.
    var far_home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_home = try farHome(io, ws, &far_home_buf);
    const spec = try homedSpec(alloc, exe, far_home);
    defer alloc.free(spec);

    const version = try pushStd(alloc, io, ws, exe, spec);
    defer alloc.free(version);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs, "--with", "std:read" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    const step = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "readfile");
    defer alloc.free(step.stdout);
    const results = toolResultsLine(step.stdout) orelse return error.NoToolResults;
    try std.testing.expect(std.mem.indexOf(u8, results, "far-side sentinel") != null);
    try std.testing.expect(std.mem.indexOf(u8, results, "host-side sentinel") == null);

    // …and the state the tool keeps between calls landed over there too, which
    // is only possible because the session's IDENTITY crossed the channel while
    // the session FILE's path — a fact about this machine — did not.
    const freshness = try std.fmt.allocPrint(alloc, ".nulya/scratch/{s}/std-freshness.jsonl", .{id});
    defer alloc.free(freshness);
    try far.dir.access(io, freshness, .{});
    try std.testing.expectError(error.FileNotFound, ws.access(io, freshness, .{}));
}

test "a package pushed nowhere fails its call and says which command delivers it, and the session goes on" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try ws.writeFile(io, .{ .sub_path = launch.ScriptedProvider.read_target, .data = "host-side sentinel\n" });

    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    var far_home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_home = try farHome(io, ws, &far_home_buf);
    const spec = try homedSpec(alloc, exe, far_home);
    defer alloc.free(spec);

    // Built here, never pushed. Creation still succeeds — the build for that
    // machine EXISTS, it is simply not over there yet, and which of those two
    // it is only the far machine can say.
    const version = try installStd(alloc, io, ws, exe);
    defer alloc.free(version);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs, "--with", "std:read" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    const step = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "readfile");
    defer alloc.free(step.stdout);
    // The step SUCCEEDED and the tool failed: the model is told what is missing
    // and by which command, and nothing on this machine was read instead.
    try std.testing.expectEqual(@as(u8, 0), step.code);
    const results = toolResultsLine(step.stdout) orelse return error.NoToolResults;
    try std.testing.expect(std.mem.indexOf(u8, results, "ext push") != null);
    try std.testing.expect(std.mem.indexOf(u8, results, "host-side sentinel") == null);
}

// ── which build serves the session ──────────────────────────────────────────

test "a member with no build for the far machine stops creation, naming the two commands that fix it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    // A peer that calls itself a machine no store can hold a build for.
    const spec = try fakeSpec(alloc, "foreign");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    const version = try installStd(alloc, io, ws, exe);
    defer alloc.free(version);

    const argv = [_][]const u8{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", "/srv/app", "--with", "std:read" };
    const new = try runCli(alloc, io, ws, &argv);
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 1), new.code);
    const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
    defer alloc.free(err_text);
    // Both commands, because both are needed and in that order: produce the
    // build, then deliver it.
    try std.testing.expect(std.mem.indexOf(u8, err_text, "--target") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_text, "ext push") != null);
    // No session was created: one frozen onto a machine that cannot run its own
    // composition would fail identically on every step it ever took. (The
    // directory itself is made before anything is composed, so what is checked
    // is that it is empty.)
    var sessions = try ws.openDir(io, ".nulya/sessions", .{ .iterate = true });
    defer sessions.close(io);
    var it = sessions.iterate();
    try std.testing.expect((try it.next(io)) == null);
}

test "a session whose header predates the exec-version column still steps" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try ws.writeFile(io, .{ .sub_path = launch.ScriptedProvider.read_target, .data = "here\n" });
    const version = try installStd(alloc, io, ws, exe);
    defer alloc.free(version);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--with", "std:read" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // Rewrite the header into the shape it had before the column existed. The
    // rule the optional column buys is that an OLD file still reads, and the
    // only way to check it is to have one.
    const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
    defer alloc.free(spath);
    const before = try ws.readFileAlloc(io, spath, alloc, .unlimited);
    defer alloc.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "\"exec_version\":\"\"") != null);
    const after = try std.mem.replaceOwned(u8, alloc, before, ",\"exec_version\":\"\"", "");
    defer alloc.free(after);
    try ws.writeFile(io, .{ .sub_path = spath, .data = after });

    const step = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "readfile");
    defer alloc.free(step.stdout);
    try std.testing.expectEqual(@as(u8, 0), step.code);
    const results = toolResultsLine(step.stdout) orelse return error.NoToolResults;
    try std.testing.expect(std.mem.indexOf(u8, results, "here") != null);
}

// ── background tasks on the far machine (Phase 4) ───────────────────────────
//
// The split under test: the command, its log and its supervisor are over there;
// the NAME and the DELIVERY are here. What a driver sees is unchanged — a
// report note drained at a step boundary — and that is the point.

/// A budget, not a delay: every wait below returns the instant the thing it
/// waits for happens (`e2e/background.zig`'s reasoning, same number).
const wait_budget_ms = "180000";

fn relTaskPath(alloc: std.mem.Allocator, id: []const u8, slot: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, ".nulya/scratch/{s}/tasks/{s}/{s}", .{ id, slot, name });
}

fn exists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

/// Which shell reads a command over there — asked of that machine, the way the
/// product asks (`hello`), rather than assumed from this one.
fn farDialect(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe: []const u8,
    spec: []const u8,
) !environment.Dialect {
    const checked = try runCli(alloc, io, ws, &.{ exe, "remote", "check", "--env", spec, "--json" });
    defer alloc.free(checked.stdout);
    if (checked.code != 0) return error.RemoteCheckFailed;
    return if (std.mem.indexOf(u8, checked.stdout, "\"dialect\":\"powershell\"") != null) .powershell else .bash;
}

test "a remote session's background task runs over there and its report arrives here as a note" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    // A workspace of its own for the far side, so "over there" is a directory
    // this test can look in and "here" is a different one.
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // The MODEL's entry point, not the CLI twin: `shell {background:true}` in a
    // session whose commands run elsewhere.
    const step1 = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "background");
    defer alloc.free(step1.stdout);
    try std.testing.expectEqual(@as(u8, 0), step1.code);
    const receipt = toolResultsLine(step1.stdout) orelse return error.NoToolResults;
    const started = try std.fmt.allocPrint(alloc, "[background task {s}/t1 started]", .{id});
    defer alloc.free(started);
    try std.testing.expect(std.mem.indexOf(u8, receipt, started) != null);

    const task_name = try std.fmt.allocPrint(alloc, "{s}/t1", .{id});
    defer alloc.free(task_name);
    const waited = try runCli(alloc, io, ws, &.{ exe, "task", "wait", task_name, "--timeout-ms", wait_budget_ms });
    defer alloc.free(waited.stdout);
    try std.testing.expectEqual(@as(u8, 0), waited.code);

    // The command ran on the FAR machine: its log and its status are in that
    // workspace, at the path the receipt names, and nothing of the sort is here.
    const log_rel = try relTaskPath(alloc, id, "t1", "output.log");
    defer alloc.free(log_rel);
    const far_log = try far.dir.readFileAlloc(io, log_rel, alloc, .unlimited);
    defer alloc.free(far_log);
    try std.testing.expect(std.mem.indexOf(u8, far_log, launch.ScriptedProvider.background_marker) != null);
    try std.testing.expect(!exists(io, ws, log_rel));

    // …while the DELIVERY is here: the wait above collected the report that
    // machine left and turned it into the event this session's inbox
    // understands. Same name a local supervisor would have deposited under.
    const deposit = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.inbox/task-{s}-t1.json", .{ id, id });
    defer alloc.free(deposit);
    const event = try ws.readFileAlloc(io, deposit, alloc, .unlimited);
    defer alloc.free(event);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"source\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, launch.ScriptedProvider.background_marker) != null);

    // Asking again does not deliver it again — the whole reason the host records
    // that it delivered one. Without that, the inbox file would come back after
    // every drain and `wait --any` would answer "something finished" forever.
    const listed = try runCli(alloc, io, ws, &.{ exe, "task", "list", "--session", id, "--json" });
    defer alloc.free(listed.stdout);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"state\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"machine\":\"remote:exec:") != null);

    // The step boundary drains it exactly as it drains a local one, and the
    // model reads it: the mechanism a driver sees did not change.
    const step2 = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "background");
    defer alloc.free(step2.stdout);
    try std.testing.expectEqual(@as(u8, 0), step2.code);
    try std.testing.expect(std.mem.indexOf(u8, step2.stdout, "\"source\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, step2.stdout, "background done") != null);

    // Drained, and it stays drained: one more poll must not put it back.
    try std.testing.expect(!exists(io, ws, deposit));
    const again = try runCli(alloc, io, ws, &.{ exe, "task", "list", "--session", id, "--json" });
    defer alloc.free(again.stdout);
    try std.testing.expect(!exists(io, ws, deposit));
}

test "a step collects a far task's report even when no task verb ever asked" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs });
    defer alloc.free(new.stdout);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    const step1 = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "background");
    defer alloc.free(step1.stdout);
    try std.testing.expectEqual(@as(u8, 0), step1.code);

    // Watch that machine's own file system rather than running a `task` verb:
    // this test is about the loop that has NO driver polling it — a bare
    // `session step` in a shell script — so nothing here may do the collecting
    // on its behalf.
    const report_rel = try relTaskPath(alloc, id, "t1", "report.txt");
    defer alloc.free(report_rel);
    var tries: usize = 0;
    while (tries < 3600 and !exists(io, far.dir, report_rel)) : (tries += 1) {
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    try std.testing.expect(exists(io, far.dir, report_rel));

    // Nothing has been deposited here yet: the far supervisor cannot reach this
    // machine's inbox, which is the whole reason the collecting happens here.
    const deposit = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.inbox/task-{s}-t1.json", .{ id, id });
    defer alloc.free(deposit);
    try std.testing.expect(!exists(io, ws, deposit));

    // The step sweeps over the channel it opens anyway, and the drain at its own
    // boundary does the rest — the model reads the report in this very step.
    const step2 = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "background");
    defer alloc.free(step2.stdout);
    try std.testing.expectEqual(@as(u8, 0), step2.code);
    try std.testing.expect(std.mem.indexOf(u8, step2.stdout, "\"source\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, step2.stdout, launch.ScriptedProvider.background_marker) != null);
}

test "prune leaves a session alone while a far task's report is still over there" {
    // `done` ends a remote task's PROCESS, not its delivery: the report waits on
    // that machine until this one fetches it, and the host-side task directory
    // is the only record of where it is owed. Removing it on `done` alone would
    // strand a result — and for a retargeted task, one that a DIFFERENT session
    // is waiting for. So this refusal is not a judgment `--force` may overrule;
    // collecting the report is what turns it into one.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs });
    defer alloc.free(new.stdout);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    const step = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "background");
    defer alloc.free(step.stdout);
    try std.testing.expectEqual(@as(u8, 0), step.code);

    // Watched on that machine's own file system, so nothing here collects the
    // report on the way past.
    const report_rel = try relTaskPath(alloc, id, "t1", "report.txt");
    defer alloc.free(report_rel);
    var tries: usize = 0;
    while (tries < 3600 and !exists(io, far.dir, report_rel)) : (tries += 1) {
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    try std.testing.expect(exists(io, far.dir, report_rel));

    const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
    defer alloc.free(spath);
    {
        const refused = try runCli(alloc, io, ws, &.{ exe, "session", "prune", id, "--force" });
        defer alloc.free(refused.stdout);
        try std.testing.expect(refused.code != 0);
        try ws.access(io, spath, .{});
    }

    // Any reading verb collects it — and then the only thing standing between
    // this session and removal is the deposit it just gained, which IS a
    // judgment.
    const task_name = try std.fmt.allocPrint(alloc, "{s}/t1", .{id});
    defer alloc.free(task_name);
    {
        const collected = try runCli(alloc, io, ws, &.{ exe, "task", "status", task_name });
        defer alloc.free(collected.stdout);
        try std.testing.expectEqual(@as(u8, 0), collected.code);
    }
    {
        const gone = try runCli(alloc, io, ws, &.{ exe, "session", "prune", id, "--force" });
        defer alloc.free(gone.stdout);
        try std.testing.expectEqual(@as(u8, 0), gone.code);
    }
    try std.testing.expectError(error.FileNotFound, ws.access(io, spath, .{}));
}

test "a report present while status still says running is not delivered — only `done` is finished" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    // A real supervisor writes `report.txt` BEFORE it writes `state:"done"`
    // (`cli/task.zig`'s `runShellTask`), so one poll can land in the window
    // between the two writes — a report already there, status still saying
    // whatever it said before. No real peer can be paused inside that window
    // on purpose, so this uses `fake_remote`'s `stalereport` mode, which
    // answers a `task-poll` with exactly that: a WELL-FORMED snapshot whose
    // `report` is non-empty and whose `status` says `running`.
    const spec = try fakeSpec(alloc, "stalereport");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // No task was ever actually started — the fake answers every poll with the
    // same fixed reply regardless of what was asked — so only the local CLAIM
    // needs to exist: the name and its directory, exactly what a real `shell
    // {background:true}` would have made before any command ran over there.
    const task_dir = try std.fmt.allocPrint(alloc, ".nulya/scratch/{s}/tasks/t1", .{id});
    defer alloc.free(task_dir);
    try ws.createDirPath(io, task_dir);

    const listed = try runCli(alloc, io, ws, &.{ exe, "task", "list", "--session", id, "--json" });
    defer alloc.free(listed.stdout);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    // The row says what it actually knows: `status.state` was `running`, and
    // the listing reads that, not `done` — the bug's report-presence shortcut
    // would have made no difference here, which is what made it easy to miss.
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"state\":\"running\"") != null);

    // The bug's whole shape: depositing on report-presence alone would have
    // written this note by now — with `exit_code:1`, read off the
    // stale `running` status, which never carries one — rather than waiting
    // for the real exit code the far side never got to send.
    const deposit = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.inbox/task-{s}-t1.json", .{ id, id });
    defer alloc.free(deposit);
    try std.testing.expect(!exists(io, ws, deposit));

    // And `delivered` must not exist either: writing it here would mean the
    // correct `done` status — if the far side ever got to send it — could
    // never be looked at again, because `pollAndDeliver` skips any task that
    // already has this marker.
    const delivered = try std.fmt.allocPrint(alloc, "{s}/delivered", .{task_dir});
    defer alloc.free(delivered);
    try std.testing.expect(!exists(io, ws, delivered));
}

test "killing a remote task ends the process tree on that machine" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs });
    defer alloc.free(new.stdout);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // Held by a file in the FAR workspace, which is where the command runs. It
    // would announce itself a second time if it ever got past the hold — that
    // second marker never appearing is what makes this about the kill reaching
    // the far process rather than the host giving up on it
    // (`e2e/background.zig`'s hold discipline, one machine further out).
    try far.dir.writeFile(io, .{ .sub_path = "hold", .data = "" });
    const command = switch (try farDialect(alloc, io, ws, exe, spec)) {
        .bash => "while [ -e hold ]; do sleep 0.05; done; touch escaped",
        .powershell => "while (Test-Path 'hold') { Start-Sleep -Milliseconds 50 }; New-Item escaped -ItemType File -Force > $null",
    };
    const run = try runCli(alloc, io, ws, &.{ exe, "task", "run", "--session", id, "--", command });
    defer alloc.free(run.stdout);
    try std.testing.expectEqual(@as(u8, 0), run.code);

    const task_name = try std.fmt.allocPrint(alloc, "{s}/t1", .{id});
    defer alloc.free(task_name);

    // Wait until that machine's supervisor really has it: `task run` returns as
    // soon as the request is accepted, and killing a `starting` task would prove
    // less.
    var tries: usize = 0;
    while (tries < 3600) : (tries += 1) {
        const live = try runCli(alloc, io, ws, &.{ exe, "task", "list", "--session", id, "--running" });
        defer alloc.free(live.stdout);
        if (std.mem.indexOf(u8, live.stdout, "running") != null) break;
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }

    const killed = try runCli(alloc, io, ws, &.{ exe, "task", "kill", task_name });
    defer alloc.free(killed.stdout);
    try std.testing.expectEqual(@as(u8, 0), killed.code);

    const waited = try runCli(alloc, io, ws, &.{ exe, "task", "wait", task_name, "--timeout-ms", wait_budget_ms });
    defer alloc.free(waited.stdout);
    try std.testing.expectEqual(@as(u8, 0), waited.code);
    try std.testing.expect(std.mem.indexOf(u8, waited.stdout, "killed") != null);

    // The hold is still in place, so a process that survived would still be
    // spinning — and it never reached its second step.
    try std.testing.expect(!exists(io, far.dir, "escaped"));
    const status_rel = try relTaskPath(alloc, id, "t1", "status.json");
    defer alloc.free(status_rel);
    const status = try far.dir.readFileAlloc(io, status_rel, alloc, .unlimited);
    defer alloc.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"ended_by\":\"kill\"") != null);
}

test "a supervisor that dies over there reads here as lost, not running" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // A `status.json` left by a supervisor that is no longer there to hold the
    // lease — written directly onto the FAR machine's disk, no `.lock` file
    // beside it, the same shape `cli/task.zig`'s own "lost is a projection"
    // unit test builds for the local case. Reached through `remote serve`'s
    // `task-poll`, this is what `leaseHeldIn` answers `false` for.
    //
    // The row's NAME still has to exist on THIS machine (`readRow`'s callers
    // discover which tasks exist by listing directories under the host's own
    // `.nulya/scratch/`, the same way "a task whose machine will not answer"
    // does above) — only its CONTENT lives over there.
    const dir = try std.fmt.allocPrint(alloc, ".nulya/scratch/{s}/tasks/t1", .{id});
    defer alloc.free(dir);
    try ws.createDirPath(io, dir);
    try far.dir.createDirPath(io, dir);
    const status_rel = try std.fmt.allocPrint(alloc, "{s}/status.json", .{dir});
    defer alloc.free(status_rel);
    try far.dir.writeFile(io, .{ .sub_path = status_rel, .data =
        \\{"v":1,"task":"S/t1","session":"S","command":"sleep 30","cwd":".","started":"2026-08-19T10:00:00Z","state":"running"}
        \\
    });

    const listed = try runCli(alloc, io, ws, &.{ exe, "task", "list", "--session", id, "--json" });
    defer alloc.free(listed.stdout);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    // Not "running" — a status this old with no supervisor holding its lease
    // used to read as running forever, so a `wait` on it could only ever end by
    // timing out — and not "unreachable": the machine DID answer, it is just
    // reporting a task nobody is watching any more. `lease_held` traveled in
    // the SAME poll as `status`, at no extra cost in round trips.
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"state\":\"lost\"") != null);
}

test "a real read fault on that machine's status file is a refusal, not an empty starting task" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // `status.json` is a DIRECTORY over there rather than a file — a read fault
    // (`error.IsDir`) that has nothing to do with "not written yet". Before this
    // fix `readTaskFile`'s blanket `catch ""` made that indistinguishable from a
    // fresh task, and the host read it as `starting` forever.
    const dir = try std.fmt.allocPrint(alloc, ".nulya/scratch/{s}/tasks/t1", .{id});
    defer alloc.free(dir);
    try ws.createDirPath(io, dir);
    const status_rel = try std.fmt.allocPrint(alloc, "{s}/status.json", .{dir});
    defer alloc.free(status_rel);
    try far.dir.createDirPath(io, status_rel);

    const listed = try runCli(alloc, io, ws, &.{ exe, "task", "list", "--session", id, "--json" });
    defer alloc.free(listed.stdout);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    // Not "starting": that machine answered, and what it answered was a fault
    // reading the file, not silence. `unreachable` is the honest word for "this
    // host could not get an answer" — the same word a channel that never opened
    // reports, for the same reason: nothing here may guess.
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"state\":\"unreachable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"state\":\"starting\"") == null);
}

test "a real read fault on that machine's lease is a refusal, not a confident lost" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // A `status.json` that says "running" — so `serveTaskPoll` actually probes
    // the lease instead of answering `null` for a statusless task — paired
    // with a `.lock` that is a DIRECTORY over there, not a missing or held
    // file. Before this fix, `leaseHeldIn`'s blanket `else => false` made an
    // unreadable lease indistinguishable from an unheld one, and the task
    // read as `lost` — a dead supervisor's shape — when what actually
    // happened is that machine could not answer the question at all.
    const dir = try std.fmt.allocPrint(alloc, ".nulya/scratch/{s}/tasks/t1", .{id});
    defer alloc.free(dir);
    try ws.createDirPath(io, dir);
    try far.dir.createDirPath(io, dir);
    const status_rel = try std.fmt.allocPrint(alloc, "{s}/status.json", .{dir});
    defer alloc.free(status_rel);
    try far.dir.writeFile(io, .{ .sub_path = status_rel, .data =
        \\{"v":1,"task":"S/t1","session":"S","command":"sleep 30","cwd":".","started":"2026-08-19T10:00:00Z","state":"running"}
        \\
    });
    const lock_rel = try std.fmt.allocPrint(alloc, "{s}/.lock", .{dir});
    defer alloc.free(lock_rel);
    try far.dir.createDirPath(io, lock_rel);

    const listed = try runCli(alloc, io, ws, &.{ exe, "task", "list", "--session", id, "--json" });
    defer alloc.free(listed.stdout);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"state\":\"unreachable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"state\":\"lost\"") == null);
}

test "a task whose machine will not answer reads as unreachable, not as lost or done" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const reachable = try execSpec(alloc, exe, "");
    defer alloc.free(reachable);
    const nowhere = try std.fmt.allocPrint(alloc, "{s}-does-not-exist", .{reachable});
    defer alloc.free(nowhere);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", nowhere });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // The directory a claim leaves on this machine, and nothing else: the name
    // is here, everything about the task is over there — and there is no there.
    const dir = try std.fmt.allocPrint(alloc, ".nulya/scratch/{s}/tasks/t1", .{id});
    defer alloc.free(dir);
    try ws.createDirPath(io, dir);

    const listed = try runCli(alloc, io, ws, &.{ exe, "task", "list", "--session", id, "--json" });
    defer alloc.free(listed.stdout);
    // Three words that must not be confused: nothing is known about this task,
    // which is not "its supervisor died" and not "it finished".
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"state\":\"unreachable\"") != null);

    // And a wait on it ends instead of hanging: this host cannot be told when it
    // finishes, so saying so is the answer (`lost`'s reasoning, one machine out).
    const task_name = try std.fmt.allocPrint(alloc, "{s}/t1", .{id});
    defer alloc.free(task_name);
    const err = try runCliStderr(alloc, io, ws, &.{ exe, "task", "wait", task_name, "--timeout-ms", "5000" }, &.{});
    defer alloc.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "did not answer") != null);
}

test "a step collects the reports of the tasks that report INTO it, not only the ones it started" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    const spec = try execSpec(alloc, exe, "");
    defer alloc.free(spec);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var far = std.testing.tmpDir(.{});
    defer far.cleanup();
    var far_buf: [std.fs.max_path_bytes]u8 = undefined;
    const far_abs = try absOf(io, far.dir, &far_buf);

    // Two sessions on the same machine: the one that STARTS the task, and the
    // one the task is handed to. That is what a compaction leaves behind, and
    // `notify` is readable from outside precisely so the second one can collect.
    var ids: [2][]u8 = undefined;
    for (&ids) |*slot| {
        const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", spec, "--workspace", far_abs });
        defer alloc.free(new.stdout);
        slot.* = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    }
    const owner = ids[0];
    defer alloc.free(owner);
    const reader = ids[1];
    defer alloc.free(reader);

    try far.dir.writeFile(io, .{ .sub_path = "hold", .data = "" });
    const command = switch (try farDialect(alloc, io, ws, exe, spec)) {
        .bash => "while [ -e hold ]; do sleep 0.05; done; echo RETARGET-SURVIVOR",
        .powershell => "while (Test-Path 'hold') { Start-Sleep -Milliseconds 50 }; Write-Output RETARGET-SURVIVOR",
    };
    {
        const run = try runCli(alloc, io, ws, &.{ exe, "task", "run", "--session", owner, "--", command });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
    }
    const task_name = try std.fmt.allocPrint(alloc, "{s}/t1", .{owner});
    defer alloc.free(task_name);

    // Hand it over while it is still HELD: with no report to fetch, the retarget
    // itself cannot have delivered anything, so whatever arrives below arrived
    // because the reading session went and got it.
    var tries: usize = 0;
    while (tries < 3600) : (tries += 1) {
        const live = try runCli(alloc, io, ws, &.{ exe, "task", "list", "--session", owner, "--running" });
        defer alloc.free(live.stdout);
        if (std.mem.indexOf(u8, live.stdout, "running") != null) break;
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    {
        const moved = try runCli(alloc, io, ws, &.{ exe, "task", "retarget", task_name, "--to", reader });
        defer alloc.free(moved.stdout);
        try std.testing.expectEqual(@as(u8, 0), moved.code);
    }

    try far.dir.deleteFile(io, "hold");
    const report_rel = try relTaskPath(alloc, owner, "t1", "report.txt");
    defer alloc.free(report_rel);
    tries = 0;
    while (tries < 3600 and !exists(io, far.dir, report_rel)) : (tries += 1) {
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    try std.testing.expect(exists(io, far.dir, report_rel));

    // Nothing has been deposited here: no `task` verb has run since the report
    // appeared, and the far supervisor cannot reach this machine's inboxes.
    const deposit = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.inbox/task-{s}-t1.json", .{ reader, owner });
    defer alloc.free(deposit);
    try std.testing.expect(!exists(io, ws, deposit));

    // The reading session's own step sweeps for it — over the channel it opens
    // anyway, for a task it never started — and the drain at its boundary puts
    // it in front of the model in that same step.
    const step = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", reader, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "finish");
    defer alloc.free(step.stdout);
    try std.testing.expectEqual(@as(u8, 0), step.code);
    try std.testing.expect(std.mem.indexOf(u8, step.stdout, "\"source\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, step.stdout, "RETARGET-SURVIVOR") != null);
}
