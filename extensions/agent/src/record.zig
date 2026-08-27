//! `.nulya/delegations/<d-id>/` — what this package knows about one delegation.
//!
//! **Why a delegation has an identity of its own.** The model used to name a
//! sub-agent by the SESSION it happened to run in (`agent{session:"s-…"}`).
//! That works exactly as long as every sub-agent is a nulya session; the moment
//! one is a Codex thread or a Claude process there is no `s-…` to name, and the
//! model would need a different vocabulary per runner. So the thing the model
//! names is the CONVERSATION — `d-<12 hex>` — and what is behind it (a nulya
//! session, a thread id, a pid) is the runner's business.
//!
//! **Abstraction, not concealment (D2).** The record is an ordinary readable
//! journal: it says which runner drives this delegation, which remote
//! conversation that runner opened, and every turn anybody sent. A report still
//! points at the remote transcript. Nothing here hides a fact — it gives the
//! facts one name.
//!
//! **Why a journal and not a state file.** Two processes write to a delegation
//! (the `agent` tool in the caller's step, and the `run` tool in a background
//! task) and neither can be sure the other is not writing right now. Appending
//! whole lines under a lock is the discipline `src/journals/journal.zig` already
//! settled on for exactly that; this is that discipline, re-implemented, because
//! an extension is compiled on its own and cannot import the kernel.
//!
//! **Layout.**
//!
//!   `<d>/record.jsonl`   this journal: one `created` row, then one `turn` row
//!                        per message anybody sent (the first task included).
//!   `<d>/.runner.lock`   the runner's exclusive lease (D4). An OS advisory
//!                        lock, so a runner that dies releases it — a marker
//!                        file would strand the delegation for ever.
//!   `<d>/interrupt`      "stop what you are doing and take the new message
//!                        now" (D6). Empty; its existence is the message.
//!   `<d>/inbox/`         messages for a runner that has no inbox of its own.
//!                        The nulya runner delivers into the child session's
//!                        own inbox instead (D5), so this stays empty here.
//!   `<d>/persona.md`     the persona frozen for this delegation, for a harness
//!                        that is told its system prompt on every process.
//!   `<d>/message.txt`    the one message a round is answering, staged where an
//!                        EXTERNAL runner extension can read it (`external.zig`)
//!                        — written only by whoever holds the lease, and only
//!                        for as long as that round.
//!
//! Every entry point takes the workspace directory rather than assuming the
//! process's own: the callers pass `std.Io.Dir.cwd()` (an extension is spawned
//! in the workspace, DESIGN §7.6) and the tests pass a temporary one.

const std = @import("std");

/// Where delegations live, relative to the workspace.
pub const root = ".nulya/delegations";

/// How a step knows which delegation it is running as. Set by the runner on the
/// process it drives, beside `NULYA_AGENT_DEPTH` and for the same reasons: it is
/// a fact about this chain rather than a secret, so it survives the environment
/// sanitising every child gets (DESIGN §7.6), and it is what lets a delegated
/// session read its OWN frozen policy instead of a definition file that may have
/// been edited since (`main.allowedHere`).
pub const delegation_var = "NULYA_AGENT_DELEGATION";

pub const record_name = "record.jsonl";
pub const lock_name = ".runner.lock";
pub const interrupt_name = "interrupt";
pub const inbox_name = "inbox";

/// Where one round's message is staged for a runner that reads it as a file
/// (`external.zig`'s contract). A path rather than a value because a task is as
/// long as it needs to be and a command line is not; whoever holds the lease is
/// the only writer, so one name is enough.
pub const message_name = "message.txt";

// ── how much a delegation may do (contract ar-h / D13) ──────────────────────

/// The one ceiling a delegation carries, in three words.
///
/// **Why three and not a flag.** `readonly` answered one question — "may this
/// sub-agent change anything" — and every harness has an answer for it. But the
/// other side of that flag was doing two jobs at once: "work in this checkout
/// the way an agent normally does" and "do whatever you are able to", and those
/// are not the same grant. A definition that needs the second one had no way to
/// say so, and a driver reading the record had no way to tell which one it got.
///
/// **`default` and `unsafe` are the same thing on the nulya arm today (D13).**
/// There is no gate between them and there is not going to be one built out of
/// guessing at command strings: a ceiling made of string classification is a
/// ceiling that reads convincingly and holds nothing (agents-and-review §1).
/// Real separation is the sandbox (PLAN §3.8). What the two words DO differ in
/// right now is what the record says, and that is not nothing — it is the
/// frozen answer a sandbox will read when there is one, and it is what an
/// external harness that HAS the distinction is told (Codex and Claude both do).
///
/// **Escalation is never inherited.** `unsafe` reaches a delegation from its
/// definition or from the `agent` call that opened it, and nowhere else: no
/// front end's mode, no environment variable, nothing about the parent. The
/// call itself passes through the parent session's own gate, so a person
/// watching an `ask`-mode conversation sees the word and can refuse it.
pub const Permissions = enum {
    /// Reads and nothing else. A hard ceiling every runner must be able to
    /// enforce or refuse the delegation for (D10).
    readonly,
    /// What an agent working in this checkout ordinarily does: read, write,
    /// run things. The default, and what an unwritten field means.
    default,
    /// Everything the harness is able to do, with its own guard rails off.
    /// Written on purpose, by somebody who meant it.
    unsafe,

    /// The word as a definition writes it and as the record freezes it. Null is
    /// "not one of the three", which is never read as a default: a misspelling
    /// that fell back to `default` would be a ceiling quietly widened, which is
    /// the one outcome this field exists to prevent.
    pub fn parse(text: []const u8) ?Permissions {
        const word = std.mem.trim(u8, text, " \t");
        if (std.mem.eql(u8, word, "readonly")) return .readonly;
        if (std.mem.eql(u8, word, "default")) return .default;
        if (std.mem.eql(u8, word, "unsafe")) return .unsafe;
        return null;
    }

    pub fn label(self: Permissions) []const u8 {
        return @tagName(self);
    }

    /// The read-only ceiling, asked as the one question the runners' own
    /// mechanisms answer. A named predicate rather than `== .readonly` spelled
    /// out in five files: the arms all ask this one thing.
    pub fn isReadonly(self: Permissions) bool {
        return self == .readonly;
    }
};

/// What an unwritten field means: an ordinary delegation.
pub const default_permissions: Permissions = .default;

