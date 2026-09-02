//! `nulya remote …` — the two ends of the remote channel.
//!
//! `serve` is the FAR side: this same binary in a shell role, as
//! `nulya task supervise` is. It reads frames on stdin, runs the commands they
//! ask for through the ordinary `LocalEnvironment`, and writes the results back
//! on stdout — which is why the remote side gets a real process-tree kill, a
//! real secret denylist and a real wall-clock budget with no second
//! implementation of any of them.
//!
//! `check` and `ls` are the HOST side: can I reach that machine, and what is on
//! it. `ls` is a protocol verb rather than a parsed `ls -1p` because a file name
//! may contain a newline and a browser needs the kind anyway.
//!
//! **stdout on the serving side is the channel.** Nothing here may print to it
//! except frames; every diagnostic goes to stderr.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const emit = @import("../emit.zig");
const environment = @import("../environment.zig");
const remote = @import("../environment/remote/mod.zig");
const protocol = @import("../environment/remote/protocol.zig");
const integrity = @import("../extension/integrity.zig");
const ext_manifest = @import("../extension/manifest.zig");
const ext_store = @import("../extension/store.zig");
const launch = @import("../launch.zig");
const common = @import("common.zig");
/// The task layout and the supervisor's own flags, borrowed rather than
/// re-derived: `cli/task.zig` owns what a task's directory is called and what
/// files are in it, on whichever machine that directory happens to be.
const task_cli = @import("task.zig");

const flagValue = common.flagValue;
const printErr = common.printErr;
const printErrFmt = common.printErrFmt;
const printOut = common.printOut;
const printRaw = common.printRaw;

/// How many directory entries one `list-dir` reply carries. The entries travel
/// as PAYLOAD (protocol rule 6), so this is not about frame size — it keeps one
/// answer a size a person or a browser can use. Truncation is SAID, never
/// silent.
const max_entries: usize = 1000;
const remote_password_buffer_bytes = 4097;

pub fn dispatchRemote(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return common.usageSection(io, common.remote_usage);
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "serve")) return remoteServe(alloc, io, rest);
    if (std.mem.eql(u8, sub, "check")) return remoteCheck(alloc, io, rest);
    if (std.mem.eql(u8, sub, "ls")) return remoteLs(alloc, io, rest);
    try printErr(io, "unknown `remote` subcommand; try serve|check|ls\n");
    return 1;
}

// ── the host side ───────────────────────────────────────────────────────────

/// Open a channel from a `--env` spec, or print why not. Shared by `check` and
/// `ls` so the two cannot disagree about what a bad spec means.
fn open(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !?remote.Channel {
    const spec = flagValue(args, "--env") orelse {
        try printErrFmt(alloc, io, "--env is required ({s})\n", .{remote.spec_syntax});
        return null;
    };
    const l = remote.parseSpec(spec) catch {
        try printErrFmt(alloc, io, "--env {s}: unrecognized (want {s})\n", .{ spec, remote.spec_syntax });
        return null;
    };
    var in_buf: [remote_password_buffer_bytes]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const password = if (common.sliceHasFlag(args, "--ssh-password-stdin"))
        remote.readSshPassword(alloc, &stdin.interface) catch |err| {
            try printErrFmt(alloc, io, "--ssh-password-stdin: {s}\n", .{@errorName(err)});
            return null;
        }
    else
        null;
    defer if (password) |secret| {
        std.crypto.secureZero(u8, secret);
        alloc.free(secret);
    };
    return remote.Channel.connectPassword(alloc, io, l, launch.version, .default, password) catch |err| {
        // The transport already wrote its own diagnostic to this process's
        // stderr (it inherits it), so this adds the one thing that is missing:
        // which spec produced it, and in the version case what to do.
        switch (err) {
            error.RemoteVersionMismatch => try printErrFmt(alloc, io, "{s}: the nulya there speaks a different remote protocol; install a matching build on that machine\n", .{spec}),
            error.RemoteSpecUnsupportedOnHost => try printErrFmt(alloc, io, "{s}: cannot be reached from this host (wsl needs Windows)\n", .{spec}),
            else => try printErrFmt(alloc, io, "{s}: could not open a channel ({s})\n", .{ spec, @errorName(err) }),
        }
        return null;
    };
}

fn remoteCheck(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var ch = (try open(alloc, io, args)) orelse return 1;
    defer ch.deinit();
    const h = ch.hello;

    if (common.sliceHasFlag(args, "--json")) {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(h, .{}, &out.writer);
        try printOut(alloc, io, "{s}\n", .{out.written()});
        return 0;
    }
    try printOut(alloc, io, "nulya {s} on {s}/{s}\n", .{ h.nulya, h.os, h.arch });
    try printOut(alloc, io, "cwd {s}\n", .{h.cwd});
    if (h.home.len != 0) try printOut(alloc, io, "home {s}\n", .{h.home});
    try printOut(alloc, io, "shell {s}\n", .{h.dialect});
    return 0;
}

fn remoteLs(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var ch = (try open(alloc, io, args)) orelse return 1;
    defer ch.deinit();

    // The first non-flag word, so `nulya remote ls --env X /srv/app` reads the
    // way every other listing verb does. No path = the agent's own directory.
    var path: []const u8 = ".";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--env")) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--")) continue;
        path = args[i];
        break;
    }

    const rep = ch.controlRound(.{ .op = protocol.Op.list_dir.wire(), .path = path }, "") catch |err| {
        try printErrFmt(alloc, io, "could not list '{s}': {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    if (!rep.ok) {
        try printErrFmt(alloc, io, "{s}\n", .{rep.message});
        return 1;
    }
    // The listing rode in as payload; it borrows the channel arena, which stays
    // valid until the next round — and there is none, this verb asks once.
    const entries = protocol.parseEntries(ch.arena.allocator(), ch.last_payload) catch {
        try printErrFmt(alloc, io, "could not read the listing of '{s}'\n", .{path});
        return 1;
    };

    if (common.sliceHasFlag(args, "--json")) {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(entries, .{}, &out.writer);
        try printOut(alloc, io, "{s}\n", .{out.written()});
    } else {
        for (entries) |e| {
            try printOut(alloc, io, "{s}{s}\n", .{ e.name, if (e.dir) "/" else "" });
        }
    }
    // A note on an answered request is not a refusal, so it goes to stderr and
    // the exit code stays 0: the listing above is real, just not all of it.
    if (rep.message.len != 0) try printErrFmt(alloc, io, "{s}\n", .{rep.message});
    return 0;
}

