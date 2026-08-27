//! An external runner: a delegation held by a harness some OTHER extension
//! knows how to talk to (`runner: ext:<id>`).
//!
//! **What this is for.** The four arms beside it (`nulya`, `codex`, `claude`,
//! `pi`) are in this package because they were the first four; nothing about
//! them is privileged. A fifth harness — one this repository has never heard of,
//! one somebody wrote this morning, one that needs a runtime nobody wants
//! compiled in here (D12) — reaches the same delegation world view by shipping
//! an ordinary extension with one tool in it. Everything the model sees is
//! unchanged: the same `agent{name|session, task}`, the same `d-…`, the same
//! report arriving through the parent's inbox.
//!
//! **What stays here and what goes out there.** The invariants are this
//! package's, always: the runner lease and its release-and-recheck (D4), the
//! record and the exchange count (D2), the per-delegation inbox and the order
//! messages come out of it (D5), the interrupt marker being written after the
//! message it belongs to (D6), the report framing, the read-only refusal. What
//! goes out is only ever "how do I say this to that harness".
//!
//! ── the `agent_runner` contract ─────────────────────────────────────────────
//!
//! A runner extension declares ONE tool, named exactly `agent_runner`, with
//! `"surface": "internal"` (it is a driver's tool, never a model's). It is
//! called through `nulya ext run <id>@<version> agent_runner --arg k=v …`, so
//! its arguments arrive the way every other extension's do (DESIGN §7.3): as one
//! JSON object on stdin, and as `NULYA_ARG_<key>` in the environment.
//!
//! It answers two operations, told apart by `op`:
//!
//!   `op=open`   Open a conversation. Arguments: `delegation` (the `d-…` this is
//!               for), `persona` (PATH of the frozen system prompt),
//!               `permissions` (`readonly` / `default` / `unsafe`), `model`
//!               (opaque, omitted when the definition named none). On success
//!               print `{"remote":"<handle>"}` — any
//!               string that lets a later round find the conversation again —
//!               and exit 0. Exit non-zero to REFUSE the whole delegation:
//!               stderr is the reason and reaches the model, and nothing is
//!               recorded.
//!
//!   `op=round`  Answer exactly one message. Arguments: `delegation`, `persona`,
//!               `permissions`, `model` as above, plus `remote` (what `open` gave
//!               back), `message_file` (PATH of the one message to answer) and
//!               `interrupt` (PATH of a marker file). On success print
//!               `{"text":"<the harness's final answer for this round>"}` and
//!               exit 0. Exit non-zero when the round could not be run: stderr
//!               is the reason, and the message goes back into the delegation's
//!               inbox for the next round rather than being lost.
//!
//!               While the turn is in flight, watch `interrupt`. If that file
//!               appears, delete it, stop the turn in whatever way the harness
//!               offers, and answer `{"text":"","interrupted":true}` — the
//!               message behind the interrupt is already queued, and the next
//!               round takes it (D6).
//!
//! Two texts arrive as PATHS rather than values, and deliberately: a persona and
//! a task are as long as they need to be, and a command line is not a place to
//! put either (Windows caps the whole of one at 32 KiB). Everything else is a
//! short scalar.
//!
//! **`permissions` is three words, and the narrow one is a ceiling (D10,
//! contract ar-h).** `readonly` means the harness must be held to reading: a
//! runner that cannot do that must refuse at `op=open`, because silently
//! running wider than the definition asked for is the one outcome this whole
//! field exists to prevent. `default` is ordinary work in this checkout;
//! `unsafe` is everything the harness can do, and it only ever arrives because
//! somebody wrote the word. **A word this runner does not recognise is refused
//! too** — the vocabulary may grow, and a runner that read a future level as
//! its own default would be widening a ceiling it never understood.
//!
//! **The version is frozen when the delegation opens (D7).** `current` is
//! resolved once, at `open`, and every later round of that delegation calls that
//! exact version — the same discipline a session freezes its composition with
//! (physics #2). Activating a new version of a runner changes what the NEXT
//! delegation runs on, never what a conversation already under way is answered
//! by.

const std = @import("std");
const proc = @import("proc.zig");
const record = @import("record.zig");
const mailbox = @import("mailbox.zig");