/// The three words, for the messages that have to list them.
pub const permission_words = "readonly, default, unsafe";

const hex_len = 12;

/// A delegation id, checked because it becomes a path — and because "that is
/// not a delegation id" is a better answer than a directory that is not there.
pub fn isPlainId(id: []const u8) bool {
    if (id.len != "d-".len + hex_len) return false;
    if (!std.mem.startsWith(u8, id, "d-")) return false;
    for (id["d-".len..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// A fresh one. Randomness rather than a counter: two `agent` calls in the same
/// step are two processes with no way to agree on the next number, and the id
/// is a name, not an ordering.
pub fn mint(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [6]u8 = undefined;
    io.random(&bytes);
    return std.fmt.allocPrint(alloc, "d-{x:0>12}", .{std.mem.readInt(u48, &bytes, .little)});
}

/// A UUID (version 4), for a harness that names its conversations that way.
///
/// Minted HERE rather than read back from the harness, and for the same reason
/// the delegation id is: the record has to be able to name the remote
/// conversation before a single turn has run, so the name must be something this
/// side chose. `claude --session-id` requires this exact shape; `pi --session-id`
/// takes any string and gets one anyway, because two harnesses naming their
/// sessions two different ways would be a difference with nothing behind it.
pub fn mintUuid(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 1
    return std.fmt.allocPrint(
        alloc,
        "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}",
        .{
            std.mem.readInt(u32, b[0..4], .big),
            std.mem.readInt(u16, b[4..6], .big),
            std.mem.readInt(u16, b[6..8], .big),
            std.mem.readInt(u16, b[8..10], .big),
            std.mem.readInt(u48, b[10..16], .big),
        },
    );
}

pub fn dirOf(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, id });
}

pub fn pathIn(alloc: std.mem.Allocator, id: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ root, id, name });
}

// ── the journal ─────────────────────────────────────────────────────────────

/// The row a delegation opens with: everything about it that is decided once.
///
/// Everything here is FROZEN for the same reason a session freezes its
/// composition (physics #2): a delegation already under way is not re-decided by
/// a file somebody edited since. The definition's job is to create NEW
/// delegations; it is never consulted again about one that exists.
///
/// That covers the runner (every later turn goes to the same harness), the
/// ceiling (a follow-up must not be able to widen it) and the three POLICY
/// numbers below — how many turns this delegation may have, how many steps one
/// of its rounds may take, and who it may pass work to. Those three used to be
/// read from the definition as it reads TODAY, which made a live delegation's
/// budget follow an edit and made deleting a definition file strand every
/// conversation wearing it.
///
/// `runner_version` is the one column that is NOT uniformly a freeze, and the
/// difference is written down rather than smoothed over (see it below).
pub const Created = struct {
    agent: []const u8,
    runner: []const u8,
    /// Which implementation of the runner this delegation opened on. **Two
    /// strengths, one column, and only one of them is a pin.**
    ///
    ///   * `ext:<id>` — a PINNED EXECUTION IDENTITY. `current` is resolved once
    ///     at `op=open` and the `v-…` frozen here is what every later round
    ///     actually calls. It can be a pin because the old version is still in
    ///     the store: activating a new one decides what the NEXT delegation runs
    ///     on, never what this conversation is answered by.
    ///   * `claude` / `pi` — OBSERVED PROVENANCE. What `--version` said on the
    ///     machine at the moment this opened, and nothing more: later rounds run
    ///     whatever that name resolves to on PATH now. There is no pin available
    ///     to make — an upgrade replaces the binary, and the version this names
    ///     is usually no longer on the machine at all. Refusing on a mismatch
    ///     would not restore reproducibility; it would only kill conversations
    ///     that would have resumed perfectly well.
    ///   * `codex` (no version of its own over app-server) and `nulya` (this
    ///     binary is the one writing the record) leave it empty.
    ///
    /// The rule the two follow is one rule: **claim only the freeze that can
    /// actually be enforced.** A field that reads as a guarantee everywhere and
    /// holds in one place out of three is worse than a field that says which is
    /// which.
    runner_version: []const u8 = "",
    /// What the runner opened to hold this conversation — a session id for the
    /// nulya runner, a thread id for Codex, whatever the harness calls it.
    remote: []const u8,
    parent: []const u8,
    /// The ceiling this delegation was opened at, frozen with everything else
    /// decided once. A row with no such column is not a row this build wrote,
    /// and it is read back as `readonly` — the narrowest answer, because a
    /// record that cannot say what it granted has not granted anything.
    permissions: Permissions = .readonly,
    profile: []const u8 = "",
    model: []const u8 = "",
    /// What an EXTERNAL runner was asked to run on — an opaque string in that
    /// harness's own vocabulary (D9), never a nulya profile/model pair.
    ///
    /// Its own column rather than reusing `model` on purpose: a row saying
    /// `runner: "codex", model: "gpt-5"` would read as a nulya model id, and a
    /// record that has to be interpreted before it can be read is the thing D2
    /// says not to build.
    ///
    /// Unlike `profile` and `model`, this one IS read back: claude, pi and an
    /// external runner are told which model to use on every round, so each
    /// `attach` takes it from here (`runner.run`). Codex is the exception it was
    /// first written for — a thread froze its model when it was created, so a
    /// later round has nothing to say.
    runner_model: []const u8 = "",
    /// How many follow-up turns this delegation may have. Zero is "no limit",
    /// which is what an unwritten `max_exchanges:` means — and what a row from
    /// before this column means, which is the same answer those delegations
    /// have been running under all along.
    max_exchanges: u32 = 0,
    /// The step budget one round of it may spend. Zero is the kernel's own.
    max_steps: u32 = 0,
    /// The personas this delegation may pass work to (`agents:`). Empty is a
    /// LEAF — the narrow answer, and the right one for a row that predates this
    /// column: a delegation opened before it was written froze no whitelist, and
    /// inventing a wide one from today's definition is exactly the drift this
    /// column exists to stop.
    agents: []const []const u8 = &.{},
};

/// A delegation, as its journal describes it.
pub const State = struct {
    created: Created,
    /// How many messages anybody has sent into it — the first task included.
    /// THE count of exchanges (contract §1): it is the only one an external
    /// runner can answer too, where "count the child session's user turns" is
    /// a fact about nulya sessions and nothing else.
    turns: u32 = 0,
};

