//! The second `Environment` implementation: the session's commands run on
//! ANOTHER machine through one long-lived channel to a `nulya remote serve`
//! there — the workspace MOVES too, and the channel opens once per session.
//!
//! All four verbs cross it. `startShellTask` starts a `nulya task supervise`
//! there, so a background command outlives this channel; its report is carried
//! back by whoever next asks, since the ledger is here. `runExtension` sends an
//! IDENTITY — `(id, version, tool)` plus the arguments — because only the machine
//! holding the bytes can say which file a version means. `putWorkspaceFile` lands
//! spilled bytes in the far workspace at the path the model is told to open.
//!
//! The far side is nulya itself in a shell role: the process-tree kill, the
//! secret denylist, the wall-clock budget and the output capture over there are
//! THE SAME CODE as here. Nothing on the channel carries a credential.

const std = @import("std");
const builtin = @import("builtin");
const environment = @import("../../environment.zig");
/// The same module under a second name: `RemoteEnvironment.environment()`
/// shadows the file-scope import inside that struct's body.
const environment_mod = environment;
const protocol = @import("protocol.zig");
const ssh_askpass = @import("ssh_askpass.zig");
const install = @import("install.zig");
const target_mod = @import("../../extension/target.zig");
const Diag = @import("../../diag.zig").Diag;

/// What marks a `--env` spec as naming this backend rather than the local
/// one. One prefix, checked in one place.
pub const spec_prefix = "remote:";

/// The vocabulary, in the one place a refusal can quote it.
pub const spec_syntax = "remote:wsl | remote:wsl:<distro> | remote:ssh:<destination> | remote:exec:<argv…>";

pub const Error = error{
    InvalidRemoteSpec,
    /// The spec parses but this host has no way to reach that machine.
    RemoteSpecUnsupportedOnHost,
    /// The channel is gone. Never folded together with a command's own failure:
    /// what the command did on that machine is then UNKNOWN.
    RemoteChannelLost,
    /// The agent did not answer within the host's bound. Same honesty as above.
    RemoteChannelStalled,
    /// The far side speaks another protocol version (protocol.zig rule 4).
    RemoteVersionMismatch,
    /// The agent named a shell dialect this build does not know. Refused, not
    /// guessed.
    RemoteDialectUnknown,
    /// The agent refused the request and said why.
    RemoteRefused,
    /// The far machine would not start the background task. Its own sentence
    /// does NOT survive: `startShellTask` answers a `TaskStart` or an error,
    /// with no failed-call shape to carry words in.
    RemoteTaskRefused,
    /// The far machine would not say what it is, so nothing may be sent to it.
    RemoteTargetUnknown,
    /// That machine is a machine this build has no binary for. Not a failure of
    /// the far side: a failure to have the bytes here.
    RemoteNoBuildForTarget,
    /// The agent over there works, and is built from other source than this
    /// binary. Not a protocol failure — a question about WHICH nulya is serving.
    RemoteAgentStale,
    /// The bytes were sent and the far side did not end up with a runnable
    /// agent. Distinct from a lost channel: something answered, and refused.
    RemoteInstallFailed,
    /// The transport never reached the machine at all — ssh could not connect,
    /// resolve, or authenticate. Separate from a lost channel because nothing
    /// on the far side can be wrong yet, so nothing there is worth retrying.
    RemoteTransportFailed,
};

/// How to start the agent. The payload borrows the spec string, so a parsed
/// value never outlives it.
pub const Launch = union(enum) {
    /// `wsl.exe [-d <distro>] -e sh -c <the serve command>`; empty payload = the
    /// default distribution.
    wsl: []const u8,
    /// `ssh -o BatchMode=yes <destination> <the serve command>`.
    ssh: []const u8,
    /// The general form: the payload IS the command that starts a process on
    /// that machine, and `remote serve` is appended to it.
    exec: []const u8,
};

pub fn isSpec(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, spec_prefix);
}

pub fn isSshSpec(spec: []const u8) bool {
    const parsed = parseSpec(spec) catch return false;
    return parsed == .ssh;
}

/// Pure syntax. Whether THIS host can reach it is `supportedOnHost`.
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
/// `entry` decides WHICH nulya over there answers, and the named transports say
/// so by handing the far shell one command instead of a bare program name
/// (`install.serveCommand`). `exec:` has no room for that choice: its payload IS
/// the program, spelled by the person who wrote the spec, split on spaces with
/// NO quoting — a program path containing a space cannot be spelled that way.
pub fn launcherArgv(
    alloc: std.mem.Allocator,
    launch: Launch,
    password: bool,
    entry: install.Entry,
    control: ?[]const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    switch (launch) {
        .wsl => |distro| {
            try argv.append(alloc, "wsl.exe");
            if (distro.len != 0) try argv.appendSlice(alloc, &.{ "-d", distro });
            // `-e` runs the argv directly rather than through the login shell,
            // so the command needs a shell of its own to be a command at all.
            try argv.appendSlice(alloc, &.{ "-e", "sh", "-c", install.serveCommand(entry) });
        },
        .ssh => |dest| {
            // SSH stdin is always the framing channel, so password mode forces
            // the askpass helper; the default stays non-interactive.
            try argv.appendSlice(alloc, &.{ "ssh", "-o", if (password) "BatchMode=no" else "BatchMode=yes" });
            if (password) try argv.appendSlice(alloc, &.{ "-o", "NumberOfPasswordPrompts=1" });
            try appendControl(alloc, &argv, control);
            // One argv word: ssh joins what follows the destination with spaces
            // and the far login shell parses the result, so the whole command
            // has to arrive as a single word to survive that round trip.
            try argv.appendSlice(alloc, &.{ dest, install.serveCommand(entry) });
        },
        .exec => |words| {
            var it = std.mem.splitScalar(u8, words, ' ');
            while (it.next()) |w| {
                if (w.len != 0) try argv.append(alloc, w);
            }
            try argv.appendSlice(alloc, &.{ "remote", "serve" });
        },
    }
    return argv.toOwnedSlice(alloc);
}

