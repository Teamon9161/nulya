//! What actually holds a sub-agent's conversation, behind the one `agent` tool.
//!
//! **One world view (D1).** The model has a single vocabulary: start a
//! delegation, send it another turn, interrupt it, read its report. Which
//! harness does the work — this nulya, a Codex thread, a Claude process — is a
//! property of the DEFINITION (`runner:`), frozen into the delegation's record
//! when it opens (D7), and never something the model has to know or say.
//!
//! **Five verbs, one switch each.** A runner is whatever can answer:
//!
//!   `start`      open a conversation and give back a handle for it
//!   `send`       deliver one message into it
//!   `pending`    is there a message nobody has picked up yet?
//!   `stop`       stop the round in flight so a new message is taken now
//!   `drive`      run it until it has nothing more to say, and report
//!
//! `drive` is the one that reads a protocol line by line, so it lives with the
//! `run` tool that is its whole process (`runner.zig`); the other four are here.
//!
//! **Why an enum and a switch rather than a vtable.** The shape was written to
//! the contract before the second arm existed, and the second arm proved the
//! point: Codex is a JSON-RPC conversation over a child's stdio, which no amount
//! of vtable would have prepared for — it shares `send` and `pending` with the
//! nulya arm and shares nothing else. When a runner moves OUT of this package
//! (`runner: ext:<id>`, contract ar-g) the switch grows one arm that shells out;
//! that is the design, not a fallback.

const std = @import("std");
const proc = @import("proc.zig");
const record = @import("record.zig");
const codex = @import("codex.zig");

pub const Runner = enum {
    /// This nulya: the delegation is a session of its own, driven by
    /// `session step --stream` in a background task.
    nulya,

    /// A Codex thread, spoken to over `codex app-server` (`codex.zig`).
    codex,

    /// The word a definition's `runner:` may say. Null is "not a runner this
    /// package knows", which costs the whole definition (a persona that would
    /// silently run on something other than what it asked for is worse than a
    /// persona that is not there).
    pub fn parse(text: []const u8) ?Runner {
        return std.meta.stringToEnum(Runner, std.mem.trim(u8, text, " \t"));
    }

    pub fn label(self: Runner) []const u8 {
        return @tagName(self);
    }

    /// Does this runner speak nulya's own model vocabulary — a profile and an id
    /// within it (DESIGN §9.5)? An external harness has its own catalogue, so a
    /// model reference for one is an OPAQUE string that goes straight through
    /// (D9): parsing it here could only ever be a second, staler copy of a list
    /// this package does not own.
    pub fn usesNulyaModels(self: Runner) bool {
        return switch (self) {
            .nulya => true,
            .codex => false,
        };
    }
};

pub const default: Runner = .nulya;

pub const StartOptions = struct {
    /// The nulya that spawned us (DESIGN §7.6) — never whichever copy is on PATH.
    exe: []const u8,
    /// The rendered persona, as a FILE PATH. For the nulya arm it is `session
    /// new --prompt`; an external runner reads the bytes and passes them however
    /// it takes a system prompt.
    prompt: []const u8,
    /// This process's environment, for a runner that has to find its own
    /// harness (`codex.exe_var`).
    env: *const std.process.Environ.Map,
    profile: []const u8 = "",
    model: []const u8 = "",
    /// The opaque model string for an external runner (D9). Never both this and
    /// `profile`/`model`: which pair applies is decided by the runner, once.
    runner_model: []const u8 = "",
    /// A hard ceiling this runner must be able to enforce, or refuse the whole
    /// delegation for (D10). The nulya arm answers the kernel's gate; an
    /// external one translates it into its own sandbox and CONFIRMS it.
    readonly: bool = false,
    pins: []const []const u8 = &.{},
    /// `--with <agent@version>` so the sub-agent can delegate onwards. Empty is
    /// a leaf, which is what every persona but a coordinator is.
    with_self: []const u8 = "",
};

