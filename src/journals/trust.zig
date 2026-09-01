//! Durable, append-only journal of the extension store roots this machine's
//! user has trusted.
//!
//! It exists for one gap: the workspace store `.nulya/extensions` is CHECKOUT
//! CONTENT and the first store root searched, so cloning a repo would put its
//! active versions straight into a session's composition — system prompts
//! into system blocks, tools one CLI call away — with nothing in between. A
//! line here is what "a person looked at this store once" is written down as.
//!
//! **What is trusted is the STORE, not its contents**: not a hash of the
//! versions it holds, since an agent that builds and activates its own
//! capability changes that hash every loop and a re-check would break
//! self-evolution. The judgement is about ORIGIN — born on this machine, or
//! arrived with a checkout? `nulya ext build` answers the first case itself
//! (recording trust the first time it fills an empty workspace store);
//! `nulya ext trust` answers the second.
//!
//! One JSON object per line in `<NULYA_HOME | ~/.nulya>/trusted-stores.jsonl`:
//!   {"v":1,"store":"/home/me/work/repo/.nulya/extensions","at":"2026-08-17T09:31:07Z"}
//!
//! `store` is the absolute REAL path (symlinks resolved), so every writer
//! resolves it from an open handle rather than joining strings. Duplicate
//! lines are harmless (the query is "does this path appear at all"); there is
//! no revoke verb — a withdrawal is deleting lines by hand.
//!
//! **The user layer is the whole point**: a project-layer record would let a
//! checkout sign for itself. File discipline (writer lease, torn-tail repair
//! on write, skip on read) is shared with the two workspace journals through
//! `journal.zig`; the schema above is this module's alone.

const std = @import("std");
const journal = @import("journal.zig");

/// Journal file name, relative to the user's `<NULYA_HOME | ~/.nulya>`.
pub const journal_name = "trusted-stores.jsonl";

/// Journal schema version, written into every line and required on read.
pub const journal_schema_version: u8 = 1;

pub const Error = error{
    /// A complete journal line is not a valid record (malformed JSON, missing
    /// field, wrong type).
    InvalidTrustJournal,
    /// A journal line carries a schema version this build does not understand.
    UnsupportedTrustVersion,
};

/// One trusted store as it was read back. Owned by the caller that received it
/// from `readAll`; free the slice with `freeAll`.
pub const Record = struct {
    /// Absolute real path of the store root.
    store: []const u8,
    /// RFC3339 UTC instant the trust was recorded.
    at: []const u8,
};

/// Record `store_path` (an absolute real path) as trusted, stamped with the
/// current instant. `home` is the user's `<NULYA_HOME | ~/.nulya>`, created when
/// missing — this is the write side, and a machine that has never had a user
/// layer should get one rather than fail. Appending a path that is already
/// trusted is legal and changes nothing a reader sees.
pub fn append(alloc: std.mem.Allocator, io: std.Io, home: []const u8, store_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, home);
    const at = try journal.rfc3339Now(alloc, io);
    defer alloc.free(at);
    const line = try encodeRecord(alloc, store_path, at);
    defer alloc.free(line);
    try journal.appendLine(io, home, journal_name, line);
}

/// Whether `store_path` appears in the journal. This is the whole query: the
/// gate asks about a path, never about the bytes under it.
pub fn isTrusted(alloc: std.mem.Allocator, io: std.Io, home: []const u8, store_path: []const u8) !bool {
    const records = try readAll(alloc, io, home);
    defer freeAll(alloc, records);
    for (records) |r| {
        if (std.mem.eql(u8, r.store, store_path)) return true;
    }
    return false;
}