pub fn appendCreated(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    id: []const u8,
    c: Created,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(1);
    try jw.objectField("kind");
    try jw.write("created");
    try jw.objectField("at");
    try jw.write(try rfc3339Now(alloc, io));
    try jw.objectField("agent");
    try jw.write(c.agent);
    try jw.objectField("runner");
    try jw.write(c.runner);
    if (c.runner_version.len != 0) {
        try jw.objectField("runner_version");
        try jw.write(c.runner_version);
    }
    try jw.objectField("remote");
    try jw.write(c.remote);
    try jw.objectField("parent");
    try jw.write(c.parent);
    try jw.objectField("permissions");
    try jw.write(c.permissions.label());
    if (c.profile.len != 0) {
        try jw.objectField("profile");
        try jw.write(c.profile);
    }
    if (c.model.len != 0) {
        try jw.objectField("model");
        try jw.write(c.model);
    }
    if (c.runner_model.len != 0) {
        try jw.objectField("runner_model");
        try jw.write(c.runner_model);
    }
    // The policy columns, written only when they say something. A delegation
    // with no limits and no whitelist writes the same row it always did.
    if (c.max_exchanges != 0) {
        try jw.objectField("max_exchanges");
        try jw.write(c.max_exchanges);
    }
    if (c.max_steps != 0) {
        try jw.objectField("max_steps");
        try jw.write(c.max_steps);
    }
    if (c.agents.len != 0) {
        try jw.objectField("agents");
        try jw.beginArray();
        for (c.agents) |one| try jw.write(one);
        try jw.endArray();
    }
    try jw.endObject();
    try out.writer.writeByte('\n');
    try appendLine(alloc, io, base, id, out.writer.buffered());
}

/// One message sent into the delegation. `interrupt` says how it was sent, not
/// what it is: a message is always an ordinary turn (D3).
pub fn appendTurn(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    id: []const u8,
    interrupt: bool,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(1);
    try jw.objectField("kind");
    try jw.write("turn");
    try jw.objectField("at");
    try jw.write(try rfc3339Now(alloc, io));
    if (interrupt) {
        try jw.objectField("interrupt");
        try jw.write(true);
    }
    try jw.endObject();
    try out.writer.writeByte('\n');
    try appendLine(alloc, io, base, id, out.writer.buffered());
}

/// A row that is there but cannot be believed. Distinct from "no delegation by
/// that name" (null) on purpose — see the discipline on `read`.
pub const Corrupt = error{CorruptDelegationRecord};