/// The argv that runs ONE ordinary shell command over there and comes back.
///
/// Not a frame and not the agent: this is what opens the door before there is
/// an agent to speak frames to — asking a machine what it is, and landing a
/// binary on it. `exec:` is refused because its payload names a program, and
/// there is no way to ask that program to be a shell instead.
pub fn farCommandArgv(
    alloc: std.mem.Allocator,
    launch: Launch,
    password: bool,
    command: []const u8,
    control: ?[]const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    switch (launch) {
        .wsl => |distro| {
            try argv.append(alloc, "wsl.exe");
            if (distro.len != 0) try argv.appendSlice(alloc, &.{ "-d", distro });
            try argv.appendSlice(alloc, &.{ "-e", "sh", "-c", command });
        },
        .ssh => |dest| {
            try argv.appendSlice(alloc, &.{ "ssh", "-o", if (password) "BatchMode=no" else "BatchMode=yes" });
            if (password) try argv.appendSlice(alloc, &.{ "-o", "NumberOfPasswordPrompts=1" });
            try appendControl(alloc, &argv, control);
            try argv.appendSlice(alloc, &.{ dest, command });
        },
        .exec => return error.InvalidRemoteSpec,
    }
    return argv.toOwnedSlice(alloc);
}

/// What the far side said about itself at `hello`. Owned by the channel's arena.
pub const Hello = struct {
    nulya: []const u8 = "",
    os: []const u8 = "",
    arch: []const u8 = "",
    home: []const u8 = "",
    /// The directory the agent started in — the workspace a session with no
    /// `--workspace` will use.
    cwd: []const u8 = "",
    dialect: []const u8 = "",
};

/// How long the host waits before deciding the agent is not answering.
///
/// A deadline, NOT a byte-level heartbeat: a legitimate ten-minute build is
/// silent on this channel. The agent's contract is one reply per request within
/// that request's own timeout, so the host's patience is that timeout plus a
/// margin, and a fixed value only where the request carries none.
pub const Bounds = struct {
    /// For a request with no budget of its own (`hello`, `list-dir`). Generous:
    /// opening an ssh connection on a cold link is not fast.
    control_ms: u32 = 60_000,
    /// Added to a command's own budget, which the agent enforces next to the
    /// process; this margin only catches an agent that stopped talking.
    reply_grace_ms: u32 = 60_000,

    /// A parameter rather than two constants, so a test or a driver on a slow
    /// link can change them.
    pub const default: Bounds = .{};
};

/// Everything a connection attempt needs beyond the spec itself.
///
/// A struct rather than four parameters because two of them — whether nulya may
/// put itself on that machine, and where the story of doing so is told — are
/// decisions of the shell layer, and every call site that has an opinion about
/// one usually has an opinion about the other.
pub const Options = struct {
    version: []const u8,
    bounds: Bounds = .default,
    /// Transient, owned by the caller, wiped by the caller.
    ssh_password: ?[]const u8 = null,
    /// May this build put a copy of itself on the far machine when no agent
    /// answers, or when the one there speaks another protocol?
    install: Install = .never,
    /// How to obtain a nulya for a far machine this build's own bytes cannot
    /// serve. Null refuses that machine instead — which is what a caller that
    /// has not opted into installing wants anyway.
    build_agent: ?AgentBuilder = null,
    /// Where ssh's multiplexing sockets may live, asked at most once per
    /// connect and only for an `ssh` launch. Null — and a provider answering
    /// null — means each connection authenticates and dials on its own.
    ssh_control_dir: ?ControlDir = null,
    /// Which build this side is (`selfbuild.build_id`). An agent answering with
    /// a different one is serving another source tree, and — when installing is
    /// allowed — is replaced. Empty compares equal to everything, so a caller
    /// that does not care is not made to.
    build_id: []const u8 = "",
    /// Where the ladder narrates what it is doing. Silent by default: a library
    /// path does not choose a destination for its own sentences.
    diag: Diag = .{},
};

/// Whether the far machine may be changed to make a session possible.
pub const Install = enum { never, auto };

/// How the shell layer produces a nulya for `for_target`.
///
/// A function rather than a path because producing one may mean COMPILING for
/// about a minute — so it is called only after the far machine has said it is
/// something else, and the sentences explaining that wait are its own to write.
/// The result is an absolute path to a runnable binary; the caller owns it.
/// Any error means "no binary for that machine", the reason having gone to the
/// diag it was handed.
pub const AgentBuilder = *const fn (
    alloc: std.mem.Allocator,
    io: std.Io,
    for_target: install.Target,
    diag: Diag,
) anyerror![]u8;

/// Where the shell layer will let ssh keep its multiplexing sockets — an
/// absolute directory that exists, or null for "not on this machine".
///
/// A function for the same reason `AgentBuilder` is one: answering means making
/// a directory and knowing where this machine keeps nulya's things, and neither
/// is a question the kernel gets to have an opinion about. Caller owns the
/// result.
pub const ControlDir = *const fn (alloc: std.mem.Allocator, io: std.Io) anyerror!?[]u8;

/// How long ssh keeps a shared connection alive after the last thing that used
/// it. An IDLE timer, refreshed by every reuse — so nothing here has to notice
/// a closed terminal or a finished session: the door shuts by itself this long
/// after the last person walks through it.
///
/// A minute covers what the cost was actually being paid on — a directory
/// browsed a level at a time, a `remote check` and the `session new` right
/// after it, a run of quick steps. It deliberately does NOT try to span the
/// minutes between one model turn and the next: re-dialing costs about a
/// second and needs no one's attention (the driver still holds the password),
/// while a shared connection that outlives the work is, on a password-authed
/// host, exactly a way past the password.
const control_persist_seconds = 60;

/// How many characters `controlOption` puts after the directory it is given —
/// a separator and the digest. Exported because the shell layer has to leave
/// room for it, and a length budget split across two files is a length budget
/// one of them will get wrong.
pub const control_name_bytes = 1 + 16;