// ── the far side ────────────────────────────────────────────────────────────

/// Everything one served channel needs. The reader is shared by the main loop
/// and the mid-command control watch, which is safe precisely because of
/// protocol rule 2: those two phases never overlap.
const Agent = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    read_buf: []u8,
    reader: std.Io.File.Reader,
    arena: std.heap.ArenaAllocator,
    lenv: *environment.LocalEnvironment,
    /// The one extension version currently being pushed into this machine's
    /// store, if any (`store-stat` opens it, `store-commit` closes it). One,
    /// because the channel is one request at a time (protocol rule 1).
    push: ?StagedPush = null,
    /// Set when the host closed the channel: the loop stops, and whatever was
    /// running has already been killed.
    stop: bool = false,

    fn reply(self: *Agent, rep: protocol.Reply, first: []const u8, second: []const u8) !void {
        const line = try protocol.encodeReply(self.alloc, rep);
        defer self.alloc.free(line);
        const out = std.Io.File.stdout();
        try out.writeStreamingAll(self.io, line);
        if (first.len != 0) try out.writeStreamingAll(self.io, first);
        if (second.len != 0) try out.writeStreamingAll(self.io, second);
    }

    fn refuse(self: *Agent, message: []const u8) !void {
        try self.reply(.{ .ok = false, .message = message }, "", "");
    }

    /// Refuse with a sentence that has a value in it. The message dies with the
    /// frame, which is exactly how long it is needed.
    fn refuseFmt(self: *Agent, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(msg);
        try self.refuse(msg);
    }
};

/// A version being copied into THIS machine's store, one file per frame.
///
/// Staged rather than written into `versions/<v>` directly: a version directory
/// that exists is one other processes will compose and run, so it may only
/// appear once these bytes have been checked against their own seal HERE. A channel
/// that dies mid-push leaves a staging directory (cleared by the next push of
/// the same id) and nothing under `versions/`.
///
/// The id's writer lease is held for the whole sequence — the same lease a
/// build or an activate of that id takes (`Store.lease`), so a push and a local
/// build cannot interleave inside one `<id>/`.
const StagedPush = struct {
    root: std.Io.Dir,
    id: []u8,
    version: []u8,
    /// `<id>/.push-<version>` — under `<id>/`, so the lease covers it, and NOT
    /// under `versions/`, where `Store.listVersions` would see it.
    staging_rel: []u8,
    lease: std.Io.File,

    fn versionRel(self: StagedPush, alloc: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.id, "versions", self.version });
    }
};

/// Abandon whatever push is open: remove the staging tree, release the lease.
/// Called on commit, on a second `store-stat`, and when the channel ends — the
/// three ways a push stops being the current one.
fn closePush(agent: *Agent) void {
    var p = agent.push orelse return;
    agent.push = null;
    p.root.deleteTree(agent.io, p.staging_rel) catch {};
    p.lease.close(agent.io);
    p.root.close(agent.io);
    agent.alloc.free(p.id);
    agent.alloc.free(p.version);
    agent.alloc.free(p.staging_rel);
}