/// Open the remote conversation. On success its stdout is the remote handle —
/// a session id for the nulya arm, a thread id for Codex.
///
/// The `proc.Run` shape is the contract on purpose: "spawn something, read what
/// it said" is what opening a conversation looks like from here whether or not
/// a process was actually spawned to do it.
pub fn start(r: Runner, alloc: std.mem.Allocator, io: std.Io, opts: StartOptions) !proc.Run {
    switch (r) {
        .codex => {
            // The persona is a file because `session new --prompt` wants one;
            // Codex wants the bytes.
            const persona = std.Io.Dir.cwd().readFileAlloc(io, opts.prompt, alloc, .limited(max_persona_bytes)) catch |err| {
                return .{
                    .code = 1,
                    .stdout = "",
                    .stderr = try std.fmt.allocPrint(alloc, "could not read the rendered persona at {s}: {s}", .{ opts.prompt, @errorName(err) }),
                };
            };
            // `pins` and `with_self` say nothing here: they are nulya
            // composition, and a Codex thread has its own tools. A definition
            // that named pins for a codex agent is warned about when it is read
            // (`defs.zig`), not silently honoured as something else.
            const opened = try codex.open(alloc, io, opts.env, .{
                .persona = persona,
                .model = opts.runner_model,
                .readonly = opts.readonly,
            });
            return switch (opened) {
                .ok => |thread| .{ .code = 0, .stdout = @constCast(thread), .stderr = "" },
                .failed => |f| .{ .code = 1, .stdout = "", .stderr = @constCast(f) },
            };
        },
        .nulya => {
            var argv: std.ArrayList([]const u8) = .empty;
            // The persona rides as BYTES the header freezes (DESIGN §3): nothing
            // is installed, so this session's identity text cannot be pruned out
            // from under its own resume.
            //
            // `--bare` (DESIGN §14): the workspace's standing `[extensions] with`
            // and `pinned_native_tools` are read as empty for it. Those two lists
            // are how a PERSON says "every session I open here carries this"; a
            // session opened by the model to do one piece of work is not one of
            // those, and inheriting them would give a sub-agent capabilities its
            // author never wrote down.
            try argv.appendSlice(alloc, &.{ opts.exe, "session", "new", "--bare", "--prompt", opts.prompt });
            if (opts.profile.len != 0) try argv.appendSlice(alloc, &.{ "--profile", opts.profile });
            if (opts.model.len != 0) try argv.appendSlice(alloc, &.{ "--model", opts.model });
            // Just the pins. A pin brings its own package into the session at
            // `current` (DESIGN §5.1) — the child composes from scratch, and the
            // kernel is the one place that implication is made, so a `--with`
            // derived here would only be a second, slightly different copy of it.
            for (opts.pins) |pin| try argv.appendSlice(alloc, &.{ "--pin", pin });
            if (opts.with_self.len != 0) try argv.appendSlice(alloc, &.{ "--with", opts.with_self });
            return proc.run(alloc, io, argv.items);
        },
    }
}

/// Deliver one message into the conversation.
///
/// **The channel is the runner's (D5).** The nulya arm appends straight into the
/// child session's own inbox, which the kernel drains at its next step boundary
/// — so a message sent WHILE the sub-agent is working reaches it mid-run, for
/// free, because the kernel already does that for every session. An external
/// runner will write `<d>/inbox/` instead and drain it at whatever granularity
/// its protocol has. Giving up nulya's mid-run delivery for the symmetry of one
/// channel would be paying for tidiness with a capability.
pub fn send(
    r: Runner,
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    exe: []const u8,
    remote: []const u8,
    delegation: []const u8,
    text: []const u8,
) !proc.Run {
    switch (r) {
        .nulya => return proc.run(alloc, io, &.{ exe, "session", "append", remote, text }),
        .codex => {
            // Always the file, never "steer if something is running": whether a
            // message arrives at the next natural boundary or is folded into the
            // turn in flight is the RUNNER's decision, made when it drains
            // (`codex.driveRound`). A sender that tried to decide it would be
            // racing the runner for the answer.
            record.inboxPut(alloc, io, base, delegation, text) catch |err| {
                return .{
                    .code = 1,
                    .stdout = "",
                    .stderr = try std.fmt.allocPrint(alloc, "could not queue that message for delegation {s}: {s}", .{ delegation, @errorName(err) }),
                };
            };
            return .{ .code = 0, .stdout = "", .stderr = "" };
        },
    }
}

const max_persona_bytes: usize = 1 << 20;

// ── naming the remote (D2) ──────────────────────────────────────────────────
//
// The model says `d-…` and never has to know what is behind it — but the facts
// are not hidden either, so a receipt names the remote conversation and a report
// says where the whole of it can be read. Both sentences are per-runner, and
// both live here rather than at their two call sites: a receipt that named a
// session and a report that pointed at a Codex thread would be two answers to
// one question.

