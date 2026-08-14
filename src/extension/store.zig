//! Extension version store — immutable versions + atomic activate/rollback
//! (DESIGN §7.4).
//!
//! Nulya never overwrites a running tool's binary. Every build produces an
//! IMMUTABLE version whose id is `hash(source + zig_version + target + manifest)`;
//! versions accumulate side by side and a single `current` pointer selects the
//! active one. Switching is an atomic rename, so rollback is just repointing
//! `current` at an older version — B breaking never disturbs A.
//!
//! Layout under the store root (`.nulya/extensions`):
//!
//!   <id>/
//!     versions/
//!       v-<hash>/
//!         extension.json
//!         bin/<entry>        # only when the manifest declares runtime
//!     current              # text file holding "v-<hash>"
//!
//! `current` is a plain file, not a symlink: symlinks need privilege on Windows
//! and buy nothing here.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("manifest.zig");

pub const version_prefix = "v-";
const current_file = "current";
const versions_dir = "versions";
const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
/// 12 bytes of digest -> 24 hex chars. Ample collision resistance for a local
/// content-addressed store while keeping directory names short.
const digest_bytes = 12;

pub const Store = struct {
    io: std.Io,
    /// The `.nulya/extensions` directory. Caller owns its lifetime.
    root: std.Io.Dir,

    pub fn init(io: std.Io, root: std.Io.Dir) Store {
        return .{ .io = io, .root = root };
    }

    /// Inputs that make a build reproducible; identical inputs -> identical
    /// version id (DESIGN §7.4, §10).
    pub const VersionInputs = struct {
        source: []const u8,
        zig_version: []const u8,
        target: []const u8,
        manifest: []const u8,
    };

    /// `v-<hex>`. Pure function of the inputs — no I/O. Caller owns the result.
    pub fn versionId(alloc: std.mem.Allocator, inputs: VersionInputs) ![]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        // Length-prefix each field so no concatenation of two fields can alias
        // another split of the same bytes.
        inline for (.{ inputs.source, inputs.zig_version, inputs.target, inputs.manifest }) |field| {
            var len_le: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_le, field.len, .little);
            h.update(&len_le);
            h.update(field);
        }
        var digest: [32]u8 = undefined;
        h.final(&digest);

        var out = try alloc.alloc(u8, version_prefix.len + digest_bytes * 2);
        @memcpy(out[0..version_prefix.len], version_prefix);
        _ = std.fmt.bufPrint(out[version_prefix.len..], "{x}", .{digest[0..digest_bytes]}) catch unreachable;
        return out;
    }

    /// Create `<id>/versions/<version>/bin/` (and parents). Idempotent.
    pub fn ensureVersionDir(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
        const sub = try std.fs.path.join(alloc, &.{ id, versions_dir, version, "bin" });
        defer alloc.free(sub);
        try self.root.createDirPath(self.io, sub);
    }

    /// Root-relative path of a version directory. Caller owns the result.
    pub fn versionDir(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) ![]u8 {
        _ = self;
        return std.fs.path.join(alloc, &.{ id, versions_dir, version });
    }

    /// Root-relative path of a version's frozen manifest. Caller owns the result.
    pub fn versionManifestPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) ![]u8 {
        _ = self;
        return std.fs.path.join(alloc, &.{ id, versions_dir, version, "extension.json" });
    }

    /// Root-relative path of a version's built entry binary. Caller owns the result.
    pub fn versionEntryPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, entry: []const u8) ![]u8 {
        _ = self;
        const entry_rel = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entry, exe_suffix });
        defer alloc.free(entry_rel);
        return std.fs.path.join(alloc, &.{ id, versions_dir, version, entry_rel });
    }

    pub fn versionExists(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) bool {
        validateBuiltVersion(self, alloc, id, version) catch return false;
        return true;
    }

    /// Point `current` at `version`. Refuses to activate a version that was never
    /// fully built. The write is atomic (temp file + rename in the same directory),
    /// so a crash mid-switch leaves the previous `current` intact.
    pub fn activate(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
        try validateBuiltVersion(self, alloc, id, version);

        const tmp_sub = try std.fs.path.join(alloc, &.{ id, ".current.tmp" });
        defer alloc.free(tmp_sub);
        const final_sub = try std.fs.path.join(alloc, &.{ id, current_file });
        defer alloc.free(final_sub);

        try self.root.writeFile(self.io, .{ .sub_path = tmp_sub, .data = version });
        try self.root.rename(tmp_sub, self.root, final_sub, self.io);
    }

    /// Rollback is mechanically identical to activate: repoint `current`
    /// (DESIGN §7.4). Named separately so call sites read intent.
    pub fn rollback(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
        return self.activate(alloc, id, version);
    }

    pub fn deactivate(self: Store, alloc: std.mem.Allocator, id: []const u8) !void {
        const sub = try std.fs.path.join(alloc, &.{ id, current_file });
        defer alloc.free(sub);
        self.root.deleteFile(self.io, sub) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// The active version id, or null if the extension has none. Caller owns the
    /// returned slice.
    pub fn activeVersion(self: Store, alloc: std.mem.Allocator, id: []const u8) !?[]u8 {
        const sub = try std.fs.path.join(alloc, &.{ id, current_file });
        defer alloc.free(sub);
        const raw = self.root.readFileAlloc(self.io, sub, alloc, .limited(256)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer alloc.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try alloc.dupe(u8, trimmed);
    }

    /// All built version ids for `id`, newest-first order not guaranteed. Caller
    /// owns the outer slice and each entry.
    pub fn listVersions(self: Store, alloc: std.mem.Allocator, id: []const u8) ![]const []u8 {
        const sub = try std.fs.path.join(alloc, &.{ id, versions_dir });
        defer alloc.free(sub);

        var dir = self.root.openDir(self.io, sub, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return alloc.alloc([]u8, 0),
            else => return err,
        };
        defer dir.close(self.io);

        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |v| alloc.free(v);
            out.deinit(alloc);
        }
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, entry.name, version_prefix)) continue;
            try out.append(alloc, try alloc.dupe(u8, entry.name));
        }
        return out.toOwnedSlice(alloc);
    }
};