/// Read every record in journal order. A missing journal — or a missing user
/// home, which is the ordinary state of a machine that has never trusted
/// anything — reads as empty. Blank lines and a torn final line are ignored; any
/// malformed COMPLETE line is an explicit error, so a corrupt journal fails the
/// gate loudly instead of quietly answering "not trusted" (or "trusted").
pub fn readAll(alloc: std.mem.Allocator, io: std.Io, home: []const u8) ![]Record {
    const bytes = (journal.readAll(alloc, io, home, journal_name) catch |err| switch (err) {
        // Unlike a workspace, the user layer legitimately may not exist yet.
        error.FileNotFound, error.NotDir => return alloc.alloc(Record, 0),
        else => return err,
    }) orelse return alloc.alloc(Record, 0);
    defer alloc.free(bytes);

    var records: std.ArrayList(Record) = .empty;
    errdefer freeAll(alloc, records.items);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try appendParsed(alloc, &records, line);
    }
    return records.toOwnedSlice(alloc);
}

pub fn freeAll(alloc: std.mem.Allocator, records: []Record) void {
    for (records) |r| {
        alloc.free(r.store);
        alloc.free(r.at);
    }
    alloc.free(records);
}

fn encodeRecord(alloc: std.mem.Allocator, store_path: []const u8, at: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(journal_schema_version);
    try jw.objectField("store");
    try jw.write(store_path);
    try jw.objectField("at");
    try jw.write(at);
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// One journal line's shape. Every column is required — this journal has no
/// older format to be lenient about. Unknown fields are ignored so a newer
/// writer at the same `v` never breaks an older reader.
const WireRecord = struct {
    /// Wider than `journal_schema_version` on purpose: a number this build does
    /// not understand must reach the version check as a version, not fail
    /// parsing as if the line were malformed.
    v: u32,
    store: []const u8,
    at: []const u8,
};

const json_opts: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = true };

fn appendParsed(alloc: std.mem.Allocator, records: *std.ArrayList(Record), line: []const u8) !void {
    const parsed = std.json.parseFromSlice(WireRecord, alloc, line, json_opts) catch |err| switch (err) {
        // A host OOM is a resource fault, never a malformed journal.
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTrustJournal,
    };
    defer parsed.deinit();
    if (parsed.value.v != journal_schema_version) return error.UnsupportedTrustVersion;

    const store_path = try alloc.dupe(u8, parsed.value.store);
    errdefer alloc.free(store_path);
    const at = try alloc.dupe(u8, parsed.value.at);
    errdefer alloc.free(at);
    try records.append(alloc, .{ .store = store_path, .at = at });
}

fn tmpPath(alloc: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

test "a store is untrusted until it is recorded, and recording it is idempotent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpPath(alloc, io, tmp);
    defer alloc.free(base);

    // A home that does not exist yet is "nothing trusted", never a fault: this
    // is the state of every machine before its first `ext build`.
    const home = try std.fs.path.join(alloc, &.{ base, ".nulya" });
    defer alloc.free(home);
    const empty = try readAll(alloc, io, home);
    defer freeAll(alloc, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expect(!try isTrusted(alloc, io, home, "/work/repo/.nulya/extensions"));

    // Recording creates the user layer and the journal beneath it.
    try append(alloc, io, home, "/work/repo/.nulya/extensions");
    try std.testing.expect(try isTrusted(alloc, io, home, "/work/repo/.nulya/extensions"));
    // Another store is a different fact — trust is per store root, and a path
    // that merely has a trusted one as a prefix is not it.
    try std.testing.expect(!try isTrusted(alloc, io, home, "/work/other/.nulya/extensions"));
    try std.testing.expect(!try isTrusted(alloc, io, home, "/work/repo/.nulya/extensions/demo"));

    // Trusting the same store twice is legal and adds nothing a reader sees.
    try append(alloc, io, home, "/work/repo/.nulya/extensions");
    try std.testing.expect(try isTrusted(alloc, io, home, "/work/repo/.nulya/extensions"));

    const records = try readAll(alloc, io, home);
    defer freeAll(alloc, records);
    try std.testing.expectEqual(@as(usize, 2), records.len);
    for (records) |r| {
        try std.testing.expectEqualStrings("/work/repo/.nulya/extensions", r.store);
        try std.testing.expectEqual(@as(usize, 20), r.at.len);
        try std.testing.expectEqual(@as(u8, 'Z'), r.at[19]);
    }
}

test "the record is one complete line with its columns in a fixed order" {
    const alloc = std.testing.allocator;
    const line = try encodeRecord(alloc, "/work/repo/.nulya/extensions", "2026-08-17T09:31:07Z");
    defer alloc.free(line);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"store\":\"/work/repo/.nulya/extensions\",\"at\":\"2026-08-17T09:31:07Z\"}\n",
        line,
    );
}

