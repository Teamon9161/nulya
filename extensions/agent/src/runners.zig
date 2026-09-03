//! What actually holds a sub-agent's conversation, behind the one `agent` tool.
//! Which harness does the work is the DEFINITION's `runner:`, frozen into the
//! record when the delegation opens, and never something the model says.
//!
//! Four verbs: `start` (open a conversation, give back a handle), `send`
//! (deliver one message), `pending` (is anything untaken?), and `drive` — which
//! reads a protocol line by line and so lives with the `run` tool that is its
//! whole process (`runner.zig`). There is no `stop`: an interrupt reaches a turn
//! on the connection running it, which only the driving code holds, so each arm's
//! stop lives in its own `driveRound`.
//!
//! Every arm translates the same three `record.Permissions` words:
//!
//!   |          | `readonly`                    | `default`         | `unsafe`             |
//!   |----------|-------------------------------|-------------------|----------------------|
//!   | `nulya`  | `--gate`, answered mechanically | no gate           | no gate              |
//!   | `codex`  | `sandbox: read-only` + echo   | `workspace-write` | `danger-full-access` |
//!   | `claude` | narrow `--tools` + `dontAsk` + echo | `acceptEdits` | `bypassPermissions`  |
//!   | `pi`     | `--tools read,grep,find,ls`   | everything built in | everything built in |
//!   | `ext:…`  | `permissions=readonly`        | `permissions=default` | `permissions=unsafe` |
//!
//! `readonly` is the only CEILING: a runner that cannot hold its harness to
//! reading refuses the delegation. The pi row is an honest shortfall — pi has no
//! level wider than its own default, so an `unsafe` delegation there runs as a
//! `default` one does and the record says what was asked for, not what was
//! granted.

const std = @import("std");
const proc = @import("proc.zig");
const record = @import("record.zig");
const mailbox = @import("mailbox.zig");
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
    /// payload is the whole word as written — that word is what the record
    /// freezes and what `list` reports.
    ext: []const u8,

    /// The word a definition's `runner:` may say. Null is "not a runner this
    /// package knows" and costs the whole definition: a persona silently running
    /// on something other than what it asked for is worse than one that is not
    /// there.
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
    /// within it? An external harness has its own catalogue, so a model reference
    /// for one is an OPAQUE string that goes straight through: parsing it here
    /// could only be a staler copy of a list this package does not own.
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
    /// The nulya that spawned us — never whichever copy is on PATH.
    exe: []const u8,
    /// The rendered persona, as a FILE PATH. For the nulya arm it is `session
    /// new --prompt`; an external runner reads the bytes and passes them however
    /// it takes a system prompt.
    prompt: []const u8,
    /// This process's environment, for a runner that has to find its own harness.
    env: *const std.process.Environ.Map,
    profile: []const u8 = "",
    model: []const u8 = "",
    /// The opaque model string for an external runner. Never both this and
    /// `profile`/`model`: which applies is decided by the runner, once.
    runner_model: []const u8 = "",
    /// How much this delegation may do, in the one vocabulary every arm
    /// translates (`record.Permissions`). `readonly` is a hard ceiling a runner
    /// must be able to enforce, or refuse the whole delegation; the other two are
    /// grants each harness has its own word for (see the table above).
    permissions: record.Permissions = record.default_permissions,
    with: []const []const u8 = &.{},
    /// `--with <agent@version>` so the sub-agent can delegate onwards. Empty is
    /// a leaf, which is what every persona but a coordinator is.
    with_self: []const u8 = "",
    /// The delegation this is being opened for, minted before the call so a
    /// runner with per-delegation state on disk has somewhere to put it. Empty
    /// only for the nulya arm.
    delegation: []const u8 = "",
    /// Where the PARENT'S commands run, verbatim from its header, so the
    /// delegated session's run in the same place: two sessions over one
    /// workspace, both ledgers on this machine. Empty is this machine.
    /// The nulya arm only — an external harness runs where it runs.
    environment: []const u8 = "",
    /// The parent's `remote_workspace`, meaningless without `environment`.
    workspace: []const u8 = "",
};

/// What opening a conversation came back with.
pub const Started = struct {
    run: proc.Run,
    /// Which implementation this delegation opened on, recorded beside the runner
    /// name. Every later round goes to the same HARNESS; whether it goes to the
    /// same VERSION depends on the arm (`record.Created.runner_version`). Empty
    /// where the harness does not say.
    version: []const u8 = "",
};

