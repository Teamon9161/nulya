//! The second `Environment` implementation: the session's commands run on
//! ANOTHER machine, through one long-lived channel to a `nulya remote serve`
//! there — the workspace MOVES too, and the channel opens once per session
//! process.
//!
//! All four verbs cross it. `startShellTask` starts a `nulya task supervise` on
//! THAT machine, so a background command outlives this channel; its report is
//! carried back by whoever next asks (`cli/task.zig`), since the ledger is here.
//! `runExtension` sends an IDENTITY — `(id, version, tool)` plus the arguments —
//! because which file a version means, and whether it still matches its seal,
//! only the machine holding the bytes can say. `putWorkspaceFile` lands spilled
//! bytes in the far workspace at the very path the model is told to open.
//!
//! The far side is nulya itself in a shell role: the process-tree kill, the
//! secret denylist, the wall-clock budget and the output capture over there are
//! THE SAME CODE as here, and cancellation reaches it because the agent holds a
//! real `Tree` around the command. Nothing on the channel carries a credential
//! (`protocol.zig` rule 5) — the model connection stays on the host.

const std = @import("std");
const builtin = @import("builtin");
const environment = @import("../../environment.zig");
/// The same module, under a second name. `RemoteEnvironment` has a method
/// called `environment()` (the handle, as `LocalEnvironment` spells it), and a
/// sibling declaration shadows the file-scope import inside that struct's body.
const environment_mod = environment;
const protocol = @import("protocol.zig");
const ssh_askpass = @import("ssh_askpass.zig");

/// What marks a `--env` spec as naming this backend rather than the
/// command-wrapping exec target. One prefix, checked in one place.
pub const spec_prefix = "remote:";

/// The vocabulary, in the one place a refusal can quote it.
pub const spec_syntax = "remote:wsl | remote:wsl:<distro> | remote:ssh:<destination> | remote:exec:<argv…>";

pub const Error = error{
    InvalidRemoteSpec,
    /// The spec parses but this host has no way to reach that machine.
    RemoteSpecUnsupportedOnHost,
    /// The channel is gone — the transport died, the agent exited, a frame did
    /// not parse. Never folded together with a command's own failure: what the
    /// command did on that machine is then UNKNOWN.
    RemoteChannelLost,
    /// The agent did not answer within the host's bound. Same honesty as above.
    RemoteChannelStalled,
    /// The far side speaks another protocol version (protocol.zig rule 4).
    RemoteVersionMismatch,
    /// The agent named a shell dialect this build does not know. Refused, not
    /// guessed: reading "fish" as bash would hand the model a wrong fact about
    /// every command it runs.
    RemoteDialectUnknown,
    /// The agent refused the request and said why.
    RemoteRefused,
    /// The far machine would not start the background task (it could not create
    /// the directory, or could not spawn a supervisor). Its own sentence does
    /// NOT survive: `startShellTask` answers a `TaskStart` or an error, with no
    /// failed-call shape to carry words in (unlike `runExtension`).
    RemoteTaskRefused,
};

/// How to start the agent. The payload borrows the spec string, so a parsed
/// value never outlives it.
pub const Launch = union(enum) {
    /// `wsl.exe [-d <distro>] -e <nulya> remote serve`; empty payload = the
    /// default distribution.
    wsl: []const u8,
    /// `ssh -o BatchMode=yes <destination> <nulya> remote serve`.
    ssh: []const u8,
    /// The general form: the payload IS the command that starts a process on
    /// that machine, and `remote serve` is appended to it. So the kernel never
    /// has to learn the word "docker", and the whole thing is testable offline
    /// by pointing it at this very binary over a pipe.
    exec: []const u8,
};

/// The program name the named launchers assume on the far side. Anything else
/// is spelled out with `remote:exec:`.
pub const default_remote_exe = "nulya";

pub fn isSpec(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, spec_prefix);
}

pub fn isSshSpec(spec: []const u8) bool {
    const parsed = parseSpec(spec) catch return false;
    return parsed == .ssh;
}

/// Pure syntax. Whether THIS host can reach it is `supportedOnHost` — the two
/// have different fixes, exactly as they do for the exec target.
pub fn parseSpec(spec: []const u8) Error!Launch {
    if (!isSpec(spec)) return error.InvalidRemoteSpec;
    const rest = spec[spec_prefix.len..];
    if (std.mem.eql(u8, rest, "wsl")) return .{ .wsl = "" };
    if (std.mem.startsWith(u8, rest, "wsl:")) {
        const distro = rest["wsl:".len..];
        if (distro.len == 0) return error.InvalidRemoteSpec;
        return .{ .wsl = distro };
    }
    if (std.mem.startsWith(u8, rest, "ssh:")) {
        const dest = rest["ssh:".len..];
        if (dest.len == 0) return error.InvalidRemoteSpec;
        return .{ .ssh = dest };
    }
    if (std.mem.startsWith(u8, rest, "exec:")) {
        const argv = rest["exec:".len..];
        if (std.mem.trim(u8, argv, " ").len == 0) return error.InvalidRemoteSpec;
        return .{ .exec = argv };
    }
    return error.InvalidRemoteSpec;
}

