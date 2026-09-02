//! Every lock and marker file in the system, and the order they are taken in.
//!
//! A LEASE is an OS advisory lock on a sidecar file, released by the kernel when
//! the holder dies or its handle closes. A MARKER is an ordinary file whose
//! existence is the message; it outlives its writer, and whoever acts on it
//! deletes it. Never a lock on a file that also carries data: on Windows a file's
//! own lock is mandatory and would block readers.
//!
//! The table is the contract. Rows whose function lives elsewhere are registered,
//! not moved.
//!
//! | file                                    | taken by                                                        | wait       | order |
//! |-----------------------------------------|-----------------------------------------------------------------|------------|-------|
//! | `<id>.inbox/.deposit.lock`              | every inbox writer; `task run` across spawn; `session prune`     | block¹     | 1     |
//! | `<id>.lock`                             | `createDurable` / `openDurable` (one writer); `session prune`    | fail_fast  | 2     |
//! | `<id>.cancel`                           | marker: any process asks a step to stop; consumed at the boundary | —         | —     |
//! | `<store>/<id>/.lock`                    | `ext build` / `activate` / `deactivate` / `seed` / `push`        | block      | *     |
//! | `<journal>.lock`                        | every journal append                                             | block      | *     |
//! | `scratch/<id>/tasks/t<N>/.lock`         | one task's supervisor, for its whole life; probed by every reader | fail_fast  | *     |
//! | `scratch/<id>/tasks/t<N>/{kill,notify,delivered}` | markers: stop it / where the report goes / it was delivered | —      | —     |
//! | `.nulya/delegations/<d>/.runner.lock`   | `extensions/agent`: the runner of one delegation                 | fail_fast  | *     |
//! | `.nulya/delegations/<d>/inbox/.writer.lock` | `extensions/agent`: a sender, across taking a number and publishing | block  | *     |
//! | `.nulya/delegations/<d>/record.jsonl.lock`  | `extensions/agent`: an appender to the delegation record     | block      | *     |
//! | `.nulya/delegations/<d>/interrupt`      | marker: take the new message now                                 | —          | —     |
//!
//! ¹ `fail_fast` for `session prune`, which is here to take a session away:
//! "somebody is depositing right now" is an answer, not a queue to join.
//!
//! ORDER is global and total for the two numbered rows: the deposit lease is
//! taken before the writer lease and never after it, so `sessionLifetime` is the
//! only place both are held. Rows marked `*` are leaves — nothing is taken while
//! one is held. Two leases of the SAME row at once happens once (`depositPair`)
//! and goes in session-path order, never call order.

const std = @import("std");

/// Whether taking a lease waits for whoever holds it. A depositor WAITS;
/// `session prune` does not — "somebody is depositing right now" is an answer.
pub const Wait = enum { block, fail_fast };

/// A held lease. Closing it twice is a no-op, which lets a callee release it at
/// the one moment it may (a lock file cannot be unlinked while its opener holds
/// it) without taking the handle away from the caller's `defer`.
pub const Lease = struct {
    file: std.Io.File,
    open: bool = true,

    pub fn close(self: *Lease, io: std.Io) void {
        if (!self.open) return;
        self.file.close(io);
        self.open = false;
    }
};

// ── A session's two ─────────────────────────────────────────────────────────