/// The one tool name a runner extension must declare. Fixed rather than
/// configurable: "which tool drives a round" is not a decision a definition
/// should have to carry, and a package with two of them is two runners.
pub const tool_name = "agent_runner";

/// How much of a round's answer is read back. The report the parent finally sees
/// is bounded again by the task supervisor's own head/tail budget (DESIGN §6.1).
const max_round_bytes: usize = 1 << 20;

/// A persona longer than this is refused rather than truncated. Generous — it is
/// handed over as a path, so the only bound is what is sensible to freeze.
const max_persona_bytes: usize = 1 << 20;

// ── resolving the extension ─────────────────────────────────────────────────

/// Which version of `<id>` a delegation opened now would be nailed to.
///
/// Asked of the kernel rather than worked out from the store: root order,
/// shadowing and what `current` means are the kernel's answers (DESIGN §5.1,
/// §7.2), and a second implementation here would be a second answer. The two
/// ways it can fail are the two the kernel itself distinguishes for `--with` —
/// nothing built under that name, or nothing activated — because the fix is
/// different.
pub fn resolveCurrent(
    alloc: std.mem.Allocator,
    io: std.Io,
    exe: []const u8,
    id: []const u8,
) !union(enum) { ok: []const u8, failed: []const u8 } {
    const said = proc.run(alloc, io, &.{ exe, "ext", "list" }) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(alloc, "could not list this machine's extensions ({s})", .{@errorName(err)}) };
    };
    if (said.code != 0) {
        return .{ .failed = try std.fmt.allocPrint(alloc, "could not list this machine's extensions: {s}", .{proc.detail(said)}) };
    }
    return switch (versionIn(said.stdout, id)) {
        .version => |v| .{ .ok = try alloc.dupe(u8, v) },
        .no_current => .{ .failed = try std.fmt.allocPrint(
            alloc,
            "extension '{s}' has no active version, so there is nothing to freeze this delegation on. Activate the version this runner should be held to: `nulya ext activate {s} <version>`.",
            .{ id, id },
        ) },
        .absent => .{ .failed = try std.fmt.allocPrint(
            alloc,
            "no extension '{s}' here, so `runner: ext:{s}` names nothing that could drive this agent. Build and activate it first (`nulya ext build <path>` then `nulya ext activate {s} <version>`); `nulya ext list` shows what this machine holds.",
            .{ id, id, id },
        ) },
    };
}

/// The two ways an id can fail to name a runner, kept apart because the fix is
/// different — nothing built under that name, or nothing activated.
pub const Listed = union(enum) { version: []const u8, no_current, absent };

/// Which version `nulya ext list` says is in effect for `id`. A tab-separated
/// projection (`<id>\t<version>\t<root>…`), read for its first two columns only:
/// the rest of the line is what a package contributes and where it came from,
/// and this asks one question.
pub fn versionIn(listing: []const u8, id: []const u8) Listed {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\n");
        if (line.len == 0) continue;
        // A copy an earlier root already answers for never runs, so it is not
        // the version a delegation would open on either.
        if (std.mem.indexOf(u8, line, "\t(shadowed)") != null) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, id)) continue;
        const version = std.mem.trim(u8, fields.next() orelse "", " \t");
        // `(no current)` is what the listing prints for an id that holds built
        // versions with none of them activated.
        if (version.len == 0 or !std.mem.startsWith(u8, version, "v-")) return .no_current;
        return .{ .version = version };
    }
    return .absent;
}

/// `<id>@<version>` — the reference every call of this delegation uses.
pub fn refOf(alloc: std.mem.Allocator, id: []const u8, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}@{s}", .{ id, version });
}

// ── opening ─────────────────────────────────────────────────────────────────

/// Copy the rendered persona into the delegation, once, when it opens — so the
/// runner is handed a path that cannot change under it, whatever happens to the
/// definition file afterwards (`record.freezePersona`).
pub fn freezePersona(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    delegation: []const u8,
    rendered: []const u8,
) !union(enum) { ok, failed: []const u8 } {
    return switch (try record.freezePersona(alloc, io, base, delegation, rendered, max_persona_bytes)) {
        .ok => .ok,
        .failed => |f| .{ .failed = f },
        .too_long => |n| .{ .failed = try std.fmt.allocPrint(
            alloc,
            "this persona is {d} bytes, and a frozen persona is held to {d}.",
            .{ n, max_persona_bytes },
        ) },
    };
}

