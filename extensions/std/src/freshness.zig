//! What the model has already seen of each file, so `read` can short-circuit a
//! redundant read of unchanged content, `write` can demand a read before it
//! overwrites, `append` can demand at least a glimpse, and both can spot
//! external modification. Zero-guessing: the model never spends tokens
//! discovering what this process already knows.
//!
//! The tracker is a port of tcode's `tcode-core/src/freshness.rs`, semantics
//! and tests included. What differs is where it lives: a tool here is one
//! process per call, so the record is an append-only JSONL file in this
//! session's scratch directory (`.nulya/scratch/<session>/std-freshness.jsonl`)
//! — one line per `record_*` event, replayed on open. A fork or handoff is a
//! new session id and therefore a fresh file, which is exactly right: the new
//! context has read nothing yet. Outside a session there is no file and no
//! gate. Paths are keyed absolute, compared byte for byte (as tcode compares
//! `PathBuf`s); the hash is only ever compared with hashes this file wrote.
//!
//! `edit` reports here too (as a read of the echoed snippet under the new
//! hash, see edit.zig), so a `write`/`append` after our own edit is not mistaken
//! for an external change; a change made any other way still is.

const std = @import("std");

/// 1-based, inclusive.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn eql(a: Range, b: Range) bool {
        return a.start == b.start and a.end == b.end;
    }
};

pub const FileRecord = struct {
    hash: u64,
    /// The model saw the entire file (vs a range).
    full: bool,
    /// Ranges seen, sorted and coalesced.
    ranges: std.ArrayList(Range),
};

/// How much of the current on-disk version (identified by `hash`) is in the
/// model's context. Powers `write`'s full-visibility overwrite gate and
/// `append`'s any-visibility gate; `partial` carries the seen ranges so a gate
/// error can tell the model exactly what is missing.
pub const Visibility = union(enum) {
    /// No record for this path.
    unseen,
    /// Recorded, but under a different hash — changed on disk since.
    stale,
    /// Current version, but only these coalesced ranges.
    partial: []const Range,
    /// The whole current version is in context.
    full,
};

/// Answer to "should this read actually return content?".
pub const ReadStatus = enum {
    /// First sighting.
    new,
    /// Same content already in context — return a stub instead.
    unchanged,
    /// File changed on disk since the model last saw it.
    changed_on_disk,
    /// Same file version, but a range the model has not seen.
    new_range,
};