pub fn supportedOnHost(launch: Launch) bool {
    return switch (launch) {
        .ssh, .exec => true,
        .wsl => builtin.os.tag == .windows,
    };
}

/// The argv that starts the agent. The returned slice is owned by `alloc`; its
/// WORDS are not — they are literals or subslices of `spec`, which must outlive
/// the argv.
///
/// `remote serve` is appended in every form, so a launcher only has to answer
/// "how do I start a process over there". `exec:` is split on spaces and has NO
/// quoting: a program path containing a space cannot be spelled this way.
pub fn launcherArgv(alloc: std.mem.Allocator, launch: Launch, password: bool) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    switch (launch) {
        .wsl => |distro| {
            try argv.append(alloc, "wsl.exe");
            if (distro.len != 0) try argv.appendSlice(alloc, &.{ "-d", distro });
            // `-e` runs the named program directly instead of handing the rest
            // to the distribution's login shell — no quoting, no profile.
            try argv.appendSlice(alloc, &.{ "-e", default_remote_exe });
        },
        .ssh => |dest| {
            // SSH stdin is always the framing channel. Explicit password mode
            // therefore forces the fixed askpass helper and permits one prompt;
            // the default remains non-interactive and byte-for-byte strict.
            try argv.appendSlice(alloc, &.{ "ssh", "-o", if (password) "BatchMode=no" else "BatchMode=yes" });
            if (password) try argv.appendSlice(alloc, &.{ "-o", "NumberOfPasswordPrompts=1" });
            try argv.appendSlice(alloc, &.{ dest, default_remote_exe });
        },
        .exec => |words| {
            var it = std.mem.splitScalar(u8, words, ' ');
            while (it.next()) |w| {
                if (w.len != 0) try argv.append(alloc, w);
            }
        },
    }
    try argv.appendSlice(alloc, &.{ "remote", "serve" });
    return argv.toOwnedSlice(alloc);
}

/// What the far side said about itself at `hello`. Owned by the channel's arena.
pub const Hello = struct {
    nulya: []const u8 = "",
    os: []const u8 = "",
    arch: []const u8 = "",
    home: []const u8 = "",
    /// The directory the agent started in — the workspace a session with no
    /// `--workspace` will use, resolved by the machine that owns it.
    cwd: []const u8 = "",
    dialect: []const u8 = "",
};

/// How long the host waits before deciding the agent is not answering.
///
/// A deadline, NOT the byte-level heartbeat `providers/wire.zig` uses: a
/// legitimate ten-minute build is silent on this channel, so a heartbeat would
/// kill the work it is meant to protect. The agent's contract is one reply per
/// request within that request's own timeout, so the host's patience is that
/// timeout plus a margin — a fixed value only where the request carries none.
pub const Bounds = struct {
    /// For a request with no budget of its own (`hello`, `list-dir`). Generous:
    /// opening an ssh connection on a cold link is not fast, and being wrong
    /// here costs a spurious failure.
    control_ms: u32 = 60_000,
    /// Added to a command's own budget. The agent enforces that budget next to
    /// the process; this margin only catches an agent that has stopped talking.
    reply_grace_ms: u32 = 60_000,

    /// A parameter rather than two constants so a test can shrink them, and so a
    /// driver on a link where 60 s is the wrong number has the same lever.
    pub const default: Bounds = .{};
};

/// Read exactly one password line from a CLI stdin stream. The caller owns the
/// mutable result and must wipe it before freeing. Keeping the reader outside
/// lets `session step --gate` continue consuming verdict lines afterwards.
pub fn readSshPassword(alloc: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return error.SshPasswordMissing,
        else => return err,
    };
    const password = std.mem.trimEnd(u8, line, "\r");
    if (password.len == 0) return error.SshPasswordMissing;
    if (password.len > ssh_askpass.max_password_bytes) return error.SshPasswordTooLong;
    return alloc.dupe(u8, password);
}

