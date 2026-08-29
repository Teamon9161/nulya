//! `session new --env <spec>`: WHERE a session's `shell` commands run
//! (DESIGN §8).
//!
//! Three things are pinned here, and only these three, because they are the
//! ones a mistake would make invisible:
//!
//!   1. a spec that does not parse, or one this host cannot reach, is refused
//!      BEFORE a session file exists — the `--prompt` / missing-credential
//!      discipline;
//!   2. the accepted spec is FROZEN in the header and read back from there, so
//!      the answer is the session's rather than today's command line;
//!   3. a session frozen onto a target NEVER falls back to running its command
//!      on this host. That is the whole safety property of the feature.
//!
//! `wsl` is the only non-local exec target left (`ssh:<destination>` was
//! retired 2026-08-30, goals/remote-env.md §7.1 — `--env remote:ssh:<dest>`
//! moves the whole workspace instead, and is exercised in `remote.zig`), and
//! `execTargetSupportedOnHost` accepts any `wsl:<distro>` spelling on Windows
//! whether or not that distro actually exists — so property 3 is pinned with a
//! distro name that does not, WITHOUT needing an actual reachable distribution:
//! `wsl.exe` itself reports the failure, and that is not this host running the
//! command. That needs Windows to freeze at all, so it is gated accordingly;
//! actually reaching a REAL distribution is a separate smoke test that skips
//! when there is no WSL to reach (the `zig build integration` discipline: a
//! machine without the thing does not go red over it).

const std = @import("std");
const builtin = @import("builtin");
const support = @import("support.zig");

const runCli = support.runCli;
const runCliEnv = support.runCliEnv;
const runCliEnvs = support.runCliEnvs;
const runCliStderr = support.runCliStderr;
const readSessionFile = support.readSessionFile;

/// The text `NULYA_SCRIPTED_MODE=finish`'s one `shell` call prints when it runs
/// on THIS host (`launch.ScriptedProvider`). Spelled out rather than imported
/// for the same reason the stand-in spells out its own markers: the e2e binary
/// is checking observable output, not sharing a constant.
const local_marker = "hello-from-nulya";

/// The `tool_results` event out of a `session step`'s JSONL, which is where a
/// command's OUTPUT is — the assistant event above it merely quotes the command,
/// marker and all, so searching the whole stream would answer a different
/// question than "did this run".
fn toolResultsLine(stdout: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"kind\":\"tool_results\"") != null) return line;
    }
    return null;
}

fn nulyaExe(alloc: std.mem.Allocator) ![]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    return std.fs.path.resolve(alloc, &.{rel});
}

test "session new --env: a bad spec creates nothing, a good one is frozen, and the listing projects it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // ① A spec nothing recognizes. The message has to carry the vocabulary —
    // there is no other place to learn it — and nothing may be left behind.
    {
        const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "wsl2" }, &.{});
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "--env") != null);
        try std.testing.expect(std.mem.indexOf(u8, err, "wsl:<distro>") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/sessions", .{}));
    }

    // ①b The retired `ssh:<destination>` exec-target spelling is refused with a
    // SPECIFIC pointer at its replacement (goals/remote-env.md §7.1) — not just
    // folded into the generic "unrecognized" message above.
    {
        const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "ssh:nobody@e2e.invalid" }, &.{});
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "remote:ssh:") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/sessions", .{}));
    }

    // ② A syntactically fine target this host cannot reach is refused too, and
    // says something different: a typo and the wrong machine are not one problem.
    if (builtin.os.tag != .windows) {
        const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "wsl" }, &.{});
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "this host") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/sessions", .{}));
    }

    // ③ `--env local` is the same session as no `--env` at all, so it freezes
    // the same way — a header that says `"environment":"local"` would make two
    // spellings of one fact.
    {
        const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "local" });
        defer alloc.free(new.stdout);
        try std.testing.expectEqual(@as(u8, 0), new.code);
        const id = std.mem.trim(u8, new.stdout, " \r\n");
        const header = try readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"environment\":\"\"") != null);
    }

    // ④ A real (non-local) spec is frozen verbatim and reported by the
    // read-only projection. `wsl` is the only such spec left, and
    // `execTargetSupportedOnHost` accepts any distro NAME on Windows without
    // checking it exists — so this needs only Windows, not an actual WSL
    // install, and a name nothing will ever really register keeps it from
    // accidentally matching a real distribution on the machine running this.
    if (builtin.os.tag == .windows) {
        const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "wsl:e2e-nonexistent-distro-nulya-test" });
        defer alloc.free(new.stdout);
        try std.testing.expectEqual(@as(u8, 0), new.code);
        const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
        defer alloc.free(id);

        const header = try readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"environment\":\"wsl:e2e-nonexistent-distro-nulya-test\"") != null);

        const listed = try runCli(alloc, io, ws, &.{ exe, "session", "list", "--json" });
        defer alloc.free(listed.stdout);
        try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "\"environment\":\"wsl:e2e-nonexistent-distro-nulya-test\"") != null);
    }
}

