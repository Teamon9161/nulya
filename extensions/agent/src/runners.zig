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
//! **Why a tagged union and a switch rather than a vtable.** The shape was
//! written to the contract before the second arm existed, and the arms since
//! have proved the point: Codex is JSON-RPC over a child's stdio, Claude is its
//! own stream-json dialect over another, pi is a third — no amount of vtable
//! would have prepared for any of them, and the external ones share `send` and
//! `pending` with each other and almost nothing else with the nulya one.
//!
//! **And the fifth arm is the one that ends the list.** `runner: ext:<id>` is a
//! harness this package has never heard of, spoken to by an ordinary extension
//! with one `agent_runner` tool in it (`external.zig`). Everything above the
//! wire stays here — the lease, the record, the inbox, the interrupt marker, the
//! report framing — so a runner that moves out of this package takes only its
//! own dialect with it. That arm is the design, not a fallback: it is why no
//! sixth harness ever needs to be compiled in here.
//!
//! What the arms DO share ends up in `record.zig` rather than in one of them:
//! the per-delegation inbox, the minted uuid, the frozen persona. Adding the
//! third external arm needed no new shape there at all.
//!
//! ── the three words, per harness (contract ar-h) ────────────────────────────
//!
//! A definition says `permissions: readonly | default | unsafe`
//! (`record.Permissions`) and every arm translates the same three words into
//! whatever its harness has. `readonly` is the only one that is a CEILING — a
//! runner that cannot hold its harness to reading refuses the delegation (D10)
//! — and the only one with a confirmation step where the protocol offers one.
//!
//!   |          | `readonly`                    | `default`         | `unsafe`             |
//!   |----------|-------------------------------|-------------------|----------------------|
//!   | `nulya`  | `--gate`, answered mechanically | no gate           | no gate (D13)        |
//!   | `codex`  | `sandbox: read-only` + echo   | `workspace-write` | `danger-full-access` |
//!   | `claude` | narrow `--tools` + `dontAsk` + echo | `acceptEdits` | `bypassPermissions`  |
//!   | `pi`     | `--tools read,grep,find,ls`   | everything built in | everything built in |
//!   | `ext:…`  | `permissions=readonly`        | `permissions=default` | `permissions=unsafe` |
//!
//! **The nulya row is deliberate, not unfinished (D13).** There is no gate
//! between `default` and `unsafe` because the only thing that could go there is
//! a classifier guessing at command strings, and a ceiling made of string
//! classification reads convincingly and holds nothing (agents-and-review §1).
//! Real separation is the sandbox (PLAN §3.8). What the two words differ in on
//! this arm today is the record — the frozen answer that sandbox will read.
//!
//! **The pi row is an honest shortfall.** Pi has no level wider than its own
//! default: no bypass, no "off" for whatever guard rails it applies. An
//! `unsafe` delegation there runs exactly as a `default` one does, and the
//! record still says `unsafe` — what was asked for, not what was granted.

const std = @import("std");
const proc = @import("proc.zig");
const record = @import("record.zig");
const codex = @import("codex.zig");
const claude = @import("claude.zig");
const pi = @import("pi.zig");
const external = @import("external.zig");

/// The prefix that says "this harness is somebody else's extension".
pub const ext_prefix = "ext:";

