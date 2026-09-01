//! `.nulya/delegations/<d-id>/` — what this package knows about one delegation.
//!
//! A journal rather than a state file because TWO processes write it (the `agent`
//! tool in the caller's step, the `run` tool in a background task): whole lines
//! appended under a lock, `src/journals/journal.zig`'s discipline re-implemented
//! because an extension cannot import the kernel.
//!
//!   `<d>/record.jsonl`   this journal: one `created` row, then one `turn` row
//!                        per message anybody sent (the first task included).
//!   `<d>/.runner.lock`   the runner's exclusive lease. An OS advisory lock, so
//!                        a runner that dies releases it — a marker file would
//!                        strand the delegation for ever.
//!   `<d>/interrupt`      "stop and take the new message now". Empty; its
//!                        existence is the message.
//!   `<d>/inbox/`         messages for a runner with no inbox of its own. The
//!                        nulya runner delivers into the child session's own
//!                        inbox instead, so this stays empty there.
//!   `<d>/persona.md`     the persona frozen for this delegation.
//!   `<d>/message.txt`    the one message a round is answering, staged where an
//!                        EXTERNAL runner extension can read it — written only by
//!                        whoever holds the lease, and only for that round.
//!
//! The last two of those are a queue with a delivery contract rather than a
//! record of what happened, so they live in `mailbox.zig`.
//!
//! Every entry point takes the workspace directory rather than assuming the
//! process's own: callers pass `std.Io.Dir.cwd()`, tests a temporary one.

const std = @import("std");

/// Where delegations live, relative to the workspace.
pub const root = ".nulya/delegations";

/// How a step knows which delegation it is running as. Set by the runner on the
/// process it drives, beside `NULYA_AGENT_DEPTH`; not secret-shaped, so it
/// survives the environment sanitising every child gets. It is what lets a
/// delegated session read its OWN frozen policy rather than a definition file
/// that may have been edited since (`main.allowedHere`).
pub const delegation_var = "NULYA_AGENT_DELEGATION";

pub const record_name = "record.jsonl";
pub const lock_name = ".runner.lock";

// ── how much a delegation may do ────────────────────────────────────────────