/// Read exactly one password line from a CLI stdin stream. The caller owns the
/// mutable result and must wipe it before freeing; the reader stays outside so
/// `session step --gate` can keep consuming verdict lines afterwards.
///
/// "One line" INCLUDES its newline. `takeDelimiterExclusive` leaves the
/// delimiter buffered, and the next reader of this stream is the gate, which
/// reads a line per tool call: a `\n` left behind is an empty first verdict,
/// which is not a word the gate knows and therefore a denial of a call nobody
/// was asked about.
pub fn readSshPassword(alloc: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return error.SshPasswordMissing,
        else => return err,
    };
    // Only reached when the delimiter was found, so there is exactly one byte
    // of it sitting there.
    reader.toss(1);
    const password = std.mem.trimEnd(u8, line, "\r");
    if (password.len == 0) return error.SshPasswordMissing;
    if (password.len > ssh_askpass.max_password_bytes) return error.SshPasswordTooLong;
    return alloc.dupe(u8, password);
}

/// The three options that make several `ssh` invocations share ONE connection.
///
/// `control` is the whole `ControlPath=…` word, built by the caller and outliving
/// the argv, because every other word here is a literal or a subslice of the
/// spec and one allocated word would make that contract a maybe.
fn appendControl(alloc: std.mem.Allocator, argv: *std.ArrayList([]const u8), control: ?[]const u8) !void {
    const path = control orelse return;
    try argv.appendSlice(alloc, &.{
        "-o", "ControlMaster=auto",
        "-o", path,
        "-o", std.fmt.comptimePrint("ControlPersist={d}", .{control_persist_seconds}),
    });
}

/// The `ControlPath=…` word for one destination, or null when the shell layer
/// offers nowhere to put a socket. Caller owns the result.
///
/// The socket's NAME is a digest nulya computes rather than ssh's own `%C`,
/// because this is a unix socket and the limit is about a hundred bytes: `%C`'s
/// length is the implementation's business, and a path over the limit costs a
/// warning on every single connection — which is how a speedup becomes noise.
/// Only `ssh` has any of this; `wsl` starts a process on this machine and
/// `exec:`'s payload is a program somebody else wrote.
fn controlOption(alloc: std.mem.Allocator, io: std.Io, launch: Launch, opts: Options) !?[]u8 {
    const dest = switch (launch) {
        .ssh => |d| d,
        else => return null,
    };
    const provider = opts.ssh_control_dir orelse return null;
    const dir = (try provider(alloc, io)) orelse return null;
    defer alloc.free(dir);

    var h = std.crypto.hash.Blake3.init(.{});
    h.update(dest);
    var digest: [control_name_bytes / 2]u8 = undefined;
    h.final(&digest);
    return try std.fmt.allocPrint(alloc, "ControlPath={s}{c}{x}", .{ dir, std.fs.path.sep, &digest });
}

/// One open channel to an agent: the transport child plus the framing.
pub const Channel = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    read_buf: []u8,
    reader: std.Io.File.Reader,
    argv: []const []const u8,
    /// The one word of `argv` this channel had to allocate (`ControlPath=…`),
    /// kept so that every word in `argv` really does outlive it.
    control: ?[]u8 = null,
    env: std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    bounds: Bounds = .default,
    hello: Hello = .{},
    /// The last `controlRound` reply's payload, in the channel arena — valid
    /// until the next round resets it.
    last_payload: []const u8 = &.{},
    /// Once true, nothing more is sent or read: a desynchronised channel that
    /// keeps being used answers questions with another request's reply.
    dead: bool = false,

    /// Start the agent and complete the handshake, or fail with a sentence the
    /// caller can print. The transport's own stderr is INHERITED, so `ssh`'s
    /// "Permission denied (publickey)" reaches the operator.
    pub fn connect(alloc: std.mem.Allocator, io: std.Io, launch: Launch, version: []const u8, bounds: Bounds) anyerror!Channel {
        return connectWith(alloc, io, launch, .{ .version = version, .bounds = bounds });
    }

    pub fn connectPassword(alloc: std.mem.Allocator, io: std.Io, launch: Launch, version: []const u8, bounds: Bounds, password: ?[]const u8) anyerror!Channel {
        return connectWith(alloc, io, launch, .{ .version = version, .bounds = bounds, .ssh_password = password });
    }

    /// The ladder: ask the far machine for an agent, and — when allowed — make
    /// there be one.
    ///
    /// Three rungs, and the ordinary case stops on the first:
    ///
    ///   1. the command that prefers nulya's own copy and falls back to PATH;
    ///   2. bare `nulya` on PATH, for a far side whose shell did not understand
    ///      rung 1 (a peer greeting commands with something other than a POSIX
    ///      shell answered to this before installs existed, and still must);
    ///   3. install this build's own bytes over there, then rung 1 again.
    ///
    /// A version mismatch jumps straight to rung 3: the agent is there and it
    /// is the wrong one, so there is nothing to look for on PATH.
    ///
    /// The askpass broker is opened ONCE around the whole ladder, so a password
    /// the person typed is asked for once however many connections this takes.
    pub fn connectWith(alloc: std.mem.Allocator, io: std.Io, launch: Launch, opts: Options) anyerror!Channel {
        if (!supportedOnHost(launch)) return error.RemoteSpecUnsupportedOnHost;
        if (opts.ssh_password != null and launch != .ssh) return error.InvalidRemoteSpec;

        var broker: ?ssh_askpass.Broker = null;
        defer if (broker) |*one| one.deinit();
        var marker: ?[]const u8 = null;
        if (opts.ssh_password) |secret| {
            broker = try .init(io, secret);
            broker.?.start();
            marker = broker.?.marker();
        }

        // Computed ONCE and used by every connection this call makes — the
        // ladder's rungs, the `uname` probe, the install — because sharing one
        // ssh connection between them is the entire point: the first dials and
        // authenticates, the rest arrive on what it opened.
        const control = try controlOption(alloc, io, launch, opts);
        defer if (control) |word| alloc.free(word);

        // `exec:` names a program, not a shell: there is nothing to install
        // into and no second spelling to try.
        const may_install = opts.install == .auto and launch != .exec;

        if (attemptOnce(alloc, io, launch, marker, .installed_or_path, opts, control)) |ch| {
            return ch;
        } else |first| switch (first) {
            error.RemoteChannelLost => {},
            error.RemoteVersionMismatch, error.RemoteAgentStale => {
                if (!may_install) return first;
                opts.diag.report(io, if (first == error.RemoteAgentStale)
                    "the nulya over there was built from other source; replacing it\n"
                else
                    "the nulya over there speaks another protocol; replacing it\n");
                try installAgent(alloc, io, launch, marker, opts, control);
                return attemptOnce(alloc, io, launch, marker, .installed_or_path, opts, control);
            },
            else => return first,
        }

        // `exec:` ignores `entry` — its argv IS the program — so rung two
        // would ask the identical question a second time.
        if (launch != .exec) {
            if (attemptOnce(alloc, io, launch, marker, .path, opts, control)) |ch| {
                return ch;
            } else |second| switch (second) {
                error.RemoteChannelLost => {},
                else => return second,
            }
        }

        if (!may_install) return error.RemoteChannelLost;
        opts.diag.report(io, "no nulya on that machine; installing one\n");
        try installAgent(alloc, io, launch, marker, opts, control);
        return attemptOnce(alloc, io, launch, marker, .installed_or_path, opts, control);
    }

    pub fn deinit(self: *Channel) void {
        // Closing stdin FIRST: EOF tells the agent to kill whatever it is
        // running and exit. Killing the transport first leaves it unsent.
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
        if (self.control) |word| self.alloc.free(word);
        self.* = undefined;
    }

    pub fn send(self: *Channel, req: protocol.Request, payload: []const u8) anyerror!void {
        // The peer refuses an oversized claimed length before allocating, but
        // by then the channel is dead. So never WRITE such a frame.
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

    /// A canceled read is THIS STEP being canceled, not the channel dying.
    /// `std.Io.Reader` folds every underlying fault into `ReadFailed` and keeps
    /// the real one in `reader.err`, so this is the only place to tell them
    /// apart.
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
            // The stream is no longer this protocol; no resynchronising.
            self.dead = true;
            return error.RemoteChannelLost;
        };
    }

    fn readExact(self: *Channel, dest: []u8) anyerror!void {
        if (dest.len == 0) return;
        self.reader.interface.readSliceAll(dest) catch return self.readFailure();
    }

    /// One round that is not a command — `hello`, `list-dir`, `put-file` — under
    /// the host's patience. The reply's payload is left in `last_payload`.
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
        // A reply's payload is ALWAYS consumed: bytes left in the stream would
        // desynchronise every later frame.
        if (rep.bytes != 0) {
            const body = try self.arena.allocator().alloc(u8, rep.bytes);
            try self.readExact(body);
            self.last_payload = body;
        }
        return rep;
    }
};

