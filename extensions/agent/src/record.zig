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
//!
//! Every entry point takes the workspace directory rather than assuming the
//! process's own: the callers pass `std.Io.Dir.cwd()` (an extension is spawned
//! in the workspace, DESIGN §7.6) and the tests pass a temporary one.

const std = @import("std");

/// Where delegations live, relative to the workspace.
pub const root = ".nulya/delegations";

pub const record_name = "record.jsonl";
pub const lock_name = ".runner.lock";
pub const interrupt_name = "interrupt";
pub const inbox_name = "inbox";

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

pub fn dirOf(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, id });
}

pub fn pathIn(alloc: std.mem.Allocator, id: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ root, id, name });
}

// ── the journal ─────────────────────────────────────────────────────────────

/// The row a delegation opens with: everything about it that is decided once.
///
/// `runner` and `runner_version` are FROZEN here for the same reason a session
/// freezes its composition (physics #2): every later turn goes to the same
/// harness, at the same version, however the definition file has changed since.
pub const Created = struct {
    agent: []const u8,
    runner: []const u8,
    runner_version: []const u8 = "",
    /// What the runner opened to hold this conversation — a session id for the
    /// nulya runner, whatever the harness calls it for an external one.
    remote: []const u8,
    parent: []const u8,
    readonly: bool = false,
    profile: []const u8 = "",
    model: []const u8 = "",
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
    try jw.objectField("readonly");
    try jw.write(c.readonly);
    if (c.profile.len != 0) {
        try jw.objectField("profile");
        try jw.write(c.profile);
    }
    if (c.model.len != 0) {
        try jw.objectField("model");
        try jw.write(c.model);
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

/// Read the journal back. Null when there is no delegation by that name, or
/// when its journal has no `created` row yet — both mean "this tool has never
/// opened a delegation called that", which is the one answer a caller needs.
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
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch continue;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const kind = stringOf(obj, "kind") orelse continue;
        if (std.mem.eql(u8, kind, "created")) {
            if (state != null) continue; // one delegation, one opening
            state = .{ .created = .{
                .agent = stringOf(obj, "agent") orelse "",
                .runner = stringOf(obj, "runner") orelse "",
                .runner_version = stringOf(obj, "runner_version") orelse "",
                .remote = stringOf(obj, "remote") orelse "",
                .parent = stringOf(obj, "parent") orelse "",
                .readonly = switch (obj.get("readonly") orelse std.json.Value{ .null = {} }) {
                    .bool => |b| b,
                    else => false,
                },
                .profile = stringOf(obj, "profile") orelse "",
                .model = stringOf(obj, "model") orelse "",
            } };
            continue;
        }
        if (std.mem.eql(u8, kind, "turn")) {
            if (state) |*s| s.turns += 1;
        }
    }
    return state;
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
        .readonly = true,
    });
    try appendTurn(a, io, ws, id, false);
    try appendTurn(a, io, ws, id, true);

    const state = (try read(a, io, ws, id)).?;
    try std.testing.expectEqualStrings("explore", state.created.agent);
    try std.testing.expectEqualStrings("nulya", state.created.runner);
    try std.testing.expectEqualStrings("s-1-abc", state.created.remote);
    try std.testing.expect(state.created.readonly);
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