/// Read the journal back. Null when there is no delegation by that name, or
/// when its journal has no `created` row yet — both mean "this tool has never
/// opened a delegation called that", which is the one answer a caller needs.
///
/// ── three answers, and which fields get which ──────────────────────────────
///
/// A TORN FINAL LINE is ignored: an append that was interrupted, or one in
/// flight right now, is not a fact yet. That has not changed.
///
/// An ABSENT field reads as its default, because that is what a row written
/// before the column existed means and those delegations have been running
/// under that answer all along.
///
/// A field that is PRESENT AND UNREADABLE is where this record stopped being
/// provenance and became an authority, and the answer depends on which
/// direction its default points:
///
///   | field                       | fallback | direction |
///   |-----------------------------|----------|-----------|
///   | `permissions`               | readonly | narrowest |
///   | `agents`                    | leaf     | narrowest |
///   | `max_exchanges` `max_steps` | 0        | UNLIMITED |
///
/// The first two can fall back, and do: corruption there can only ever take a
/// capability away, which is the same discipline the kernel's own standing
/// records follow (DESIGN §5.1). The two budgets have no narrow reading
/// available — zero means "no limit" and "the kernel's own" — so a damaged one
/// cannot be read at all, and the whole record is refused instead. Reading
/// `"max_exchanges": "2"` as "unlimited follow-ups" is precisely the fail-open
/// this distinction exists to prevent.
///
/// ── and the shape of the journal itself ────────────────────────────────────
///
/// Read as a two-state machine, because that is all it is: BEFORE the opening
/// row only a `created` is legal, and after it only a `turn`. Anything else — a
/// second `created`, a `kind` this build does not know, a line that is not JSON,
/// a `v` from a schema that is not this one — refuses the whole record.
///
/// Strict rather than skipping, and for the reason the budget columns are: every
/// row this cannot read LOWERS the exchange count, and a lower count is a wider
/// budget. `{"kind":"turm"}` used to fall through both arms in silence and hand
/// the delegation a free follow-up. The `v` check is the same rule pointed
/// forward: a v2 row read by a v1 build would be guessed at rather than
/// understood, and this file is an authority.
pub fn read(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) !?State {
    const path = try pathIn(alloc, id, record_name);
    const bytes = base.readFileAlloc(io, path, alloc, .limited(max_record_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    // A torn final line is an append that was interrupted (or is in flight right
    // now); it is not a fact yet.
    const whole = bytes[0..if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |i| i + 1 else 0];

    var state: ?State = null;
    var lines = std.mem.splitScalar(u8, whole, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch return Corrupt.CorruptDelegationRecord;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return Corrupt.CorruptDelegationRecord,
        };
        // The schema this build reads. A row from another one is not guessed at.
        switch (obj.get("v") orelse std.json.Value{ .null = {} }) {
            .integer => |v| if (v != 1) return Corrupt.CorruptDelegationRecord,
            else => return Corrupt.CorruptDelegationRecord,
        }
        const kind = stringOf(obj, "kind") orelse return Corrupt.CorruptDelegationRecord;
        if (state == null) {
            // Before the opening row, only an opening row is legal.
            if (!std.mem.eql(u8, kind, "created")) return Corrupt.CorruptDelegationRecord;
            state = .{
                .created = .{
                    .agent = stringOf(obj, "agent") orelse "",
                    .runner = stringOf(obj, "runner") orelse "",
                    .runner_version = stringOf(obj, "runner_version") orelse "",
                    .remote = stringOf(obj, "remote") orelse "",
                    .parent = stringOf(obj, "parent") orelse "",
                    // Missing or unreadable is `readonly`, the narrowest of the
                    // three: a delegation whose record cannot say what it was
                    // opened at is not one to keep driving at the wider setting.
                    .permissions = Permissions.parse(stringOf(obj, "permissions") orelse "") orelse .readonly,
                    .profile = stringOf(obj, "profile") orelse "",
                    .model = stringOf(obj, "model") orelse "",
                    .runner_model = stringOf(obj, "runner_model") orelse "",
                    .max_exchanges = try budgetOf(obj, "max_exchanges"),
                    .max_steps = try budgetOf(obj, "max_steps"),
                    .agents = try stringsOf(alloc, obj, "agents"),
                },
            };
            continue;
        }
        // After it, only a turn is — a delegation opens once.
        if (!std.mem.eql(u8, kind, "turn")) return Corrupt.CorruptDelegationRecord;
        state.?.turns += 1;
    }
    return state;
}

/// One of the two budget columns. Absent is zero — no limit, the answer every
/// row written before these columns existed carries. Anything else present is
/// CORRUPTION rather than zero: zero is the widest reading there is here, so
/// falling back to it would let a damaged row hand out an unlimited one (see
/// the table on `read`).
fn budgetOf(obj: std.json.ObjectMap, key: []const u8) !u32 {
    return switch (obj.get(key) orelse return 0) {
        .integer => |i| if (i > 0 and i <= std.math.maxInt(u32)) @intCast(i) else Corrupt.CorruptDelegationRecord,
        else => Corrupt.CorruptDelegationRecord,
    };
}

/// A list of strings, skipping anything in it that is not one. An absent column
/// and an empty list are the same answer, which is what the callers want — and
/// an unreadable one is that answer too, because here it is the NARROW one: a
/// delegation that cannot say who it may delegate to is a leaf.
fn stringsOf(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const items = switch (obj.get(key) orelse return &.{}) {
        .array => |a| a.items,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        switch (item) {
            .string => |s| try out.append(alloc, s),
            else => continue,
        }
    }
    return out.items;
}

fn boolOf(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

const max_record_bytes: usize = 4 << 20;

/// Append one complete line, holding the journal's writer lease for the whole
/// of it — measure, repair a crash tail, write — so two appenders serialize
/// instead of landing on the same offset (`src/journals/journal.zig`'s rule,
/// for its reason: many processes write this file).
fn appendLine(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    id: []const u8,
    line: []const u8,
) !void {
    const dir = try dirOf(alloc, id);
    try base.createDirPath(io, dir);

    const lock_path = try pathIn(alloc, id, record_name ++ ".lock");
    var lease = try base.createFile(io, lock_path, .{ .truncate = false, .read = true, .lock = .exclusive });
    defer lease.close(io);

    const path = try pathIn(alloc, id, record_name);
    var file = try base.createFile(io, path, .{ .truncate = false, .read = true });
    defer file.close(io);
    const size = (try file.stat(io)).size;
    const end = try repairCrashTail(file, io, size);
    if (end != size) try file.setLength(io, end);
    try file.writePositionalAll(io, line, end);
}

/// Where the next line must go: just past the last `\n`, dropping whatever a
/// crashed append left behind. Events are single-line JSON, so `\n` always
/// separates them.
fn repairCrashTail(file: std.Io.File, io: std.Io, size: u64) !u64 {
    if (size == 0) return 0;
    var last: [1]u8 = undefined;
    const n = try file.readPositionalAll(io, &last, size - 1);
    if (n == 1 and last[0] == '\n') return size;

    var chunk: [4096]u8 = undefined;
    var pos = size;
    while (pos > 0) {
        const read_len = @min(chunk.len, pos);
        const start = pos - read_len;
        const got = try file.readPositionalAll(io, chunk[0..read_len], start);
        var i = got;
        while (i > 0) {
            i -= 1;
            if (chunk[i] == '\n') return start + i + 1;
        }
        pos = start;
    }
    return 0;
}

/// RFC3339 UTC, second granularity — the stamp every journal in this repository
/// writes (`src/journals/journal.zig`), so a delegation's rows read the same way
/// as a session's.
fn rfc3339Now(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    const ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const secs: u64 = if (ms < 0) 0 else @intCast(@divFloor(ms, 1000));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

// ── the runner's lease (D4) ─────────────────────────────────────────────────

/// Take the delegation's runner lease, or null when somebody already holds it.
///
/// An OS advisory lock, never a marker file: a runner is a background process
/// that can be killed, and a marker left by a dead one would strand the
/// delegation for ever with nothing able to tell the difference.
pub fn takeLease(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) !?std.Io.File {
    const dir = try dirOf(alloc, id);
    try base.createDirPath(io, dir);
    const path = try pathIn(alloc, id, lock_name);
    return base.createFile(io, path, .{
        .truncate = false,
        .read = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => null,
        else => return err,
    };
}

/// Is a runner driving this delegation right now? The sender's half of the wake
/// invariant: probe after delivering, and start a runner only when nobody holds
/// the lease. Probing by TAKING it and letting go is the only honest answer —
/// the lock is the fact, and anything else would be a second one.
///
/// Unreadable for any other reason counts as held: starting a second runner is
/// the mistake this is here to avoid, and the holder's own release-then-recheck
/// still catches the message.
pub fn leaseHeld(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) bool {
    const probe = takeLease(alloc, io, base, id) catch return true;
    if (probe) |file| {
        var f = file;
        f.close(io);
        return false;
    }
    return true;
}

// ── the external runner's inbox (D5) ────────────────────────────────────────

/// How many messages may wait for one round. A backstop on the name search
/// below, not a budget: `max_exchanges` is where a delegation's turns are
/// counted, and the runner drains everything it finds each round.
const max_queued: usize = 4096;

/// One message waiting for a runner, and how it was sent.
///
/// **Why `interrupt` rides in the envelope.** It is not a kind of message — the
/// text is an ordinary user turn either way (D3) — it is a fact about DELIVERY:
/// take this now rather than at the next natural boundary. It has to travel
/// WITH the message because the alternative is two writes, and two writes is a
/// race whichever order they go in:
///
///   * message first, then the marker (what this used to do): a runner that
///     drains mid-turn — the codex arm does, that is what `turn/steer` is for —
///     can take the message in the gap and steer it INTO the very turn the
///     marker is about to cut down. The message is then inside an answer that
///     is being thrown away.
///   * marker first, then the message: a sender that dies in the gap has cut a
///     turn short and delivered no new direction to replace it.
///
/// One atomic rename carries both, and the ambiguity is gone rather than moved.
/// The `<d>/interrupt` marker still exists and is still what stops a turn on
/// the arms that do NOT drain mid-turn (claude, pi, an external runner): they
/// take their one message at the start of a round and watch the marker while it
/// runs, so nothing there can be steered into a doomed turn. Belt and braces on
/// the codex arm, where either order is now correct.
pub const Message = struct {
    text: []const u8,
    interrupt: bool = false,
};

/// Deliver one message into `<d>/inbox/`.
///
/// The nulya runner never uses this — it appends straight into the child
/// session's own inbox, which the kernel drains mid-run for free (D5). A runner
/// whose harness has no inbox of its own reads this one at whatever granularity
/// its protocol gives it.
///
/// `<12 digits>.json`, taking the first free number by EXCLUSIVE creation: the
/// name sorts the same way it counts, so a reader gets the messages back in the
/// order they were sent, and two senders racing cannot land on the same name.
/// `.json` because a half-written message must not look like a whole one, and
/// the extension is the same convention the kernel's own inbox uses.
///
/// TWO steps, both of them load-bearing, and for two different races:
///
///   * the exclusive create of `<n>.tmp` claims the NUMBER, against another
///     sender picking the same one;
///   * the rename to `<n>.json` publishes the CONTENT, against a runner that is
///     draining this directory right now.
///
/// The second one is the kernel's own discipline (`ledger.depositEvent`) and it
/// is not optional here either: a directory entry exists the moment the file is
/// created, not when it is closed, so a reader scanning for `.json` between the
/// create and the write would find a name with nothing behind it — and an empty
/// file is not a message, so the reader would drop it (`inboxPeek`). That is a
/// message accepted and then lost, which is the one thing D4 is for.
///
/// A `.tmp` left behind by a sender that died mid-write costs its number and
/// nothing else: `nextFree` counts it (it reads the stem, before any extension)
/// and no reader will ever look at it.
pub fn inboxPut(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    id: []const u8,
    msg: Message,
) !void {
    const dir = try pathIn(alloc, id, inbox_name);
    try base.createDirPath(io, dir);

    var body: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &body.writer };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(1);
    try jw.objectField("text");
    try jw.write(msg.text);
    // Only when it is one, so an ordinary message is the same bytes it always
    // was and an older reader sees exactly what it saw before.
    if (msg.interrupt) {
        try jw.objectField("interrupt");
        try jw.write(true);
    }
    try jw.endObject();

    var n: usize = try nextFree(io, base, dir);
    while (n < max_queued) : (n += 1) {
        const staged = try std.fmt.allocPrint(alloc, "{s}/{d:0>12}.tmp", .{ dir, n });
        const path = try std.fmt.allocPrint(alloc, "{s}/{d:0>12}.json", .{ dir, n });
        const file = base.createFile(io, staged, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        {
            defer file.close(io);
            try file.writeStreamingAll(io, body.writer.buffered());
        }
        try base.rename(staged, base, path, io);
        return;
    }
    return error.InboxFull;
}

/// Where to start looking for a free name: one past the highest number already
/// there. Without it a delegation with a thousand answered messages would try a
/// thousand names for the next one.
///
/// So a number IS handed out again once the directory empties, and that is fine
/// for what the numbers carry — order only has to hold among messages that
/// coexist, and an empty inbox is one where everything before was answered. It
/// is not fine for a reader that remembers names ACROSS an ack, which is why the
/// one runner that offers several messages into a single turn holds its
/// acknowledgements to the end of the round (`codex.driveRound`).
fn nextFree(io: std.Io, base: std.Io.Dir, dir: []const u8) !usize {
    var d = base.openDir(io, dir, .{ .iterate = true }) catch return 1;
    defer d.close(io);
    var highest: usize = 0;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        const stem = std.mem.sliceTo(entry.name, '.');
        const n = std.fmt.parseInt(usize, stem, 10) catch continue;
        if (n > highest) highest = n;
    }
    return highest + 1;
}

/// One message waiting, under the name it waits by.
pub const Entry = struct {
    /// Its file name inside `<d>/inbox/`. Two jobs: it is the handle `inboxAck`
    /// is given, and it is what a runner offering several messages into one turn
    /// remembers so it does not offer the same one twice (`codex.zig`).
    name: []const u8,
    msg: Message,
};

/// Every message waiting, in the order it was sent — READ, not taken.
///
/// **Why peek and ack rather than take and put back.** A message used to be
/// deleted the moment a runner read it, and put back with a fresh number if the
/// round could not use it after all — a refused `turn/steer`, a harness that
/// would not start. That cost three things:
///
///   * ORDER. A put-back takes the next free number, so a message that arrived
///     while the first one was in flight now sorts ahead of it. The order this
///     directory exists to keep was kept only when nothing went wrong.
///   * THE MESSAGE ITSELF, sometimes. Every put-back was a write that could
///     fail, and all three of them failed quietly (`catch {}`) — an accepted
///     message vanishing is the one outcome D4 exists to prevent.
///   * EVERY MESSAGE A RUNNER WAS HOLDING, on a crash. A killed process took
///     with it whatever it had taken and not yet answered.
///
/// Reading and then deleting on success has none of those. Nothing moves, so
/// nothing reorders; the failure direction flips from "lost" to "delivered
/// twice", which a sub-agent answers again and a person can see; and a runner
/// that dies leaves its message exactly where the next one will find it. The
/// cost is stated plainly: this is AT LEAST once, not exactly once.
///
/// A file that cannot be parsed IS deleted here, and it is the only thing that
/// is. It cannot be half-written (a `.json` name was published by a rename, so
/// whatever is behind it is whole), so it will never parse — and leaving it
/// would hold `pending` true for ever, which is a delegation whose every future
/// runner spins until it gives up.
pub fn inboxPeek(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) ![]const Entry {
    return inboxPeekUpTo(alloc, io, base, id, max_queued);
}

/// The oldest message waiting, or null when there is none. For a runner that
/// answers one message per round (claude, pi, an external one).
pub fn inboxPeekOne(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) !?Entry {
    const found = try inboxPeekUpTo(alloc, io, base, id, 1);
    return if (found.len == 0) null else found[0];
}

/// This message has been delivered: drop it.
///
/// Best effort, and the direction of that is the point. An ack that does not
/// land leaves the message for the next round, which delivers it twice; the
/// alternative — deleting before delivery is certain — loses it. Of the two, the
/// one that can be seen and answered again is the one to choose.
pub fn inboxAck(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8, name: []const u8) void {
    const dir = pathIn(alloc, id, inbox_name) catch return;
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch return;
    base.deleteFile(io, path) catch {};
}

fn inboxPeekUpTo(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    id: []const u8,
    limit: usize,
) ![]const Entry {
    const dir = try pathIn(alloc, id, inbox_name);
    var names: std.ArrayList([]const u8) = .empty;
    {
        var d = base.openDir(io, dir, .{ .iterate = true }) catch return &.{};
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }
    // Zero-padded names, so the order they sort in is the order they were sent.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var out: std.ArrayList(Entry) = .empty;
    for (names.items) |name| {
        if (out.items.len >= limit) break;
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        // Anything that is not a message is dropped as it is found; a message is
        // left exactly where it is until somebody acks it (see `inboxPeek`).
        const raw = base.readFileAlloc(io, path, alloc, .limited(max_message_bytes)) catch {
            base.deleteFile(io, path) catch {};
            continue;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch {
            base.deleteFile(io, path) catch {};
            continue;
        };
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                base.deleteFile(io, path) catch {};
                continue;
            },
        };
        const text = stringOf(obj, "text") orelse "";
        if (text.len == 0) {
            base.deleteFile(io, path) catch {};
            continue;
        }
        try out.append(alloc, .{
            .name = name,
            .msg = .{ .text = text, .interrupt = boolOf(obj, "interrupt") },
        });
    }
    return out.items;
}

const max_message_bytes: usize = 4 << 20;

// ── the frozen persona ──────────────────────────────────────────────────────

/// The persona a delegation was opened with, frozen beside its journal.
///
/// The nulya runner does not need this — `session new --prompt` freezes those
/// bytes into the session header (DESIGN §3) and Codex freezes them into the
/// thread. A harness that is TOLD its system prompt on every process does: the
/// rendered file follows the definition, and without a copy of its own a
/// delegation would silently become somebody else the moment that file was
/// edited. One delegation, one persona, whichever harness holds it.
pub const persona_name = "persona.md";

/// Copy the rendered persona in, once, when the delegation opens. `too_long` is
/// handed back rather than worded here: what the limit is FOR is the runner's
/// business (a command line, a wire), and only it can say so.
pub fn freezePersona(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    id: []const u8,
    rendered: []const u8,
    limit: usize,
) !union(enum) { ok, too_long: usize, failed: []const u8 } {
    const body = base.readFileAlloc(io, rendered, alloc, .limited(limit + 1)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.StreamTooLong => return .{ .too_long = limit + 1 },
        else => return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "could not read the rendered persona at {s}: {s}",
            .{ rendered, @errorName(err) },
        ) },
    };
    if (body.len > limit) return .{ .too_long = body.len };
    try base.createDirPath(io, try dirOf(alloc, id));
    try base.writeFile(io, .{ .sub_path = try pathIn(alloc, id, persona_name), .data = body });
    return .ok;
}