/// The identity of one on-disk version. Only ever compared with hashes this
/// same code produced, so any stable function will do.
pub fn contentHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// The in-memory tracker (tcode `FreshnessTracker`). Owns copies of its keys.
pub const Tracker = struct {
    alloc: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(FileRecord) = .empty,

    pub fn init(alloc: std.mem.Allocator) Tracker {
        return .{ .alloc = alloc };
    }

    pub fn checkRead(self: *const Tracker, path: []const u8, hash: u64, range: ?Range) ReadStatus {
        const rec = self.files.get(path) orelse return .new;
        if (rec.hash != hash) return .changed_on_disk;
        const covered = if (range) |r| rec.full or covers(rec.ranges.items, r) else rec.full;
        return if (covered) .unchanged else .new_range;
    }

    pub fn recordRead(self: *Tracker, path: []const u8, hash: u64, range: ?Range) !void {
        const rec = try self.entry(path, hash);
        if (rec.hash != hash) {
            // New version: everything previously seen is stale.
            rec.hash = hash;
            rec.full = false;
            rec.ranges.clearRetainingCapacity();
        }
        if (range) |r| {
            // Coalesced so accumulated small reads combine into the union they
            // cover — a later read spanning two prior windows is then
            // correctly recognized as already seen.
            try insertCoalesced(self.alloc, &rec.ranges, r);
        } else {
            rec.full = true;
        }
    }

    /// The single contiguous slice of `range` the model has not seen yet, when
    /// the remainder is already covered. Null when the request is wholly new,
    /// wholly seen, or its uncovered part is fragmented — the caller reads the
    /// full requested range in those cases. Lets an overlapping re-read (same
    /// offset, wider window) return only the delta.
    pub fn uncoveredGap(self: *const Tracker, path: []const u8, hash: u64, range: Range) ?Range {
        const rec = self.files.get(path) orelse return null;
        if (rec.hash != hash or rec.full) return null;
        // ranges is sorted and coalesced; walk the gaps within [s, e].
        var cursor = range.start;
        var gaps: [2]Range = undefined;
        var n: usize = 0;
        for (rec.ranges.items) |seen| {
            if (seen.end < cursor or seen.start > range.end) continue;
            if (seen.start > cursor) {
                if (n == 2) return null;
                gaps[n] = .{ .start = cursor, .end = seen.start - 1 };
                n += 1;
            }
            cursor = @max(cursor, seen.end + 1);
            if (cursor > range.end) break;
        }
        if (cursor <= range.end) {
            if (n == 2) return null;
            gaps[n] = .{ .start = cursor, .end = range.end };
            n += 1;
        }
        // A single gap strictly inside the request is a real trim; a lone gap
        // equal to the whole request means nothing was covered.
        if (n == 1 and !gaps[0].eql(range)) return gaps[0];
        return null;
    }

    /// After our own write the produced content is known and shown to the
    /// model, so the new version counts as seen in full.
    pub fn recordWrite(self: *Tracker, path: []const u8, hash: u64) !void {
        const rec = try self.entry(path, hash);
        rec.hash = hash;
        rec.full = true;
        rec.ranges.clearRetainingCapacity();
    }

    /// Has the model seen the current on-disk version?
    pub fn seenCurrent(self: *const Tracker, path: []const u8, hash: u64) bool {
        const rec = self.files.get(path) orelse return false;
        return rec.hash == hash;
    }

    /// How much of the version identified by `hash` the model has seen.
    pub fn visibility(self: *const Tracker, path: []const u8, hash: u64) Visibility {
        const rec = self.files.get(path) orelse return .unseen;
        if (rec.hash != hash) return .stale;
        if (rec.full) return .full;
        return .{ .partial = rec.ranges.items };
    }

    /// After our own `append`: visibility of the prior version carries forward
    /// — appended lines are model-authored and count as seen, but a partial
    /// view of the old content must not become "fully seen". `appended` is the
    /// range of the NEW version now visible from this append — the appendix
    /// plus any context lines echoed back — with `appended.end` equal to the
    /// new total line count. (When the old content did not end in '\n' the
    /// first appended chunk merges into the old last line; that line belongs in
    /// the range.)
    pub fn recordAppend(self: *Tracker, path: []const u8, new_hash: u64, appended: Range) !void {
        // The append gate requires prior sight; stay conservative if not.
        const rec = try self.entry(path, new_hash);
        rec.hash = new_hash;
        if (rec.full) {
            rec.ranges.clearRetainingCapacity();
        } else {
            try insertCoalesced(self.alloc, &rec.ranges, appended);
            // Coalesced coverage of every line of the new version is full
            // sight — a later whole-file read must stub correctly.
            if (rec.ranges.items.len == 1 and rec.ranges.items[0].eql(.{ .start = 1, .end = appended.end })) {
                rec.full = true;
                rec.ranges.clearRetainingCapacity();
            }
        }
    }

    /// Context no longer contains old reads (compaction/rewind).
    pub fn clear(self: *Tracker) void {
        self.files.clearRetainingCapacity();
    }

    fn entry(self: *Tracker, path: []const u8, hash: u64) !*FileRecord {
        const gop = try self.files.getOrPut(self.alloc, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc.dupe(u8, path);
            gop.value_ptr.* = .{ .hash = hash, .full = false, .ranges = .empty };
        }
        return gop.value_ptr;
    }
};

fn covers(ranges: []const Range, r: Range) bool {
    for (ranges) |seen| if (seen.start <= r.start and r.end <= seen.end) return true;
    return false;
}