fn validateBuiltVersion(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
    const manifest_sub = try self.versionManifestPath(alloc, id, version);
    defer alloc.free(manifest_sub);
    const bytes = self.root.readFileAlloc(self.io, manifest_sub, alloc, .limited(1 << 20)) catch
        return error.VersionNotFound;
    defer alloc.free(bytes);

    var m = try manifest.parse(alloc, bytes);
    defer m.deinit();
    try m.validate();
    if (!std.mem.eql(u8, m.id, id)) return error.VersionManifestIdMismatch;

    if (m.runtime) |rt| {
        const entry_sub = try self.versionEntryPath(alloc, id, version, rt.entry);
        defer alloc.free(entry_sub);
        self.root.access(self.io, entry_sub, .{}) catch return error.VersionEntryNotFound;
    }
}

fn writeBuiltVersion(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, version: []const u8) !void {
    const dir = try std.fs.path.join(alloc, &.{ id, versions_dir, version, "bin" });
    defer alloc.free(dir);
    try root.createDirPath(io, dir);

    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","version":"0.1.0","runtime":{{"entry":"bin/demo","mode":"oneshot"}},"contributes":{{"tools":[{{"name":"greet","input":{{}}}}],"skills":[]}},"permissions":{{}}}}
    , .{id});
    defer alloc.free(manifest_bytes);
    const manifest_sub = try std.fs.path.join(alloc, &.{ id, versions_dir, version, "extension.json" });
    defer alloc.free(manifest_sub);
    try root.writeFile(io, .{ .sub_path = manifest_sub, .data = manifest_bytes });

    const entry = try std.fmt.allocPrint(alloc, "bin{c}demo{s}", .{ std.fs.path.sep, exe_suffix });
    defer alloc.free(entry);
    const entry_sub = try std.fs.path.join(alloc, &.{ id, versions_dir, version, entry });
    defer alloc.free(entry_sub);
    try root.writeFile(io, .{ .sub_path = entry_sub, .data = "" });
}