// ── the interrupt marker (D6) ───────────────────────────────────────────────

/// "Stop what you are doing and take the new message now." Written after the
/// message, so a runner that sees the marker always finds something behind it.
pub fn markInterrupt(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) !void {
    const dir = try dirOf(alloc, id);
    try base.createDirPath(io, dir);
    const path = try pathIn(alloc, id, interrupt_name);
    try base.writeFile(io, .{ .sub_path = path, .data = "" });
}

/// Take the marker if it is there. Taking rather than reading, so a runner
/// cannot see the same interrupt twice and cut short the round it started
/// BECAUSE of it.
pub fn takeInterrupt(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) bool {
    const path = pathIn(alloc, id, interrupt_name) catch return false;
    return takeInterruptAt(io, base, path);
}

/// The same, with the path worked out once. The runner polls between stream
/// lines — thousands of times in a turn — and a delegation's interrupt path
/// does not change while it is being driven.
pub fn takeInterruptAt(io: std.Io, base: std.Io.Dir, path: []const u8) bool {
    base.access(io, path, .{}) catch return false;
    base.deleteFile(io, path) catch return false;
    return true;
}

// ── tests ───────────────────────────────────────────────────────────────────

test "a delegation id is checked because it becomes a path" {
    try std.testing.expect(isPlainId("d-0123456789ab"));
    try std.testing.expect(!isPlainId("d-0123456789"));
    try std.testing.expect(!isPlainId("d-0123456789abc"));
    try std.testing.expect(!isPlainId("s-1787207848147-47acf2"));
    try std.testing.expect(!isPlainId("d-../etc/pass"));
    try std.testing.expect(!isPlainId(""));

    const alloc = std.testing.allocator;
    const minted = try mint(alloc, std.testing.io);
    defer alloc.free(minted);
    try std.testing.expect(isPlainId(minted));
}