/// One open channel to an agent: the transport child plus the framing.
pub const Channel = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    read_buf: []u8,
    reader: std.Io.File.Reader,
    argv: []const []const u8,
    env: std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    bounds: Bounds = .default,
    hello: Hello = .{},
    /// The payload of the last `controlRound` reply, in the channel arena — so
    /// valid until the next round resets it.
    last_payload: []const u8 = &.{},
    /// Once true, nothing more is sent or read: a desynchronised channel that
    /// keeps being used answers questions with another request's reply.
    dead: bool = false,

    /// Start the agent and complete the handshake, or fail with a sentence the
    /// caller can print. The transport's own stderr is INHERITED: `ssh`'s
    /// "Permission denied (publickey)" is the most useful thing that can happen
    /// on a bad connection, and stderr is already where every refusal goes.
    pub fn connect(alloc: std.mem.Allocator, io: std.Io, launch: Launch, version: []const u8, bounds: Bounds) anyerror!Channel {
        return connectPassword(alloc, io, launch, version, bounds, null);
    }

    pub fn connectPassword(alloc: std.mem.Allocator, io: std.Io, launch: Launch, version: []const u8, bounds: Bounds, password: ?[]const u8) anyerror!Channel {
        if (!supportedOnHost(launch)) return error.RemoteSpecUnsupportedOnHost;
        if (password != null and launch != .ssh) return error.InvalidRemoteSpec;

        const argv = try launcherArgv(alloc, launch, password != null);
        errdefer alloc.free(argv);

        // Whatever `ssh` / `wsl.exe` gets is the stripped map, so there is no
        // secret for `SendEnv` / `WSLENV` to forward even if someone configured
        // them to.
        var env = try environment.sanitizedChildEnv(alloc, io);
        errdefer env.deinit();

        var broker: ?ssh_askpass.Broker = null;
        defer if (broker) |*one| one.deinit();
        if (password) |secret| {
            broker = try .init(io, secret);
            const helper = env.get("NULYA_EXE") orelse return error.RemoteChannelLost;
            try env.put("SSH_ASKPASS", helper);
            try env.put("SSH_ASKPASS_REQUIRE", "force");
            try env.put(ssh_askpass.marker_env, broker.?.marker());
            broker.?.start();
        }

        var child = std.process.spawn(io, .{
            .argv = argv,
            // The stripped map, explicitly: without it the transport — and
            // therefore the agent, and therefore every command it runs —
            // inherits this process's environment whole, secrets included.
            .environ_map = &env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        }) catch return error.RemoteChannelLost;
        errdefer child.kill(io);

        const read_buf = try alloc.alloc(u8, protocol.max_header_bytes);
        errdefer alloc.free(read_buf);

        var ch: Channel = .{
            .alloc = alloc,
            .io = io,
            .child = child,
            .read_buf = read_buf,
            .reader = child.stdout.?.readerStreaming(io, read_buf),
            .argv = argv,
            .env = env,
            .arena = .init(alloc),
            .bounds = bounds,
        };
        errdefer ch.arena.deinit();

        const rep = try ch.controlRound(.{ .op = protocol.Op.hello.wire(), .v = protocol.version, .nulya = version }, "");
        protocol.checkHello(rep) catch |err| switch (err) {
            error.VersionMismatch => {
                ch.dead = true;
                return error.RemoteVersionMismatch;
            },
            else => {
                ch.dead = true;
                return error.RemoteChannelLost;
            },
        };
        ch.hello = .{
            .nulya = rep.nulya,
            .os = rep.os,
            .arch = rep.arch,
            .home = rep.home,
            .cwd = rep.cwd,
            .dialect = rep.dialect,
        };
        return ch;
    }

    pub fn deinit(self: *Channel) void {
        // Closing stdin FIRST: EOF is what tells the agent to kill whatever it
        // is running and exit. Killing the transport first would leave that
        // signal unsent, and on a slow link the far command could outlive us.
        if (self.child.stdin) |stdin| {
            var f = stdin;
            f.close(self.io);
            self.child.stdin = null;
        }
        self.child.kill(self.io);
        self.arena.deinit();
        self.env.deinit();
        self.alloc.free(self.read_buf);
        self.alloc.free(self.argv);
        self.* = undefined;
    }

    pub fn send(self: *Channel, req: protocol.Request, payload: []const u8) anyerror!void {
        // The reader refuses a claimed length over `max_payload_bytes` before
        // allocating — but by then the payload bytes are already in the stream
        // and the channel is dead. So never WRITE a frame the peer must refuse.
        if (payload.len > protocol.max_payload_bytes) return error.PayloadTooLarge;
        const line = try protocol.encodeRequest(self.alloc, req);
        defer self.alloc.free(line);
        const stdin = self.child.stdin orelse return error.RemoteChannelLost;
        stdin.writeStreamingAll(self.io, line) catch |err| return self.writeFailure(err);
        if (payload.len != 0) stdin.writeStreamingAll(self.io, payload) catch |err| return self.writeFailure(err);
    }

    fn writeFailure(self: *Channel, err: anyerror) anyerror {
        if (err == error.Canceled) return err;
        self.dead = true;
        return error.RemoteChannelLost;
    }

    /// A canceled read is THIS STEP being canceled, not the channel dying, and
    /// the two need different answers. `std.Io.Reader` folds every underlying
    /// fault into `ReadFailed` and keeps the real one in `reader.err`, so this is
    /// the only place they can be told apart.
    fn readFailure(self: *Channel) anyerror {
        if (self.reader.err) |e| {
            if (e == error.Canceled) return error.Canceled;
        }
        self.dead = true;
        return error.RemoteChannelLost;
    }

    /// Read one reply header. The returned strings live in the channel arena,
    /// which is reset at the start of every round.
    fn readHeader(self: *Channel) anyerror!protocol.Reply {
        const line = (self.reader.interface.takeDelimiter('\n') catch return self.readFailure()) orelse {
            self.dead = true;
            return error.RemoteChannelLost;
        };
        return protocol.parseReply(self.arena.allocator(), line) catch {
            // A frame that does not parse means the stream is no longer this
            // protocol; there is no resynchronising from here.
            self.dead = true;
            return error.RemoteChannelLost;
        };
    }

    fn readExact(self: *Channel, dest: []u8) anyerror!void {
        if (dest.len == 0) return;
        self.reader.interface.readSliceAll(dest) catch return self.readFailure();
    }

    /// One round that is not a command — `hello`, `list-dir`, `put-file` — under
    /// the host's patience, so an agent that never answers cannot hang the
    /// caller. The reply's payload, if any, is left in `last_payload`.
    pub fn controlRound(self: *Channel, req: protocol.Request, payload: []const u8) anyerror!protocol.Reply {
        var ex: ControlExchange = .{ .ch = self, .req = req, .payload = payload };
        const Race = union(enum) { done: void, expired: void };
        var buf: [2]Race = undefined;
        var sel: std.Io.Select(Race) = .init(self.io, &buf);
        sel.concurrent(.expired, sleepMs, .{ self.io, self.bounds.control_ms }) catch {
            ControlExchange.run(&ex);
            return ex.out orelse error.Canceled;
        };
        sel.concurrent(.done, ControlExchange.run, .{&ex}) catch {
            sel.cancelDiscard();
            ControlExchange.run(&ex);
            return ex.out orelse error.Canceled;
        };
        const first = sel.await() catch |err| {
            sel.cancelDiscard();
            return err;
        };
        sel.cancelDiscard();
        if (ex.out) |settled| return settled;
        if (first == .done) return error.Canceled;
        self.dead = true;
        return error.RemoteChannelStalled;
    }

    fn controlRoundUnbounded(self: *Channel, req: protocol.Request, payload: []const u8) anyerror!protocol.Reply {
        if (self.dead) return error.RemoteChannelLost;
        _ = self.arena.reset(.retain_capacity);
        self.last_payload = &.{};
        try self.send(req, payload);
        const rep = try self.readHeader();
        // A reply's payload is ALWAYS consumed, whether or not the caller wants
        // it: leaving bytes in the stream would desynchronise every later frame.
        if (rep.bytes != 0) {
            const body = try self.arena.allocator().alloc(u8, rep.bytes);
            try self.readExact(body);
            self.last_payload = body;
        }
        return rep;
    }
};

