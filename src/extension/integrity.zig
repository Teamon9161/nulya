//! Content-addressed extension identity and at-rest integrity helpers.
//!
//! The version id is still the content address of the frozen package snapshot,
//! compiler identity, and host target. `seal.json` records those reproducibility
//! inputs plus the built binary digest so activation and `ext run` can detect a
//! version directory that was modified after build.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("manifest.zig");

pub const version_prefix = "v-";
pub const manifest_file = "extension.json";
pub const package_dir = "package";
pub const seal_file = "seal.json";
pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

const max_snapshot_file_bytes: usize = 16 * 1024 * 1024;
const digest_bytes = 12;

pub const SnapshotFile = struct {
    rel: []u8,
    bytes: []u8,
};

pub const PackageSnapshot = struct {
    files: []SnapshotFile,

    pub fn deinit(self: PackageSnapshot, alloc: std.mem.Allocator) void {
        for (self.files) |file| {
            alloc.free(file.rel);
            alloc.free(file.bytes);
        }
        alloc.free(self.files);
    }

    pub fn canonicalBytes(self: PackageSnapshot, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "nulya-package-snapshot-v1\n");
        try appendU64(&out, alloc, self.files.len);
        for (self.files) |file| {
            try appendU64(&out, alloc, file.rel.len);
            try out.appendSlice(alloc, file.rel);
            try appendU64(&out, alloc, file.bytes.len);
            try out.appendSlice(alloc, file.bytes);
        }
        return out.toOwnedSlice(alloc);
    }
};

pub const Seal = struct {
    alloc: std.mem.Allocator,
    package_digest: []const u8,
    compiler: []const u8,
    target: []const u8,
    binary_digest: ?[]const u8,

    pub fn deinit(self: *Seal) void {
        self.alloc.free(self.package_digest);
        self.alloc.free(self.compiler);
        self.alloc.free(self.target);
        if (self.binary_digest) |digest| self.alloc.free(digest);
        self.* = undefined;
    }
};