test "a minted uuid is the shape a harness that names sessions that way demands" {
    const alloc = std.testing.allocator;
    const id = try mintUuid(alloc, std.testing.io);
    defer alloc.free(id);

    try std.testing.expectEqual(@as(usize, 36), id.len);
    for (id, 0..) |c, i| {
        switch (i) {
            8, 13, 18, 23 => try std.testing.expectEqual(@as(u8, '-'), c),
            else => try std.testing.expect(std.ascii.isHex(c)),
        }
    }
    // Version and variant, which is what makes it a UUID rather than 32 hex
    // digits with dashes in them — `claude --session-id` checks.
    try std.testing.expectEqual(@as(u8, '4'), id[14]);
    try std.testing.expect(id[19] == '8' or id[19] == '9' or id[19] == 'a' or id[19] == 'b');
}

test "the record opens once and counts every turn, and a torn tail is not a fact yet" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-0123456789ab";
    // Nothing written: not a delegation this tool knows about.
    try std.testing.expect((try read(a, io, ws, id)) == null);

    try appendCreated(a, io, ws, id, .{
        .agent = "explore",
        .runner = "nulya",
        .remote = "s-1-abc",
        .parent = "s-0-def",
        .permissions = .readonly,
    });
    try appendTurn(a, io, ws, id, false);
    try appendTurn(a, io, ws, id, true);

    const state = (try read(a, io, ws, id)).?;
    try std.testing.expectEqualStrings("explore", state.created.agent);
    try std.testing.expectEqualStrings("nulya", state.created.runner);
    try std.testing.expectEqualStrings("s-1-abc", state.created.remote);
    try std.testing.expectEqual(Permissions.readonly, state.created.permissions);
    try std.testing.expectEqual(@as(u32, 2), state.turns);

    // An append cut short mid-line is dropped rather than glued onto the next
    // one, and it does not count as a turn while it is torn.
    const path = try pathIn(a, id, record_name);
    const existing = try ws.readFileAlloc(io, path, a, .unlimited);
    try ws.writeFile(io, .{
        .sub_path = path,
        .data = try std.fmt.allocPrint(a, "{s}{{\"v\":1,\"kind\":\"tu", .{existing}),
    });
    try std.testing.expectEqual(@as(u32, 2), (try read(a, io, ws, id)).?.turns);
    try appendTurn(a, io, ws, id, false);
    try std.testing.expectEqual(@as(u32, 3), (try read(a, io, ws, id)).?.turns);
}