/// One payload-free round, as a task, so the bound above can race it. A canceled
/// task leaves `out` null, which is how the caller tells "did not settle" from
/// "settled badly".
const ControlExchange = struct {
    ch: *Channel,
    req: protocol.Request,
    payload: []const u8 = "",
    out: ?anyerror!protocol.Reply = null,

    fn run(self: *ControlExchange) void {
        const result = self.ch.controlRoundUnbounded(self.req, self.payload);
        if (result) |_| {} else |err| {
            if (err == error.Canceled) return;
        }
        self.out = result;
    }
};

/// What a run of SOMETHING on the far side came back as. One shape for both run
/// verbs: `ShellOutcome` and `ExtensionOutcome` are the same four fields, and
/// the reply frame does not distinguish them either.
const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    timed_out: bool,
    /// The agent refused the request, in its own words (owned). Kept rather than
    /// folded into an error because the two callers answer it differently: a
    /// refused SHELL is a host fault, and a refused EXTENSION is an ordinary
    /// failed call the model gets to read.
    refusal: ?[]u8 = null,

    fn deinit(self: Captured, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
        if (self.refusal) |m| alloc.free(m);
    }
};

/// A command round: request out, reply and its payload back, split into the two
/// owned slices an outcome wants.
const CommandExchange = struct {
    ch: *Channel,
    alloc: std.mem.Allocator,
    req: protocol.Request,
    payload: []const u8,
    out: ?anyerror!Captured = null,

    fn run(self: *CommandExchange) void {
        const result = self.round();
        // A canceled exchange leaves `out` null, so the caller knows the task
        // did not settle.
        if (result) |_| {} else |err| {
            if (err == error.Canceled) return;
        }
        self.out = result;
    }

    fn round(self: *CommandExchange) anyerror!Captured {
        const ch = self.ch;
        if (ch.dead) return error.RemoteChannelLost;
        _ = ch.arena.reset(.retain_capacity);
        try ch.send(self.req, self.payload);

        const rep = try ch.readHeader();
        if (!rep.ok) {
            return .{
                .stdout = try self.alloc.alloc(u8, 0),
                .stderr = try self.alloc.alloc(u8, 0),
                .exit_code = 1,
                .timed_out = false,
                .refusal = try self.alloc.dupe(u8, rep.message),
            };
        }
        if (rep.out > rep.bytes) {
            ch.dead = true;
            return error.RemoteChannelLost;
        }

        const stdout = try self.alloc.alloc(u8, rep.out);
        errdefer self.alloc.free(stdout);
        try ch.readExact(stdout);
        const stderr = try self.alloc.alloc(u8, rep.bytes - rep.out);
        errdefer self.alloc.free(stderr);
        try ch.readExact(stderr);

        return .{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = rep.exit_code,
            .timed_out = rep.timed_out,
        };
    }
};

