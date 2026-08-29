//! Content-addressed extension identity and at-rest integrity helpers.
//!
//! The version id is the content address of the frozen package snapshot plus,
//! for a COMPILED extension only, the compiler identity and host target (a data
//! or script version records both as ""; see `manifest.ImplementationKind`).
//! `seal.json` records those reproducibility inputs plus the built binary digest
//! so activation and `ext run` can detect a version directory that was modified
//! after build.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("manifest.zig");
const target_mod = @import("target.zig");

pub const version_prefix = "v-";
pub const manifest_file = "extension.json";
pub const package_dir = "package";
pub const seal_file = "seal.json";
/// The suffix a version built FOR THIS HOST carries. Derived from the same one
/// function a seal's target goes through (`target.exeSuffixFor`), so the host
/// case is not a second rule — it is the general rule asked about this machine.
/// Callers that are about to run something here want this one; validation wants
/// the seal's (see `openVersion`).
pub const exe_suffix = target_mod.exeSuffixFor(target_mod.host);

const max_snapshot_file_bytes: usize = 16 * 1024 * 1024;
const digest_bytes = 12;
/// How much of a file `fileDigestHex` holds at once. Only a hashing buffer —
/// it bounds memory, never the file.
const digest_read_chunk_bytes: usize = 64 * 1024;

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

