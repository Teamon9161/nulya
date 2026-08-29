//! `--env remote:…`: the workspace lives on another machine (DESIGN §8.1,
//! goals/remote-env.md Phase 1).
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
//!   7. what is NOT moved yet says so: extension tools and background tasks
//!      refuse, in sentences, rather than silently touching this machine.

const std = @import("std");
const builtin = @import("builtin");
const support = @import("support.zig");

const remote = support.remote;
const environment = support.environment;
const emit = support.emit;

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

// ── what is not moved yet ───────────────────────────────────────────────────

test "extension tools and background tasks refuse in a remote session, in sentences" {
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

    // An extension call is answered as a FAILED CALL, so the sentence reaches
    // the model through the path every failed extension call already uses —
    // rather than as a host error, which would fail the whole step.
    const ext = try renv.environment().runExtension(alloc, .{
        .entry_path = "bin/whatever",
        .cwd = ".",
        .request_json = "{}",
        .max_output_bytes = 1 << 20,
    });
    defer ext.deinit(alloc);
    try std.testing.expect(ext.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, ext.stderr, "harness") != null);

    // A background task has no supervisor over there yet, and says so as its
    // own error so `tools/shell.zig` can turn it into the model's sentence.
    try std.testing.expectError(
        error.RemoteBackgroundUnsupported,
        renv.environment().startShellTask(alloc, .{ .command = "echo hi", .cwd = "." }),
    );
}

test "nulya task run refuses a remote session rather than running the command here" {
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

    const err = try runCliStderr(alloc, io, ws, &.{ exe, "task", "run", "--session", id, "--", "echo nope" }, &.{});
    defer alloc.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "background tasks run where the harness runs") != null);
    // Nothing was started: no task directory for this session.
    try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/scratch", .{}));
}