test "the ceiling is one of three words, and anything else is the narrowest one" {
    try std.testing.expectEqual(Permissions.readonly, Permissions.parse("readonly").?);
    try std.testing.expectEqual(Permissions.default, Permissions.parse(" default ").?);
    try std.testing.expectEqual(Permissions.unsafe, Permissions.parse("unsafe").?);
    // Never a default: a misspelling that widened the ceiling is the one
    // outcome this field exists to prevent.
    try std.testing.expect(Permissions.parse("true") == null);
    try std.testing.expect(Permissions.parse("read-only") == null);
    try std.testing.expect(Permissions.parse("") == null);
    try std.testing.expectEqualStrings("unsafe", Permissions.unsafe.label());
    try std.testing.expect(Permissions.readonly.isReadonly());
    try std.testing.expect(!Permissions.default.isReadonly());
}

test "a created row this build did not write grants nothing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-000000000fa1";
    try ws.createDirPath(io, try dirOf(a, id));
    try ws.writeFile(io, .{
        .sub_path = try pathIn(a, id, record_name),
        .data = "{\"v\":1,\"kind\":\"created\",\"agent\":\"x\",\"runner\":\"nulya\",\"remote\":\"s-1\",\"parent\":\"s-0\"}\n",
    });
    const state = (try read(a, io, ws, id)).?;
    try std.testing.expectEqual(Permissions.readonly, state.created.permissions);
    // The policy columns are just as narrow when they are not there. Zero is
    // "no limit" for the two budgets, which is what those delegations have been
    // running under all along; an empty whitelist is a LEAF, because a row that
    // froze no list must not be handed one invented from today's definition.
    try std.testing.expectEqual(@as(u32, 0), state.created.max_exchanges);
    try std.testing.expectEqual(@as(u32, 0), state.created.max_steps);
    try std.testing.expectEqual(@as(usize, 0), state.created.agents.len);
}

test "the policy a delegation opens with is frozen in its record, whatever the definition says later" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-0000000000b0";
    try appendCreated(a, io, ws, id, .{
        .agent = "coordinator",
        .runner = "nulya",
        .remote = "s-1",
        .parent = "s-0",
        .permissions = .default,
        .max_exchanges = 4,
        .max_steps = 12,
        .agents = &.{ "explore", "plan" },
    });

    const state = (try read(a, io, ws, id)).?;
    try std.testing.expectEqual(@as(u32, 4), state.created.max_exchanges);
    try std.testing.expectEqual(@as(u32, 12), state.created.max_steps);
    try std.testing.expectEqual(@as(usize, 2), state.created.agents.len);
    try std.testing.expectEqualStrings("explore", state.created.agents[0]);
    try std.testing.expectEqualStrings("plan", state.created.agents[1]);
}

test "an external runner's inbox hands messages back in the order they were sent, and keeps them until they are acked" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-00000000cafe";
    // Nothing queued is not an error: a runner asks this every round.
    try std.testing.expectEqual(@as(usize, 0), (try inboxPeek(a, io, ws, id)).len);

    try inboxPut(a, io, ws, id, .{ .text = "first" });
    try inboxPut(a, io, ws, id, .{ .text = "second" });
    try inboxPut(a, io, ws, id, .{ .text = "third" });

    const seen = try inboxPeek(a, io, ws, id);
    try std.testing.expectEqual(@as(usize, 3), seen.len);
    try std.testing.expectEqualStrings("first", seen[0].msg.text);
    try std.testing.expectEqualStrings("third", seen[2].msg.text);

    // Reading is not taking: a round that died here would leave all three where
    // the next runner finds them, which is the half of D4 a crash used to lose.
    try std.testing.expectEqual(@as(usize, 3), (try inboxPeek(a, io, ws, id)).len);

    inboxAck(a, io, ws, id, seen[0].name);
    inboxAck(a, io, ws, id, seen[1].name);
    const left = try inboxPeek(a, io, ws, id);
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("third", left[0].msg.text);

    // Numbers are never reused, so a message queued later still sorts after one
    // that is still waiting.
    try inboxPut(a, io, ws, id, .{ .text = "fourth" });
    const both = try inboxPeek(a, io, ws, id);
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqualStrings("third", both[0].msg.text);
    try std.testing.expectEqualStrings("fourth", both[1].msg.text);
}

test "a message nobody could use stays in its place, so a later one cannot overtake it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // The order this directory exists to keep, in the case that used to break
    // it: a message is read, the round cannot use it (a refused steer, a harness
    // that would not start), and a second message arrives before the first is
    // dealt with. Taking and putting back gave the first message a NEW number,
    // behind the second; reading leaves it in front, where it was sent.
    const id = "d-0000000000f0";
    try inboxPut(a, io, ws, id, .{ .text = "A" });
    const first = (try inboxPeekOne(a, io, ws, id)).?;
    try std.testing.expectEqualStrings("A", first.msg.text);

    try inboxPut(a, io, ws, id, .{ .text = "B" });

    // Not acked — the round did nothing with it.
    const next_round = try inboxPeek(a, io, ws, id);
    try std.testing.expectEqual(@as(usize, 2), next_round.len);
    try std.testing.expectEqualStrings("A", next_round[0].msg.text);
    try std.testing.expectEqualStrings("B", next_round[1].msg.text);
}