pub fn isVersionId(s: []const u8) bool {
    if (s.len != version_prefix.len + digest_bytes * 2) return false;
    if (!std.mem.startsWith(u8, s, version_prefix)) return false;
    for (s[version_prefix.len..]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

pub fn versionId(alloc: std.mem.Allocator, snapshot_bytes: []const u8, compiler: []const u8, target: []const u8) ![]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (.{ snapshot_bytes, compiler, target }) |field| {
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

pub fn collectPackageSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    ext_dir_rel: []const u8,
    manifest_bytes: []const u8,
    m: manifest.Manifest,
) !PackageSnapshot {
    var files: std.ArrayList(SnapshotFile) = .empty;
    errdefer deinitFiles(alloc, files.items);

    try files.append(alloc, .{ .rel = try alloc.dupe(u8, manifest_file), .bytes = try alloc.dupe(u8, manifest_bytes) });

    if (m.runtime != null) {
        const src_dir = try std.fs.path.join(alloc, &.{ ext_dir_rel, "src" });
        defer alloc.free(src_dir);
        try collectTree(alloc, io, root, src_dir, "src", &files);
    }

    for (m.skills) |skill_path| {
        const skill_fs = try std.fs.path.join(alloc, &.{ ext_dir_rel, skill_path });
        defer alloc.free(skill_fs);
        const skill_rel = try canonicalRel(alloc, skill_path);
        defer alloc.free(skill_rel);
        try collectTree(alloc, io, root, skill_fs, skill_rel, &files);
    }

    for (m.system_prompts) |prompt_path| {
        const prompt_fs = try std.fs.path.join(alloc, &.{ ext_dir_rel, prompt_path });
        defer alloc.free(prompt_fs);
        const prompt_rel = try canonicalRel(alloc, prompt_path);
        defer alloc.free(prompt_rel);
        try collectFile(alloc, io, root, prompt_fs, prompt_rel, &files);
    }

    return finishSnapshot(alloc, &files);
}

pub fn collectFrozenSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    version_rel: []const u8,
    manifest_bytes: []const u8,
    m: manifest.Manifest,
) !PackageSnapshot {
    var files: std.ArrayList(SnapshotFile) = .empty;
    errdefer deinitFiles(alloc, files.items);

    try files.append(alloc, .{ .rel = try alloc.dupe(u8, manifest_file), .bytes = try alloc.dupe(u8, manifest_bytes) });

    if (m.runtime != null) {
        const src_dir = try std.fs.path.join(alloc, &.{ version_rel, package_dir, "src" });
        defer alloc.free(src_dir);
        try collectTree(alloc, io, root, src_dir, "src", &files);
    }

    for (m.skills) |skill_path| {
        const skill_fs = try std.fs.path.join(alloc, &.{ version_rel, package_dir, skill_path });
        defer alloc.free(skill_fs);
        const skill_rel = try canonicalRel(alloc, skill_path);
        defer alloc.free(skill_rel);
        try collectTree(alloc, io, root, skill_fs, skill_rel, &files);
    }

    for (m.system_prompts) |prompt_path| {
        const prompt_fs = try std.fs.path.join(alloc, &.{ version_rel, package_dir, prompt_path });
        defer alloc.free(prompt_fs);
        const prompt_rel = try canonicalRel(alloc, prompt_path);
        defer alloc.free(prompt_rel);
        try collectFile(alloc, io, root, prompt_fs, prompt_rel, &files);
    }

    return finishSnapshot(alloc, &files);
}

pub fn freezeSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    version_rel: []const u8,
    manifest_bytes: []const u8,
    snapshot: PackageSnapshot,
) !void {
    try root.createDirPath(io, version_rel);
    const manifest_dst = try std.fs.path.join(alloc, &.{ version_rel, manifest_file });
    defer alloc.free(manifest_dst);
    try root.writeFile(io, .{ .sub_path = manifest_dst, .data = manifest_bytes });

    for (snapshot.files) |file| {
        if (std.mem.eql(u8, file.rel, manifest_file)) continue;
        const dst = try std.fs.path.join(alloc, &.{ version_rel, package_dir, file.rel });
        defer alloc.free(dst);
        if (std.fs.path.dirname(dst)) |dir| try root.createDirPath(io, dir);
        try root.writeFile(io, .{ .sub_path = dst, .data = file.bytes });
    }
}

pub fn packageDigestHex(alloc: std.mem.Allocator, snapshot: PackageSnapshot) ![]u8 {
    const canonical = try snapshot.canonicalBytes(alloc);
    defer alloc.free(canonical);
    return digestHex(alloc, canonical);
}

pub fn fileDigestHex(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, sub_path: []const u8) ![]u8 {
    const bytes = root.readFileAlloc(io, sub_path, alloc, .limited(max_snapshot_file_bytes)) catch return error.VersionEntryNotFound;
    defer alloc.free(bytes);
    return digestHex(alloc, bytes);
}

