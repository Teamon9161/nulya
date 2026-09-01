//! `nulya ext seed`: the extension drafts this binary ships, written into a
//! store root and kept in step with the binary afterwards.
//!
//! Seeding writes SOURCE only: `ext sync` builds what lands here like any other
//! draft, and every later gate (trust, activation, pins) is unchanged.
//!
//! A seeded draft carries a `.seed` record — the digest of the tree this binary
//! wrote — which answers "whose bytes are these". Either it still describes
//! what is on disk (nobody touched it, so it may be refreshed to the newer
//! bundled source) or it does not (someone edited it: left alone and named).
//!
//! The record is a fact about one directory, gone when the directory goes. The
//! package snapshot a build freezes is manifest-driven, so `.seed` never enters
//! a version and never moves a version id.

const std = @import("std");
const store = @import("../extension/store.zig");
const bundled = @import("../bundled.zig");
const launch = @import("../launch.zig");
const journal = @import("../journals/journal.zig");
const common = @import("common.zig");
const writeRootSpec = common.writeRootSpec;
const takeUserFlag = common.takeUserFlag;
const cwdRealPath = common.cwdRealPath;
const printOut = common.printOut;
const printErrFmt = common.printErrFmt;
const printErr = common.printErr;

/// Where a draft records which binary wrote it. A dotfile beside `current` and
/// `.lock`, in the same directory it describes.
pub const record_file = ".seed";

/// The entries at the top of `<root>/<id>/` that are the STORE's, not the
/// draft's: immutable versions, the activation pointer, the writer lease, and
/// this record itself. Everything else under `<id>/` is draft source.
const store_entries = [_][]const u8{ "versions", "current", ".lock", record_file };

/// What one seeded draft says about itself (`<root>/<id>/.seed`).
///
/// `digest` is the whole point; `nulya` and `at` are provenance for the line a
/// person reads. Nothing branches on them.
pub const Record = struct {
    v: u32 = 1,
    digest: []const u8,
    nulya: []const u8 = "",
    at: []const u8 = "",
};

/// What this pass found a draft to be, before deciding anything.
pub const State = enum {
    /// No draft: seeding writes one.
    absent,
    /// Byte for byte what this binary ships. Nothing to do.
    current,
    /// The binary's own copy, untouched since it was written, from an older
    /// nulya. Safe to refresh.
    stale,
    /// Somebody's: edited here, hand-copied, or seeded by a nulya from before
    /// there were records. Left alone unless `--force` names it.
    theirs,
};

/// Compare what is on disk with what this binary ships, and with what the last
/// seed said it wrote.
///
/// Both digests are computed the same way over the same shape (paths relative
/// to the draft directory, sorted, with their bytes), so `disk == bundled` and
/// `disk == record` are comparable statements.
pub fn classify(
    alloc: std.mem.Allocator,
    io: std.Io,
    root_dir: ?std.Io.Dir,
    id: []const u8,
) !State {
    const dir = root_dir orelse return .absent;
    const disk = (try draftDigest(alloc, io, dir, id)) orelse return .absent;
    defer alloc.free(disk);
    const ships = try bundledDigest(alloc, id);
    defer alloc.free(ships);
    if (std.mem.eql(u8, disk, ships)) return .current;

    const record = try readRecord(alloc, io, dir, id) orelse return .theirs;
    defer alloc.free(record);
    return if (std.mem.eql(u8, record, disk)) .stale else .theirs;
}

/// The digest of the draft tree this binary carries for `id`, keyed by paths
/// relative to the draft directory (`src/main.zig`, not `agent/src/main.zig`).
pub fn bundledDigest(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    var files: Files = .empty;
    defer files.deinit(alloc);
    for (bundled.files) |f| {
        if (!std.mem.eql(u8, bundled.idOf(f.path), id)) continue;
        try files.append(alloc, .{ .rel = f.path[id.len + 1 ..], .bytes = f.bytes });
    }
    return digestOf(alloc, &files);
}

/// The digest of what is on disk under `<root>/<id>/`, or null when there is no
/// draft there at all. Store-owned entries are skipped: a build that produced a
/// version, an activation, or this record must not make a draft look edited.
pub fn draftDigest(alloc: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, id: []const u8) !?[]u8 {
    const marker = try std.fs.path.join(alloc, &.{ id, "extension.json" });
    defer alloc.free(marker);
    root_dir.access(io, marker, .{}) catch return null;

    var files: Files = .empty;
    defer {
        for (files.items) |f| {
            alloc.free(f.rel);
            alloc.free(f.bytes);
        }
        files.deinit(alloc);
    }
    try collect(alloc, io, root_dir, id, "", &files, true);
    return try digestOf(alloc, &files);
}

