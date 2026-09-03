//! Test-only fixtures: materialize seal-valid frozen extension versions on disk.
//!
//! One place for the snapshot -> canonical -> versionId -> freeze -> seal dance,
//! so a fixture can never drift from the real definitions in `integrity.zig`.
//! Fixture *shape* (which manifest, which files) stays local to each test; only
//! the plumbing lives here.

const std = @import("std");
const integrity = @import("integrity.zig");
const manifest = @import("manifest.zig");
const store = @import("store.zig");
const target_mod = @import("target.zig");

const compiler = "zig test";
/// A fixture's binary is written with the HOST's exe suffix, so its seal has to
/// say so: validation reads the suffix off `seal.target` (`integrity.openVersion`),
/// and a made-up target word would send it looking for `bin/demo` next to a
/// `bin/demo.exe` this file just wrote.
const target = target_mod.host;
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
    // A SCRIPT version has no separately-built binary: its entry is frozen
    // inside `package/` and covered by the package digest, so its seal must
    // record no binary digest at all (`integrity.openVersion`). Writing one
    // would make every script fixture fail validation for a reason that has
    // nothing to do with what the test is about.
    if (if (m.runtime) |rt| (if (manifest.isScript(rt)) null else rt) else null) |rt| {
        const host_entry = rt.entry.forHost() orelse return error.EntryUnsupportedOnHost;
        const entry = try std.fmt.allocPrint(alloc, "{s}{s}", .{ host_entry, integrity.exe_suffix });
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

/// A frozen contribution-only version of `id` carrying one skill whose body is
/// `body` — the smallest real version there is (no runtime, so no binary), which
/// is what makes it the fixture of choice for store / roots tests. Caller owns
/// the returned version id.
pub fn writeSkillVersion(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, body: []const u8) ![]u8 {
    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","contributes":{{"skills":["skills/demo"]}}}}
    , .{id});
    defer alloc.free(manifest_bytes);
    return writeFrozenVersion(alloc, io, root, id, manifest_bytes, &.{.{ .rel = "skills/demo/SKILL.md", .bytes = body }});
}

/// Point `current` at a written version.
pub fn activate(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, version: []const u8) !void {
    return store.Store.init(io, root).activate(alloc, id, version);
}

/// Drop `current` — the other direction of `activate`.
pub fn deactivate(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8) !void {
    return store.Store.init(io, root).deactivate(alloc, id);
}