/// The transport's environment: the stripped host map, plus the askpass wiring
/// when a password is in play. Built fresh per attempt because a `Channel` owns
/// the map it was spawned with.
fn transportEnv(alloc: std.mem.Allocator, io: std.Io, marker: ?[]const u8) !std.process.Environ.Map {
    // The stripped map, so there is no secret for `SendEnv` / `WSLENV` to
    // forward even if someone configured them to.
    var env = try environment.sanitizedChildEnv(alloc, io);
    errdefer env.deinit();
    if (marker) |m| {
        const helper = env.get("NULYA_EXE") orelse return error.RemoteChannelLost;
        try env.put("SSH_ASKPASS", helper);
        try env.put("SSH_ASKPASS_REQUIRE", "force");
        try env.put(ssh_askpass.marker_env, m);
    }
    return env;
}

/// One rung of the ladder: start the agent this way and complete the handshake.
fn attemptOnce(
    alloc: std.mem.Allocator,
    io: std.Io,
    launch: Launch,
    marker: ?[]const u8,
    entry: install.Entry,
    opts: Options,
    control: ?[]const u8,
) anyerror!Channel {
    // A copy per channel: the caller's word is freed when its ladder ends, and
    // a channel outlives that.
    const control_owned: ?[]u8 = if (control) |word| try alloc.dupe(u8, word) else null;
    errdefer if (control_owned) |word| alloc.free(word);
    const argv = try launcherArgv(alloc, launch, marker != null, entry, control_owned);
    errdefer alloc.free(argv);

    var env = try transportEnv(alloc, io, marker);
    errdefer env.deinit();

    var child = std.process.spawn(io, .{
        .argv = argv,
        // The stripped map, explicitly: without it the transport, the agent
        // and every command it runs inherit this environment whole.
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .create_no_window = true,
    }) catch return error.RemoteChannelLost;
    // Killing a process that was already waited for would signal whatever pid
    // the system handed out next, so the two paths that can end this child are
    // exclusive by construction.
    var reaped = false;
    errdefer if (!reaped) child.kill(io);

    const read_buf = try alloc.alloc(u8, protocol.max_header_bytes);
    errdefer alloc.free(read_buf);

    var ch: Channel = .{
        .alloc = alloc,
        .io = io,
        .child = child,
        .read_buf = read_buf,
        .reader = child.stdout.?.readerStreaming(io, read_buf),
        .argv = argv,
        .control = control_owned,
        .env = env,
        .arena = .init(alloc),
        .bounds = opts.bounds,
    };
    errdefer ch.arena.deinit();

    const rep = ch.controlRound(.{ .op = protocol.Op.hello.wire(), .v = protocol.version, .nulya = opts.version }, "") catch |err| {
        if (err == error.RemoteChannelLost) return transportVerdict(&ch, launch, &reaped);
        return err;
    };
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
    // The protocol matches, so this agent WORKS — it is just built from other
    // source, which is a different question and gets a different answer.
    if (opts.build_id.len != 0 and rep.build.len != 0 and !std.mem.eql(u8, opts.build_id, rep.build)) {
        ch.dead = true;
        return error.RemoteAgentStale;
    }
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

/// Nothing greeted us: was that the machine, or the way there?
///
/// OpenSSH answers 255 for its own failures and passes anything else through
/// from the command it ran, so an unreachable host is one exit code and a far
/// side with no nulya on it (127 from that shell) is another. Worth telling
/// apart: the ladder's remaining rungs all ask the same machine the same
/// question, and asking a host that is down three times only makes the wait
/// three times as long.
fn transportVerdict(ch: *Channel, launch: Launch, reaped: *bool) anyerror {
    ch.dead = true;
    if (launch != .ssh) return error.RemoteChannelLost;
    // Closing stdin first: the transport is gone or going, and a held write end
    // is the one thing that can keep a wait from returning.
    if (ch.child.stdin) |stdin| {
        var f = stdin;
        f.close(ch.io);
        ch.child.stdin = null;
    }
    const term = ch.child.wait(ch.io) catch return error.RemoteChannelLost;
    reaped.* = true;
    return switch (term) {
        .exited => |code| if (code == 255) error.RemoteTransportFailed else error.RemoteChannelLost,
        else => error.RemoteChannelLost,
    };
}

/// Put this build's own binary on the far machine.
///
/// Ask that machine what it is, then hand it a binary built for it: the bytes
/// this process was started from when it is the same machine, and otherwise
/// whatever `opts.build_agent` produces. Only the second case compiles anything,
/// and nothing is ever fetched — a nulya binary is statically linked and carries
/// everything it ships, its own checkout included.
fn installAgent(
    alloc: std.mem.Allocator,
    io: std.Io,
    launch: Launch,
    marker: ?[]const u8,
    opts: Options,
    control: ?[]const u8,
) anyerror!void {
    var probe_buf: [512]u8 = undefined;
    const probe = try runFar(alloc, io, launch, marker, install.probe_command, "", &probe_buf, control);
    const far = install.parseUname(probe_buf[0..probe.out_len]) orelse {
        opts.diag.reportFmt(io, "that machine calls itself \"{s}\", which this build has no binary for\n", .{
            std.mem.trim(u8, probe_buf[0..probe.out_len], " \t\r\n"),
        });
        return error.RemoteTargetUnknown;
    };

    // The same machine needs no build: the bytes this process was started from
    // ARE the ones that belong over there.
    const built: ?[]u8 = if (install.isHost(far)) null else blk: {
        const make = opts.build_agent orelse {
            opts.diag.reportFmt(io, "that machine is {s} and this nulya is {s}: no binary to send\n", .{
                far.words(), target_mod.host,
            });
            return error.RemoteNoBuildForTarget;
        };
        opts.diag.reportFmt(io, "that machine is {s} and this nulya is {s}\n", .{ far.words(), target_mod.host });
        break :blk make(alloc, io, far, opts.diag) catch return error.RemoteNoBuildForTarget;
    };
    defer if (built) |path| alloc.free(path);

    const own: ?[]u8 = if (built == null)
        (std.process.executablePathAlloc(io, alloc) catch return error.RemoteInstallFailed)
    else
        null;
    defer if (own) |path| alloc.free(path);

    const exe = built orelse own.?;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, exe, alloc, .limited(max_agent_bytes)) catch {
        return error.RemoteInstallFailed;
    };
    defer alloc.free(bytes);

    opts.diag.reportFmt(io, "sending a nulya ({d} MB) to {s}\n", .{ bytes.len / (1024 * 1024), far.words() });
    var sink: [256]u8 = undefined;
    const landed = try runFar(alloc, io, launch, marker, install.install_command, bytes, &sink, control);
    if (landed.exit_code != 0) return error.RemoteInstallFailed;
    opts.diag.reportFmt(io, "installed at {s}\n", .{install.far_exe});
}