fn remoteServe(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    _ = args;
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    // The ordinary local environment of THIS machine. No session ref: an agent
    // runs commands, it does not own a ledger.
    //
    // THIS machine's store, resolved the way every other nulya process on it
    // resolves it: a version that arrived by `ext push` lands here, and the
    // host never names a directory on this machine.
    const ext_store_path = try launch.storePath(alloc, &host);
    defer alloc.free(ext_store_path);
    var lenv = try launch.localEnvironment(alloc, io, &cfg, null, "", ext_store_path);
    defer lenv.deinit();

    const read_buf = try alloc.alloc(u8, protocol.max_header_bytes);
    defer alloc.free(read_buf);
    var agent: Agent = .{
        .alloc = alloc,
        .io = io,
        .read_buf = read_buf,
        .reader = std.Io.File.stdin().readerStreaming(io, read_buf),
        .arena = .init(alloc),
        .lenv = &lenv,
    };
    defer agent.arena.deinit();
    // A channel that ends mid-push leaves no half-installed version and no held
    // lease — the staging tree goes with the connection that was filling it.
    defer closePush(&agent);

    while (!agent.stop) {
        _ = agent.arena.reset(.retain_capacity);
        const line = (agent.reader.interface.takeDelimiter('\n') catch break) orelse break;
        const req = protocol.parseRequest(agent.arena.allocator(), line) catch {
            // Not this protocol any more. Say so once and stop: there is no
            // resynchronising a stream whose framing is unknown.
            try agent.refuse("frame not understood");
            break;
        };
        const payload = try agent.arena.allocator().alloc(u8, req.bytes);
        if (payload.len != 0) agent.reader.interface.readSliceAll(payload) catch break;
        serveOne(&agent, req, payload) catch |err| {
            // A write failure means the host is gone; anything else is this
            // agent's own fault and is worth one line on stderr before exiting.
            if (err != error.Canceled) std.debug.print("nulya remote serve: {s}\n", .{@errorName(err)});
            break;
        };
    }
    return 0;
}

fn serveOne(agent: *Agent, req: protocol.Request, payload: []const u8) !void {
    // The session this belongs to is published to everything spawned from here.
    // Only the IDENTITY exists on this machine — the session file is on the
    // host — which is why it is `NULYA_SESSION_ID` and not `NULYA_SESSION`.
    // Idempotent: one channel serves one session.
    if (req.session.len != 0) {
        const known = agent.lenv.env.get("NULYA_SESSION_ID") orelse "";
        if (!std.mem.eql(u8, known, req.session)) try agent.lenv.env.put("NULYA_SESSION_ID", req.session);
    }
    switch (protocol.Op.parse(req.op)) {
        .hello => try serveHello(agent, req),
        .run_shell => try serveShell(agent, req, payload),
        .list_dir => try serveListDir(agent, req),
        // A cancel with nothing running: the command it was meant for already
        // finished. Acknowledged rather than treated as an error — the race is
        // legitimate and the host is about to close the channel anyway.
        .cancel => try agent.reply(.{ .ok = true }, "", ""),
        .put_file => try servePutFile(agent, req, payload),
        .store_stat => try serveStoreStat(agent, req),
        .store_put => try serveStorePut(agent, req, payload),
        .store_commit => try serveStoreCommit(agent),
        .run_extension => try serveRunExtension(agent, req, payload),
        .start_task => try serveStartTask(agent, req, payload),
        .task_poll => try serveTaskPoll(agent, req),
        .task_kill => try serveTaskKill(agent, req),
        .unknown => try agent.refuse("unknown request; this build understands hello, run-shell, run-extension, put-file, list-dir, start-task, task-poll, task-kill, store-stat, store-put, store-commit and cancel"),
    }
}

fn serveHello(agent: *Agent, req: protocol.Request) !void {
    if (req.v != protocol.version) {
        // Answer with OUR version rather than a refusal: the host's
        // `checkHello` compares and produces the sentence, and a reply that
        // carried no version would make "wrong version" and "broken agent"
        // indistinguishable.
        try agent.reply(.{ .ok = true, .v = protocol.version, .nulya = launch.version }, "", "");
        return;
    }
    var host = try environment.hostEnvironMap(agent.alloc);
    defer host.deinit();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = common.cwdRealPath(agent.io, &cwd_buf) catch "";
    try agent.reply(.{
        .ok = true,
        .v = protocol.version,
        .nulya = launch.version,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .home = host.get("HOME") orelse host.get("USERPROFILE") orelse "",
        .cwd = cwd,
        .dialect = agent.lenv.environment().dialect().label(),
    }, "", "");
}