/// The session's writer lease: only one process opens the file for append at a
/// time. Taken non-blocking — a second writer fails fast with
/// `error.SessionBusy`. The handle must stay open for the writer's lifetime.
///
/// Public because `pruneSession` has to know that nobody is writing, and only
/// taking the lease answers that — probing races with the next taker.
pub fn sessionWriter(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, session_path: []const u8) !std.Io.File {
    const lock_path = try siblingPath(alloc, session_path, ".lock");
    defer alloc.free(lock_path);
    return dir.createFile(io, lock_path, .{ .truncate = false, .read = true, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.WouldBlock => error.SessionBusy,
        else => err,
    };
}

/// The exclusive right to deposit into this session's inbox. Held by EVERY
/// writer of the inbox, for three rules:
///
///   * A delivery id is minted from what is already waiting
///     (`ledger.freshDeliveryName`), so two depositors racing would otherwise
///     take the same queue position.
///   * A session may not be taken away between a depositor's check and its
///     write. `ledger.pruneSession` removes one only while holding this and the
///     writer lease; every deposit re-checks the session under this lease.
///   * Nor between the check and the START of something long-lived under it:
///     `nulya task run` holds this across "does this session exist" and the
///     spawn of a supervisor that writes under the session for as long as it
///     runs.
///
/// It lives INSIDE the inbox and is not the session's `.lock`: that one belongs
/// to `step`, and every gate above must work while a step runs. Neither the
/// drain nor a scan looks at anything but `*.json` there.
pub fn sessionDeposits(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
    wait: Wait,
) !Lease {
    const inbox = try siblingPath(alloc, session_path, ".inbox");
    defer alloc.free(inbox);
    try base.createDirPath(io, inbox);
    const lock_rel = try depositLockPath(alloc, session_path);
    defer alloc.free(lock_rel);
    const file = base.createFile(io, lock_rel, .{
        .truncate = false,
        .read = true,
        .lock = .exclusive,
        .lock_nonblocking = wait == .fail_fast,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.DepositInFlight,
        else => return err,
    };
    return .{ .file = file };
}

/// `<inbox>/.deposit.lock`.
pub fn depositLockPath(alloc: std.mem.Allocator, session_path: []const u8) ![]u8 {
    const inbox = try siblingPath(alloc, session_path, ".inbox");
    defer alloc.free(inbox);
    return std.fmt.allocPrint(alloc, "{s}{c}.deposit.lock", .{ inbox, std.fs.path.sep });
}

/// BOTH of a session's leases, held at once.
///
/// Only under the pair does "nothing is alive under this session" stay true long
/// enough to act on: a long-lived writer under the scratch tree starts down
/// either of two paths — `nulya task run` under the deposit lease, an in-step
/// `shell {background:true}` under the writer lease its step holds.
pub const SessionLeases = struct {
    deposits: Lease,
    writer: Lease,

    pub fn close(self: *SessionLeases, io: std.Io) void {
        self.writer.close(io);
        self.deposits.close(io);
    }
};

/// Take both: `error.DepositInFlight` when somebody is inside its inbox,
/// `error.SessionBusy` when a step is writing it. Neither is a queue to join —
/// both are answers.
pub fn sessionLifetime(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
) !SessionLeases {
    var deposits = try sessionDeposits(alloc, io, base, session_path, .fail_fast);
    errdefer deposits.close(io);
    const writer = try sessionWriter(alloc, io, base, session_path);
    return .{ .deposits = deposits, .writer = .{ .file = writer } };
}

/// The deposit leases of TWO sessions, held at once — what changing WHERE a
/// result will land needs, since neither end may be pruned in between. Naming
/// one session twice takes one lease; taking the same lease twice deadlocks.
pub const DepositPair = struct {
    first: Lease,
    second: ?Lease,

    pub fn close(self: *DepositPair, io: std.Io) void {
        if (self.second) |*l| l.close(io);
        self.first.close(io);
    }
};

pub fn depositPair(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    a_session_path: []const u8,
    b_session_path: []const u8,
    wait: Wait,
) !DepositPair {
    if (std.mem.eql(u8, a_session_path, b_session_path)) {
        return .{ .first = try sessionDeposits(alloc, io, base, a_session_path, wait), .second = null };
    }
    const a_first = std.mem.lessThan(u8, a_session_path, b_session_path);
    const first_path = if (a_first) a_session_path else b_session_path;
    const second_path = if (a_first) b_session_path else a_session_path;

    var first = try sessionDeposits(alloc, io, base, first_path, wait);
    errdefer first.close(io);
    const second = try sessionDeposits(alloc, io, base, second_path, wait);
    return .{ .first = first, .second = second };
}

/// `<dir>/<stem><suffix>`: the naming rule for every per-session sibling
/// (`.lock`, `.inbox`, `.cancel`). Purely lexical, so it preserves whether
/// `session_path` is relative or absolute. Caller owns the result.
pub fn siblingPath(alloc: std.mem.Allocator, session_path: []const u8, suffix: []const u8) ![]u8 {
    const stem = std.fs.path.stem(std.fs.path.basename(session_path));
    const name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, suffix });
    defer alloc.free(name);
    if (std.fs.path.dirname(session_path)) |dir| return std.fs.path.join(alloc, &.{ dir, name });
    return alloc.dupe(u8, name);
}

// ── Extension store ─────────────────────────────────────────────────────────

/// `<store>/<id>/.lock`, the writer lease every mutation of `<id>/` runs under.
/// Blocking, and held for the whole mutation — for a compiled build that is the
/// entire `zig build-exe`, since a second writer wants the result, not a
/// refusal. Creates `<id>/` when missing.
pub fn extensionStore(alloc: std.mem.Allocator, io: std.Io, store_root: std.Io.Dir, id: []const u8) !std.Io.File {
    try store_root.createDirPath(io, id);
    const sub = try std.fs.path.join(alloc, &.{ id, ".lock" });
    defer alloc.free(sub);
    return store_root.createFile(io, sub, .{ .truncate = false, .read = true, .lock = .exclusive });
}

// ── Journals ────────────────────────────────────────────────────────────────