pub fn sealJson(alloc: std.mem.Allocator, package_digest: []const u8, compiler: []const u8, target: []const u8, binary_digest: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("schema");
    try jw.write("nulya.extension.seal/v1");
    try jw.objectField("package_digest");
    try jw.write(package_digest);
    try jw.objectField("compiler");
    try jw.write(compiler);
    try jw.objectField("target");
    try jw.write(target);
    try jw.objectField("binary_digest");
    if (binary_digest) |digest| {
        try jw.write(digest);
    } else {
        try jw.write(null);
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

pub fn parseSeal(gpa: std.mem.Allocator, bytes: []const u8) !Seal {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidSeal;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidSeal,
    };
    const schema = stringField(obj, "schema") orelse return error.InvalidSeal;
    if (!std.mem.eql(u8, schema, "nulya.extension.seal/v1")) return error.InvalidSeal;

    const package_digest = try gpa.dupe(u8, stringField(obj, "package_digest") orelse return error.InvalidSeal);
    errdefer gpa.free(package_digest);
    const compiler = try gpa.dupe(u8, stringField(obj, "compiler") orelse return error.InvalidSeal);
    errdefer gpa.free(compiler);
    const target = try gpa.dupe(u8, stringField(obj, "target") orelse return error.InvalidSeal);
    errdefer gpa.free(target);
    const binary_digest = try optionalStringField(gpa, obj, "binary_digest");
    errdefer if (binary_digest) |digest| gpa.free(digest);

    return .{
        .alloc = gpa,
        .package_digest = package_digest,
        .compiler = compiler,
        .target = target,
        .binary_digest = binary_digest,
    };
}

/// Re-raise `error.Canceled` unchanged; fold every other error into `fallback`.
/// Lets integrity validation keep host cancellation distinct from corruption
/// while still reporting descriptive `Version*` errors for real faults.
inline fn cancelable(err: anytype, comptime fallback: anyerror) (error{Canceled} || @TypeOf(fallback)) {
    return if (err == error.Canceled) error.Canceled else fallback;
}

pub fn validateVersionDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    version_rel: []const u8,
    version: []const u8,
    expected_id: []const u8,
) !void {
    // Integrity checks map I/O failures to descriptive `Version*` errors, but a
    // cancellation is host execution control, not corruption — it must propagate
    // as `error.Canceled` so callers on cancellation-sensitive paths (note sync,
    // manifest reads) can record a canceled step instead of a spurious integrity
    // failure. `cancelable` re-raises it and folds everything else into `fallback`.
    root.access(io, version_rel, .{}) catch |err| return cancelable(err, error.VersionNotFound);

    const seal_sub = try std.fs.path.join(alloc, &.{ version_rel, seal_file });
    defer alloc.free(seal_sub);
    const seal_bytes = root.readFileAlloc(io, seal_sub, alloc, .limited(1 << 20)) catch |err| return cancelable(err, error.VersionSealInvalid);
    defer alloc.free(seal_bytes);
    var seal = parseSeal(alloc, seal_bytes) catch return error.VersionSealInvalid;
    defer seal.deinit();

    const manifest_sub = try std.fs.path.join(alloc, &.{ version_rel, manifest_file });
    defer alloc.free(manifest_sub);
    const manifest_bytes = root.readFileAlloc(io, manifest_sub, alloc, .limited(1 << 20)) catch |err| return cancelable(err, error.VersionNotFound);
    defer alloc.free(manifest_bytes);

    var m = try manifest.parse(alloc, manifest_bytes);
    defer m.deinit();
    try m.validate();
    if (!std.mem.eql(u8, m.id, expected_id)) return error.VersionManifestIdMismatch;

    const snapshot = collectFrozenSnapshot(alloc, io, root, version_rel, manifest_bytes, m) catch |err| return cancelable(err, error.VersionPackageMissing);
    defer snapshot.deinit(alloc);
    const canonical = try snapshot.canonicalBytes(alloc);
    defer alloc.free(canonical);

    const package_digest = try digestHex(alloc, canonical);
    defer alloc.free(package_digest);
    if (!std.mem.eql(u8, package_digest, seal.package_digest)) return error.VersionSealInvalid;

    const expected_version = try versionId(alloc, canonical, seal.compiler, seal.target);
    defer alloc.free(expected_version);
    if (!std.mem.eql(u8, version, expected_version)) return error.VersionSealInvalid;

    if (m.runtime) |rt| {
        const entry = try std.fmt.allocPrint(alloc, "{s}{s}", .{ rt.entry, exe_suffix });
        defer alloc.free(entry);
        const entry_sub = try std.fs.path.join(alloc, &.{ version_rel, entry });
        defer alloc.free(entry_sub);
        const binary_digest = try fileDigestHex(alloc, io, root, entry_sub);
        defer alloc.free(binary_digest);
        const sealed_binary = seal.binary_digest orelse return error.VersionSealInvalid;
        if (!std.mem.eql(u8, binary_digest, sealed_binary)) return error.VersionSealInvalid;
    } else if (seal.binary_digest != null) {
        return error.VersionSealInvalid;
    }
}

test "validates version id shape" {
    try std.testing.expect(isVersionId("v-0123456789abcdefabcdef01"));
    try std.testing.expect(!isVersionId("v-0123456789abcdefabcdef0"));
    try std.testing.expect(!isVersionId("v-0123456789abcdefabcdef0g"));
    try std.testing.expect(!isVersionId("v-0123456789ABCDEFABCDEF01"));
}