/// Insert `r` into a sorted, non-overlapping range list, merging any ranges it
/// touches (adjacent counts: `[1,50]` + `[51,80]` → `[1,80]`).
fn insertCoalesced(alloc: std.mem.Allocator, ranges: *std.ArrayList(Range), r: Range) !void {
    var s = r.start;
    var e = r.end;
    var merged: std.ArrayList(Range) = .empty;
    try merged.ensureTotalCapacity(alloc, ranges.items.len + 1);
    var inserted = false;
    for (ranges.items) |seen| {
        if (seen.end + 1 < s) {
            merged.appendAssumeCapacity(seen); // wholly before the new range
        } else if (e + 1 < seen.start) {
            if (!inserted) {
                merged.appendAssumeCapacity(.{ .start = s, .end = e }); // new range slots in here
                inserted = true;
            }
            merged.appendAssumeCapacity(seen);
        } else {
            // Overlapping or adjacent: absorb into the growing new range.
            s = @min(s, seen.start);
            e = @max(e, seen.end);
        }
    }
    if (!inserted) merged.appendAssumeCapacity(.{ .start = s, .end = e });
    ranges.deinit(alloc);
    ranges.* = merged;
}

// ---------------------------------------------------------------- journal

/// Where this session's record lives, under the workspace (`cwd`).
pub const scratch_dir = ".nulya/scratch";
pub const journal_name = "std-freshness.jsonl";

/// One line of the journal. Field names are the on-disk keys.
const Event = struct {
    op: []const u8,
    path: []const u8,
    /// Hex of `contentHash`.
    hash: []const u8,
    /// `[start, end]`, or null for a whole-file read and for a write.
    range: ?[2]usize = null,
};

/// The tracker for one session, replayed from and appended to its journal.
/// Every `record*` both updates the in-memory tracker and appends one line, so
/// the next call in the session (a new process) starts from the same state.
pub const Journal = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Absolute path of the journal file.
    file: []const u8,
    tracker: Tracker,

    /// Replay the journal of `session_id` under `cwd`; a missing file is an
    /// empty record, a malformed line is skipped. Null when there is no
    /// session — and then there is no freshness at all.
    pub fn open(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, session_id: ?[]const u8) !?Journal {
        const sid = session_id orelse return null;
        const file = try std.fs.path.join(alloc, &.{ cwd, scratch_dir, sid, journal_name });
        var journal: Journal = .{ .alloc = alloc, .io = io, .file = file, .tracker = Tracker.init(alloc) };
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, alloc, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return journal,
            else => return err,
        };
        try journal.replay(bytes);
        return journal;
    }

    fn replay(self: *Journal, bytes: []const u8) !void {
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const ev = std.json.parseFromSliceLeaky(Event, self.alloc, line, .{ .ignore_unknown_fields = true }) catch continue;
            const hash = std.fmt.parseInt(u64, ev.hash, 16) catch continue;
            const range: ?Range = if (ev.range) |r| .{ .start = r[0], .end = r[1] } else null;
            if (std.mem.eql(u8, ev.op, "read")) {
                try self.tracker.recordRead(ev.path, hash, range);
            } else if (std.mem.eql(u8, ev.op, "write")) {
                try self.tracker.recordWrite(ev.path, hash);
            } else if (std.mem.eql(u8, ev.op, "append")) {
                try self.tracker.recordAppend(ev.path, hash, range orelse continue);
            }
        }
    }

    pub fn checkRead(self: *const Journal, path: []const u8, hash: u64, range: ?Range) ReadStatus {
        return self.tracker.checkRead(path, hash, range);
    }

    pub fn uncoveredGap(self: *const Journal, path: []const u8, hash: u64, range: Range) ?Range {
        return self.tracker.uncoveredGap(path, hash, range);
    }

    pub fn visibility(self: *const Journal, path: []const u8, hash: u64) Visibility {
        return self.tracker.visibility(path, hash);
    }

    pub fn recordRead(self: *Journal, path: []const u8, hash: u64, range: ?Range) !void {
        try self.tracker.recordRead(path, hash, range);
        try self.appendEvent("read", path, hash, range);
    }

    pub fn recordWrite(self: *Journal, path: []const u8, hash: u64) !void {
        try self.tracker.recordWrite(path, hash);
        try self.appendEvent("write", path, hash, null);
    }

    pub fn recordAppend(self: *Journal, path: []const u8, hash: u64, appended: Range) !void {
        try self.tracker.recordAppend(path, hash, appended);
        try self.appendEvent("append", path, hash, appended);
    }

    fn appendEvent(self: *Journal, op: []const u8, path: []const u8, hash: u64, range: ?Range) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        const hex = try std.fmt.allocPrint(self.alloc, "{x:0>16}", .{hash});
        const ev: Event = .{
            .op = op,
            .path = path,
            .hash = hex,
            .range = if (range) |r| .{ r.start, r.end } else null,
        };
        try std.json.Stringify.value(ev, .{}, &out.writer);
        try out.writer.writeByte('\n');

        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(self.file)) |parent| try cwd.createDirPath(self.io, parent);
        // One writer per session (tool calls run one at a time), so an
        // append is: open without truncating, write at the current end.
        var file = try cwd.createFile(self.io, self.file, .{ .truncate = false, .read = true });
        defer file.close(self.io);
        const end = (try file.stat(self.io)).size;
        try file.writePositionalAll(self.io, out.writer.buffered(), end);
    }
};