/// Runs something while watching for a `cancel` frame, so a canceled step on
/// the host actually ends the process HERE.
///
/// One task for both run verbs: a shell command and an extension call are the
/// same thing to this side — a child of this machine's local environment, with
/// the same tree kill, the same budget and the same capture.
const RunTask = struct {
    agent: *Agent,
    req: union(enum) {
        shell: environment.ShellRequest,
        extension: environment.ExtensionRequest,
    },
    out: ?anyerror!Captured = null,

    /// The two outcome types are the same four fields; keeping one shape here
    /// is what lets the reply below be written once.
    const Captured = struct {
        stdout: []u8,
        stderr: []u8,
        exit_code: u8,
        timed_out: bool,

        fn deinit(self: Captured, alloc: std.mem.Allocator) void {
            alloc.free(self.stdout);
            alloc.free(self.stderr);
        }
    };

    fn run(self: *RunTask) void {
        const result = self.round();
        // Canceled leaves `out` null: the local runner has already killed the
        // whole process tree on that path and there is no outcome to report.
        if (result) |_| {} else |err| {
            if (err == error.Canceled) return;
        }
        self.out = result;
    }

    fn round(self: *RunTask) anyerror!Captured {
        const env = self.agent.lenv.environment();
        const alloc = self.agent.alloc;
        switch (self.req) {
            .shell => |r| {
                const o = try env.runShell(alloc, r);
                return .{ .stdout = o.stdout, .stderr = o.stderr, .exit_code = o.exit_code, .timed_out = o.timed_out };
            },
            .extension => |r| {
                const o = try env.runExtension(alloc, r);
                return .{ .stdout = o.stdout, .stderr = o.stderr, .exit_code = o.exit_code, .timed_out = o.timed_out };
            },
        }
    }
};

/// Reads exactly one control frame while a command runs. Per protocol rule 2
/// the host sends `cancel` or nothing, so cancelling this read when the command
/// wins cannot have eaten a partial frame.
const ControlWatch = struct {
    agent: *Agent,
    eof: bool = false,

    fn run(self: *ControlWatch) void {
        const line = self.agent.reader.interface.takeDelimiter('\n') catch {
            self.eof = true;
            return;
        } orelse {
            self.eof = true;
            return;
        };
        // Whatever it says, it means "stop": the only frame allowed here is
        // `cancel`, and a host that broke the rule has desynchronised the
        // channel, which is also a reason to stop.
        _ = line;
    }
};

fn serveShell(agent: *Agent, req: protocol.Request, command: []const u8) !void {
    return serveRun(agent, .{ .shell = .{
        .command = command,
        .cwd = if (req.cwd.len != 0) req.cwd else ".",
        .max_output_bytes = if (req.max_output_bytes != 0) req.max_output_bytes else 1 << 20,
        .timeout_ms = req.timeout_ms,
    } });
}

/// Run one extension tool HERE, against this machine's workspace and store.
///
/// The frame named `(id, version, tool)`; everything else is decided on this
/// side, by the same code a local session goes through: `extension/exec.zig`
/// picks the entry variant for THIS OS and verifies the version against its own
/// seal, and `extension/protocol.zig` derives `NULYA_TOOL` / `NULYA_ARG_<k>`
/// from the arguments in the payload.
///
/// No presentation file: its reader is the front end, on the host.
fn serveRunExtension(agent: *Agent, req: protocol.Request, arguments: []const u8) !void {
    if (req.id.len == 0 or req.version.len == 0 or req.tool.len == 0) {
        try agent.refuse("run-extension needs an extension id, a version and a tool");
        return;
    }
    const cwd = if (req.cwd.len != 0) req.cwd else ".";
    return serveRun(agent, .{ .extension = .{
        .id = req.id,
        .version = req.version,
        .tool = req.tool,
        .cwd = cwd,
        .request_json = if (arguments.len != 0) arguments else "{}",
        .max_output_bytes = if (req.max_output_bytes != 0) req.max_output_bytes else 1 << 20,
        .timeout_ms = req.timeout_ms,
    } });
}

fn serveRun(agent: *Agent, request: @FieldType(RunTask, "req")) !void {
    var task: RunTask = .{ .agent = agent, .req = request };
    var watch: ControlWatch = .{ .agent = agent };

    const Race = union(enum) { command: void, control: void };
    var buf: [2]Race = undefined;
    var sel: std.Io.Select(Race) = .init(agent.io, &buf);
    // Without two units of concurrency the command still runs; what is lost is
    // only the mid-command cancel, and losing the command instead would be a
    // worse trade. Same degradation `waitBounded` takes.
    sel.concurrent(.control, ControlWatch.run, .{&watch}) catch {
        RunTask.run(&task);
        return replyRun(agent, &task);
    };
    sel.concurrent(.command, RunTask.run, .{&task}) catch {
        sel.cancelDiscard();
        RunTask.run(&task);
        return replyRun(agent, &task);
    };
    _ = sel.await() catch {
        sel.cancelDiscard();
        return;
    };
    sel.cancelDiscard(); // cancels and JOINS the loser

    if (task.out != null) return replyRun(agent, &task);

    // The control frame (or EOF) won: cancelling the command task made the
    // local runner kill the whole tree. Answer so the channel stays well formed
    // — no output, because the kill path has none to report and inventing one
    // would be worse than saying there is none.
    agent.stop = watch.eof;
    if (!watch.eof) try agent.reply(.{ .ok = true, .canceled = true, .exit_code = 1 }, "", "");
}