/// Write the bundled files for `id` into the root, replacing whatever draft is
/// there, and record what was written. Versions and `current` are untouched:
/// this only ever rewrites source.
///
/// Takes the store's own `<id>/.lock`, so a seed cannot land in the middle of a
/// `build` reading the same tree.
pub fn writeDraft(alloc: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, id: []const u8) !usize {
    const st = store.Store.init(io, root_dir);
    var held = try st.lease(alloc, id);
    defer held.close(io);

    try removeDraftFiles(alloc, io, root_dir, id);
    var count: usize = 0;
    for (bundled.files) |f| {
        if (!std.mem.eql(u8, bundled.idOf(f.path), id)) continue;
        count += 1;
        if (std.fs.path.dirname(f.path)) |parent| try root_dir.createDirPath(io, parent);
        try root_dir.writeFile(io, .{ .sub_path = f.path, .data = f.bytes });
    }
    try writeRecord(alloc, io, root_dir, id);
    return count;
}

/// Record the tree that is on disk right now as this binary's own.
///
/// Called after writing a draft, and also when an existing draft turns out to
/// be byte-identical to what this binary ships: that draft IS the binary's
/// copy, so recording it lets the NEXT nulya refresh it without asking. It is
/// the only catching-up available to a store seeded before records existed.
pub fn writeRecord(alloc: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, id: []const u8) !void {
    const digest = (try draftDigest(alloc, io, root_dir, id)) orelse return;
    defer alloc.free(digest);
    const at = try journal.rfc3339Now(alloc, io);
    defer alloc.free(at);
    const bytes = try std.json.Stringify.valueAlloc(
        alloc,
        Record{ .digest = digest, .nulya = launch.version, .at = at },
        .{},
    );
    defer alloc.free(bytes);
    const path = try std.fs.path.join(alloc, &.{ id, record_file });
    defer alloc.free(path);
    try root_dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// The digest the last seed recorded, or null when there is no record, it is
/// unreadable, or it speaks a version this binary does not know.
///
/// Unreadable is deliberately the same answer as missing: the record only ever
/// grants permission to overwrite, so a failure to read one must land on
/// "leave it alone".
fn readRecord(alloc: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, id: []const u8) !?[]u8 {
    const path = try std.fs.path.join(alloc, &.{ id, record_file });
    defer alloc.free(path);
    const bytes = root_dir.readFileAlloc(io, path, alloc, .limited(64 * 1024)) catch return null;
    defer alloc.free(bytes);
    const parsed = std.json.parseFromSlice(Record, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.v != 1) return null;
    return try alloc.dupe(u8, parsed.value.digest);
}

const File = struct { rel: []const u8, bytes: []const u8 };
const Files = std.ArrayList(File);

/// Sorted paths and their bytes, hashed — the same canonical shape
/// `integrity.PackageSnapshot` uses: a digest is only comparable if the
/// encoding cannot depend on directory iteration order.
fn digestOf(alloc: std.mem.Allocator, files: *Files) ![]u8 {
    std.mem.sort(File, files.items, {}, lessRel);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("nulya-seed-v1\n");
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, files.items.len, .little);
    h.update(&len);
    for (files.items) |f| {
        std.mem.writeInt(u64, &len, f.rel.len, .little);
        h.update(&len);
        h.update(f.rel);
        std.mem.writeInt(u64, &len, f.bytes.len, .little);
        h.update(&len);
        h.update(f.bytes);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const out = try alloc.alloc(u8, digest.len * 2);
    _ = std.fmt.bufPrint(out, "{x}", .{digest[0..]}) catch unreachable;
    return out;
}

fn lessRel(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

/// Walk `<root>/<dir_rel>` into `files`, keyed by `rel_prefix`-relative paths.
/// `top` marks the draft directory itself, the only level where the store's own
/// entries live.
fn collect(
    alloc: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    dir_rel: []const u8,
    rel_prefix: []const u8,
    files: *Files,
    top: bool,
) !void {
    var dir = root_dir.openDir(io, dir_rel, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (top and isStoreEntry(entry.name)) continue;
        const child_fs = try std.fs.path.join(alloc, &.{ dir_rel, entry.name });
        defer alloc.free(child_fs);
        const child_rel = if (rel_prefix.len == 0)
            try alloc.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel_prefix, entry.name });
        switch (entry.kind) {
            .file => {
                const bytes = root_dir.readFileAlloc(io, child_fs, alloc, .limited(8 * 1024 * 1024)) catch {
                    alloc.free(child_rel);
                    continue;
                };
                try files.append(alloc, .{ .rel = child_rel, .bytes = bytes });
            },
            .directory => {
                defer alloc.free(child_rel);
                try collect(alloc, io, root_dir, child_fs, child_rel, files, false);
            },
            else => alloc.free(child_rel),
        }
    }
}