/// How thoroughly a frozen version directory is checked (DESIGN §7.4). Two
/// questions, not one: "is this directory a complete extension version?" and
/// "are these still the bytes that were sealed?". They used to be answered
/// together, which made every read-only listing pay a full-tree sha256 of
/// megabytes of built binary.
pub const Level = enum {
    /// Structure only: the directory is there, its `seal.json` parses, its
    /// manifest parses, validates and names this id, and every path the manifest
    /// declares — the frozen `src/` tree, each skill directory, each system
    /// prompt, a compiled entry binary — exists. Nothing is digested, so the
    /// cost is a handful of stats plus two small file reads and does not grow
    /// with the package. What a READ-ONLY projection needs: it must not invent
    /// an extension that is not there, and it is not about to run any of it.
    structural,
    /// Structural, plus the at-rest content re-digest: the frozen package must
    /// hash to the seal's `package_digest`, that digest must reproduce this very
    /// version id, and a compiled binary must hash to the sealed one. What every
    /// path that is about to RUN these bytes or FREEZE them into a session
    /// needs — session composition, `ext run`, activation, a copied version.
    sealed,
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
    errdefer deinitPartialSnapshot(alloc, &files);

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

    for (m.system_prompts) |p| {
        const prompt_fs = try std.fs.path.join(alloc, &.{ ext_dir_rel, p.path });
        defer alloc.free(prompt_fs);
        const prompt_rel = try canonicalRel(alloc, p.path);
        defer alloc.free(prompt_rel);
        try collectFile(alloc, io, root, prompt_fs, prompt_rel, &files);
    }

    for (m.ui) |u| {
        const ui_fs = try std.fs.path.join(alloc, &.{ ext_dir_rel, u.entry });
        defer alloc.free(ui_fs);
        const ui_rel = try canonicalRel(alloc, u.entry);
        defer alloc.free(ui_rel);
        try collectFile(alloc, io, root, ui_fs, ui_rel, &files);
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
    errdefer deinitPartialSnapshot(alloc, &files);

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

    for (m.system_prompts) |p| {
        const prompt_fs = try std.fs.path.join(alloc, &.{ version_rel, package_dir, p.path });
        defer alloc.free(prompt_fs);
        const prompt_rel = try canonicalRel(alloc, p.path);
        defer alloc.free(prompt_rel);
        try collectFile(alloc, io, root, prompt_fs, prompt_rel, &files);
    }

    for (m.ui) |u| {
        const ui_fs = try std.fs.path.join(alloc, &.{ version_rel, package_dir, u.entry });
        defer alloc.free(ui_fs);
        const ui_rel = try canonicalRel(alloc, u.entry);
        defer alloc.free(ui_rel);
        try collectFile(alloc, io, root, ui_fs, ui_rel, &files);
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

/// Digest a file on disk, hashed as it is read rather than after it is held.
///
/// This used to read the whole file under `max_snapshot_file_bytes`, which put
/// the COMPILER'S OUTPUT under a cap meant for one source file inside a package
/// snapshot — a ceiling nobody chose for a binary, and one that announced
/// itself as `VersionEntryNotFound`: what a person read was "that version has no
/// entry", what had happened was "the entry is 18 MB". Nothing on this path
/// wants the bytes, only their digest, so there is no size left to cap.
///
/// A file that will not open stays `VersionEntryNotFound` — that IS the entry
/// missing, and `store.isExtensionFault` reads it as a broken extension. A read
/// that fails after the file opened is a host fault and travels as itself.
pub fn fileDigestHex(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, sub_path: []const u8) ![]u8 {
    var file = root.openFile(io, sub_path, .{}) catch return error.VersionEntryNotFound;
    defer file.close(io);

    const buf = try alloc.alloc(u8, digest_read_chunk_bytes);
    defer alloc.free(buf);

    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, buf, offset);
        h.update(buf[0..n]);
        offset += n;
        if (n < buf.len) break; // short read is end of file
    }
    return finishHex(alloc, &h);
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
    level: Level,
) !void {
    var m = try openVersion(alloc, io, root, version_rel, version, expected_id, level);
    m.deinit();
}

/// `validateVersionDir` that hands back what it already parsed. Reading and
/// validating the frozen manifest IS part of validation at either level, so the
/// caller that also wants the manifest (`Store.readManifest`, and through it
/// every `Roots.Resolved`) gets it from here instead of reading and parsing the
/// same file a second time. Caller owns the result.
pub fn openVersion(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    version_rel: []const u8,
    version: []const u8,
    expected_id: []const u8,
    level: Level,
) !manifest.Manifest {
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
    errdefer m.deinit();
    try m.validate();
    if (!std.mem.eql(u8, m.id, expected_id)) return error.VersionManifestIdMismatch;

    switch (level) {
        .structural => try requireDeclaredPaths(alloc, io, root, version_rel, m),
        .sealed => {
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
        },
    }

    if (m.runtime) |rt| {
        if (manifest.isScript(rt)) {
            // A script extension is frozen into `package/` and covered by the
            // package digest; it has no separately-built binary, so the seal must
            // record none. Cheap either way — a shape check on the seal.
            if (seal.binary_digest != null) return error.VersionSealInvalid;
        } else {
            // A compiled entry is never per-OS (`manifest.validate` refuses the
            // object form for `bin/` paths), so the host always has one.
            //
            // The SUFFIX comes off the seal, not off this machine: a version
            // cross-built for another target (`ext build --target`, DESIGN §7.4)
            // is validated here — on the host that produced it, and again on the
            // machine it was pushed to — and asking `builtin` would send both of
            // them looking for a file named for the wrong platform.
            const compiled_entry = rt.entry.forHost() orelse return error.VersionEntryNotFound;
            const entry = try std.fmt.allocPrint(alloc, "{s}{s}", .{ compiled_entry, target_mod.exeSuffixFor(seal.target) });
            defer alloc.free(entry);
            const entry_sub = try std.fs.path.join(alloc, &.{ version_rel, entry });
            defer alloc.free(entry_sub);
            switch (level) {
                // The built binary is the one file whose size is unbounded, so
                // it is exactly where the two levels part: is it there, versus
                // is it byte for byte the one that was sealed.
                .structural => {
                    root.access(io, entry_sub, .{}) catch |err| return cancelable(err, error.VersionEntryNotFound);
                    if (seal.binary_digest == null) return error.VersionSealInvalid;
                },
                .sealed => {
                    const binary_digest = try fileDigestHex(alloc, io, root, entry_sub);
                    defer alloc.free(binary_digest);
                    const sealed_binary = seal.binary_digest orelse return error.VersionSealInvalid;
                    if (!std.mem.eql(u8, binary_digest, sealed_binary)) return error.VersionSealInvalid;
                },
            }
        }
    } else if (seal.binary_digest != null) {
        return error.VersionSealInvalid;
    }
    return m;
}

/// Every path the frozen manifest declares is present — the existence half of
/// what `Level.sealed` proves by digesting. `access` only: the frozen `src/`
/// tree, each declared skill directory, each declared system prompt file. It
/// answers "this version directory is complete", never "these are the sealed
/// bytes", and its cost does not grow with the package.
fn requireDeclaredPaths(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    version_rel: []const u8,
    m: manifest.Manifest,
) !void {
    if (m.runtime != null) try requirePackagePath(alloc, io, root, version_rel, "src");
    for (m.skills) |skill_path| try requirePackagePath(alloc, io, root, version_rel, skill_path);
    for (m.system_prompts) |p| try requirePackagePath(alloc, io, root, version_rel, p.path);
    for (m.ui) |u| try requirePackagePath(alloc, io, root, version_rel, u.entry);
}

fn requirePackagePath(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    version_rel: []const u8,
    rel: []const u8,
) !void {
    const sub = try std.fs.path.join(alloc, &.{ version_rel, package_dir, rel });
    defer alloc.free(sub);
    root.access(io, sub, .{}) catch |err| return cancelable(err, error.VersionPackageMissing);
}

test "a built binary is digested at any size, and streaming does not change the digest" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Past the snapshot's per-source-file cap, and not a whole number of read
    // chunks: the size a compiled extension actually reaches is what used to
    // fail here, and the last partial chunk is what ends the read loop.
    const size = max_snapshot_file_bytes + digest_read_chunk_bytes + 7;
    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    for (bytes, 0..) |*b, i| b.* = @truncate(i *% 31);
    try tmp.dir.writeFile(io, .{ .sub_path = "bin", .data = bytes });

    const streamed = try fileDigestHex(alloc, io, tmp.dir, "bin");
    defer alloc.free(streamed);
    const one_shot = try digestHex(alloc, bytes);
    defer alloc.free(one_shot);
    try std.testing.expectEqualStrings(one_shot, streamed);

    // An entry that is not there is still the extension fault it always was.
    try std.testing.expectError(error.VersionEntryNotFound, fileDigestHex(alloc, io, tmp.dir, "absent"));
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

/// Free a snapshot that was never finished: the strings each entry owns AND the
/// list holding them.
///
/// On the success path `finishSnapshot` hands the buffer on with
/// `toOwnedSlice`, so nothing here runs. Every path that REFUSES arrives here
/// instead — a declared file that will not read, a duplicate path — and freeing
/// only the entries left the list itself behind. That leak was reachable only
/// by a build that had already decided to refuse, so what it corrupted was the
/// refusal: the allocator's report printed its stack traces underneath the
/// sentence the author is supposed to read.
fn deinitPartialSnapshot(alloc: std.mem.Allocator, files: *std.ArrayList(SnapshotFile)) void {
    for (files.items) |file| {
        alloc.free(file.rel);
        alloc.free(file.bytes);
    }
    files.deinit(alloc);
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
    return finishHex(alloc, &h);
}

/// The hex of a finished hash. Shared so the one-shot and the streamed path
/// cannot drift into two different spellings of the same digest.
fn finishHex(alloc: std.mem.Allocator, h: *std.crypto.hash.sha2.Sha256) ![]u8 {
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