fn replyRun(agent: *Agent, task: *RunTask) !void {
    const settled = task.out orelse {
        try agent.reply(.{ .ok = true, .canceled = true, .exit_code = 1 }, "", "");
        return;
    };
    const outcome = settled catch |err| {
        try agent.refuseFmt("{s}", .{try runFailure(agent, task.req, err)});
        return;
    };
    defer outcome.deinit(agent.alloc);
    try agent.reply(.{
        .ok = true,
        .exit_code = outcome.exit_code,
        .timed_out = outcome.timed_out,
        .bytes = outcome.stdout.len + outcome.stderr.len,
        .out = outcome.stdout.len,
    }, outcome.stdout, outcome.stderr);
}

/// Write one file into this session's workspace on THIS machine.
///
/// The bytes go through `agent.lenv`'s `putWorkspaceFile` — the same function a
/// local session's spill goes through, not a copy of it.
///
/// `path` is workspace-relative and `/`-spelled (it is the string the model
/// will read in the footer); `cwd` is where that workspace is here. They are
/// joined exactly once, and only in this direction — the host never learns a
/// path on this machine.
fn servePutFile(agent: *Agent, req: protocol.Request, payload: []const u8) !void {
    if (req.path.len == 0) {
        try agent.refuse("put-file needs a path");
        return;
    }
    const rel = if (req.cwd.len == 0 or std.mem.eql(u8, req.cwd, "."))
        try agent.alloc.dupe(u8, req.path)
    else
        try std.fs.path.join(agent.alloc, &.{ req.cwd, req.path });
    defer agent.alloc.free(rel);

    agent.lenv.environment().putWorkspaceFile(rel, payload) catch |err| {
        const msg = try std.fmt.allocPrint(agent.alloc, "could not write '{s}': {s}", .{ req.path, @errorName(err) });
        defer agent.alloc.free(msg);
        try agent.refuse(msg);
        return;
    };
    try agent.reply(.{ .ok = true }, "", "");
}

// ── background tasks on this machine ────────────────────────────────────────
//
// A remote session's background task is supervised HERE, by the same
// `nulya task supervise` a local one is, with the log, the status and the lease
// in the far — that is, this — workspace. The host keeps the NAME and the
// delivery, because the ledger the report belongs in is over there.
//
// No path crosses: the frames name `<sid>/t<N>`, and each side turns that into a
// directory with `task_cli.taskDirRel` against its own workspace.

/// Where a task's files are on THIS machine, and the workspace they hang off.
/// Null means the name is not a task name; the caller refuses.
fn taskPaths(agent: *Agent, req: protocol.Request) !?struct { cwd: []const u8, dir: []u8 } {
    const dir = (try task_cli.taskDirRel(agent.alloc, req.task)) orelse return null;
    return .{ .cwd = if (req.cwd.len != 0) req.cwd else ".", .dir = dir };
}

/// Start a supervisor for one background task on this machine.
///
/// It is deliberately detached from this channel: a task outliving the
/// connection that asked for it is the whole point of `background: true`, and
/// the agent exiting must not take it with it (`environment.spawnSupervisor`
/// gives it its own process group / no console, exactly as a host one gets).
fn serveStartTask(agent: *Agent, req: protocol.Request, command: []const u8) !void {
    if (command.len == 0) {
        try agent.refuse("start-task needs a command");
        return;
    }
    const paths = (try taskPaths(agent, req)) orelse {
        try agent.refuse("start-task needs a task named <session>/t<N>");
        return;
    };
    defer agent.alloc.free(paths.dir);

    // The one thing this machine has to know about itself to start one: which
    // binary it is.
    const exe = agent.lenv.env.get("NULYA_EXE") orelse {
        try agent.refuse("the nulya here does not know its own path, so it cannot start a supervisor");
        return;
    };

    var ws = std.Io.Dir.cwd().openDir(agent.io, paths.cwd, .{}) catch |err| {
        try agent.refuseFmt("could not open the workspace '{s}' here: {s}", .{ paths.cwd, @errorName(err) });
        return;
    };
    defer ws.close(agent.io);
    ws.createDirPath(agent.io, paths.dir) catch |err| {
        try agent.refuseFmt("could not make room for the task here: {s}", .{@errorName(err)});
        return;
    };

    environment.spawnSupervisor(agent.alloc, agent.io, &agent.lenv.env, .{
        .exe = exe,
        .dir_rel = paths.dir,
        // No session file on this machine — the report is left beside the log
        // and the host collects it (`cli/task.zig`).
        .task_name = req.task,
        .cwd = paths.cwd,
        .timeout_ms = req.timeout_ms,
        .command = command,
        // The supervisor starts in the workspace, because `--dir` hangs off it.
        .spawn_cwd = paths.cwd,
    }) catch |err| {
        try agent.refuseFmt("could not start a supervisor here: {s}", .{@errorName(err)});
        return;
    };
    try agent.reply(.{ .ok = true }, "", "");
}