fn isStoreEntry(name: []const u8) bool {
    for (store_entries) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

/// Drop the draft's own files, leaving the store's entries in place.
fn removeDraftFiles(alloc: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, id: []const u8) !void {
    var dir = root_dir.openDir(io, id, .{ .iterate = true }) catch return;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    {
        defer dir.close(io);
        var it = dir.iterate();
        // Collected first: deleting while iterating the same handle is not
        // portable.
        while (try it.next(io)) |entry| {
            if (isStoreEntry(entry.name)) continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }
    for (names.items) |name| {
        const child = try std.fs.path.join(alloc, &.{ id, name });
        defer alloc.free(child);
        root_dir.deleteTree(io, child) catch {};
    }
}

/// `nulya ext seed [--user] [<id>…] [--force] [--dry-run]`.
///
/// Four outcomes, one line each, and the summary counts them: `seeded` (there
/// was nothing), `updated` (this binary's own copy, moved forward), `up to date`
/// (nothing to do), `left alone` (someone else's — named, with the way to
/// replace it). `--force` turns the last into `replaced`; it is the only way a
/// seed overwrites work that is not its own.
pub fn extSeed(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    var dry_run = false;
    var force = false;
    var named: std.ArrayList([]const u8) = .empty;
    defer named.deinit(alloc);
    for (flags.rest) |a| {
        if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            try printErr(io, "usage: nulya ext seed [--user] [<id>…] [--force] [--dry-run]\n");
            return 1;
        } else {
            try named.append(alloc, a);
        }
    }

    const all_ids = try bundled.ids(alloc);
    defer alloc.free(all_ids);
    for (named.items) |want| {
        if (bundled.has(want)) continue;
        var list: std.Io.Writer.Allocating = .init(alloc);
        defer list.deinit();
        for (all_ids, 0..) |id, i| try list.writer.print("{s}{s}", .{ if (i == 0) "" else " ", id });
        try printErrFmt(alloc, io, "this binary ships no draft '{s}'; bundled: {s}\n", .{ want, list.written() });
        return 1;
    }

    const root_spec = (try writeRootSpec(alloc, flags.user)) orelse {
        try printErr(io, "no home directory for --user (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(root_spec);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    // A plan must not leave a mark, and creating the root directory IS one, so
    // dry-run only opens what exists.
    var root_dir: ?std.Io.Dir = if (dry_run)
        store.openRoot(io, cwd_path, root_spec) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        }
    else
        try store.openOrCreateRoot(io, cwd_path, root_spec);
    defer if (root_dir) |*d| d.close(io);

    var seeded: usize = 0;
    var updated: usize = 0;
    var kept: usize = 0;
    var theirs: std.ArrayList([]const u8) = .empty;
    defer theirs.deinit(alloc);
    for (all_ids) |id| {
        if (named.items.len != 0 and !sliceHasString(named.items, id)) continue;

        const state = try classify(alloc, io, root_dir, id);
        const write = switch (state) {
            .absent, .stale => true,
            .theirs => force,
            .current => false,
        };
        if (!write) {
            if (state == .theirs) {
                try theirs.append(alloc, id);
                try printOut(alloc, io, "{s}: differs from this build, left alone ({s}) — `nulya ext seed{s} --force {s}` replaces it\n", .{
                    id,
                    root_spec,
                    if (flags.user) " --user" else "",
                    id,
                });
            } else {
                kept += 1;
                try printOut(alloc, io, "{s}: up to date in {s}\n", .{ id, root_spec });
                // The record catches up even when nothing else does, so the
                // next nulya may move this tree on.
                if (!dry_run) writeRecord(alloc, io, root_dir.?, id) catch {};
            }
            continue;
        }

        var count: usize = 0;
        if (dry_run) {
            for (bundled.files) |f| {
                if (std.mem.eql(u8, bundled.idOf(f.path), id)) count += 1;
            }
        } else {
            count = try writeDraft(alloc, io, root_dir.?, id);
        }
        const verb = switch (state) {
            .absent => if (dry_run) "would seed" else "seeded",
            .stale => if (dry_run) "would update" else "updated",
            else => if (dry_run) "would replace" else "replaced",
        };
        if (state == .absent) seeded += 1 else updated += 1;
        try printOut(alloc, io, "{s}: {s} ({d} files) into {s}\n", .{ id, verb, count, root_spec });
    }

    try printOut(alloc, io, "{d} seeded, {d} updated, {d} up to date, {d} left alone\n", .{
        seeded,
        updated,
        kept,
        theirs.items.len,
    });
    if ((seeded != 0 or updated != 0) and !dry_run) {
        try printOut(alloc, io, "`nulya ext sync{s}` builds them\n", .{if (flags.user) " --user" else ""});
    }
    return 0;
}

fn sliceHasString(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

test "a draft seeded by this binary is recognised as its own, and an edit makes it theirs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const id = bundled.idOf(bundled.files[0].path);

    try std.testing.expectEqual(State.absent, try classify(alloc, io, tmp.dir, id));
    _ = try writeDraft(alloc, io, tmp.dir, id);
    try std.testing.expectEqual(State.current, try classify(alloc, io, tmp.dir, id));

    // A version and an activation are the store's, not the draft's: neither may
    // make a seeded draft look like somebody's work.
    const version_rel = try std.fs.path.join(alloc, &.{ id, "versions", "v-0" });
    defer alloc.free(version_rel);
    try tmp.dir.createDirPath(io, version_rel);
    const current_rel = try std.fs.path.join(alloc, &.{ id, "current" });
    defer alloc.free(current_rel);
    try tmp.dir.writeFile(io, .{ .sub_path = current_rel, .data = "v-0" });
    try std.testing.expectEqual(State.current, try classify(alloc, io, tmp.dir, id));

    // An edit to the draft itself is exactly what the record exists to notice.
    const manifest_rel = try std.fs.path.join(alloc, &.{ id, "extension.json" });
    defer alloc.free(manifest_rel);
    const original = try tmp.dir.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20));
    defer alloc.free(original);
    const edited = try std.fmt.allocPrint(alloc, "{s}\n", .{original});
    defer alloc.free(edited);
    try tmp.dir.writeFile(io, .{ .sub_path = manifest_rel, .data = edited });
    try std.testing.expectEqual(State.theirs, try classify(alloc, io, tmp.dir, id));

    // …and a draft with no record at all is theirs too: that is every store
    // seeded before records existed.
    const record_rel = try std.fs.path.join(alloc, &.{ id, record_file });
    defer alloc.free(record_rel);
    try tmp.dir.deleteFile(io, record_rel);
    try std.testing.expectEqual(State.theirs, try classify(alloc, io, tmp.dir, id));
}