/// Open the remote conversation. On success its stdout is the remote handle — a
/// session id for the nulya arm, a thread id for Codex.
///
/// The `proc.Run` shape is the contract even where no process is spawned:
/// "spawn something, read what it said" is what opening a conversation looks
/// like from here.
pub fn start(r: Runner, alloc: std.mem.Allocator, io: std.Io, opts: StartOptions) !Started {
    switch (r) {
        .ext => |word| {
            const id = word[ext_prefix.len..];
            // The version FIRST, before anything is written: it is what this
            // delegation is nailed to for the rest of its life, and a runner
            // nobody activated is a definition that cannot run at all.
            const version = switch (try external.resolveCurrent(alloc, io, opts.exe, id)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => |v| v,
            };
            // Then the persona, because `op=open` is handed its PATH — a runner
            // that builds a thread out of it needs it to exist by then, and the
            // frozen copy is what stops this delegation from following later
            // edits to the definition file.
            switch (try external.freezePersona(alloc, io, std.Io.Dir.cwd(), opts.delegation, opts.prompt)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => {},
            }
            // `with` and `with_self` say nothing here, for the reason they say
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
                // The frozen EXTENSION version — "the same runner, at the same
                // version, for every later round" as it means out here. Whatever
                // the harness behind it calls its own version is that runner's
                // business.
                .version = version,
            };
        },
        .claude => {
            // Reachability first, at the cost of one local process: a definition
            // naming a harness this machine does not have is refused HERE, before
            // a record exists and before a receipt says work is under way.
            const version = switch (try claude.probe(alloc, io, opts.env)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => |v| v,
            };
            // The persona is frozen into the delegation rather than left in the
            // rendered file: Claude rebuilds its prompt from flags on every round,
            // so without a copy this delegation would follow edits to the
            // definition.
            switch (try claude.freezePersona(alloc, io, std.Io.Dir.cwd(), opts.delegation, opts.prompt)) {
                .failed => |f| return .{ .run = .{ .code = 1, .stdout = "", .stderr = @constCast(f) } },
                .ok => {},
            }
            // No process is started: a Claude session comes into being when the
            // first `claude -p --session-id <uuid>` runs, in the background task
            // driving the first round. The name is what this opens, and it is
            // enough to resume from ever after.
            //
            // `with` and `with_self` say nothing here: they are nulya
            // composition.
            return .{
                .run = .{ .code = 0, .stdout = try record.mintUuid(alloc, io), .stderr = "" },
                .version = version,
            };
        },
        .pi => {
            // Reachability first, as on the claude arm: a definition naming a
            // harness this machine does not have is refused before a record
            // exists.
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
            // `with` and `with_self` say nothing here: they are nulya
            // composition, and a Codex thread has its own tools. A definition
            // naming members for a codex agent is warned about when it is read
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
            // The persona rides as BYTES the header freezes: nothing is
            // installed, so this session's identity text cannot be pruned out
            // from under its own resume.
            //
            // `--bare`: the workspace's standing `[extensions] with` is read as
            // empty for it. Inheriting it would give a sub-agent capabilities
            // its author never wrote down.
            try argv.appendSlice(alloc, &.{ opts.exe, "session", "new", "--bare", "--prompt", opts.prompt });
            // Not inherited by `session new` itself (`--bare` or not): a child
            // session is told where its commands run, or it opens on this
            // machine while its parent works on another one.
            if (opts.environment.len != 0) try argv.appendSlice(alloc, &.{ "--env", opts.environment });
            if (opts.workspace.len != 0) try argv.appendSlice(alloc, &.{ "--workspace", opts.workspace });
            if (opts.profile.len != 0) try argv.appendSlice(alloc, &.{ "--profile", opts.profile });
            if (opts.model.len != 0) try argv.appendSlice(alloc, &.{ "--model", opts.model });
            for (opts.with) |member| try argv.appendSlice(alloc, &.{ "--with", member });
            if (opts.with_self.len != 0) try argv.appendSlice(alloc, &.{ "--with", opts.with_self });
            return .{ .run = try proc.run(alloc, io, argv.items) };
        },
    }
}