/// Everything the host needs to know about one task here, in one round: the
/// status its supervisor wrote, the report it left if it has finished, and
/// whether a supervisor still holds the lease (`cli/task.zig`'s `readRow` turns
/// that into `lost` without a second question).
///
/// A directory with nothing in it is answered as nothing, not as a refusal: that
/// is the same `starting` a local task with no status yet reports, and a
/// supervisor that has not written its first line is exactly that. But a real
/// I/O fault reading either file is refused rather than folded into that same
/// silence — see `readTaskFile`.
fn serveTaskPoll(agent: *Agent, req: protocol.Request) !void {
    const paths = (try taskPaths(agent, req)) orelse {
        try agent.refuse("task-poll needs a task named <session>/t<N>");
        return;
    };
    defer agent.alloc.free(paths.dir);
    const a = agent.arena.allocator();

    var ws = std.Io.Dir.cwd().openDir(agent.io, paths.cwd, .{}) catch |err| {
        try agent.refuseFmt("could not open the workspace '{s}' here: {s}", .{ paths.cwd, @errorName(err) });
        return;
    };
    defer ws.close(agent.io);

    const status = readTaskFile(agent, ws, a, paths.dir, task_cli.status_file, 256 << 10) catch |err| {
        try agent.refuseFmt("could not read {s}'s status here: {s}", .{ req.task, @errorName(err) });
        return;
    };
    const raw_report = readTaskFile(agent, ws, a, paths.dir, task_cli.report_file, 4 << 20) catch |err| {
        try agent.refuseFmt("could not read {s}'s report here: {s}", .{ req.task, @errorName(err) });
        return;
    };
    // The report is already valid UTF-8 when a supervisor writes it
    // (`emit.utf8Lossy` runs over the log tail there); this makes that a
    // checked fact rather than an assumption, since `std.json` writes invalid
    // bytes as an array of numbers instead of a string.
    const cleaned = try emit.utf8Lossy(a, raw_report);
    const report = if (cleaned) |c| c.text else raw_report;

    // Same probe `task list` uses locally (`leaseHeldIn`), just pointed at this
    // agent's already-open workspace handle instead of `std.Io.Dir.cwd()` — one
    // implementation of "is anyone holding this lease" for both machines.
    //
    // ONLY once a status exists, and that guard is safety rather than thrift.
    // The probe takes the lease itself, non-blocking, for the instant it is
    // open; a supervisor whose own acquire lands in that instant is told
    // "another supervisor already owns this" and EXITS, so the task silently
    // never runs. A supervisor writes its first status only after it holds the
    // lease, so requiring one closes that window. Null is honest meanwhile:
    // `readRow` reads a statusless task as `starting`.
    // A real fault reading `.lock` is refused rather than swallowed into "not
    // held": `readRow` turns a refusal into `unreachable`, not `lost`.
    const lease_held: ?bool = if (status.len == 0)
        null
    else
        task_cli.leaseHeldIn(ws, agent.io, agent.alloc, paths.dir) catch |err| {
            try agent.refuseFmt("could not read {s}'s lease here: {s}", .{ req.task, @errorName(err) });
            return;
        };

    const body = try protocol.encodeTaskSnapshot(a, .{ .status = status, .report = report, .lease_held = lease_held });
    try agent.reply(.{ .ok = true, .bytes = body.len }, body, "");
}

/// Read one task file here, `arena`-owned. `error.FileNotFound` answers empty —
/// the same "nothing written yet" a directory with no status reports locally —
/// but every other failure (permission denied, a read past `cap`) propagates:
/// those are this machine unable to answer, and an I/O fault must not read as a
/// confident "starting". The caller decides what to say about it.
fn readTaskFile(
    agent: *Agent,
    ws: std.Io.Dir,
    arena: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    cap: usize,
) ![]const u8 {
    const path = try std.fs.path.join(agent.alloc, &.{ dir, name });
    defer agent.alloc.free(path);
    return ws.readFileAlloc(agent.io, path, arena, .limited(cap)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
}

/// Put the kill marker down beside the command, which is here. Refused when
/// there is no such task on this machine: a marker written into nothing would
/// be a request nobody will ever read, reported as success.
fn serveTaskKill(agent: *Agent, req: protocol.Request) !void {
    const paths = (try taskPaths(agent, req)) orelse {
        try agent.refuse("task-kill needs a task named <session>/t<N>");
        return;
    };
    defer agent.alloc.free(paths.dir);

    var ws = std.Io.Dir.cwd().openDir(agent.io, paths.cwd, .{}) catch |err| {
        try agent.refuseFmt("could not open the workspace '{s}' here: {s}", .{ paths.cwd, @errorName(err) });
        return;
    };
    defer ws.close(agent.io);
    ws.access(agent.io, paths.dir, .{}) catch {
        try agent.refuseFmt("this machine has no task {s}", .{req.task});
        return;
    };

    const path = try std.fs.path.join(agent.alloc, &.{ paths.dir, task_cli.kill_file });
    defer agent.alloc.free(path);
    ws.writeFile(agent.io, .{ .sub_path = path, .data = "" }) catch |err| {
        try agent.refuseFmt("could not ask task {s} to stop: {s}", .{ req.task, @errorName(err) });
        return;
    };
    try agent.reply(.{ .ok = true }, "", "");
}

// ── receiving an extension version (`nulya ext push`) ───────────────────────
//
// The far side of a push is thin: open a staging directory, take bytes, then
// ask `integrity.validateVersionDir` — the same function activation, `ext run`
// and a donor copy ask — whether what arrived is that version.

/// Where a pushed version lands: this machine's store, which is the only place
/// version bytes live here. Not a choice the host gets to make — the host
/// resolving a path over here would be the host modelling another machine's
/// file system.
fn openUserStore(agent: *Agent) !?std.Io.Dir {
    const spec = try common.storePath(agent.alloc);
    defer agent.alloc.free(spec);
    if (spec.len == 0) return null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try common.cwdRealPath(agent.io, &cwd_buf);
    return try ext_store.openOrCreateRoot(agent.io, cwd, spec);
}

/// A version-relative path this agent is willing to write, or null.
///
/// The ordinary rule that a directory being filled from a stream may only grow
/// inwards: a `..` or an absolute path would put bytes outside the staging
/// tree, where nothing would ever validate them.
fn safeVersionRel(path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (std.fs.path.isAbsolute(path)) return null;
    var it = std.mem.splitAny(u8, path, "/\\");
    var parts: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
        // A drive-relative spelling (`C:foo`) is absolute on one platform and a
        // legal file name on another; neither belongs in a frozen version.
        if (std.mem.indexOfScalar(u8, part, ':') != null) return null;
        parts += 1;
    }
    return if (parts == 0) null else path;
}