test "the journal lives in the home it is given, so NULYA_HOME relocates it wholesale" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpPath(alloc, io, tmp);
    defer alloc.free(base);

    // Two homes, as `NULYA_HOME` pointing at two places would give: a trust
    // recorded in one is invisible in the other, which is what makes a test (or
    // a second identity) hermetic.
    const alt = try std.fs.path.join(alloc, &.{ base, "alt-home" });
    defer alloc.free(alt);
    const real = try std.fs.path.join(alloc, &.{ base, "real-home" });
    defer alloc.free(real);

    try append(alloc, io, alt, "/work/repo/.nulya/extensions");
    try std.testing.expect(try isTrusted(alloc, io, alt, "/work/repo/.nulya/extensions"));
    try std.testing.expect(!try isTrusted(alloc, io, real, "/work/repo/.nulya/extensions"));

    // The journal is a bare file in that directory — no nested `.nulya`.
    var alt_dir = try std.Io.Dir.openDirAbsolute(io, alt, .{});
    defer alt_dir.close(io);
    try alt_dir.access(io, journal_name, .{});
    try std.testing.expectError(error.FileNotFound, alt_dir.access(io, journal.journal_dir, .{}));
}

test "a corrupt journal fails the query loudly instead of answering it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(alloc, io, tmp);
    defer alloc.free(home);

    // Not JSON, and a complete line missing a required column: both are the
    // consumer's error. Answering "not trusted" would send a person to re-run
    // `ext trust` forever; answering "trusted" would be worse.
    try tmp.dir.writeFile(io, .{ .sub_path = journal_name, .data = "not json\n" });
    try std.testing.expectError(error.InvalidTrustJournal, isTrusted(alloc, io, home, "/x"));
    try tmp.dir.writeFile(io, .{ .sub_path = journal_name, .data = "{\"v\":1,\"store\":\"/x\"}\n" });
    try std.testing.expectError(error.InvalidTrustJournal, isTrusted(alloc, io, home, "/x"));
    try tmp.dir.writeFile(io, .{ .sub_path = journal_name, .data = "{\"v\":2,\"store\":\"/x\",\"at\":\"z\"}\n" });
    try std.testing.expectError(error.UnsupportedTrustVersion, isTrusted(alloc, io, home, "/x"));

    // A torn final line (an append interrupted, or in flight right now) is not
    // corruption — the complete records before it still answer.
    try tmp.dir.writeFile(io, .{
        .sub_path = journal_name,
        .data = "{\"v\":1,\"store\":\"/x\",\"at\":\"2026-08-17T09:31:07Z\"}\n{\"v\":1,\"store\":\"/y\",\"at",
    });
    try std.testing.expect(try isTrusted(alloc, io, home, "/x"));
    try std.testing.expect(!try isTrusted(alloc, io, home, "/y"));

    // A column this build does not know is ignored, not an error.
    try tmp.dir.writeFile(io, .{
        .sub_path = journal_name,
        .data = "{\"v\":1,\"store\":\"/x\",\"at\":\"2026-08-17T09:31:07Z\",\"future\":1}\n",
    });
    try std.testing.expect(try isTrusted(alloc, io, home, "/x"));
}
