//! `nulya remote …` (DESIGN §8.1, §14): the two ends of the remote channel.
//!
//! `serve` is the FAR side — this same binary, in a shell role, exactly as
//! `nulya task supervise` is (DESIGN §6.1). It reads frames on stdin, runs the
//! commands they ask for through the ordinary `LocalEnvironment`, and writes
//! the results back on stdout. That is the whole reason the remote side of a
//! nulya session gets a real process-tree kill, a real secret denylist and a
//! real wall-clock budget without a second implementation of any of them: over
//! there, nulya IS the local environment.
//!
//! `check` and `ls` are the HOST side, and they exist because a driver needs
//! two answers before it can offer a machine to a person: can I reach it, and
//! what is on it. `ls` is a protocol verb rather than `ls -1p` parsed out of a
//! shell call because a file name may contain a newline and a browser needs the
//! kind anyway — parsing a listing back out of text would be a second, lossier
//! answer to a question the agent can just answer.
//!
//! **stdout on the serving side is the channel.** Nothing here may print to it
//! except frames; every diagnostic goes to stderr, where the transport's own
//! errors already go.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const environment = @import("../environment.zig");
const remote = @import("../environment/remote/mod.zig");
const protocol = @import("../environment/remote/protocol.zig");
const launch = @import("../launch.zig");
const common = @import("common.zig");

const flagValue = common.flagValue;
const printErr = common.printErr;
const printErrFmt = common.printErrFmt;
const printOut = common.printOut;
const printRaw = common.printRaw;

/// How many directory entries one `list-dir` reply carries. The entries travel
/// as PAYLOAD (protocol rule 6), so this is no longer what keeps the frame
/// readable — it is what keeps one answer to "what is in this directory" a size
/// a person or a browser can use. Truncation is SAID, never silent.
const max_entries: usize = 1000;

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
    return remote.Channel.connect(alloc, io, l, launch.version, .default) catch |err| {
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
};

fn remoteServe(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    _ = args;
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    // The ordinary local environment of THIS machine — the whole point. No
    // session ref: an agent runs commands, it does not own a ledger, so
    // `startShellTask` here would have nowhere to report and says so.
    var lenv = try launch.localEnvironment(alloc, io, &cfg, null, "");
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
    switch (protocol.Op.parse(req.op)) {
        .hello => try serveHello(agent, req),
        .run_shell => try serveShell(agent, req, payload),
        .list_dir => try serveListDir(agent, req),
        // A cancel with nothing running: the command it was meant for already
        // finished. Acknowledged rather than treated as an error — the race is
        // legitimate and the host is about to close the channel anyway.
        .cancel => try agent.reply(.{ .ok = true }, "", ""),
        .put_file => try servePutFile(agent, req, payload),
        .run_extension => try agent.refuse("extension tools do not run over this channel yet; they still run on the machine the harness runs on"),
        .start_task => try agent.refuse("background tasks do not run over this channel yet; they still run on the machine the harness runs on"),
        .unknown => try agent.refuse("unknown request; this build understands hello, run-shell, put-file, list-dir and cancel"),
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

/// Runs the command while watching for a `cancel` frame, so a canceled step on
/// the host actually ends the process HERE — the guarantee the exec target
/// could not make (DESIGN §8.1's first honest limit).
const ShellTask = struct {
    agent: *Agent,
    req: environment.ShellRequest,
    out: ?anyerror!environment.ShellOutcome = null,

    fn run(self: *ShellTask) void {
        const result = self.agent.lenv.environment().runShell(self.agent.alloc, self.req);
        // Canceled leaves `out` null: the local runner has already killed the
        // whole process tree on that path and there is no outcome to report.
        if (result) |_| {} else |err| {
            if (err == error.Canceled) return;
        }
        self.out = result;
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
    const shell_req: environment.ShellRequest = .{
        .command = command,
        .cwd = if (req.cwd.len != 0) req.cwd else ".",
        .max_output_bytes = if (req.max_output_bytes != 0) req.max_output_bytes else 1 << 20,
        .timeout_ms = req.timeout_ms,
    };
    var task: ShellTask = .{ .agent = agent, .req = shell_req };
    var watch: ControlWatch = .{ .agent = agent };

    const Race = union(enum) { command: void, control: void };
    var buf: [2]Race = undefined;
    var sel: std.Io.Select(Race) = .init(agent.io, &buf);
    // Without two units of concurrency the command still runs; what is lost is
    // only the mid-command cancel, and losing the command instead would be a
    // worse trade. Same degradation `waitBounded` takes.
    sel.concurrent(.control, ControlWatch.run, .{&watch}) catch {
        ShellTask.run(&task);
        return replyShell(agent, &task);
    };
    sel.concurrent(.command, ShellTask.run, .{&task}) catch {
        sel.cancelDiscard();
        ShellTask.run(&task);
        return replyShell(agent, &task);
    };
    _ = sel.await() catch {
        sel.cancelDiscard();
        return;
    };
    sel.cancelDiscard(); // cancels and JOINS the loser

    if (task.out != null) return replyShell(agent, &task);

    // The control frame (or EOF) won: cancelling the command task made the
    // local runner kill the whole tree. Answer so the channel stays well formed
    // — no output, because the kill path has none to report and inventing one
    // would be worse than saying there is none.
    agent.stop = watch.eof;
    if (!watch.eof) try agent.reply(.{ .ok = true, .canceled = true, .exit_code = 1 }, "", "");
}

fn replyShell(agent: *Agent, task: *ShellTask) !void {
    const settled = task.out orelse {
        try agent.reply(.{ .ok = true, .canceled = true, .exit_code = 1 }, "", "");
        return;
    };
    const outcome = settled catch |err| {
        const msg = try std.fmt.allocPrint(agent.alloc, "could not run the command: {s}", .{@errorName(err)});
        defer agent.alloc.free(msg);
        try agent.refuse(msg);
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
/// local session's spill goes through, not a copy of it. That is the point of
/// the far side being nulya itself: "spill on the far machine" is not a second
/// implementation of "spill here", it is the same one, reached over a channel.
///
/// `path` is workspace-relative and `/`-spelled (it is the string the model will
/// read in the footer); `cwd` is where that workspace is here. They are joined
/// exactly once, and only in this direction — the host never learns a path on
/// this machine (goals/remote-env.md §3.3).
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
        // (`std.json` would write it as an array of numbers and the host's
        // parse would then declare the channel dead). Skipping it and SAYING SO
        // keeps one odd file from taking the whole listing down.
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
    // header may not (protocol rule 6). The note stays in the header — it is one
    // sentence this build wrote, not something the directory decides the size of.
    const body = try protocol.encodeEntries(a, entries.items);
    try agent.reply(.{ .ok = true, .bytes = body.len, .message = note }, body, "");
}

fn lessThanEntry(_: void, a: protocol.Entry, b: protocol.Entry) bool {
    // Directories first, then by name: what a browser wants, and deterministic,
    // which is what a test wants.
    if (a.dir != b.dir) return a.dir;
    return std.mem.lessThan(u8, a.name, b.name);
}