/// The most a far agent may weigh. A guard on a path that reads a file and
/// writes it down someone else's pipe, not a budget anyone tunes.
const max_agent_bytes: usize = 256 * 1024 * 1024;

/// Run one ordinary command over there, hand it `stdin_bytes`, and keep the
/// first `out.len` bytes it printed.
///
/// The far side of this is `cat` or `uname`: one of them says almost nothing and
/// the other is handed nothing, so writing all of stdin before reading any of
/// stdout cannot deadlock here. A far side that floods stdout while refusing to
/// read stdin would be a machine no session could use anyway.
fn runFar(
    alloc: std.mem.Allocator,
    io: std.Io,
    launch: Launch,
    marker: ?[]const u8,
    command: []const u8,
    stdin_bytes: []const u8,
    out: []u8,
    control: ?[]const u8,
) anyerror!struct { exit_code: u8, out_len: usize } {
    const argv = try farCommandArgv(alloc, launch, marker != null, command, control);
    defer alloc.free(argv);

    var env = try transportEnv(alloc, io, marker);
    defer env.deinit();

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .create_no_window = true,
    }) catch return error.RemoteChannelLost;
    errdefer child.kill(io);

    if (child.stdin) |stdin| {
        var f = stdin;
        if (stdin_bytes.len != 0) f.writeStreamingAll(io, stdin_bytes) catch {};
        // EOF is what tells `cat` the file is whole.
        f.close(io);
        child.stdin = null;
    }

    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &read_buf);
    var filled: usize = 0;
    while (filled < out.len) {
        const n = reader.interface.readSliceShort(out[filled..]) catch break;
        if (n == 0) break;
        filled += n;
    }
    // Whatever did not fit is drained, or the child can block on a full pipe.
    var drain: [4096]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&drain) catch break;
        if (n == 0) break;
    }

    const term = child.wait(io) catch return error.RemoteChannelLost;
    return .{
        .exit_code = switch (term) {
            .exited => |code| code,
            else => 1,
        },
        .out_len = filled,
    };
}

/// One payload-free round, as a task, so the bound above can race it. A canceled
/// task leaves `out` null: "did not settle" rather than "settled badly".
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
/// verbs — the reply frame does not distinguish them either.
const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    timed_out: bool,
    /// The agent refused the request, in its own words (owned). The two callers
    /// answer it differently: a refused SHELL is a host fault, a refused
    /// EXTENSION an ordinary failed call the model gets to read.
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
        // A canceled exchange leaves `out` null: the task did not settle.
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
// These take a `*Channel` rather than a `RemoteEnvironment` because
// `nulya task list` has no session environment, only a machine to ask.

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

/// Put the kill marker down over there. A marker rather than a signal, as here:
/// the supervisor owns the process tree and picks it up at its next poll.
pub fn killTaskOn(ch: *Channel, cwd: []const u8, task_name: []const u8) anyerror!void {
    const rep = try ch.controlRound(.{
        .op = protocol.Op.task_kill.wire(),
        .task = task_name,
        .cwd = cwd,
    }, "");
    if (!rep.ok) return error.RemoteRefused;
}