// ------------------------------------------------------------------ tests
// The tracker tests are tcode's, one for one.

test {
    std.testing.refAllDecls(@This());
}

fn expectPartial(v: Visibility, want: []const Range) !void {
    try std.testing.expect(v == .partial);
    try std.testing.expectEqual(want.len, v.partial.len);
    for (want, v.partial) |w, g| try std.testing.expect(w.eql(g));
}

test "dedupes unchanged full read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try std.testing.expectEqual(ReadStatus.new, t.checkRead(p, 1, null));
    try t.recordRead(p, 1, null);
    try std.testing.expectEqual(ReadStatus.unchanged, t.checkRead(p, 1, null));
    try std.testing.expectEqual(ReadStatus.unchanged, t.checkRead(p, 1, .{ .start = 5, .end = 10 }));
    try std.testing.expectEqual(ReadStatus.changed_on_disk, t.checkRead(p, 2, null));
}

test "range reads cover subranges only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try t.recordRead(p, 1, .{ .start = 10, .end = 50 });
    try std.testing.expectEqual(ReadStatus.unchanged, t.checkRead(p, 1, .{ .start = 20, .end = 30 }));
    try std.testing.expectEqual(ReadStatus.new_range, t.checkRead(p, 1, .{ .start = 40, .end = 60 }));
    try std.testing.expectEqual(ReadStatus.new_range, t.checkRead(p, 1, null));
}

test "new version resets ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try t.recordRead(p, 1, .{ .start = 1, .end = 100 });
    try t.recordRead(p, 2, .{ .start = 1, .end = 10 });
    try std.testing.expectEqual(ReadStatus.new_range, t.checkRead(p, 2, .{ .start = 50, .end = 60 }));
}

test "coalesced ranges recognize the union as seen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try t.recordRead(p, 1, .{ .start = 1, .end = 50 });
    try t.recordRead(p, 1, .{ .start = 51, .end = 80 }); // adjacent → merges into (1,80)
    // A read spanning both prior windows is now fully covered.
    try std.testing.expectEqual(ReadStatus.unchanged, t.checkRead(p, 1, .{ .start = 20, .end = 70 }));
}

test "uncovered gap returns only the new suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try t.recordRead(p, 1, .{ .start = 1300, .end = 1449 });
    // Same offset, wider window: only 1450-1479 is new.
    try std.testing.expect(t.uncoveredGap(p, 1, .{ .start = 1300, .end = 1479 }).?.eql(.{ .start = 1450, .end = 1479 }));
    // A wholly-new range has no partial gap to trim.
    try std.testing.expect(t.uncoveredGap(p, 1, .{ .start = 2000, .end = 2100 }) == null);
    // A fragmented request (hole in the middle already seen) reads whole.
    try t.recordRead(p, 1, .{ .start = 1600, .end = 1650 });
    try std.testing.expect(t.uncoveredGap(p, 1, .{ .start = 1500, .end = 1700 }) == null);
}

test "write marks current version seen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try std.testing.expect(!t.seenCurrent(p, 7));
    try t.recordWrite(p, 7);
    try std.testing.expect(t.seenCurrent(p, 7));
    try std.testing.expectEqual(ReadStatus.unchanged, t.checkRead(p, 7, null));
}

test "visibility reports unseen stale partial full" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try std.testing.expect(t.visibility(p, 1) == .unseen);
    try t.recordRead(p, 1, .{ .start = 10, .end = 20 });
    try std.testing.expect(t.visibility(p, 2) == .stale);
    try expectPartial(t.visibility(p, 1), &.{.{ .start = 10, .end = 20 }});
    try t.recordRead(p, 1, null);
    try std.testing.expect(t.visibility(p, 1) == .full);
}