pub const Runner = union(enum) {
    /// This nulya: the delegation is a session of its own, driven by
    /// `session step --stream` in a background task.
    nulya,

    /// A Codex thread, spoken to over `codex app-server` (`codex.zig`).
    codex,

    /// A Claude Code session, spoken to over `claude -p`'s bidirectional
    /// stream-json stdio (`claude.zig`).
    claude,

    /// A pi session, spoken to over `pi --mode rpc`'s JSONL commands and events
    /// (`pi.zig`).
    pi,

    /// A harness some other extension knows how to talk to: `ext:<id>`, whose
    /// `agent_runner` tool answers one round at a time (`external.zig`). The
    /// payload is the whole word as written, because that word is what the
    /// record freezes and what `list` reports; the id is the part after the
    /// prefix.
    ext: []const u8,

    /// The word a definition's `runner:` may say. Null is "not a runner this
    /// package knows", which costs the whole definition (a persona that would
    /// silently run on something other than what it asked for is worse than a
    /// persona that is not there) — and `ext:` with nothing usable after it is
    /// exactly as unknown as a misspelling.
    pub fn parse(text: []const u8) ?Runner {
        const word = std.mem.trim(u8, text, " \t");
        if (std.mem.startsWith(u8, word, ext_prefix)) {
            return if (isPlainExtId(word[ext_prefix.len..])) .{ .ext = word } else null;
        }
        if (std.mem.eql(u8, word, "nulya")) return .nulya;
        if (std.mem.eql(u8, word, "codex")) return .codex;
        if (std.mem.eql(u8, word, "claude")) return .claude;
        if (std.mem.eql(u8, word, "pi")) return .pi;
        return null;
    }

    /// The word as a definition writes it and as the record freezes it. One
    /// spelling for both, so a delegation opened today is read back tomorrow by
    /// the same name it was written with.
    pub fn label(self: Runner) []const u8 {
        return switch (self) {
            .ext => |word| word,
            else => @tagName(std.meta.activeTag(self)),
        };
    }

    /// The extension id behind `ext:<id>`, for the arms that have to name it.
    pub fn extId(self: Runner) []const u8 {
        return switch (self) {
            .ext => |word| word[ext_prefix.len..],
            else => "",
        };
    }

    /// Does this runner speak nulya's own model vocabulary — a profile and an id
    /// within it (DESIGN §9.5)? An external harness has its own catalogue, so a
    /// model reference for one is an OPAQUE string that goes straight through
    /// (D9): parsing it here could only ever be a second, staler copy of a list
    /// this package does not own.
    pub fn usesNulyaModels(self: Runner) bool {
        return switch (self) {
            .nulya => true,
            .codex, .claude, .pi, .ext => false,
        };
    }
};

pub const default: Runner = .nulya;

/// An extension id, by the kernel's own rule (`manifest.isValidId`) — checked
/// here because `ext:<id>` becomes a store reference, and because "that is not
/// an extension id" is a better answer than a lookup that finds nothing.
fn isPlainExtId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

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
    /// How much this delegation may do, in the one vocabulary every arm
    /// translates (`record.Permissions`, contract ar-h). `readonly` is a hard
    /// ceiling a runner must be able to enforce or refuse the whole delegation
    /// for (D10); the other two are grants each harness has its own word for
    /// (§ "the three words, per harness", below).
    permissions: record.Permissions = record.default_permissions,
    pins: []const []const u8 = &.{},
    /// `--with <agent@version>` so the sub-agent can delegate onwards. Empty is
    /// a leaf, which is what every persona but a coordinator is.
    with_self: []const u8 = "",
    /// The delegation this is being opened for, minted before the call so a
    /// runner with per-delegation state on disk (the claude arm freezes the
    /// persona there) has somewhere to put it. Empty for a caller with no
    /// delegation, which only the nulya arm tolerates.
    delegation: []const u8 = "",
};

/// What opening a conversation came back with.
pub const Started = struct {
    run: proc.Run,
    /// What the harness says about its own version, to be frozen beside the
    /// runner name (D7): every later round of this delegation goes to the same
    /// harness, and a record that says which one it was is the only way to read
    /// an old delegation afterwards. Empty where the harness does not say —
    /// `codex app-server` reports no version of its own, and this nulya is the
    /// binary running the record.
    version: []const u8 = "",
};