fn sleepMs(io: std.Io, ms: u32) void {
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

// ── background tasks over there, on a bare channel ──────────────────────────
//
// These take a `*Channel` rather than a `RemoteEnvironment` because their other
// caller is `cli/task.zig`: `nulya task list` on this host has no session
// environment, only a machine to ask.

/// The two files that machine's supervisor writes, verbatim. The strings live in
/// the channel arena — valid until the next round on it.
pub fn pollTaskOn(ch: *Channel, cwd: []const u8, task_name: []const u8) anyerror!protocol.TaskSnapshot {
    const rep = try ch.controlRound(.{
        .op = protocol.Op.task_poll.wire(),
        .task = task_name,
        .cwd = cwd,
    }, "");
    if (!rep.ok) return error.RemoteRefused;
    return protocol.parseTaskSnapshot(ch.arena.allocator(), ch.last_payload) catch error.RemoteChannelLost;
}

/// Put the kill marker down over there. A marker rather than a signal, exactly
/// as it is here: the supervisor owns the process tree and picks it up at its
/// next poll.
pub fn killTaskOn(ch: *Channel, cwd: []const u8, task_name: []const u8) anyerror!void {
    const rep = try ch.controlRound(.{
        .op = protocol.Op.task_kill.wire(),
        .task = task_name,
        .cwd = cwd,
    }, "");
    if (!rep.ok) return error.RemoteRefused;
}

/// The `Environment` backed by a channel. Fixed shape, like `LocalEnvironment`:
/// nothing here grows with the conversation.
pub const RemoteEnvironment = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    ch: Channel,
    /// The spec this was built from, owned — it is what a refusal names, so the
    /// model is told WHICH machine its commands are on.
    spec: []u8,
    /// The absolute directory on the far side this session works in, owned.
    /// Empty means "wherever the agent started", which `hello` reported.
    workspace: []u8,
    /// This session's IDENTITY, owned, published to everything the agent runs as
    /// `NULYA_SESSION_ID`. Not the session file's path: that names a file on the
    /// host, so sending it would be a lie a package could act on.
    /// Empty until a driver publishes one (`session step` does; `remote check`
    /// does not).
    session_id: []u8 = &.{},
    /// The session background tasks belong to, copied. Both halves stay on the
    /// HOST even though the command will not: the far machine holds the log and
    /// the status, this one holds the name and the delivery. Null = no session,
    /// so `startShellTask` refuses exactly as the local one does.
    session_path: ?[]u8 = null,
    tasks_dir: ?[]u8 = null,
    dialect_val: environment_mod.Dialect,
    bounds: Bounds = .default,

    pub const ConnectOptions = struct {
        spec: []const u8,
        /// The absolute directory on that machine this session works in; empty
        /// means wherever the agent started.
        workspace: []const u8 = "",
        /// This build's version string, for the handshake's diagnostic half.
        version: []const u8 = "",
        /// The durable session this environment's background tasks belong to,
        /// as on the local one — the shell layer computes both halves
        /// (`launch.sessionEnvironment`).
        session: ?environment_mod.SessionRef = null,
        /// Transient SSH password, owned and wiped by the caller.
        ssh_password: ?[]const u8 = null,
        bounds: Bounds = .default,
    };

    pub fn connect(
        alloc: std.mem.Allocator,
        io: std.Io,
        opts: ConnectOptions,
    ) anyerror!RemoteEnvironment {
        const spec = opts.spec;
        const launch = try parseSpec(spec);
        var ch = try Channel.connectPassword(alloc, io, launch, opts.version, opts.bounds, opts.ssh_password);
        errdefer ch.deinit();

        const spec_owned = try alloc.dupe(u8, spec);
        errdefer alloc.free(spec_owned);
        const ws = try alloc.dupe(u8, opts.workspace);
        errdefer alloc.free(ws);

        var session_path: ?[]u8 = null;
        errdefer if (session_path) |p| alloc.free(p);
        var tasks_dir: ?[]u8 = null;
        errdefer if (tasks_dir) |p| alloc.free(p);
        if (opts.session) |s| {
            session_path = try alloc.dupe(u8, s.session_path);
            tasks_dir = try alloc.dupe(u8, s.tasks_dir);
        }

        // The far side says which shell reads its commands; this host's config
        // and detection have nothing to say about another machine. A word this
        // build does not know is refused, never guessed.
        const dialect_val: environment_mod.Dialect = if (std.mem.eql(u8, ch.hello.dialect, "powershell"))
            .powershell
        else if (std.mem.eql(u8, ch.hello.dialect, "bash"))
            .bash
        else
            return error.RemoteDialectUnknown; // errdefer above closes the channel

        return .{
            .alloc = alloc,
            .io = io,
            .ch = ch,
            .spec = spec_owned,
            .workspace = ws,
            .session_path = session_path,
            .tasks_dir = tasks_dir,
            .dialect_val = dialect_val,
            .bounds = opts.bounds,
        };
    }

    pub fn deinit(self: *RemoteEnvironment) void {
        self.ch.deinit();
        self.alloc.free(self.spec);
        self.alloc.free(self.workspace);
        if (self.session_path) |p| self.alloc.free(p);
        if (self.tasks_dir) |p| self.alloc.free(p);
        if (self.session_id.len != 0) self.alloc.free(self.session_id);
        self.* = undefined;
    }

    /// Tell the far side which session its commands belong to. Only the id
    /// travels — see `session_id`.
    pub fn publishSession(self: *RemoteEnvironment, session_id: []const u8) !void {
        if (session_id.len == 0) return;
        const owned = try self.alloc.dupe(u8, session_id);
        if (self.session_id.len != 0) self.alloc.free(self.session_id);
        self.session_id = owned;
    }

    pub fn environment(self: *RemoteEnvironment) environment_mod.Environment {
        return .{ .io = self.io, .ptr = self, .vtable = &vtable };
    }

    /// What the agent is told to run in. The CALLER's `cwd` is deliberately
    /// ignored: it is a path on THIS machine, and a host path means nothing over
    /// there. Every model-facing path in a nulya session is workspace-relative,
    /// so no path is ever translated — each side reads "." as its own workspace.
    fn remoteCwd(self: *const RemoteEnvironment) []const u8 {
        return if (self.workspace.len != 0) self.workspace else ".";
    }

    fn dialectImpl(ptr: *anyopaque) environment_mod.Dialect {
        const self: *RemoteEnvironment = @ptrCast(@alignCast(ptr));
        return self.dialect_val;
    }

    fn runShellImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment_mod.ShellRequest) anyerror!environment_mod.ShellOutcome {
        const self: *RemoteEnvironment = @ptrCast(@alignCast(ptr));
        const captured = try self.runBounded(alloc, .{
            .op = protocol.Op.run_shell.wire(),
            .cwd = self.remoteCwd(),
            .session = self.session_id,
            .timeout_ms = req.timeout_ms,
            .max_output_bytes = req.max_output_bytes,
            .bytes = req.command.len,
        }, req.command, req.timeout_ms);
        if (captured.refusal != null) {
            captured.deinit(alloc);
            return error.RemoteRefused;
        }
        return .{
            .stdout = captured.stdout,
            .stderr = captured.stderr,
            .exit_code = captured.exit_code,
            .timed_out = captured.timed_out,
        };
    }

    /// One run round under the host's patience. The bound is the request's own
    /// budget plus a margin (the agent enforces the budget next to the process),
    /// or the fixed control bound when the request carries none.
    fn runBounded(
        self: *RemoteEnvironment,
        alloc: std.mem.Allocator,
        req: protocol.Request,
        payload: []const u8,
        timeout_ms: ?u32,
    ) anyerror!Captured {
        var ex: CommandExchange = .{ .ch = &self.ch, .alloc = alloc, .req = req, .payload = payload };

        const bound: u32 = if (timeout_ms) |ms| ms +| self.bounds.reply_grace_ms else self.bounds.control_ms;
        const Race = union(enum) { done: void, expired: void };
        var buf: [2]Race = undefined;
        var sel: std.Io.Select(Race) = .init(self.io, &buf);
        // If the io cannot give the pair their own units of concurrency the
        // exchange runs unguarded: no false failure, just no guard.
        sel.concurrent(.expired, sleepMs, .{ self.io, bound }) catch {
            CommandExchange.run(&ex);
            return ex.out orelse error.Canceled;
        };
        sel.concurrent(.done, CommandExchange.run, .{&ex}) catch {
            sel.cancelDiscard();
            CommandExchange.run(&ex);
            return ex.out orelse error.Canceled;
        };
        const first = sel.await() catch |err| {
            sel.cancelDiscard();
            // The step is being canceled. Tell the far side so it can kill the
            // command NOW; the guaranteed signal is the stdin EOF `deinit`
            // sends a moment later, which is why this one is best-effort.
            self.requestCancel();
            return err;
        };
        sel.cancelDiscard();
        if (ex.out) |settled| return settled;
        // The exchange did not settle. Either it was the one canceled (this
        // whole call is being canceled), or the bound expired with the agent
        // silent — and then what the command did over there is unknown.
        if (first == .done) return error.Canceled;
        self.ch.dead = true;
        return error.RemoteChannelStalled;
    }

    fn requestCancel(self: *RemoteEnvironment) void {
        self.ch.send(.{ .op = protocol.Op.cancel.wire() }, "") catch {};
        self.ch.dead = true;
    }

    /// The extension runs on the far machine, against the far workspace, so
    /// `ext:std/read` and `shell` answer about the same repository.
    ///
    /// Only the identity and the arguments cross. NOT `presentation_file`: who
    /// READS a file decides which machine it lives on, and that one's reader is
    /// the front end, here. A package asked to render over there sees no
    /// presentation file, exactly as when a driver offers none.
    ///
    /// A version that machine does not hold comes back as the agent's own
    /// sentence, answered as a FAILED CALL rather than a host error: it then
    /// reaches the model through the path every failed extension call already
    /// uses (exit code plus stderr), and the usage journal records a true
    /// `ok=false`.
    fn runExtensionImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment_mod.ExtensionRequest) anyerror!environment_mod.ExtensionOutcome {
        const self: *RemoteEnvironment = @ptrCast(@alignCast(ptr));
        const captured = try self.runBounded(alloc, .{
            .op = protocol.Op.run_extension.wire(),
            .id = req.id,
            .version = req.version,
            .tool = req.tool,
            .cwd = self.remoteCwd(),
            .session = self.session_id,
            .timeout_ms = req.timeout_ms,
            .max_output_bytes = req.max_output_bytes,
            .bytes = req.request_json.len,
        }, req.request_json, req.timeout_ms);
        if (captured.refusal) |message| {
            alloc.free(captured.stdout);
            alloc.free(captured.stderr);
            return .{ .stdout = try alloc.alloc(u8, 0), .stderr = message, .exit_code = 1 };
        }
        return .{
            .stdout = captured.stdout,
            .stderr = captured.stderr,
            .exit_code = captured.exit_code,
            .timed_out = captured.timed_out,
        };
    }

    /// Start a background command on the far machine.
    ///
    /// The NAME is claimed here and the WORK happens there: the name is what the
    /// ledger, the receipt and every `task` verb speak, and the ledger is on this
    /// machine; the log, the status file and the lease belong beside the command,
    /// over there. Both sides spell the directory from the same name with the
    /// same rule (`launch.sessionTasksDir`), each against its own workspace — no
    /// path crosses the channel. The host directory claimed here holds what only
    /// this machine can know: a retarget (`notify`) and whether a report has
    /// already been delivered (`cli/task.zig`).
    ///
    /// The task outlives this channel: the far supervisor is detached over there
    /// exactly as one here is, so closing the channel ends the agent and not the
    /// task, and the report is collected by whoever next asks.
    fn startShellTaskImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment_mod.TaskRequest) anyerror!environment_mod.TaskStart {
        const self: *RemoteEnvironment = @ptrCast(@alignCast(ptr));
        const session_path = self.session_path orelse return error.NoDurableSession;
        const tasks_dir = self.tasks_dir orelse return error.NoDurableSession;
        const session_id = std.fs.path.stem(std.fs.path.basename(session_path));
        if (session_id.len == 0) return error.NoDurableSession;

        var claimed = try environment_mod.claimTaskSlot(alloc, self.io, tasks_dir, session_id);
        errdefer claimed.deinit(alloc);

        const rep = self.ch.controlRound(.{
            .op = protocol.Op.start_task.wire(),
            .task = claimed.task_id,
            .cwd = self.remoteCwd(),
            .session = self.session_id,
            .timeout_ms = req.timeout_ms,
            .bytes = req.command.len,
        }, req.command) catch |err| {
            // The claim STAYS. Whether that machine started the task before the
            // channel broke is unknown, and releasing the name would make a task
            // that did start invisible here forever — nothing to poll, nothing
            // to kill. Known narrow gap: `task-poll` answers empty for "no status
            // yet" and "no such task directory over there" alike, so a request
            // that never reached that machine reads `starting` FOREVER, not just
            // until it answers again. `start-task` is not safe to retry — a
            // second spawn is a second supervisor.
            return err;
        };
        if (!rep.ok) {
            // A refusal is definitive: that machine said it did not start it, so
            // the name is released rather than left standing for nothing.
            std.Io.Dir.cwd().deleteTree(self.io, claimed.dir_rel) catch {};
            return error.RemoteTaskRefused;
        }
        return claimed.intoStart(alloc);
    }

    /// Ask the far machine about one of this session's tasks: the two files its
    /// supervisor writes, verbatim. The returned strings live in the channel
    /// arena — valid until the next round on it.
    pub fn pollTask(self: *RemoteEnvironment, task_name: []const u8) anyerror!protocol.TaskSnapshot {
        return pollTaskOn(&self.ch, self.remoteCwd(), task_name);
    }

    pub fn killTask(self: *RemoteEnvironment, task_name: []const u8) anyerror!void {
        return killTaskOn(&self.ch, self.remoteCwd(), task_name);
    }

    /// The bytes cross the channel and the far agent writes them, relative to
    /// THIS session's workspace — the same directory its commands run in, which
    /// is why the frame carries `cwd` as well as the relative path. So a spill
    /// footer names a file the model can open with the very next command it runs.
    fn putWorkspaceFileImpl(ptr: *anyopaque, rel_path: []const u8, bytes: []const u8) anyerror!void {
        const self: *RemoteEnvironment = @ptrCast(@alignCast(ptr));
        const rep = try self.ch.controlRound(.{
            .op = protocol.Op.put_file.wire(),
            .cwd = self.remoteCwd(),
            .path = rel_path,
            .bytes = bytes.len,
        }, bytes);
        // A refusal is the far side's own sentence about its own file system,
        // and the caller (`emit`) treats a failed spill exactly as it treats a
        // failed local write: it does not pretend the file is there.
        if (!rep.ok) return error.RemoteRefused;
    }

    const vtable: environment_mod.Environment.VTable = .{
        .dialect = dialectImpl,
        .runShell = runShellImpl,
        .runExtension = runExtensionImpl,
        .startShellTask = startShellTaskImpl,
        .putWorkspaceFile = putWorkspaceFileImpl,
    };
};