test "how a message was sent travels with it, in the same atomic write" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-0000000000e1";
    try inboxPut(a, io, ws, id, .{ .text = "carry on" });
    try inboxPut(a, io, ws, id, .{ .text = "stop", .interrupt = true });

    const seen = try inboxPeek(a, io, ws, id);
    try std.testing.expectEqual(@as(usize, 2), seen.len);
    try std.testing.expect(!seen[0].msg.interrupt);
    try std.testing.expect(seen[1].msg.interrupt);

    // And it is still an interrupt when a round that could not act on it leaves
    // it for the next one: nothing is rewritten, so nothing can be dropped on
    // the way — an interrupt cannot quietly become an ordinary turn.
    inboxAck(a, io, ws, id, seen[0].name);
    const again = try inboxPeek(a, io, ws, id);
    try std.testing.expectEqual(@as(usize, 1), again.len);
    try std.testing.expectEqualStrings("stop", again[0].msg.text);
    try std.testing.expect(again[0].msg.interrupt);
}

test "a policy column that cannot be read refuses the record rather than reading as unlimited" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const head = "{\"v\":1,\"kind\":\"created\",\"agent\":\"x\",\"runner\":\"nulya\",\"remote\":\"s-1\",\"parent\":\"s-0\",\"permissions\":\"default\"";

    // Zero is the WIDEST reading of these two columns, so a damaged one must not
    // fall back to it: "2" as a string, or a negative, would otherwise hand out
    // unlimited follow-ups.
    for ([_][]const u8{
        ",\"max_exchanges\":\"2\"}\n",
        ",\"max_exchanges\":-1}\n",
        ",\"max_steps\":null}\n",
    }, 0..) |tail, i| {
        const id = try std.fmt.allocPrint(a, "d-00000000d1{d:0>2}", .{i});
        try ws.createDirPath(io, try dirOf(a, id));
        try ws.writeFile(io, .{
            .sub_path = try pathIn(a, id, record_name),
            .data = try std.mem.concat(a, u8, &.{ head, tail }),
        });
        try std.testing.expectError(Corrupt.CorruptDelegationRecord, read(a, io, ws, id));
    }

    // Every row this build cannot read is a row that LOWERS the turn count, and
    // a lower count is a wider budget — so none of them may be skipped, whatever
    // shape the damage takes.
    for ([_][]const u8{
        // Not JSON at all.
        "{not json}\n",
        // JSON, and a `kind` nothing answers to: this is the one that used to
        // fall through both arms in silence and hand out a free follow-up.
        "{\"v\":1,\"kind\":\"turm\"}\n",
        // A second opening row. A delegation opens once.
        "{\"v\":1,\"kind\":\"created\",\"agent\":\"y\",\"runner\":\"nulya\",\"remote\":\"s-9\",\"parent\":\"s-0\"}\n",
        // A schema this build does not know: guessed at, or refused.
        "{\"v\":2,\"kind\":\"turn\"}\n",
        "{\"kind\":\"turn\"}\n",
    }, 0..) |tail, i| {
        const id = try std.fmt.allocPrint(a, "d-00000000d2{d:0>2}", .{i});
        try ws.createDirPath(io, try dirOf(a, id));
        try ws.writeFile(io, .{
            .sub_path = try pathIn(a, id, record_name),
            .data = try std.mem.concat(a, u8, &.{ head, ",\"max_exchanges\":2}\n{\"v\":1,\"kind\":\"turn\"}\n", tail }),
        });
        try std.testing.expectError(Corrupt.CorruptDelegationRecord, read(a, io, ws, id));
    }

    // And a row before the opening one is not a record either.
    {
        const id = "d-00000000d299";
        try ws.createDirPath(io, try dirOf(a, id));
        try ws.writeFile(io, .{
            .sub_path = try pathIn(a, id, record_name),
            .data = try std.mem.concat(a, u8, &.{ "{\"v\":1,\"kind\":\"turn\"}\n", head, "}\n" }),
        });
        try std.testing.expectError(Corrupt.CorruptDelegationRecord, read(a, io, ws, id));
    }
}

test "a message is published by a rename, so a reader never takes one that is still being written" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-00000000beef";
    const dir = try pathIn(a, id, inbox_name);
    try ws.createDirPath(io, dir);

    // A sender part way through: the number is claimed, the body is not there
    // yet. This is the state the reader used to walk into — it would take the
    // name, delete it, fail to parse it, and the message would be gone.
    try ws.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/000000000001.tmp", .{dir}), .data = "" });

    try std.testing.expectEqual(@as(usize, 0), (try inboxPeek(a, io, ws, id)).len);
    // …and it is still there afterwards, because the reader never looked at it.
    try ws.access(io, try std.fmt.allocPrint(a, "{s}/000000000001.tmp", .{dir}), .{});

    // A number a half-written message claimed is not handed out again either:
    // the next sender takes the one after it, so order still counts up.
    try inboxPut(a, io, ws, id, .{ .text = "after" });
    const seen = try inboxPeek(a, io, ws, id);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("after", seen[0].msg.text);
}

test "a file in the inbox that can never be a message is dropped rather than left to spin" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Published by a rename, so it is whole — and it will never parse. Leaving
    // it would hold `pending` true for ever: every future runner would find work
    // it cannot do, go round again, and give up after the idle cap.
    const id = "d-00000000ba17";
    const dir = try pathIn(a, id, inbox_name);
    try ws.createDirPath(io, dir);
    try ws.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/000000000001.json", .{dir}),
        .data = "not json at all",
    });
    try inboxPut(a, io, ws, id, .{ .text = "the real one" });

    const seen = try inboxPeek(a, io, ws, id);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("the real one", seen[0].msg.text);
    try std.testing.expectError(
        error.FileNotFound,
        ws.access(io, try std.fmt.allocPrint(a, "{s}/000000000001.json", .{dir}), .{}),
    );
}

test "the runner lease is exclusive while it is held, and the interrupt marker is taken once" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-abcdef012345";
    try std.testing.expect(!leaseHeld(a, io, ws, id));

    var held = (try takeLease(a, io, ws, id)).?;
    try std.testing.expect(leaseHeld(a, io, ws, id));
    // A second runner does not queue behind it: it learns it lost and leaves.
    try std.testing.expect((try takeLease(a, io, ws, id)) == null);

    held.close(io);
    try std.testing.expect(!leaseHeld(a, io, ws, id));

    try std.testing.expect(!takeInterrupt(a, io, ws, id));
    try markInterrupt(a, io, ws, id);
    try std.testing.expect(takeInterrupt(a, io, ws, id));
    try std.testing.expect(!takeInterrupt(a, io, ws, id));
}