test "record append after full sight stays full" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try t.recordWrite(p, 1);
    try t.recordAppend(p, 2, .{ .start = 11, .end = 15 });
    try std.testing.expect(t.visibility(p, 2) == .full);
    try std.testing.expectEqual(ReadStatus.unchanged, t.checkRead(p, 2, null));
}

test "record append after partial read stays partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    // Saw lines 1-10 of a 30-line file, then appended lines 31-35.
    try t.recordRead(p, 1, .{ .start = 1, .end = 10 });
    try t.recordAppend(p, 2, .{ .start = 31, .end = 35 });
    try expectPartial(t.visibility(p, 2), &.{ .{ .start = 1, .end = 10 }, .{ .start = 31, .end = 35 } });
    try std.testing.expectEqual(ReadStatus.new_range, t.checkRead(p, 2, null));
    try std.testing.expectEqual(ReadStatus.new_range, t.checkRead(p, 2, .{ .start = 15, .end = 20 }));
    try std.testing.expectEqual(ReadStatus.unchanged, t.checkRead(p, 2, .{ .start = 32, .end = 35 }));
}

test "record append no trailing newline covers the merged line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    // Saw lines 5-20; old last line 20 had no trailing newline, so the
    // appended range starts at 20 and coalesces with the seen range.
    try t.recordRead(p, 1, .{ .start = 5, .end = 20 });
    try t.recordAppend(p, 2, .{ .start = 20, .end = 24 });
    try expectPartial(t.visibility(p, 2), &.{.{ .start = 5, .end = 24 }});
}

test "record append full coverage upgrades to full" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try t.recordRead(p, 1, .{ .start = 1, .end = 30 });
    try t.recordAppend(p, 2, .{ .start = 31, .end = 40 });
    try std.testing.expect(t.visibility(p, 2) == .full);
    try std.testing.expectEqual(ReadStatus.unchanged, t.checkRead(p, 2, null));
}

test "record append on an unseen path stays conservative (partial, never full)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tracker.init(arena.allocator());
    const p = "a.rs";
    try t.recordAppend(p, 2, .{ .start = 5, .end = 9 });
    try expectPartial(t.visibility(p, 2), &.{.{ .start = 5, .end = 9 }});
}

test "journal: events replay into the same tracker state; no session means no journal; a bad line is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = buf[0..try tmp.dir.realPath(io, &buf)];

    try std.testing.expect((try Journal.open(alloc, io, cwd, null)) == null);

    const p = try std.fs.path.join(alloc, &.{ cwd, "a.rs" });
    {
        var j = (try Journal.open(alloc, io, cwd, "s-1")).?;
        try std.testing.expectEqual(ReadStatus.new, j.checkRead(p, 1, null));
        try j.recordRead(p, 1, .{ .start = 1, .end = 10 });
        try j.recordAppend(p, 2, .{ .start = 31, .end = 35 });
        try j.recordWrite(p, 3);
        try j.recordRead(p, 4, .{ .start = 2, .end = 5 });
    }
    // Something else in the session wrote a torn / foreign line: ignored.
    {
        const rel_path = try std.fs.path.join(alloc, &.{ scratch_dir, "s-1", journal_name });
        const existing = try tmp.dir.readFileAlloc(io, rel_path, alloc, .unlimited);
        try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, existing, "\n"));
        try std.testing.expect(std.mem.indexOf(u8, existing, "\"op\":\"append\"") != null);
        const with_junk = try std.mem.concat(alloc, u8, &.{ existing, "{not json\n{\"op\":\"read\",\"path\":\"x\"}\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = rel_path, .data = with_junk });
    }
    {
        const j = (try Journal.open(alloc, io, cwd, "s-1")).?;
        try expectPartial(j.visibility(p, 4), &.{.{ .start = 2, .end = 5 }});
        try std.testing.expect(j.visibility(p, 3) == .stale);
        try std.testing.expectEqual(ReadStatus.unchanged, j.checkRead(p, 4, .{ .start = 3, .end = 4 }));
    }
    // Another session shares nothing.
    {
        const other = (try Journal.open(alloc, io, cwd, "s-2")).?;
        try std.testing.expect(other.visibility(p, 4) == .unseen);
    }
}