// ── tests ───────────────────────────────────────────────────────────────────

test "the remote vocabulary parses into three launchers, and nothing else does" {
    try std.testing.expectEqualStrings("", (try parseSpec("remote:wsl")).wsl);
    try std.testing.expectEqualStrings("Ubuntu-22.04", (try parseSpec("remote:wsl:Ubuntu-22.04")).wsl);
    try std.testing.expectEqualStrings("me@box", (try parseSpec("remote:ssh:me@box")).ssh);
    try std.testing.expectEqualStrings("/bin/nulya", (try parseSpec("remote:exec:/bin/nulya")).exec);

    // A prefix with nothing after it names no machine: refused rather than read
    // as "the default one" — the colon says something was meant to follow.
    for ([_][]const u8{ "remote:", "remote:wsl:", "remote:ssh:", "remote:exec:", "remote:exec:   ", "remote:podman:x", "remote" }) |bad| {
        try std.testing.expectError(error.InvalidRemoteSpec, parseSpec(bad));
    }

    // The older exec-target words are NOT this backend. Two points on one axis,
    // two vocabularies; conflating them is what the prefix prevents.
    for ([_][]const u8{ "", "local", "wsl", "wsl:Ubuntu", "ssh:me@box" }) |other| {
        try std.testing.expect(!isSpec(other));
        try std.testing.expectError(error.InvalidRemoteSpec, parseSpec(other));
    }
}