fn finishSnapshot(alloc: std.mem.Allocator, files: *std.ArrayList(SnapshotFile)) !PackageSnapshot {
    std.mem.sort(SnapshotFile, files.items, {}, lessFileRel);
    for (files.items[1..], 1..) |file, i| {
        if (std.mem.eql(u8, files.items[i - 1].rel, file.rel)) return error.DuplicateSnapshotPath;
    }
    return .{ .files = try files.toOwnedSlice(alloc) };
}

fn collectFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    fs_file_rel: []const u8,
    snapshot_file_rel: []const u8,
    files: *std.ArrayList(SnapshotFile),
) !void {
    const bytes = root.readFileAlloc(io, fs_file_rel, alloc, .limited(max_snapshot_file_bytes)) catch return error.SourceUnreadable;
    errdefer alloc.free(bytes);
    try files.append(alloc, .{ .rel = try alloc.dupe(u8, snapshot_file_rel), .bytes = bytes });
}

fn collectTree(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    fs_dir_rel: []const u8,
    snapshot_dir_rel: []const u8,
    files: *std.ArrayList(SnapshotFile),
) !void {
    var dir = root.openDir(io, fs_dir_rel, .{ .iterate = true }) catch return error.SourceUnreadable;
    defer dir.close(io);

    var saw_any = false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child_fs = try std.fs.path.join(alloc, &.{ fs_dir_rel, entry.name });
        defer alloc.free(child_fs);
        const child_snapshot = try joinCanonical(alloc, snapshot_dir_rel, entry.name);
        defer alloc.free(child_snapshot);

        switch (entry.kind) {
            .file => {
                const bytes = root.readFileAlloc(io, child_fs, alloc, .limited(max_snapshot_file_bytes)) catch return error.SourceUnreadable;
                errdefer alloc.free(bytes);
                try files.append(alloc, .{ .rel = try alloc.dupe(u8, child_snapshot), .bytes = bytes });
                saw_any = true;
            },
            .directory => {
                try collectTree(alloc, io, root, child_fs, child_snapshot, files);
                saw_any = true;
            },
            else => {},
        }
    }
    if (!saw_any) return error.SourceUnreadable;
}

fn deinitFiles(alloc: std.mem.Allocator, files: []SnapshotFile) void {
    for (files) |file| {
        alloc.free(file.rel);
        alloc.free(file.bytes);
    }
}

pub fn lessFileRel(_: void, a: SnapshotFile, b: SnapshotFile) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

/// The frozen bytes of `rel` inside a collected snapshot, or null. `rel` must be
/// in canonical (forward-slash) form — see `canonicalRel`.
pub fn findSnapshotFile(snapshot: PackageSnapshot, rel: []const u8) ?[]const u8 {
    for (snapshot.files) |file| {
        if (std.mem.eql(u8, file.rel, rel)) return file.bytes;
    }
    return null;
}

fn appendU64(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: usize) !void {
    var len_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_le, value, .little);
    try out.appendSlice(alloc, &len_le);
}

/// Normalize a relative path to canonical form: forward-slash separators, no
/// empty segments. The shared spelling used for snapshot file keys.
pub fn canonicalRel(alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitAny(u8, rel, "/\\");
    var first = true;
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (!first) try out.append(alloc, '/');
        try out.appendSlice(alloc, part);
        first = false;
    }
    return out.toOwnedSlice(alloc);
}

pub fn joinCanonical(alloc: std.mem.Allocator, parent: []const u8, child: []const u8) ![]u8 {
    const child_norm = try canonicalRel(alloc, child);
    defer alloc.free(child_norm);
    if (parent.len == 0) return try alloc.dupe(u8, child_norm);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ parent, child_norm });
}

fn digestHex(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(bytes);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const out = try alloc.alloc(u8, digest.len * 2);
    _ = std.fmt.bufPrint(out, "{x}", .{digest[0..]}) catch unreachable;
    return out;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn optionalStringField(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| try a.dupe(u8, s),
        .null => null,
        else => error.InvalidSeal,
    };
}