/// Open the remote conversation. On success its stdout is the remote handle —
/// a session id for the nulya arm, a thread id for Codex.
///
/// The `proc.Run` shape is the contract on purpose: "spawn something, read what
/// it said" is what opening a conversation looks like from here whether or not
/// a process was actually spawned to do it.
pub fn start(r: Runner, alloc: std.mem.Allocator, io: std.Io, opts: StartOptions) !Started {
    switch (r) {
        .ext => |word| {
            const id = word[ext_prefix.len..];
            // The version FIRST, before anything is written: it is what this
            // delegation is nailed to for the rest of its life (D7), and a
            // runner nobody activated is a definition that cannot run at all.
            const version = switch (try external.resolveCurrent(alloc, io, opts.exe, id)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => |v| v,
            };
            // Then the persona, because `op=open` is handed its PATH — a runner
            // that builds a thread out of it needs it to exist by then, and one
            // frozen copy is what stops this delegation from following later
            // edits to the definition file.
            switch (try external.freezePersona(alloc, io, std.Io.Dir.cwd(), opts.delegation, opts.prompt)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => {},
            }
            // `pins` and `with_self` say nothing here, for the reason they say
            // nothing to Codex: they are nulya composition.
            const opened = try external.open(alloc, io, opts.exe, .{
                .ref = try external.refOf(alloc, id, version),
                .delegation = opts.delegation,
                .persona = try record.pathIn(alloc, opts.delegation, record.persona_name),
                .permissions = opts.permissions,
                .model = opts.runner_model,
            });
            return .{
                .run = switch (opened) {
                    .ok => |remote| .{ .code = 0, .stdout = @constCast(remote), .stderr = "" },
                    .failed => |f| .{ .code = 1, .stdout = "", .stderr = @constCast(f) },
                },
                // The frozen EXTENSION version, which is what "the same runner,
                // at the same version, for every later round" means out here.
                // Whatever the harness behind it calls its own version is that
                // runner's business to record in its own space.
                .version = version,
            };
        },
        .claude => {
            // Reachability first, and it costs one local process: a definition
            // naming a harness this machine does not have is refused HERE —
            // before a record exists, before a receipt says work is under way.
            // (Codex answers the same question by opening the thread; Claude has
            // no "open a conversation" verb at all, so this is the moment.)
            const version = switch (try claude.probe(alloc, io, opts.env)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => |v| v,
            };
            // The persona is frozen into the delegation rather than left in the
            // rendered file: Claude rebuilds its prompt from flags on every
            // round, so without a copy this delegation would silently follow
            // edits to the definition (`claude.zig`).
            switch (try claude.freezePersona(alloc, io, std.Io.Dir.cwd(), opts.delegation, opts.prompt)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => {},
            }
            // No process is started: a Claude session comes into being when the
            // first `claude -p --session-id <uuid>` runs, and that happens in the
            // background task that drives the first round. The name is what this
            // opens, and it is enough to resume from ever after.
            //
            // `pins` and `with_self` say nothing here, for the reason they say
            // nothing to Codex: they are nulya composition.
            return .{
                .run = .{ .code = 0, .stdout = try record.mintUuid(alloc, io), .stderr = "" },
                .version = version,
            };
        },
        .pi => {
            // Reachability first, for the reason the claude arm does it: a
            // definition naming a harness this machine does not have is refused
            // before a record exists.
            const version = switch (try pi.probe(alloc, io, opts.env)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => |v| v,
            };
            switch (try pi.freezePersona(alloc, io, std.Io.Dir.cwd(), opts.delegation, opts.prompt)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => {},
            }
            // No process is started: `pi --session-id <id>` creates the session
            // under that name the first time a round runs it, so the name is the
            // whole of what opening one means here.
            return .{
                .run = .{ .code = 0, .stdout = try record.mintUuid(alloc, io), .stderr = "" },
                .version = version,
            };
        },
        .codex => {
            // The persona is a file because `session new --prompt` wants one;
            // Codex wants the bytes.
            const persona = std.Io.Dir.cwd().readFileAlloc(io, opts.prompt, alloc, .limited(max_persona_bytes)) catch |err| {
                return .{ .run = .{
                    .code = 1,
                    .stdout = "",
                    .stderr = try std.fmt.allocPrint(alloc, "could not read the rendered persona at {s}: {s}", .{ opts.prompt, @errorName(err) }),
                } };
            };
            // `pins` and `with_self` say nothing here: they are nulya
            // composition, and a Codex thread has its own tools. A definition
            // that named pins for a codex agent is warned about when it is read
            // (`defs.zig`), not silently honoured as something else.
            const opened = try codex.open(alloc, io, opts.env, .{
                .persona = persona,
                .model = opts.runner_model,
                .permissions = opts.permissions,
            });
            return .{ .run = switch (opened) {
                .ok => |thread| .{ .code = 0, .stdout = @constCast(thread), .stderr = "" },
                .failed => |f| .{ .code = 1, .stdout = "", .stderr = @constCast(f) },
            } };
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
            return .{ .run = try proc.run(alloc, io, argv.items) };
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
        .codex, .claude, .pi, .ext => {
            // Always the file, never "steer if something is running": whether a
            // message arrives at the next natural boundary or is folded into the
            // turn in flight is the RUNNER's decision, made when it drains
            // (`codex.driveRound`, `claude.driveRound`). A sender that tried to
            // decide it would be racing the runner for the answer.
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
        .claude => try std.fmt.allocPrint(alloc, "claude session {s}", .{remote}),
        .pi => try std.fmt.allocPrint(alloc, "pi session {s}", .{remote}),
        // Whatever the runner named it. This side does not know what kind of
        // thing that handle is, and saying "session" about it would be a guess.
        .ext => |word| try std.fmt.allocPrint(alloc, "{s} conversation {s}", .{ word, remote }),
    };
}

/// Where the whole of it can be read. A pointer at the wrong harness's
/// transcript would be worse than none — it invites a command that cannot work.
pub fn transcriptHint(r: Runner, alloc: std.mem.Allocator, remote: []const u8) ![]const u8 {
    return switch (r) {
        .nulya => try std.fmt.allocPrint(alloc, "Its full transcript is `nulya session events {s}`.", .{remote}),
        .codex => try std.fmt.allocPrint(alloc, "It ran as codex thread {s}; its transcript is Codex's own.", .{remote}),
        // A pointer that actually works: Claude keeps the whole conversation and
        // resumes it by that name.
        .claude => try std.fmt.allocPrint(alloc, "It ran as claude session {s}; the whole of it is `claude --resume {s}`.", .{ remote, remote }),
        .pi => try std.fmt.allocPrint(alloc, "It ran as pi session {s}; the whole of it is `pi --session {s}`.", .{ remote, remote }),
        // No command is offered: only that runner knows where its harness keeps
        // a transcript, and a pointer that does not work is worse than none.
        .ext => |word| try std.fmt.allocPrint(alloc, "It ran on {s} as {s}, which keeps its own transcript.", .{ word, remote }),
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
        .codex, .claude, .pi, .ext => return packageInboxPending(alloc, io, base, delegation),
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
        //
        // Claude is the same shape for the same reason: its interrupt is a
        // control request written into the stdin of the process that is running
        // the turn, and only the driving process holds that pipe.
        //
        // An external runner is told where the marker is and watches it itself
        // (`external.zig`) — for the same reason again, one level further out.
        .codex, .claude, .pi, .ext => {},
    }
}

test "a runner is named by the definition, and an unknown word is not one" {
    try std.testing.expectEqual(Runner.nulya, Runner.parse("nulya").?);
    try std.testing.expectEqual(Runner.nulya, Runner.parse("  nulya ").?);
    try std.testing.expectEqual(Runner.codex, Runner.parse("codex").?);
    try std.testing.expectEqual(Runner.claude, Runner.parse("claude").?);
    try std.testing.expectEqual(Runner.pi, Runner.parse("pi").?);
    try std.testing.expect(Runner.parse("borges") == null);
    try std.testing.expect(Runner.parse("") == null);
    try std.testing.expectEqualStrings("nulya", Runner.parse("nulya").?.label());
    try std.testing.expectEqualStrings("codex", Runner.parse("codex").?.label());
    try std.testing.expectEqualStrings("claude", Runner.parse("claude").?.label());
    try std.testing.expectEqualStrings("pi", Runner.parse("pi").?.label());
}

test "a harness this package never heard of is named ext:<id>, and a shape that is not one is unknown" {
    const named = Runner.parse("ext:my-runner").?;
    try std.testing.expectEqualStrings("my-runner", named.extId());
    // The word round-trips: it is what the record freezes and what `list` says.
    try std.testing.expectEqualStrings("ext:my-runner", named.label());
    try std.testing.expect(!named.usesNulyaModels());

    // An id that could not name an extension is as unknown as a misspelling —
    // it costs the whole definition rather than becoming a lookup that fails
    // later, somewhere else.
    try std.testing.expect(Runner.parse("ext:") == null);
    try std.testing.expect(Runner.parse("ext:../std") == null);
    try std.testing.expect(Runner.parse("ext:a/b") == null);
    try std.testing.expect(Runner.parse("ext") == null);
}

test "only this nulya speaks nulya's model vocabulary" {
    try std.testing.expect(Runner.parse("nulya").?.usesNulyaModels());
    try std.testing.expect(!Runner.parse("codex").?.usesNulyaModels());
    try std.testing.expect(!Runner.parse("claude").?.usesNulyaModels());
    try std.testing.expect(!Runner.parse("pi").?.usesNulyaModels());
    try std.testing.expect(!Runner.parse("ext:whatever").?.usesNulyaModels());
}