pub const OpenOptions = struct {
    ref: []const u8,
    delegation: []const u8,
    persona: []const u8,
    permissions: record.Permissions,
    model: []const u8,
};

/// `op=open`. Its stdout is the handle this delegation is answered through;
/// a non-zero exit refuses the delegation outright (D10 included).
pub fn open(
    alloc: std.mem.Allocator,
    io: std.Io,
    exe: []const u8,
    opts: OpenOptions,
) !union(enum) { ok: []const u8, failed: []const u8 } {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ exe, "ext", "run", opts.ref, tool_name });
    try appendArg(alloc, &argv, "op", "open");
    try appendArg(alloc, &argv, "delegation", opts.delegation);
    try appendArg(alloc, &argv, "persona", opts.persona);
    try appendArg(alloc, &argv, "permissions", opts.permissions.label());
    if (opts.model.len != 0) try appendArg(alloc, &argv, "model", opts.model);

    const said = proc.run(alloc, io, argv.items) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(alloc, "could not run {s} ({s})", .{ opts.ref, @errorName(err) }) };
    };
    if (said.code != 0) return .{ .failed = try std.fmt.allocPrint(alloc, "{s} refused to open this delegation: {s}", .{ opts.ref, proc.detail(said) }) };

    const obj = jsonObject(alloc, said.stdout) orelse {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "{s} answered `op=open` with something that is not a JSON object: {s}",
            .{ opts.ref, proc.detail(said) },
        ) };
    };
    const remote = std.mem.trim(u8, stringOf(obj, "remote") orelse "", " \t\r\n");
    if (remote.len == 0) {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "{s} opened no conversation: `op=open` must answer {{\"remote\":\"…\"}} with the handle a later round finds it by.",
            .{opts.ref},
        ) };
    }
    return .{ .ok = try alloc.dupe(u8, remote) };
}

// ── driving one round ───────────────────────────────────────────────────────

/// Everything a round of this delegation needs. No process and no connection:
/// each round is one `ext run`, so there is nothing to hold open between them —
/// which is also why this arm needs no `close`.
pub const Session = struct {
    exe: []const u8,
    ref: []const u8,
    remote: []const u8,
    persona: []const u8,
    model: []const u8,
    permissions: record.Permissions = record.default_permissions,
};

pub const Attempt = union(enum) { ok: Session, failed: []const u8 };

/// What a round of this delegation will be run by, from what the record froze.
pub fn attach(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    exe: []const u8,
    id: []const u8,
    version: []const u8,
    delegation: []const u8,
    remote: []const u8,
    permissions: record.Permissions,
    model: []const u8,
) !Attempt {
    if (delegation.len == 0) {
        return .{ .failed = "an external runner drives a delegation: its persona and its message channel both live in `.nulya/delegations/<d>/`" };
    }
    if (version.len == 0) {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "delegation {s} names the runner ext:{s} but its record froze no version of it, so there is no implementation to hold it to. Start a fresh delegation.",
            .{ delegation, id },
        ) };
    }
    const persona = try record.pathIn(alloc, delegation, record.persona_name);
    base.access(io, persona, .{}) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(alloc, "delegation {s} has no frozen persona ({s})", .{ delegation, @errorName(err) }) };
    };
    return .{ .ok = .{
        .exe = exe,
        .ref = try refOf(alloc, id, version),
        .remote = remote,
        .persona = persona,
        .model = model,
        .permissions = permissions,
    } };
}

/// One round, as the loop in `runner.zig` reads every round.
pub const RoundResult = struct {
    text: []const u8 = "",
    stopped: []const u8 = "",
    failure: []const u8 = "",
    interrupted: bool = false,
};