/// `<file_rel>.lock`, held across one journal append's measure-repair-write, so
/// concurrent appenders serialize instead of landing on the same offset.
pub fn journalAppend(io: std.Io, workspace: std.Io.Dir, file_rel: []const u8) !std.Io.File {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_rel = try std.fmt.bufPrint(&buf, "{s}.lock", .{file_rel});
    return workspace.createFile(io, lock_rel, .{ .truncate = false, .read = true, .lock = .exclusive });
}

// ── Background tasks ────────────────────────────────────────────────────────

/// The supervisor's lease inside one task directory. Its being FREE while the
/// status still says `running` is the only evidence that a supervisor died.
pub const task_lock_name = ".lock";

/// Take it, for the supervisor's whole life. Null means another supervisor
/// already owns this directory — not something to queue behind.
pub fn taskSupervisor(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, dir: []const u8) !?std.Io.File {
    const path = try std.fs.path.join(alloc, &.{ dir, task_lock_name });
    defer alloc.free(path);
    return base.createFile(io, path, .{
        .truncate = false,
        .read = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => null,
        else => err,
    };
}

/// Is a supervisor alive on this task? Asked by OPENING the lease file, never by
/// creating it: a probe that created `.lock` could make the real supervisor's own
/// non-blocking acquire fail. A missing lease file means "no supervisor started".
///
/// `base` is the directory `dir` is relative to: `std.Io.Dir.cwd()` for a reader
/// on this machine, a remote agent's workspace handle when the far side polls.
pub fn taskHeld(base: std.Io.Dir, io: std.Io, alloc: std.mem.Allocator, dir: []const u8) !bool {
    const path = try std.fs.path.join(alloc, &.{ dir, task_lock_name });
    defer alloc.free(path);
    // Reject a corrupt directory before asking Windows to open it with file
    // locking flags: Zig's threaded Windows backend turns that combination's
    // INVALID_PARAMETER into a panic rather than a catchable I/O error.
    const before = base.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    if (before.kind != .file) return error.InvalidLeaseFile;
    var f = base.openFile(io, path, .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return true,
        // No lease file at all IS "nobody holds it". Every other failure
        // propagates: an unreadable lease is not the same claim as an unheld
        // one, and callers decide what an unanswerable lease means.
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer f.close(io);
    // POSIX permits opening and flocking a directory while Windows rejects it,
    // so check the kind explicitly rather than let the OS decide.
    if ((try f.stat(io)).kind != .file) return error.InvalidLeaseFile;
    return false;
}

const testing = std.testing;

test "the session's two leases are independent, and each refuses rather than queues" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = "{}\n" });

    var both = try sessionLifetime(alloc, io, tmp.dir, "s.jsonl");
    try testing.expectError(error.SessionBusy, sessionWriter(alloc, io, tmp.dir, "s.jsonl"));
    try testing.expectError(error.DepositInFlight, sessionDeposits(alloc, io, tmp.dir, "s.jsonl", .fail_fast));
    both.close(io);

    var again = try sessionLifetime(alloc, io, tmp.dir, "s.jsonl");
    again.close(io);
    again.close(io);
}

test "two sessions' deposit leases are taken in path order, whichever way the caller names them" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.jsonl", .data = "{}\n" });

    var pair = try depositPair(alloc, io, tmp.dir, "b.jsonl", "a.jsonl", .fail_fast);
    try testing.expectError(
        error.DepositInFlight,
        depositPair(alloc, io, tmp.dir, "a.jsonl", "b.jsonl", .fail_fast),
    );
    pair.close(io);

    var single = try depositPair(alloc, io, tmp.dir, "a.jsonl", "a.jsonl", .fail_fast);
    try testing.expect(single.second == null);
    single.close(io);
}

test "a task lease reads as held only while somebody holds it" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expect(!try taskHeld(tmp.dir, io, alloc, "t1"));

    try tmp.dir.createDirPath(io, "t1");
    var held = (try taskSupervisor(alloc, io, tmp.dir, "t1")).?;
    try testing.expect(try taskHeld(tmp.dir, io, alloc, "t1"));
    try testing.expect(try taskSupervisor(alloc, io, tmp.dir, "t1") == null);
    held.close(io);
    try testing.expect(!try taskHeld(tmp.dir, io, alloc, "t1"));
}

test "siblingPath names <stem><suffix> next to the session file" {
    const alloc = testing.allocator;
    const a = try siblingPath(alloc, ".nulya/sessions/s-1.jsonl", ".inbox");
    defer alloc.free(a);
    try testing.expectEqualStrings(".nulya/sessions" ++ std.fs.path.sep_str ++ "s-1.inbox", a);

    const b = try siblingPath(alloc, "s-2.jsonl", ".cancel");
    defer alloc.free(b);
    try testing.expectEqualStrings("s-2.cancel", b);
}