test "each launcher argv starts an agent, and every form ends in `remote serve`" {
    const alloc = std.testing.allocator;

    const ssh = try launcherArgv(alloc, .{ .ssh = "me@box" }, false);
    defer alloc.free(ssh);
    try std.testing.expectEqualStrings("ssh", ssh[0]);
    // The destination is its own word — never interpolated into a command.
    try std.testing.expectEqualStrings("me@box", ssh[3]);
    try std.testing.expectEqualStrings("remote", ssh[ssh.len - 2]);
    try std.testing.expectEqualStrings("serve", ssh[ssh.len - 1]);

    const password_ssh = try launcherArgv(alloc, .{ .ssh = "me@box" }, true);
    defer alloc.free(password_ssh);
    var has_batch_no = false;
    var has_one_prompt = false;
    var has_batch_yes = false;
    for (password_ssh) |word| {
        has_batch_no = has_batch_no or std.mem.eql(u8, word, "BatchMode=no");
        has_one_prompt = has_one_prompt or std.mem.eql(u8, word, "NumberOfPasswordPrompts=1");
        has_batch_yes = has_batch_yes or std.mem.eql(u8, word, "BatchMode=yes");
    }
    try std.testing.expect(has_batch_no);
    try std.testing.expect(has_one_prompt);
    try std.testing.expect(!has_batch_yes);
    // The password has no argv slot at all; only fixed options and destination
    // differ from the non-interactive launcher.
    try std.testing.expectEqualStrings("me@box", password_ssh[5]);

    const wsl = try launcherArgv(alloc, .{ .wsl = "Ubuntu" }, false);
    defer alloc.free(wsl);
    try std.testing.expectEqualStrings("-d", wsl[1]);
    try std.testing.expectEqualStrings("Ubuntu", wsl[2]);
    const wsl_default = try launcherArgv(alloc, .{ .wsl = "" }, false);
    defer alloc.free(wsl_default);
    // No distro named: two fewer words, and no empty one left behind.
    try std.testing.expectEqual(wsl.len - 2, wsl_default.len);

    // `exec:` is the general form: the words are the caller's, the suffix ours.
    const exec = try launcherArgv(alloc, .{ .exec = "docker exec -i box /usr/bin/nulya" }, false);
    defer alloc.free(exec);
    try std.testing.expectEqualStrings("docker", exec[0]);
    try std.testing.expectEqualStrings("/usr/bin/nulya", exec[exec.len - 3]);
    try std.testing.expectEqualStrings("remote", exec[exec.len - 2]);
}

test "wsl is reachable only from Windows, and the other two from anywhere" {
    try std.testing.expect(supportedOnHost(.{ .ssh = "h" }));
    try std.testing.expect(supportedOnHost(.{ .exec = "x" }));
    try std.testing.expectEqual(builtin.os.tag == .windows, supportedOnHost(.{ .wsl = "" }));
}