/// Answer the next message waiting for this delegation.
///
/// The message is read from the inbox HERE rather than out there: the wake
/// invariant (D4) is this package's to keep, and a runner on the far side of a
/// contract cannot be trusted with it. It is copied to a file the runner reads,
/// and acked only once the round answers — so a runner that crashes, or a
/// harness that is not installed, costs a retry rather than a message.
pub fn driveRound(
    alloc: std.mem.Allocator,
    io: std.Io,
    sess: *Session,
    base: std.Io.Dir,
    delegation: []const u8,
    interrupt_path: []const u8,
) !RoundResult {
    var out: RoundResult = .{};

    const entry = (try mailbox.peekOne(alloc, io, base, delegation)) orelse {
        out.stopped = "idle";
        return out;
    };
    const message = entry.msg;
    // Left in the inbox until the round settles, and dropped only then — every
    // early return goes through here having acked nothing (`mailbox.peekAfter`).
    var answered = false;
    defer if (answered) mailbox.ack(alloc, io, base, delegation, entry.name);

    const message_path = try record.pathIn(alloc, delegation, mailbox.message_name);
    base.writeFile(io, .{ .sub_path = message_path, .data = message.text }) catch |err| {
        out.failure = try std.fmt.allocPrint(alloc, "could not stage that turn for {s} ({s})", .{ sess.ref, @errorName(err) });
        return out;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ sess.exe, "ext", "run", sess.ref, tool_name });
    try appendArg(alloc, &argv, "op", "round");
    try appendArg(alloc, &argv, "delegation", delegation);
    try appendArg(alloc, &argv, "remote", sess.remote);
    try appendArg(alloc, &argv, "persona", sess.persona);
    try appendArg(alloc, &argv, "message_file", message_path);
    try appendArg(alloc, &argv, "permissions", sess.permissions.label());
    if (sess.model.len != 0) try appendArg(alloc, &argv, "model", sess.model);
    try appendArg(alloc, &argv, "interrupt", interrupt_path);

    const said = proc.run(alloc, io, argv.items) catch |err| {
        out.failure = try std.fmt.allocPrint(alloc, "could not run {s} ({s})", .{ sess.ref, @errorName(err) });
        return out;
    };
    if (said.code != 0) {
        out.failure = try std.fmt.allocPrint(alloc, "{s} could not answer that turn: {s}", .{ sess.ref, proc.detail(said) });
        return out;
    }

    const obj = jsonObject(alloc, said.stdout[0..@min(said.stdout.len, max_round_bytes)]) orelse {
        out.failure = try std.fmt.allocPrint(
            alloc,
            "{s} answered `op=round` with something that is not a JSON object: {s}",
            .{ sess.ref, proc.detail(said) },
        );
        return out;
    };
    // Answered either way from here: the runner ran the turn, and whatever it
    // produced is this round's answer. An interrupted round is answered too —
    // the run it cut short consumed this message and its half-answer is thrown
    // away on purpose, because the interrupt IS the new direction and the
    // message behind it is already waiting (D6).
    answered = true;
    out.interrupted = boolOf(obj, "interrupted");
    if (!out.interrupted) {
        if (stringOf(obj, "text")) |text| out.text = std.mem.trim(u8, text, " \t\r\n");
        out.stopped = "settled";
    }
    return out;
}

// ── small shared pieces ─────────────────────────────────────────────────────

fn appendArg(alloc: std.mem.Allocator, argv: *std.ArrayList([]const u8), key: []const u8, value: []const u8) !void {
    try argv.appendSlice(alloc, &.{ "--arg", try std.fmt.allocPrint(alloc, "{s}={s}", .{ key, value }) });
}

fn jsonObject(alloc: std.mem.Allocator, text: []const u8) ?std.json.ObjectMap {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch return null;
    return switch (parsed.value) {
        .object => |o| o,
        else => null,
    };
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn boolOf(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse std.json.Value{ .null = {} }) {
        .bool => |b| b,
        else => false,
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

test "the version a delegation freezes on is the one in effect, and the two ways there is none are told apart" {
    const listing =
        "compact\tv-aaa\t[project]\t[tools]\n" ++
        "my-runner\tv-bbb\t[project]\t[tools]\n" ++
        "my-runner\tv-ccc\t[user]\t[tools]\t(shadowed)\n" ++
        "half-built\t(no current)\t[project]\n";

    try std.testing.expectEqualStrings("v-bbb", versionIn(listing, "my-runner").version);
    // The shadowed copy is not what would run, so it is not what is frozen.
    try std.testing.expect(versionIn(listing, "nowhere") == .absent);
    try std.testing.expect(versionIn(listing, "half-built") == .no_current);
    try std.testing.expect(versionIn("no extensions\n", "my-runner") == .absent);
}