test "a draft the binary ships but a stale record describes is this binary's to move on" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const id = bundled.idOf(bundled.files[0].path);
    _ = try writeDraft(alloc, io, tmp.dir, id);

    // What an OLDER binary would have left: a draft of its own, and a record
    // that matches that draft rather than what ships today.
    const manifest_rel = try std.fs.path.join(alloc, &.{ id, "extension.json" });
    defer alloc.free(manifest_rel);
    const original = try tmp.dir.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20));
    defer alloc.free(original);
    const older = try std.fmt.allocPrint(alloc, "{s}\n", .{original});
    defer alloc.free(older);
    try tmp.dir.writeFile(io, .{ .sub_path = manifest_rel, .data = older });
    try writeRecord(alloc, io, tmp.dir, id);
    try std.testing.expectEqual(State.stale, try classify(alloc, io, tmp.dir, id));

    // Seeding it again restores this binary's bytes and re-records them; a file
    // the newer draft does not have goes with it.
    const junk_rel = try std.fs.path.join(alloc, &.{ id, "left-over.txt" });
    defer alloc.free(junk_rel);
    try tmp.dir.writeFile(io, .{ .sub_path = junk_rel, .data = "x" });
    _ = try writeDraft(alloc, io, tmp.dir, id);
    try std.testing.expectEqual(State.current, try classify(alloc, io, tmp.dir, id));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, junk_rel, .{}));
}
