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
//! **Why an enum and a switch rather than a vtable.** There is exactly one arm
//! today. The shape is written to the contract now so that adding Codex is
//! adding an arm and nothing else, but an interface with one implementation is
//! a guess about the second one — and the second one is going to be a JSON-RPC
//! conversation over stdio, which no amount of vtable prepared for. When a
//! runner moves OUT of this package (`runner: ext:<id>`, contract ar-g) the
//! switch grows one arm that shells out; that is the design, not a fallback.

const std = @import("std");
const proc = @import("proc.zig");
const record = @import("record.zig");

pub const Runner = enum {
    /// This nulya: the delegation is a session of its own, driven by
    /// `session step --stream` in a background task.
    nulya,

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
};

pub const default: Runner = .nulya;

pub const StartOptions = struct {
    /// The nulya that spawned us (DESIGN §7.6) — never whichever copy is on PATH.
    exe: []const u8,
    /// The rendered persona. For the nulya arm it is `session new --prompt`; an
    /// external runner passes the same bytes however it takes a system prompt.
    prompt: []const u8,
    profile: []const u8 = "",
    model: []const u8 = "",
    pins: []const []const u8 = &.{},
    /// `--with <agent@version>` so the sub-agent can delegate onwards. Empty is
    /// a leaf, which is what every persona but a coordinator is.
    with_self: []const u8 = "",
};

/// Open the remote conversation. On success its stdout is the remote handle —
/// a session id for the nulya arm.
pub fn start(r: Runner, alloc: std.mem.Allocator, io: std.Io, opts: StartOptions) !proc.Run {
    switch (r) {
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
    exe: []const u8,
    remote: []const u8,
    text: []const u8,
) !proc.Run {
    switch (r) {
        .nulya => return proc.run(alloc, io, &.{ exe, "session", "append", remote, text }),
    }
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
    // Named for the arms that will use it: an external runner's messages wait in
    // `<d>/inbox/`, which is a fact about the delegation, not about a session.
    _ = delegation;
    switch (r) {
        .nulya => {
            const path = std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.inbox", .{remote}) catch return false;
            return holdsJson(io, base, path);
        },
    }
}

/// `<d>/inbox/` — where an external runner's messages wait. Unused by the nulya
/// arm (it has the kernel's own inbox), and here because `pending` for the next
/// runner is this function with the other path.
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
    }
}

test "a runner is named by the definition, and an unknown word is not one" {
    try std.testing.expectEqual(Runner.nulya, Runner.parse("nulya").?);
    try std.testing.expectEqual(Runner.nulya, Runner.parse("  nulya ").?);
    try std.testing.expect(Runner.parse("codex") == null);
    try std.testing.expect(Runner.parse("") == null);
    try std.testing.expectEqualStrings("nulya", Runner.nulya.label());
}