/// Deliver one message into the conversation. The CHANNEL is the runner's: the
/// nulya arm appends into the child session's own inbox, which the kernel drains
/// at its next step boundary, so a message sent while the sub-agent is working
/// reaches it mid-run for free. Every other arm writes `<d>/inbox/`; one channel
/// for all of them would cost that mid-run delivery.
pub fn send(
    r: Runner,
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    exe: []const u8,
    remote: []const u8,
    delegation: []const u8,
    msg: mailbox.Message,
) !proc.Run {
    switch (r) {
        .nulya => return proc.run(alloc, io, &.{ exe, "session", "append", remote, msg.text }),
        .codex, .claude, .pi, .ext => {
            // Always the file, never "steer if something is running": whether a
            // message arrives at the next natural boundary or is folded into the
            // turn in flight is the RUNNER's decision, made when it drains. A
            // sender deciding it would be racing the runner for the answer.
            //
            // How it was sent goes IN with it: an interrupt written as a second
            // file is a window in which a runner can take the message and fold it
            // into the turn that interrupt is about to cut short.
            mailbox.put(alloc, io, base, delegation, msg) catch |err| {
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

// ── naming the remote ───────────────────────────────────────────────────────
//
// A receipt names the remote conversation and a report says where the whole of
// it can be read. Both sentences are per-runner and both live here, so the two
// call sites cannot give two answers to one question.

/// What holds this conversation, in one phrase for the middle of a sentence.
pub fn remoteLabel(r: Runner, alloc: std.mem.Allocator, remote: []const u8) ![]const u8 {
    return switch (r) {
        .nulya => try std.fmt.allocPrint(alloc, "session {s}", .{remote}),
        .codex => try std.fmt.allocPrint(alloc, "codex thread {s}", .{remote}),
        .claude => try std.fmt.allocPrint(alloc, "claude session {s}", .{remote}),
        .pi => try std.fmt.allocPrint(alloc, "pi session {s}", .{remote}),
        // Whatever the runner named it: this side does not know what kind of
        // thing that handle is, so "session" would be a guess.
        .ext => |word| try std.fmt.allocPrint(alloc, "{s} conversation {s}", .{ word, remote }),
    };
}

/// Where the whole of it can be read. A pointer at the wrong harness's
/// transcript invites a command that cannot work.
pub fn transcriptHint(r: Runner, alloc: std.mem.Allocator, remote: []const u8) ![]const u8 {
    return switch (r) {
        .nulya => try std.fmt.allocPrint(alloc, "Its full transcript is `nulya session events {s}`.", .{remote}),
        .codex => try std.fmt.allocPrint(alloc, "It ran as codex thread {s}; its transcript is Codex's own.", .{remote}),
        // A pointer that actually works: Claude keeps the whole conversation and
        // resumes it by that name.
        .claude => try std.fmt.allocPrint(alloc, "It ran as claude session {s}; the whole of it is `claude --resume {s}`.", .{ remote, remote }),
        .pi => try std.fmt.allocPrint(alloc, "It ran as pi session {s}; the whole of it is `pi --session {s}`.", .{ remote, remote }),
        // No command is offered: only that runner knows where its harness keeps
        // a transcript.
        .ext => |word| try std.fmt.allocPrint(alloc, "It ran on {s} as {s}, which keeps its own transcript.", .{ word, remote }),
    };
}

/// Is a message sitting in the channel that nobody has taken yet?
///
/// The runner asks it before letting go of its lease and again after; a sender
/// never does, having just delivered. Unreadable counts as NOTHING pending — the
/// sender's probe is the other half, and an error here is not evidence.
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
        // `<d>/inbox/` — a fact about the DELEGATION, where the nulya arm's is a
        // fact about a session.
        .codex, .claude, .pi, .ext => return mailbox.pending(alloc, io, base, delegation),
    }
}

fn holdsJson(io: std.Io, base: std.Io.Dir, path: []const u8) bool {
    var dir = base.openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind == .directory) continue;
        // The kernel deposits `<name>.tmp` and renames it into place, so only a
        // `.json` has actually landed.
        if (std.mem.endsWith(u8, entry.name, ".json")) return true;
    }
    return false;
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

    // An id that could not name an extension is as unknown as a misspelling.
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