/// The one ceiling a delegation carries, in three words.
///
/// `default` and `unsafe` behave identically on the nulya arm today: what
/// differs is what the record says, which is what an external harness that HAS
/// the distinction is told (Codex and Claude both do).
///
/// ESCALATION IS NEVER INHERITED: `unsafe` reaches a delegation from its
/// definition or from the `agent` call that opened it and nowhere else — no
/// front end's mode, no environment variable, nothing about the parent.
pub const Permissions = enum {
    /// Reads and nothing else. A hard ceiling every runner must be able to
    /// enforce, or refuse the whole delegation.
    readonly,
    /// Read, write, run things: the default, and what an unwritten field means.
    default,
    /// Everything the harness can do, with its own guard rails off.
    unsafe,

    /// The word as a definition writes it and as the record freezes it. Null is
    /// "not one of the three" and is never read as a default: a misspelling
    /// falling back to `default` would be a ceiling quietly widened.
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
    /// mechanisms answer.
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
/// step are two processes with no way to agree on the next number, and the id is
/// a name, not an ordering.
pub fn mint(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [6]u8 = undefined;
    io.random(&bytes);
    return std.fmt.allocPrint(alloc, "d-{x:0>12}", .{std.mem.readInt(u48, &bytes, .little)});
}

/// A UUID (version 4), for a harness that names its conversations that way.
///
/// Minted HERE rather than read back from the harness: the record must be able
/// to name the remote conversation before a single turn has run, so the name has
/// to be one this side chose. `claude --session-id` requires this exact shape;
/// `pi --session-id` takes any string and gets one anyway.
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
/// Everything here is FROZEN, as a session freezes its composition: a delegation
/// already under way is not re-decided by a file somebody edited since. The
/// definition creates NEW delegations and is never consulted again about one
/// that exists — that covers the runner, the ceiling, and the three policy
/// numbers below (how many turns, how many steps a round may take, who it may
/// pass work to).
///
/// `runner_version` is the one column that is NOT uniformly a freeze; see it
/// below.
pub const Created = struct {
    agent: []const u8,
    runner: []const u8,
    /// Which implementation of the runner this delegation opened on. Two
    /// strengths in one column, and only one of them is a pin:
    ///
    ///   * `ext:<id>` — a PINNED EXECUTION IDENTITY. `current` is resolved once
    ///     at `op=open` and the `v-…` frozen here is what every later round
    ///     calls; the old version stays in the store.
    ///   * `claude` / `pi` — OBSERVED PROVENANCE. What `--version` said when this
    ///     opened: later rounds run whatever that name resolves to on PATH now,
    ///     and there is no pin available to make.
    ///   * `codex` (no version of its own over app-server) and `nulya` (this
    ///     binary writes the record) leave it empty.
    runner_version: []const u8 = "",
    /// What the runner opened to hold this conversation — a session id for the
    /// nulya runner, a thread id for Codex, whatever the harness calls it.
    remote: []const u8,
    parent: []const u8,
    /// The ceiling this delegation was opened at. A row without this column is
    /// read back as `readonly` — the narrowest answer, because a record that
    /// cannot say what it granted has not granted anything.
    permissions: Permissions = .readonly,
    profile: []const u8 = "",
    model: []const u8 = "",
    /// What an EXTERNAL runner was asked to run on — an opaque string in that
    /// harness's own vocabulary, never a nulya profile/model pair. Its own column
    /// rather than reusing `model`, which would read as a nulya model id.
    ///
    /// Unlike `profile` and `model`, this one IS read back: claude, pi and an
    /// external runner are told which model to use on every round. Codex is the
    /// exception — a thread froze its model when it was created.
    runner_model: []const u8 = "",
    /// How many follow-up turns this delegation may have. Zero is "no limit",
    /// which is what an unwritten `max_exchanges:` means.
    max_exchanges: u32 = 0,
    /// The step budget one round of it may spend. Zero is the kernel's own.
    max_steps: u32 = 0,
    /// The personas this delegation may pass work to (`agents:`). Empty is a
    /// LEAF, which is also the right reading of a row without the column: it
    /// froze no whitelist, and one invented from today's definition is the drift
    /// this column exists to stop.
    agents: []const []const u8 = &.{},
};

/// A delegation, as its journal describes it.
pub const State = struct {
    created: Created,
    /// How many messages anybody has sent into it — the first task included. THE
    /// count of exchanges: the only one an external runner can answer too.
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
    // The policy columns, written only when they say something.
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
/// what it is: a message is always an ordinary turn.
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
/// that name" (null) — see the discipline on `read`.
pub const Corrupt = error{CorruptDelegationRecord};

/// Read the journal back. Null when there is no delegation by that name, or when
/// its journal has no `created` row yet — both mean "this tool has never opened a
/// delegation called that".
///
/// A TORN FINAL LINE is ignored: an interrupted or in-flight append is not a
/// fact yet. An ABSENT field reads as its default. A field PRESENT AND
/// UNREADABLE is where the record is an authority, so the answer depends on
/// which direction its default points:
///
///   | field                       | fallback | direction |
///   |-----------------------------|----------|-----------|
///   | `permissions`               | readonly | narrowest |
///   | `agents`                    | leaf     | narrowest |
///   | `max_exchanges` `max_steps` | 0        | UNLIMITED |
///
/// The first two fall back, since corruption there can only take a capability
/// away. The two budgets have no narrow reading available — zero means "no
/// limit" and "the kernel's own" — so a damaged one refuses the whole record.
///
/// The journal itself is a two-state machine: BEFORE the opening row only a
/// `created` is legal, and after it only a `turn`. Anything else — a second
/// `created`, an unknown `kind`, a line that is not JSON, a `v` from another
/// schema — refuses the whole record. Strict rather than skipping, for the same
/// reason as the budgets: every row this cannot read LOWERS the exchange count,
/// and a lower count is a wider budget.
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
                    // three.
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

/// One of the two budget columns. Absent is zero — no limit. Anything else
/// present is CORRUPTION rather than zero: zero is the widest reading here, so
/// falling back to it would let a damaged row hand out an unlimited budget.
fn budgetOf(obj: std.json.ObjectMap, key: []const u8) !u32 {
    return switch (obj.get(key) orelse return 0) {
        .integer => |i| if (i > 0 and i <= std.math.maxInt(u32)) @intCast(i) else Corrupt.CorruptDelegationRecord,
        else => Corrupt.CorruptDelegationRecord,
    };
}

/// A list of strings, skipping anything in it that is not one. Absent, empty and
/// unreadable are all the same answer, and here that answer is the NARROW one: a
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

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

const max_record_bytes: usize = 4 << 20;

/// Append one complete line, holding the journal's writer lease for the whole of
/// it — measure, repair a crash tail, write — so two appenders serialize instead
/// of landing on the same offset. Many processes write this file.
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
/// writes, so a delegation's rows read the same way as a session's.
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

// ── the runner's lease ──────────────────────────────────────────────────────

/// Take the delegation's runner lease, or null when somebody already holds it.
///
/// An OS advisory lock, never a marker file: a runner is a background process
/// that can be killed, and a marker left by a dead one would strand the
/// delegation for ever.
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
/// invariant: probe AFTER delivering, and start a runner only when nobody holds
/// the lease. Probing by taking it and letting go — the lock is the fact.
///
/// Unreadable for any other reason counts as held: starting a second runner is
/// the mistake this avoids, and the holder's own release-then-recheck still
/// catches the message.
pub fn leaseHeld(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) bool {
    const probe = takeLease(alloc, io, base, id) catch return true;
    if (probe) |file| {
        var f = file;
        f.close(io);
        return false;
    }
    return true;
}

// ── the frozen persona ──────────────────────────────────────────────────────

/// The persona a delegation was opened with, frozen beside its journal.
///
/// Only needed by a harness TOLD its system prompt on every process: the
/// rendered file follows the definition, so without a copy of its own a
/// delegation would silently become somebody else the moment that file was
/// edited. (`session new --prompt` and Codex both freeze it themselves.)
pub const persona_name = "persona.md";

/// Copy the rendered persona in, once, when the delegation opens. `too_long` is
/// handed back rather than worded here: what the limit is FOR (a command line, a
/// wire) is the runner's business.
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

    // An append cut short mid-line is dropped rather than glued onto the next,
    // and it does not count as a turn while it is torn.
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
    // Never a default: a misspelling that widened the ceiling is the one outcome
    // this field exists to prevent.
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
    // The policy columns are just as narrow when they are not there: zero is "no
    // limit" for the two budgets, and an empty whitelist is a LEAF.
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
        // JSON, and a `kind` nothing answers to.
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

test "the runner lease is exclusive while it is held" {
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
}