/// What holds this conversation, in one phrase for the middle of a sentence.
pub fn remoteLabel(r: Runner, alloc: std.mem.Allocator, remote: []const u8) ![]const u8 {
    return switch (r) {
        .nulya => try std.fmt.allocPrint(alloc, "session {s}", .{remote}),
        .codex => try std.fmt.allocPrint(alloc, "codex thread {s}", .{remote}),
    };
}

/// Where the whole of it can be read. A pointer at the wrong harness's
/// transcript would be worse than none — it invites a command that cannot work.
pub fn transcriptHint(r: Runner, alloc: std.mem.Allocator, remote: []const u8) ![]const u8 {
    return switch (r) {
        .nulya => try std.fmt.allocPrint(alloc, "Its full transcript is `nulya session events {s}`.", .{remote}),
        .codex => try std.fmt.allocPrint(alloc, "It ran as codex thread {s}; its transcript is Codex's own.", .{remote}),
    };
}

/// Is a message sitting in the channel that nobody has taken yet?
///
/// Both halves of the wake invariant ask this (D4): the runner before it lets
/// go of its lease and again after, the sender never — a sender that has just
/// delivered knows the answer. Unreadable counts as NOTHING pending, because the
/// sender's probe is the other half and an error here is not evidence.
pub fn pending(
    r: Runner,
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    remote: []const u8,
    delegation: []const u8,
) bool {
    switch (r) {
        .nulya => {
            const path = std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.inbox", .{remote}) catch return false;
            return holdsJson(io, base, path);
        },
        .codex => return packageInboxPending(alloc, io, base, delegation),
    }
}

/// `<d>/inbox/` — where an external runner's messages wait. Unused by the nulya
/// arm (it has the kernel's own inbox), and named separately because it is a
/// fact about the DELEGATION where the other is a fact about a session.
pub fn packageInboxPending(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    delegation: []const u8,
) bool {
    const path = record.pathIn(alloc, delegation, record.inbox_name) catch return false;
    return holdsJson(io, base, path);
}

fn holdsJson(io: std.Io, base: std.Io.Dir, path: []const u8) bool {
    var dir = base.openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind == .directory) continue;
        // The kernel deposits `<name>.tmp` and renames it into place, so only a
        // `.json` is a message that has actually landed.
        if (std.mem.endsWith(u8, entry.name, ".json")) return true;
    }
    return false;
}

/// Stop the round in flight, in this harness's own dialect (D6).
///
/// For nulya that is the cancel marker the kernel already understands: it is
/// consumed at the session's next step boundary, where the ledger is in a legal
/// state. The runner kills the step process on top of this — killing is what
/// makes an interrupt immediate, and the marker is what makes a step that is
/// between two steps stop by itself. Best effort by design: the kill is the
/// guarantee, this is the polite half.
pub fn stop(r: Runner, alloc: std.mem.Allocator, io: std.Io, exe: []const u8, remote: []const u8) void {
    switch (r) {
        .nulya => _ = proc.run(alloc, io, &.{ exe, "session", "cancel", remote }) catch return,
        // Nothing to do from out here. A Codex turn is stopped by
        // `turn/interrupt` on the very connection that is driving it, naming the
        // turn in flight — facts only the driving process holds. So the codex
        // arm interrupts IN BAND (`codex.driveRound`) and never calls this;
        // there is no marker a second process could leave that would reach it.
        .codex => {},
    }
}

test "a runner is named by the definition, and an unknown word is not one" {
    try std.testing.expectEqual(Runner.nulya, Runner.parse("nulya").?);
    try std.testing.expectEqual(Runner.nulya, Runner.parse("  nulya ").?);
    try std.testing.expectEqual(Runner.codex, Runner.parse("codex").?);
    try std.testing.expect(Runner.parse("claude") == null);
    try std.testing.expect(Runner.parse("") == null);
    try std.testing.expectEqualStrings("nulya", Runner.nulya.label());
    try std.testing.expectEqualStrings("codex", Runner.codex.label());
}

test "only this nulya speaks nulya's model vocabulary" {
    try std.testing.expect(Runner.nulya.usesNulyaModels());
    try std.testing.expect(!Runner.codex.usesNulyaModels());
}
