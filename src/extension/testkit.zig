//! Test-only fixtures: materialize seal-valid frozen extension versions on disk.
//!
//! Four modules used to hand-roll the same snapshot -> canonical -> versionId ->
//! freeze -> seal dance to stand up a fake built version for their tests. This
//! collapses that mechanism into one place so the fixtures can never drift from
//! the real freeze/seal definitions in `integrity.zig`. Fixture *shape* (which
//! manifest, which files) stays local to each test; only the plumbing lives here.

const std = @import("std");
const integrity = @import("integrity.zig");
const manifest = @import("manifest.zig");
const store = @import("store.zig");

const compiler = "zig test";
const target = "test-target";
const default_main = "pub fn main() void {}\n";
const stub_binary = "stub-binary\n";

/// A package-relative file (forward-slash rel) to freeze into `package/`.
pub const File = struct { rel: []const u8, bytes: []const u8 };

/// Write a fully frozen, seal-valid version of `id` under `root` and return its
/// content-addressed version id (caller owns it). A runtime manifest gets a stub
/// `src/main.zig` (unless `files` supplies one) plus a `bin/<entry>`; a
/// contribution-only manifest seals with no binary digest.
pub fn writeFrozenVersion(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    id: []const u8,
    manifest_bytes: []const u8,
    files: []const File,
) ![]u8 {
    var m = try manifest.parse(alloc, manifest_bytes);
    defer m.deinit();
    try m.validate();

    var snap: std.ArrayList(integrity.SnapshotFile) = .empty;
    defer {
        for (snap.items) |f| {
            alloc.free(f.rel);
            alloc.free(f.bytes);
        }
        snap.deinit(alloc);
    }

    try snap.append(alloc, .{ .rel = try alloc.dupe(u8, integrity.manifest_file), .bytes = try alloc.dupe(u8, manifest_bytes) });

    var have_src_main = false;
    for (files) |f| {
        const rel = try integrity.canonicalRel(alloc, f.rel);
        errdefer alloc.free(rel);
        const bytes = try alloc.dupe(u8, f.bytes);
        errdefer alloc.free(bytes);
        if (std.mem.eql(u8, rel, "src/main.zig")) have_src_main = true;
        try snap.append(alloc, .{ .rel = rel, .bytes = bytes });
    }
    if (m.runtime != null and !have_src_main) {
        try snap.append(alloc, .{ .rel = try alloc.dupe(u8, "src/main.zig"), .bytes = try alloc.dupe(u8, default_main) });
    }

    std.mem.sort(integrity.SnapshotFile, snap.items, {}, integrity.lessFileRel);
    const snapshot: integrity.PackageSnapshot = .{ .files = snap.items };

    const canonical = try snapshot.canonicalBytes(alloc);
    defer alloc.free(canonical);
    const version = try integrity.versionId(alloc, canonical, compiler, target);
    errdefer alloc.free(version);

    const version_rel = try std.fs.path.join(alloc, &.{ id, "versions", version });
    defer alloc.free(version_rel);
    try integrity.freezeSnapshot(alloc, io, root, version_rel, manifest_bytes, snapshot);

    var binary_digest: ?[]u8 = null;
    defer if (binary_digest) |d| alloc.free(d);
    if (m.runtime) |rt| {
        const entry = try std.fmt.allocPrint(alloc, "{s}{s}", .{ rt.entry, integrity.exe_suffix });
        defer alloc.free(entry);
        const entry_sub = try std.fs.path.join(alloc, &.{ version_rel, entry });
        defer alloc.free(entry_sub);
        if (std.fs.path.dirname(entry_sub)) |dir| try root.createDirPath(io, dir);
        try root.writeFile(io, .{ .sub_path = entry_sub, .data = stub_binary });
        binary_digest = try integrity.fileDigestHex(alloc, io, root, entry_sub);
    }

    const package_digest = try integrity.packageDigestHex(alloc, snapshot);
    defer alloc.free(package_digest);
    const seal = try integrity.sealJson(alloc, package_digest, compiler, target, binary_digest);
    defer alloc.free(seal);
    const seal_sub = try std.fs.path.join(alloc, &.{ version_rel, integrity.seal_file });
    defer alloc.free(seal_sub);
    try root.writeFile(io, .{ .sub_path = seal_sub, .data = seal });

    return version;
}

/// Point `current` at a written version.
pub fn activate(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, version: []const u8) !void {
    return store.Store.init(io, root).activate(alloc, id, version);
}