/// The `Environment` backed by a channel. Fixed shape: nothing grows with the
/// conversation.
pub const RemoteEnvironment = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    ch: Channel,
    /// The spec this was built from, owned — what a refusal names.
    spec: []u8,
    /// The absolute directory on the far side this session works in, owned.
    /// Empty means "wherever the agent started", which `hello` reported.
    workspace: []u8,
    /// This session's IDENTITY, owned, published to everything the agent runs as
    /// `NULYA_SESSION_ID` — never the session file's path, which names a file on
    /// the host. Empty until a driver publishes one.
    session_id: []u8 = &.{},
    /// The session background tasks belong to, copied. Both halves stay on the
    /// HOST even though the command will not: the far machine holds the log and
    /// the status, this one the name and the delivery. Null = no session.
    session_path: ?[]u8 = null,
    tasks_dir: ?[]u8 = null,
    dialect_val: environment_mod.Dialect,
    bounds: Bounds = .default,
    /// Where THIS machine keeps extension versions, copied. Only the members
    /// that land here need it; empty means none can.
    ext_store: []u8 = &.{},
    /// The members whose calls stay on this machine. Absent until the shell
    /// layer says which those are, which it cannot do before composition has
    /// answered — so an extension call arriving before that crosses the
    /// channel, as every call did before.
    host_side: ?HostSide = null,

    /// The members landing beside the session, and the backend they run
    /// through: the ordinary local one, so there is a single implementation of
    /// "spawn a frozen version on this machine".
    const HostSide = struct {
        ids: [][]u8,
        env: environment_mod.LocalEnvironment,
    };

    pub const ConnectOptions = struct {
        spec: []const u8,
        /// The absolute directory on that machine this session works in; empty
        /// means wherever the agent started.
        workspace: []const u8 = "",
        /// This build's version string, for the handshake's diagnostic half.
        version: []const u8 = "",
        /// The durable session this environment's background tasks belong to;
        /// the shell layer computes both halves.
        session: ?environment_mod.SessionRef = null,
        /// Where THIS machine keeps extension versions. Which version means
        /// which file over THERE is the far agent's own answer; this is for the
        /// members that never go there (`useHostSide`).
        extension_store: []const u8 = "",
        /// Transient SSH password, owned and wiped by the caller.
        ssh_password: ?[]const u8 = null,
        /// May nulya put a copy of itself on that machine to make this session
        /// possible? The shell layer decides; the kernel only carries it.
        install: Install = .never,
        /// Passed straight through: which machine the far side is, and so
        /// which binary it needs, is the channel's question to ask.
        build_agent: ?AgentBuilder = null,
        /// Which build this side is; see `Options.build_id`.
        build_id: []const u8 = "",
        /// Where ssh may share one connection; see `Options.ssh_control_dir`.
        ssh_control_dir: ?ControlDir = null,
        /// Where the connect ladder narrates itself. Silent by default.
        diag: Diag = .{},
        bounds: Bounds = .default,
    };

    pub fn connect(
        alloc: std.mem.Allocator,
        io: std.Io,
        opts: ConnectOptions,
    ) anyerror!RemoteEnvironment {
        const spec = opts.spec;
        const launch = try parseSpec(spec);
        var ch = try Channel.connectWith(alloc, io, launch, .{
            .version = opts.version,
            .bounds = opts.bounds,
            .ssh_password = opts.ssh_password,
            .install = opts.install,
            .build_agent = opts.build_agent,
            .build_id = opts.build_id,
            .ssh_control_dir = opts.ssh_control_dir,
            .diag = opts.diag,
        });
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
        const ext_store = try alloc.dupe(u8, opts.extension_store);
        errdefer alloc.free(ext_store);

        // The far side says which shell reads its commands. A word this build
        // does not know is refused, never guessed.
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
            .ext_store = ext_store,
        };
    }

    pub fn deinit(self: *RemoteEnvironment) void {
        self.ch.deinit();
        if (self.host_side) |*h| {
            for (h.ids) |id| self.alloc.free(id);
            self.alloc.free(h.ids);
            h.env.deinit();
        }
        self.alloc.free(self.ext_store);
        self.alloc.free(self.spec);
        self.alloc.free(self.workspace);
        if (self.session_path) |p| self.alloc.free(p);
        if (self.tasks_dir) |p| self.alloc.free(p);
        if (self.session_id.len != 0) self.alloc.free(self.session_id);
        self.* = undefined;
    }

    /// Name the members whose calls stay on THIS machine — the answer belongs to
    /// composition, which is built after this environment, so it arrives here
    /// second rather than at `connect`. An empty list undoes nothing that was
    /// set before, and calling it twice replaces the set.
    ///
    /// The set is the shell layer's to compute: a manifest is answered by the
    /// machine holding the bytes, and this object is a handle to another one.
    pub fn useHostSide(self: *RemoteEnvironment, ids: []const []const u8) !void {
        if (self.host_side) |*h| {
            for (h.ids) |id| self.alloc.free(id);
            self.alloc.free(h.ids);
            h.env.deinit();
            self.host_side = null;
        }
        if (ids.len == 0) return;

        var owned = try self.alloc.alloc([]u8, ids.len);
        var filled: usize = 0;
        errdefer {
            for (owned[0..filled]) |id| self.alloc.free(id);
            self.alloc.free(owned);
        }
        for (ids, owned) |id, *slot| {
            slot.* = try self.alloc.dupe(u8, id);
            filled += 1;
        }

        var env = try environment_mod.LocalEnvironment.init(self.alloc, self.io, .{
            .extension_store = self.ext_store,
        });
        errdefer env.deinit();
        // A package running here IS beside the session file, so it gets the path
        // as well as the id — the whole reason it asked to land on this side.
        try env.publishSession(self.session_path orelse "", self.session_id);
        self.host_side = .{ .ids = owned, .env = env };
    }

    fn hostSideEnv(self: *RemoteEnvironment, id: []const u8) ?*environment_mod.LocalEnvironment {
        const h = if (self.host_side) |*x| x else return null;
        for (h.ids) |named| {
            if (std.mem.eql(u8, named, id)) return &h.env;
        }
        return null;
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

    /// What the agent is told to run in. The CALLER's `cwd` is ignored: it is a
    /// path on THIS machine. Every model-facing path is workspace-relative, so
    /// each side reads "." as its own workspace and nothing is translated.
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

    /// One run round under the host's patience: the request's own budget plus a
    /// margin, or the fixed control bound when it carries none.
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
        // Without concurrency for the pair the exchange runs unguarded.
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
            // Tell the far side so it can kill the command NOW; the guaranteed
            // signal is the stdin EOF `deinit` sends, so this is best-effort.
            self.requestCancel();
            return err;
        };
        sel.cancelDiscard();
        if (ex.out) |settled| return settled;
        // The exchange did not settle: either this whole call is being
        // canceled, or the bound expired and what happened over there is
        // unknown.
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
    /// Only the identity and the arguments cross. NOT `presentation_file`: its
    /// reader is the front end, here.
    ///
    /// A version that machine does not hold comes back as the agent's own
    /// sentence, answered as a FAILED CALL rather than a host error, so it
    /// reaches the model the way every failed extension call does.
    fn runExtensionImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment_mod.ExtensionRequest) anyerror!environment_mod.ExtensionOutcome {
        const self: *RemoteEnvironment = @ptrCast(@alignCast(ptr));
        // A member that declared it lands beside the session never reaches the
        // channel: it runs here, against this workspace, with the caller's cwd
        // (a path on THIS machine) and the presentation file the front end
        // reads — everything the far side has to drop.
        if (self.hostSideEnv(req.id)) |local| return local.environment().runExtension(alloc, req);
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
    /// The NAME is claimed here and the WORK happens there: the ledger, the
    /// receipt and every `task` verb speak the name, and the ledger is on this
    /// machine; the log, the status file and the lease sit beside the command.
    /// Both sides spell the directory from the same name with the same rule, so
    /// no path crosses the channel. The host directory holds what only this
    /// machine can know: which machine took the command (`machine`), a retarget
    /// (`notify`) and whether a report was delivered.
    ///
    /// The task outlives this channel: closing it ends the agent, not the task,
    /// and the report is collected by whoever next asks.
    fn startShellTaskImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment_mod.TaskRequest) anyerror!environment_mod.TaskStart {
        const self: *RemoteEnvironment = @ptrCast(@alignCast(ptr));
        const session_path = self.session_path orelse return error.NoDurableSession;
        const tasks_dir = self.tasks_dir orelse return error.NoDurableSession;
        const session_id = std.fs.path.stem(std.fs.path.basename(session_path));
        if (session_id.len == 0) return error.NoDurableSession;

        var claimed = try environment_mod.claimTaskSlot(alloc, self.io, tasks_dir, session_id);
        errdefer claimed.deinit(alloc);
        // Before the start, not after: a task started but unplaceable is a task
        // whose report nothing collects. A session may hold tasks on both
        // machines, so the header no longer answers this.
        try environment_mod.markTaskMachine(self.io, alloc, claimed.dir_rel, self.spec);

        const rep = self.ch.controlRound(.{
            .op = protocol.Op.start_task.wire(),
            .task = claimed.task_id,
            .cwd = self.remoteCwd(),
            .session = self.session_id,
            .timeout_ms = req.timeout_ms,
            .bytes = req.command.len,
        }, req.command) catch |err| {
            // The claim STAYS: whether that machine started the task is
            // unknown, and releasing the name would make one that did start
            // invisible forever. Known gap: `task-poll` answers empty for "no
            // status yet" and "no such task there" alike, so a request that
            // never arrived reads `starting` forever. `start-task` is not safe
            // to retry — a second spawn is a second supervisor.
            return err;
        };
        if (!rep.ok) {
            // A refusal is definitive, so the name is released.
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
    /// is why the frame carries `cwd` as well as the relative path.
    fn putWorkspaceFileImpl(ptr: *anyopaque, rel_path: []const u8, bytes: []const u8) anyerror!void {
        const self: *RemoteEnvironment = @ptrCast(@alignCast(ptr));
        const rep = try self.ch.controlRound(.{
            .op = protocol.Op.put_file.wire(),
            .cwd = self.remoteCwd(),
            .path = rel_path,
            .bytes = bytes.len,
        }, bytes);
        // The caller treats a failed spill exactly as a failed local write.
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

    for ([_][]const u8{ "remote:", "remote:wsl:", "remote:ssh:", "remote:exec:", "remote:exec:   ", "remote:podman:x", "remote" }) |bad| {
        try std.testing.expectError(error.InvalidRemoteSpec, parseSpec(bad));
    }

    for ([_][]const u8{ "", "local", "wsl", "wsl:Ubuntu", "ssh:me@box" }) |other| {
        try std.testing.expect(!isSpec(other));
        try std.testing.expectError(error.InvalidRemoteSpec, parseSpec(other));
    }
}

test "one ssh connection is shared, and only ssh has one to share" {
    const alloc = std.testing.allocator;
    const control = "ControlPath=/home/x/.nulya/ssh/abc";

    const ssh = try launcherArgv(alloc, .{ .ssh = "me@box" }, false, .installed_or_path, control);
    defer alloc.free(ssh);
    // Every option that makes a second `ssh` arrive on the first one's
    // connection, and the path itself passed through untouched.
    try std.testing.expect(hasWord(ssh, "ControlMaster=auto"));
    try std.testing.expect(hasWord(ssh, control));
    try std.testing.expect(hasWord(ssh, "ControlPersist=60"));
    // …before the destination, which is where ssh stops reading options.
    const dest_at = indexOfWord(ssh, "me@box").?;
    try std.testing.expect(indexOfWord(ssh, control).? < dest_at);

    // A one-shot command over the same transport joins the same connection —
    // the probe and the install are most of what the sharing is for.
    const far = try farCommandArgv(alloc, .{ .ssh = "me@box" }, false, "uname -sm", control);
    defer alloc.free(far);
    try std.testing.expect(hasWord(far, control));

    // `wsl` starts a process on this machine and `exec:`'s payload is somebody
    // else's program: neither has an ssh connection to share, whatever is
    // offered.
    const wsl = try launcherArgv(alloc, .{ .wsl = "" }, false, .installed_or_path, control);
    defer alloc.free(wsl);
    try std.testing.expect(!hasWord(wsl, control));
    const exec = try launcherArgv(alloc, .{ .exec = "docker exec -i box nulya" }, false, .installed_or_path, control);
    defer alloc.free(exec);
    try std.testing.expect(!hasWord(exec, control));

    // Offered nothing, ssh is spelled exactly as it was before sharing existed.
    const alone = try launcherArgv(alloc, .{ .ssh = "me@box" }, false, .installed_or_path, null);
    defer alloc.free(alone);
    try std.testing.expect(!hasWord(alone, "ControlMaster=auto"));
}

fn indexOfWord(argv: []const []const u8, want: []const u8) ?usize {
    for (argv, 0..) |word, at| {
        if (std.mem.eql(u8, word, want)) return at;
    }
    return null;
}

fn hasWord(argv: []const []const u8, want: []const u8) bool {
    return indexOfWord(argv, want) != null;
}

test "the password is one line, and the stream is left at the next one" {
    const alloc = std.testing.allocator;
    // Exactly what `session step --gate --ssh-password-stdin` is handed: the
    // password, then the verdicts for that step's tool calls.
    var reader: std.Io.Reader = .fixed("hunter2\nallow\ndeny too risky\n");

    const password = try readSshPassword(alloc, &reader);
    defer alloc.free(password);
    try std.testing.expectEqualStrings("hunter2", password);

    // The next read is the FIRST verdict, not the empty tail of the password's
    // own line — an empty line is no verdict, and would deny a call nobody was
    // asked about.
    try std.testing.expectEqualStrings("allow", (try reader.takeDelimiter('\n')).?);
    try std.testing.expectEqualStrings("deny too risky", (try reader.takeDelimiter('\n')).?);

    var crlf: std.Io.Reader = .fixed("hunter2\r\nallow\n");
    const trimmed = try readSshPassword(alloc, &crlf);
    defer alloc.free(trimmed);
    try std.testing.expectEqualStrings("hunter2", trimmed);
    try std.testing.expectEqualStrings("allow", (try crlf.takeDelimiter('\n')).?);

    var empty: std.Io.Reader = .fixed("\n");
    try std.testing.expectError(error.SshPasswordMissing, readSshPassword(alloc, &empty));
}

test "each launcher argv starts an agent, and the destination is never interpolated" {
    const alloc = std.testing.allocator;

    const ssh = try launcherArgv(alloc, .{ .ssh = "me@box" }, false, .installed_or_path, null);
    defer alloc.free(ssh);
    try std.testing.expectEqualStrings("ssh", ssh[0]);
    // The destination is its own word — never interpolated into a command.
    try std.testing.expectEqualStrings("me@box", ssh[3]);
    // …and the command is ONE word after it, because ssh joins what follows
    // with spaces and lets the far shell parse the result.
    try std.testing.expectEqual(@as(usize, 5), ssh.len);
    try std.testing.expect(std.mem.indexOf(u8, ssh[4], "remote serve") != null);

    const password_ssh = try launcherArgv(alloc, .{ .ssh = "me@box" }, true, .installed_or_path, null);
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
    try std.testing.expectEqualStrings("me@box", password_ssh[5]);

    // The rung a peer with no POSIX shell still answers to: no test, no
    // `$HOME`, nothing but the program name every earlier build used.
    const bare = try launcherArgv(alloc, .{ .ssh = "me@box" }, false, .path, null);
    defer alloc.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare[4], "$HOME") == null);
    try std.testing.expectEqualStrings("nulya remote serve", bare[4]);

    const wsl = try launcherArgv(alloc, .{ .wsl = "Ubuntu" }, false, .installed_or_path, null);
    defer alloc.free(wsl);
    try std.testing.expectEqualStrings("-d", wsl[1]);
    try std.testing.expectEqualStrings("Ubuntu", wsl[2]);
    const wsl_default = try launcherArgv(alloc, .{ .wsl = "" }, false, .installed_or_path, null);
    defer alloc.free(wsl_default);
    try std.testing.expectEqual(wsl.len - 2, wsl_default.len);

    // `exec:` names a program, so it keeps the shape it always had: the words
    // as written, then the verb.
    const exec = try launcherArgv(alloc, .{ .exec = "docker exec -i box /usr/bin/nulya" }, false, .installed_or_path, null);
    defer alloc.free(exec);
    try std.testing.expectEqualStrings("docker", exec[0]);
    try std.testing.expectEqualStrings("/usr/bin/nulya", exec[exec.len - 3]);
    try std.testing.expectEqualStrings("remote", exec[exec.len - 2]);
    try std.testing.expectEqualStrings("serve", exec[exec.len - 1]);
}