fn serveStoreStat(agent: *Agent, req: protocol.Request) !void {
    if (!ext_manifest.isValidId(req.id) or !integrity.isVersionId(req.version)) {
        try agent.refuse("store-stat needs an extension id and a v-<hash> version");
        return;
    }
    // Whatever was being pushed before is abandoned: one channel, one push.
    closePush(agent);

    var root = (try openUserStore(agent)) orelse {
        try agent.refuse("this machine has no home directory, so it has no user extension store to push into");
        return;
    };
    var keep_root = false;
    defer if (!keep_root) root.close(agent.io);

    // `.sealed`, not `.structural`: "already there" has to mean the bytes are
    // still the ones this id names, otherwise a corrupted copy would refuse
    // every future push of the version that would have repaired it.
    if (ext_store.Store.init(agent.io, root).versionExists(agent.alloc, req.id, req.version, .sealed)) {
        try agent.reply(.{ .ok = true, .held = true }, "", "");
        return;
    }

    const id = try agent.alloc.dupe(u8, req.id);
    errdefer agent.alloc.free(id);
    const version = try agent.alloc.dupe(u8, req.version);
    errdefer agent.alloc.free(version);
    const staging_rel = try std.fmt.allocPrint(agent.alloc, "{s}{c}.push-{s}", .{ id, std.fs.path.sep, version });
    errdefer agent.alloc.free(staging_rel);

    var lease = ext_store.Store.init(agent.io, root).lease(agent.alloc, req.id) catch {
        try agent.refuse("could not take the writer lease for that extension here");
        return;
    };
    errdefer lease.close(agent.io);

    // A leftover staging tree from a channel that died mid-push is cleared
    // rather than resumed: partial bytes from an earlier attempt would either
    // fail the commit or, worse, pass it while describing two pushes.
    root.deleteTree(agent.io, staging_rel) catch {};
    try root.createDirPath(agent.io, staging_rel);

    agent.push = .{ .root = root, .id = id, .version = version, .staging_rel = staging_rel, .lease = lease };
    keep_root = true;
    try agent.reply(.{ .ok = true, .held = false }, "", "");
}

fn serveStorePut(agent: *Agent, req: protocol.Request, payload: []const u8) !void {
    const p = agent.push orelse {
        try agent.refuse("no version is being pushed here; send store-stat first");
        return;
    };
    const rel = safeVersionRel(req.path) orelse {
        try agent.refuseFmt("'{s}' is not a path inside a version directory", .{req.path});
        return;
    };

    const dest = try std.fs.path.join(agent.alloc, &.{ p.staging_rel, rel });
    defer agent.alloc.free(dest);
    if (std.fs.path.dirname(dest)) |dir| try p.root.createDirPath(agent.io, dir);
    p.root.writeFile(agent.io, .{ .sub_path = dest, .data = payload }) catch |err| {
        try agent.refuseFmt("could not write '{s}': {s}", .{ rel, @errorName(err) });
        return;
    };
    // The mode a copy would have carried. Refused rather than shrugged off: a
    // binary that is there and cannot run is the failure a push exists to avoid,
    // and this is the last moment anyone can see it happen.
    if (req.exec and std.Io.File.Permissions.has_executable_bit) {
        p.root.setFilePermissions(agent.io, dest, .executable_file, .{}) catch |err| {
            try agent.refuseFmt("could not make '{s}' executable: {s}", .{ rel, @errorName(err) });
            return;
        };
    }
    try agent.reply(.{ .ok = true }, "", "");
}