test "session step: a session frozen onto an unreachable target never runs its command on this host" {
    // `wsl` is the only non-local exec target left, and it needs Windows to
    // freeze at all — see the doc comment at the top of this file for why a
    // nonexistent distro NAME is enough to pin this property without an
    // actual reachable distribution.
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Two sessions, the same scripted model, the same one `shell` call. The
    // only difference is where the command was frozen to run.
    const here = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted" });
    defer alloc.free(here.stdout);
    const here_id = try alloc.dupe(u8, std.mem.trim(u8, here.stdout, " \r\n"));
    defer alloc.free(here_id);

    const away = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "wsl:e2e-nonexistent-distro-nulya-test" });
    defer alloc.free(away.stdout);
    const away_id = try alloc.dupe(u8, std.mem.trim(u8, away.stdout, " \r\n"));
    defer alloc.free(away_id);

    // The control: on this host the command runs and its output is in the
    // transcript. Without this line the assertion below would also pass if the
    // scripted model had simply stopped calling `shell`.
    {
        const step = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", here_id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "finish");
        defer alloc.free(step.stdout);
        const results = toolResultsLine(step.stdout) orelse return error.NoToolResults;
        try std.testing.expect(std.mem.indexOf(u8, results, local_marker) != null);
    }

    // The property: whatever happened — `wsl.exe` reporting no such
    // distribution, or missing entirely — the one thing that must NOT have
    // happened is the command running here. A silent fallback to the host is
    // the failure this whole axis exists to prevent, and it would look like
    // success in every other way.
    {
        const step = try runCliEnv(alloc, io, ws, &.{ exe, "session", "step", away_id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "finish");
        defer alloc.free(step.stdout);
        const results = toolResultsLine(step.stdout) orelse return error.NoToolResults;
        try std.testing.expect(std.mem.indexOf(u8, results, local_marker) == null);
    }
}

/// Whether this machine can actually enter a WSL distribution. Cheap and
/// conclusive: run the smallest possible command in one.
fn wslAvailable(alloc: std.mem.Allocator, io: std.Io) bool {
    if (builtin.os.tag != .windows) return false;
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "wsl.exe", "-e", "true" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

test "a wsl session runs its command inside the distribution, from the workspace as the distribution sees it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    if (!wslAvailable(alloc, io)) return error.SkipZigTest;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "wsl" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // `task run` rather than a step: it is the one verb that takes an ARBITRARY
    // command and still belongs to a session, so it asks the two questions a
    // fixed scripted command cannot — which kernel read this, and from where —
    // while going through the whole real path (the header's spec, the
    // supervisor's `--env`, `shellArgv`'s wrapping).
    const started = try runCli(alloc, io, ws, &.{ exe, "task", "run", "--session", id, "--", "uname -s; pwd" });
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, started.stdout, " \r\n"), '\n');
    const task_id = try alloc.dupe(u8, std.mem.trim(u8, lines.next() orelse "", " \r\n"));
    defer alloc.free(task_id);
    const log_line = std.mem.trim(u8, lines.next() orelse "", " \r\n");
    const log_path = try alloc.dupe(u8, std.mem.trimStart(u8, log_line["log:".len..], " "));
    defer alloc.free(log_path);

    const waited = try runCli(alloc, io, ws, &.{ exe, "task", "wait", task_id, "--timeout-ms", "60000" });
    defer alloc.free(waited.stdout);

    const log = try ws.readFileAlloc(io, log_path, alloc, .unlimited);
    defer alloc.free(log);
    // A Linux kernel answered `uname`, and `pwd` is the workspace under `/mnt`:
    // between them, the command neither ran on the host nor started in the
    // distribution's home directory.
    try std.testing.expect(std.mem.indexOf(u8, log, "Linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "/mnt/") != null);
}