test "a one-shot far command carries the command, and exec: cannot host one" {
    const alloc = std.testing.allocator;

    const ssh = try farCommandArgv(alloc, .{ .ssh = "me@box" }, false, "uname -sm", null);
    defer alloc.free(ssh);
    try std.testing.expectEqualStrings("me@box", ssh[3]);
    try std.testing.expectEqualStrings("uname -sm", ssh[4]);

    const wsl = try farCommandArgv(alloc, .{ .wsl = "" }, false, "uname -sm", null);
    defer alloc.free(wsl);
    try std.testing.expectEqualStrings("sh", wsl[2]);
    try std.testing.expectEqualStrings("-c", wsl[3]);
    try std.testing.expectEqualStrings("uname -sm", wsl[4]);

    // The payload of `exec:` is a program; nothing can ask it to be a shell.
    try std.testing.expectError(
        error.InvalidRemoteSpec,
        farCommandArgv(alloc, .{ .exec = "docker exec -i box nulya" }, false, "uname -sm", null),
    );
}

test "wsl is reachable only from Windows, and the other two from anywhere" {
    try std.testing.expect(supportedOnHost(.{ .ssh = "h" }));
    try std.testing.expect(supportedOnHost(.{ .exec = "x" }));
    try std.testing.expectEqual(builtin.os.tag == .windows, supportedOnHost(.{ .wsl = "" }));
}
