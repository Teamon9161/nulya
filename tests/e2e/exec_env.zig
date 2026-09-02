//! `session new --env <spec>`: WHERE a session's `shell` commands run.
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
//! `--env` accepts only `local` and the `remote:…` family (exercised in
//! `remote.zig`), which moves the whole workspace. Two spellings that used to
//! move only the command — `wsl[:<distro>]`, and before that a bare
//! `ssh:<destination>` — are retired: both are refused with a pointer at their
//! `remote:` replacement, whether typed fresh or found frozen in an old header.

const std = @import("std");
const support = @import("support.zig");

const runCli = support.runCli;
const runCliStderr = support.runCliStderr;
const readSessionFile = support.readSessionFile;

test "session new --parent inherits environment and remote_workspace from the frozen header, and --env local forks back to nothing" {
    // `remote:exec:` needs only a non-empty argv word to PARSE — it is never
    // actually spawned here, because `--bare` composes no compiled extension
    // member, and `ExecTargetProbe` only connects when a compiled member is in
    // play. So this pins the header-inheritance property without a real peer.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const parent = try runCli(alloc, io, ws, &.{
        exe,     "session",          "new",         "--profile", "scripted",
        "--env", "remote:exec:true", "--workspace", "/x",        "--bare",
    });
    defer alloc.free(parent.stdout);
    try std.testing.expectEqual(@as(u8, 0), parent.code);
    const parent_id = try alloc.dupe(u8, std.mem.trim(u8, parent.stdout, " \r\n"));
    defer alloc.free(parent_id);

    const parent_header = try readSessionFile(alloc, io, ws, parent_id);
    defer alloc.free(parent_header);
    try std.testing.expect(std.mem.indexOf(u8, parent_header, "\"environment\":\"remote:exec:true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent_header, "\"remote_workspace\":\"/x\"") != null);

    const parent_ref = try std.fmt.allocPrint(alloc, "{s}:0", .{parent_id});
    defer alloc.free(parent_ref);

    // ① No `--env` at all on the fork: both columns carry over from the
    // parent's own frozen header, not from today's (absent) flags.
    {
        const fork = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--parent", parent_ref });
        defer alloc.free(fork.stdout);
        try std.testing.expectEqual(@as(u8, 0), fork.code);
        const id = try alloc.dupe(u8, std.mem.trim(u8, fork.stdout, " \r\n"));
        defer alloc.free(id);

        const header = try readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"environment\":\"remote:exec:true\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"remote_workspace\":\"/x\"") != null);
    }

    // ② `--env local` IS naming `--env` (it just normalizes to `""`), so the
    // parent's two columns play no part at all — a fork that explicitly asks
    // for a local machine gets a local machine, with no workspace column.
    {
        const fork = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--parent", parent_ref, "--env", "local" });
        defer alloc.free(fork.stdout);
        try std.testing.expectEqual(@as(u8, 0), fork.code);
        const id = try alloc.dupe(u8, std.mem.trim(u8, fork.stdout, " \r\n"));
        defer alloc.free(id);

        const header = try readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"environment\":\"\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"remote_workspace\":\"\"") != null);
    }
}

/// How many session files exist right now — whether an inherited-`--env`
/// refusal left a fork behind (`session.zig`'s own `countSessions` twin; not
/// shared because it is three lines and the two files do not otherwise import
/// each other).
fn countSessions(io: std.Io, ws: std.Io.Dir) !usize {
    var dir = ws.openDir(io, ".nulya/sessions", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".jsonl")) n += 1;
    }
    return n;
}

/// A header frozen with `environment`, built directly on disk rather than
/// through the CLI — the only way a retired exec-target spelling reaches this
/// binary at all, since `session new --env` refuses it outright.
fn writeLegacyHeader(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, session: []const u8, environment_spec: []const u8) !void {
    try ws.createDirPath(io, ".nulya/sessions");
    const header = try support.ledger.encodeHeaderLine(alloc, .{
        .session = session,
        .environment = environment_spec,
    });
    defer alloc.free(header);
    const path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{session});
    defer alloc.free(path);
    try ws.writeFile(io, .{ .sub_path = path, .data = header });
}

test "session new --parent: an inherited legacy ssh: environment is refused with a pointer at remote:ssh:, and names the parent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    try writeLegacyHeader(alloc, io, ws, "s-legacy", "ssh:box.example");

    const before = try countSessions(io, ws);
    const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--parent", "s-legacy:0" }, &.{});
    defer alloc.free(err);
    // The specific pointer (not the generic "unrecognized" message), and the
    // fact that this value came from the parent rather than an `--env` on this
    // command line — the whole point of the contract's "拒绝文案要说清这个值
    // 来自父场" requirement.
    try std.testing.expect(std.mem.indexOf(u8, err, "remote:ssh:") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "s-legacy") != null);
    // Only the pre-existing parent file — the fork was refused, not created.
    try std.testing.expectEqual(@as(usize, 1), before);
    try std.testing.expectEqual(before, try countSessions(io, ws));
}

test "session new --parent: an inherited legacy wsl environment is refused with a pointer at remote:wsl, and names the parent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    try writeLegacyHeader(alloc, io, ws, "s-legacy-wsl", "wsl:Ubuntu");

    const before = try countSessions(io, ws);
    const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--parent", "s-legacy-wsl:0" }, &.{});
    defer alloc.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "remote:wsl") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "s-legacy-wsl") != null);
    try std.testing.expectEqual(@as(usize, 1), before);
    try std.testing.expectEqual(before, try countSessions(io, ws));
}

fn nulyaExe(alloc: std.mem.Allocator) ![]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    return std.fs.path.resolve(alloc, &.{rel});
}

test "session new --env: a bad spec creates nothing, a retired spelling points at its replacement, and local is frozen as absence" {
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
        const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "podman:x" }, &.{});
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "--env") != null);
        try std.testing.expect(std.mem.indexOf(u8, err, "remote:") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/sessions", .{}));
    }

    // ①b The retired `ssh:<destination>` exec-target spelling is refused with a
    // SPECIFIC pointer at its replacement — not just folded into the generic
    // "unrecognized" message above.
    {
        const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "ssh:nobody@e2e.invalid" }, &.{});
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "remote:ssh:") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/sessions", .{}));
    }

    // ①c The retired `wsl`/`wsl:<distro>` exec-target spelling gets the same
    // treatment, on every host — neither needs Windows any more, since both are
    // flat refusals rather than an attempt to reach anything.
    {
        const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "wsl" }, &.{});
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "remote:wsl") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/sessions", .{}));
    }
    {
        const err = try runCliStderr(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted", "--env", "wsl:Ubuntu" }, &.{});
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "remote:wsl") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/sessions", .{}));
    }

    // ② `--env local` is the same session as no `--env` at all, so it freezes
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
}

test "session step: a session frozen onto a retired wsl exec target refuses loudly, never falls back to this host" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    try writeLegacyHeader(alloc, io, ws, "s-wsl-legacy", "wsl:e2e-nonexistent-distro-nulya-test");

    // The property this whole axis exists for: a session frozen onto a target
    // this binary no longer moves commands to must NEVER run them here instead
    // — that would look like success in every other way. `step` refuses before
    // touching the model or the tool at all, and names the replacement — on
    // stdout now, as the line protocol's own `run error` line (§14).
    const run = try runCli(alloc, io, ws, &.{ exe, "session", "step", "s-wsl-legacy", "--max-steps", "1" });
    defer alloc.free(run.stdout);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "remote:wsl") != null);
}