fn freeVersions(alloc: std.mem.Allocator, versions: []const []u8) void {
    for (versions) |v| alloc.free(v);
    alloc.free(versions);
}

test "version id is deterministic and inputs-sensitive" {
    const alloc = std.testing.allocator;
    const base: Store.VersionInputs = .{ .source = "pub fn main() {}", .zig_version = "0.16.0", .target = "x86_64-windows", .manifest = "{}" };

    const a = try Store.versionId(alloc, base);
    defer alloc.free(a);
    const b = try Store.versionId(alloc, base);
    defer alloc.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.startsWith(u8, a, "v-"));

    var changed = base;
    changed.source = "pub fn main() void {}";
    const c = try Store.versionId(alloc, changed);
    defer alloc.free(c);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "activate and rollback move the current pointer atomically" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(std.testing.io, tmp.dir);

    const id = "demo";
    try writeBuiltVersion(alloc, std.testing.io, tmp.dir, id, "v-aaaa");
    try writeBuiltVersion(alloc, std.testing.io, tmp.dir, id, "v-bbbb");

    // No current pointer yet.
    try std.testing.expect((try store.activeVersion(alloc, id)) == null);

    try store.activate(alloc, id, "v-aaaa");
    {
        const active = (try store.activeVersion(alloc, id)).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings("v-aaaa", active);
    }

    try store.activate(alloc, id, "v-bbbb");
    {
        const active = (try store.activeVersion(alloc, id)).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings("v-bbbb", active);
    }

    // Rollback is just repointing current at the old version.
    try store.rollback(alloc, id, "v-aaaa");
    {
        const active = (try store.activeVersion(alloc, id)).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings("v-aaaa", active);
    }
}

test "activate refuses an unbuilt version" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(std.testing.io, tmp.dir);
    try writeBuiltVersion(alloc, std.testing.io, tmp.dir, "demo", "v-aaaa");
    try std.testing.expectError(error.VersionNotFound, store.activate(alloc, "demo", "v-nope"));
}

test "activate refuses an incomplete version directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(std.testing.io, tmp.dir);
    try store.ensureVersionDir(alloc, "demo", "v-empty");
    try std.testing.expectError(error.VersionNotFound, store.activate(alloc, "demo", "v-empty"));
}

test "activate accepts a runtime-less skill version" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(io, tmp.dir);

    try tmp.dir.createDirPath(io, "skills" ++ std.fs.path.sep_str ++ "versions" ++ std.fs.path.sep_str ++ "v-aaaa");
    try tmp.dir.writeFile(io, .{ .sub_path = "skills" ++ std.fs.path.sep_str ++ "versions" ++ std.fs.path.sep_str ++ "v-aaaa" ++ std.fs.path.sep_str ++ "extension.json", .data =
        \\{"schema":"nulya.extension/v2","id":"skills","version":"1","contributes":{"skills":["skills/demo"]}}
    });

    try store.activate(alloc, "skills", "v-aaaa");
    const active = (try store.activeVersion(alloc, "skills")).?;
    defer alloc.free(active);
    try std.testing.expectEqualStrings("v-aaaa", active);
}

test "listVersions returns every built version" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(std.testing.io, tmp.dir);

    try store.ensureVersionDir(alloc, "demo", "v-aaaa");
    try store.ensureVersionDir(alloc, "demo", "v-bbbb");

    const versions = try store.listVersions(alloc, "demo");
    defer freeVersions(alloc, versions);
    try std.testing.expectEqual(@as(usize, 2), versions.len);

    const none = try store.listVersions(alloc, "missing");
    defer freeVersions(alloc, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}