fn serveStoreCommit(agent: *Agent) !void {
    const p = agent.push orelse {
        try agent.refuse("no version is being pushed here; send store-stat first");
        return;
    };
    defer closePush(agent);

    // These bytes arrived over a channel, so this is the moment to re-digest
    // the package, prove it reproduces this very version id, and prove the
    // binary is the sealed one.
    integrity.validateVersionDir(agent.alloc, agent.io, p.root, p.staging_rel, p.version, p.id, .sealed) catch |err| {
        try agent.refuseFmt("what arrived is not {s}@{s} ({s}); nothing was installed", .{ p.id, p.version, @errorName(err) });
        return;
    };

    const version_rel = try p.versionRel(agent.alloc);
    defer agent.alloc.free(version_rel);
    const versions_dir = std.fs.path.dirname(version_rel).?;
    try p.root.createDirPath(agent.io, versions_dir);
    // Only reached when this root held no VALID copy (`store-stat`), so what is
    // being replaced, if anything, is a broken one.
    p.root.deleteTree(agent.io, version_rel) catch {};
    p.root.rename(p.staging_rel, p.root, version_rel, agent.io) catch |err| {
        try agent.refuseFmt("could not install {s}@{s}: {s}", .{ p.id, p.version, @errorName(err) });
        return;
    };
    try agent.reply(.{ .ok = true }, "", "");
}

fn serveListDir(agent: *Agent, req: protocol.Request) !void {
    const path = if (req.path.len != 0) req.path else ".";
    var dir = std.Io.Dir.cwd().openDir(agent.io, path, .{ .iterate = true }) catch |err| {
        const msg = try std.fmt.allocPrint(agent.alloc, "{s}: {s}", .{ path, @errorName(err) });
        defer agent.alloc.free(msg);
        try agent.refuse(msg);
        return;
    };
    defer dir.close(agent.io);

    const a = agent.arena.allocator();
    var entries: std.ArrayList(protocol.Entry) = .empty;
    var skipped: usize = 0;
    var truncated = false;
    var it = dir.iterate();
    while (it.next(agent.io) catch null) |e| {
        // A name that is not valid UTF-8 cannot be encoded as JSON at all
        // (`std.json` writes it as an array of numbers, and the host's parse
        // then declares the channel dead). Skipped, and SAID.
        if (!std.unicode.utf8ValidateSlice(e.name)) {
            skipped += 1;
            continue;
        }
        if (entries.items.len >= max_entries) {
            truncated = true;
            break;
        }
        try entries.append(a, .{ .name = try a.dupe(u8, e.name), .dir = e.kind == .directory });
    }
    std.mem.sort(protocol.Entry, entries.items, {}, lessThanEntry);

    var note: []const u8 = "";
    if (truncated) {
        note = try std.fmt.allocPrint(a, "listing stopped at {d} entries; name a subdirectory for the rest", .{max_entries});
    } else if (skipped != 0) {
        note = try std.fmt.allocPrint(a, "{d} entries were left out: their names are not valid UTF-8", .{skipped});
    }
    // The listing is the payload: it grows with what this machine holds, and a
    // header may not (protocol rule 6). The note stays in the header — one
    // sentence this build wrote, not something the directory sizes.
    const body = try protocol.encodeEntries(a, entries.items);
    try agent.reply(.{ .ok = true, .bytes = body.len, .message = note }, body, "");
}

/// Why a run did not happen, in that machine's own words. An extension gets the
/// sentence that names the missing version and the command that delivers it —
/// the one failure a push fixes. The host turns this into an ordinary failed
/// call, so the model reads it.
fn runFailure(agent: *Agent, request: @FieldType(RunTask, "req"), err: anyerror) ![]const u8 {
    switch (request) {
        .shell => return std.fmt.allocPrint(agent.arena.allocator(), "could not run the command: {s}", .{@errorName(err)}),
        .extension => |r| {
            const missing = err == error.VersionNotFound or err == error.VersionSealInvalid or
                err == error.VersionEntryNotFound or err == error.VersionPackageMissing;
            if (!missing) {
                return std.fmt.allocPrint(agent.arena.allocator(), "could not run {s}@{s} here: {s}", .{ r.id, r.version, @errorName(err) });
            }
            return std.fmt.allocPrint(
                agent.arena.allocator(),
                "this machine has no usable copy of {s}@{s} ({s}), so its tools cannot run here; " ++
                    "on the harness machine run `nulya ext push {s}@{s} --env <this session's --env>`",
                .{ r.id, r.version, @errorName(err), r.id, r.version },
            );
        },
    }
}

fn lessThanEntry(_: void, a: protocol.Entry, b: protocol.Entry) bool {
    // Directories first, then by name: what a browser wants, and deterministic,
    // which is what a test wants.
    if (a.dir != b.dir) return a.dir;
    return std.mem.lessThan(u8, a.name, b.name);
}
