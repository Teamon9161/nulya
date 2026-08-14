//! `nulya ext build` — compile an extension into an immutable version (DESIGN
//! §7.4, §10).
//!
//! The AI never runs `zig build` itself. This module fixes every knob (zig
//! identity, optimize, target, output location) so a given package snapshot maps
//! to the same content-addressed version id and the build is reproducible.
//!
//! The Zig executable is injected rather than resolved here: production wires in
//! `toolchain.ensureExtracted` (the embedded toolchain), while tests can wire in
//! the host's own zig — so the whole close-the-loop path is testable without the
//! ~90MB embed.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("manifest.zig");
const store = @import("store.zig");
const toolchain = @import("../toolchain.zig");

/// Executable suffix on the host. Extensions are built for and run on the same
/// host nulya runs on, so build and run agree on this.
pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

const manifest_file = "extension.json";
const package_dir = "package";
const source_rel_canonical = "src/main.zig";
const max_snapshot_file_bytes: usize = 16 * 1024 * 1024;

pub const BuildResult = struct {
    /// Content-addressed immutable version id (`v-<hash>`).
    version: []u8,
    /// Built binary path, relative to the version directory (e.g. `bin/demo.exe`).
    /// Pure contribution packages without runtime do not have one.
    entry_rel: ?[]u8,
    /// True when this exact version already existed — an immutable, reproducible
    /// no-op (DESIGN §7.4).
    already_built: bool,
    /// False when the compiler rejected the source; `stderr` then holds the
    /// diagnostics for the model to correct against (DESIGN §6.2 spirit).
    compile_ok: bool,
    stderr: []u8,

    pub fn deinit(self: BuildResult, alloc: std.mem.Allocator) void {
        alloc.free(self.version);
        if (self.entry_rel) |entry_rel| alloc.free(entry_rel);
        alloc.free(self.stderr);
    }
};

const SnapshotFile = struct {
    rel: []u8,
    bytes: []u8,
};

const PackageSnapshot = struct {
    files: []SnapshotFile,

    fn deinit(self: PackageSnapshot, alloc: std.mem.Allocator) void {
        for (self.files) |file| {
            alloc.free(file.rel);
            alloc.free(file.bytes);
        }
        alloc.free(self.files);
    }

    fn canonicalBytes(self: PackageSnapshot, alloc: std.mem.Allocator) ![]u8 {
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

/// Build `ext_dir_rel` (relative to `workspace`) with `zig_exe`. Stops at the
/// "built" state — activation is a separate, explicit step (DESIGN §7.4). The
/// error set is inferred: it folds manifest/source unreadability, manifest
/// parse/validate errors, compiler identity errors, and filesystem errors from
/// the version-directory writes.
pub fn buildExtension(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    zig_exe: []const u8,
) !BuildResult {
    const manifest_rel = try std.fs.path.join(alloc, &.{ ext_dir_rel, manifest_file });
    defer alloc.free(manifest_rel);
    const manifest_bytes = workspace.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20)) catch
        return error.ManifestUnreadable;
    defer alloc.free(manifest_bytes);

    var m = try manifest.parse(alloc, manifest_bytes);
    defer m.deinit();
    try m.validate();

    const snapshot = try collectPackageSnapshot(alloc, io, workspace, ext_dir_rel, manifest_bytes, m);
    defer snapshot.deinit(alloc);
    const snapshot_bytes = try snapshot.canonicalBytes(alloc);
    defer alloc.free(snapshot_bytes);

    const compiler = try compilerIdentity(alloc, io, workspace, zig_exe);
    defer alloc.free(compiler);

    const version = try store.Store.versionId(alloc, .{
        .snapshot = snapshot_bytes,
        .compiler = compiler,
        .target = toolchain.host_target,
    });
    errdefer alloc.free(version);

    const version_rel = try std.fs.path.join(alloc, &.{ ext_dir_rel, "versions", version });
    defer alloc.free(version_rel);

    const manifest_dst = try std.fs.path.join(alloc, &.{ version_rel, manifest_file });
    defer alloc.free(manifest_dst);

    const entry_rel: ?[]u8 = if (m.runtime) |rt|
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ rt.entry, exe_suffix })
    else
        null;
    errdefer if (entry_rel) |entry| alloc.free(entry);

    const has_manifest = if (workspace.access(io, manifest_dst, .{})) |_| true else |_| false;
    const has_package = snapshotIsFrozen(alloc, io, workspace, version_rel, snapshot);
    const has_bin = if (entry_rel) |entry| blk: {
        const bin_rel = try std.fs.path.join(alloc, &.{ version_rel, entry });
        defer alloc.free(bin_rel);
        break :blk if (workspace.access(io, bin_rel, .{})) |_| true else |_| false;
    } else true;

    if (has_manifest and has_package and has_bin) {
        return .{ .version = version, .entry_rel = entry_rel, .already_built = true, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
    }
    if (has_manifest or has_package or !has_bin) workspace.deleteTree(io, version_rel) catch {};

    if (m.runtime == null) {
        try freezeSnapshot(alloc, io, workspace, version_rel, manifest_bytes, snapshot);
        return .{ .version = version, .entry_rel = null, .already_built = false, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
    }

    const rt = m.runtime.?;
    const entry = entry_rel.?;
    const bin_rel = try std.fs.path.join(alloc, &.{ version_rel, entry });
    defer alloc.free(bin_rel);
    const bin_dir_rel = std.fs.path.dirname(bin_rel) orelse version_rel;

    try freezeSnapshot(alloc, io, workspace, version_rel, manifest_bytes, snapshot);
    try workspace.createDirPath(io, bin_dir_rel);

    const frozen_source = try std.fs.path.join(alloc, &.{ version_rel, package_dir, "src", "main.zig" });
    defer alloc.free(frozen_source);
    const emit_arg = try std.fmt.allocPrint(alloc, "-femit-bin={s}", .{bin_rel});
    defer alloc.free(emit_arg);

    // Fixed, reproducible invocation — the AI gets no say in the flags. Compile
    // from the frozen package, never the mutable draft tree.
    const result = std.process.run(alloc, io, .{
        .argv = &.{ zig_exe, "build-exe", frozen_source, "-O", "ReleaseSafe", emit_arg, "--name", std.fs.path.stem(rt.entry) },
        .cwd = .{ .dir = workspace },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        workspace.deleteTree(io, version_rel) catch {};
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SourceUnreadable, // spawn/compile plumbing failure
        };
    };
    defer alloc.free(result.stdout);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };
    if (exit_code != 0) {
        // Leave no half-built version behind.
        workspace.deleteTree(io, version_rel) catch {};
        return .{ .version = version, .entry_rel = entry_rel, .already_built = false, .compile_ok = false, .stderr = result.stderr };
    }
    alloc.free(result.stderr);

    return .{ .version = version, .entry_rel = entry_rel, .already_built = false, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
}

fn appendU64(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: usize) !void {
    var len_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_le, value, .little);
    try out.appendSlice(alloc, &len_le);
}

fn compilerIdentity(alloc: std.mem.Allocator, io: std.Io, workspace: std.Io.Dir, zig_exe: []const u8) ![]u8 {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ zig_exe, "version" },
        .cwd = .{ .dir = workspace },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.ZigVersionUnreadable;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return error.ZigVersionUnreadable,
    };
    if (exit_code != 0) return error.ZigVersionUnreadable;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.ZigVersionUnreadable;
    return try std.fmt.allocPrint(alloc, "zig {s}", .{trimmed});
}

fn collectPackageSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
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
        try collectTree(alloc, io, workspace, src_dir, "src", &files);
    }

    for (m.skills) |skill_path| {
        const skill_fs = try std.fs.path.join(alloc, &.{ ext_dir_rel, skill_path });
        defer alloc.free(skill_fs);
        const skill_rel = try canonicalRel(alloc, skill_path);
        defer alloc.free(skill_rel);
        try collectTree(alloc, io, workspace, skill_fs, skill_rel, &files);
    }

    std.mem.sort(SnapshotFile, files.items, {}, lessFileRel);
    for (files.items[1..], 1..) |file, i| {
        if (std.mem.eql(u8, files.items[i - 1].rel, file.rel)) return error.DuplicateSnapshotPath;
    }
    return .{ .files = try files.toOwnedSlice(alloc) };
}

fn deinitFiles(alloc: std.mem.Allocator, files: []SnapshotFile) void {
    for (files) |file| {
        alloc.free(file.rel);
        alloc.free(file.bytes);
    }
}

fn lessFileRel(_: void, a: SnapshotFile, b: SnapshotFile) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

fn collectTree(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    fs_dir_rel: []const u8,
    snapshot_dir_rel: []const u8,
    files: *std.ArrayList(SnapshotFile),
) !void {
    var dir = workspace.openDir(io, fs_dir_rel, .{ .iterate = true }) catch return error.SourceUnreadable;
    defer dir.close(io);

    var saw_any = false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "versions") or
            std.mem.eql(u8, entry.name, ".zig-cache") or
            std.mem.eql(u8, entry.name, "tests"))
        {
            if (entry.kind == .directory) continue;
        }

        const child_fs = try std.fs.path.join(alloc, &.{ fs_dir_rel, entry.name });
        defer alloc.free(child_fs);
        const child_snapshot = try joinCanonical(alloc, snapshot_dir_rel, entry.name);
        defer alloc.free(child_snapshot);

        switch (entry.kind) {
            .file => {
                const bytes = workspace.readFileAlloc(io, child_fs, alloc, .limited(max_snapshot_file_bytes)) catch return error.SourceUnreadable;
                errdefer alloc.free(bytes);
                try files.append(alloc, .{ .rel = try alloc.dupe(u8, child_snapshot), .bytes = bytes });
                saw_any = true;
            },
            .directory => {
                try collectTree(alloc, io, workspace, child_fs, child_snapshot, files);
                saw_any = true;
            },
            else => {},
        }
    }
    if (!saw_any) return error.SourceUnreadable;
}

fn canonicalRel(alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
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

fn joinCanonical(alloc: std.mem.Allocator, parent: []const u8, child: []const u8) ![]u8 {
    const child_norm = try canonicalRel(alloc, child);
    defer alloc.free(child_norm);
    if (parent.len == 0) return try alloc.dupe(u8, child_norm);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ parent, child_norm });
}

fn snapshotIsFrozen(alloc: std.mem.Allocator, io: std.Io, workspace: std.Io.Dir, version_rel: []const u8, snapshot: PackageSnapshot) bool {
    for (snapshot.files) |file| {
        if (std.mem.eql(u8, file.rel, manifest_file)) continue;
        const sub = std.fs.path.join(alloc, &.{ version_rel, package_dir, file.rel }) catch return false;
        defer alloc.free(sub);
        const frozen = workspace.readFileAlloc(io, sub, alloc, .limited(max_snapshot_file_bytes)) catch return false;
        defer alloc.free(frozen);
        if (!std.mem.eql(u8, frozen, file.bytes)) return false;
    }
    return true;
}

fn freezeSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    version_rel: []const u8,
    manifest_bytes: []const u8,
    snapshot: PackageSnapshot,
) !void {
    try workspace.createDirPath(io, version_rel);
    const manifest_dst = try std.fs.path.join(alloc, &.{ version_rel, manifest_file });
    defer alloc.free(manifest_dst);
    try workspace.writeFile(io, .{ .sub_path = manifest_dst, .data = manifest_bytes });

    for (snapshot.files) |file| {
        if (std.mem.eql(u8, file.rel, manifest_file)) continue;
        const dst = try std.fs.path.join(alloc, &.{ version_rel, package_dir, file.rel });
        defer alloc.free(dst);
        if (std.fs.path.dirname(dst)) |dir| try workspace.createDirPath(io, dir);
        try workspace.writeFile(io, .{ .sub_path = dst, .data = file.bytes });
    }
}

fn testZigExe(alloc: std.mem.Allocator) ![]u8 {
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();
    if (host.get("NULYA_TEST_ZIG")) |zig_exe| if (zig_exe.len != 0) return try alloc.dupe(u8, zig_exe);
    return try alloc.dupe(u8, "zig");
}

test "missing manifest is a clear error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "ext");
    try std.testing.expectError(
        error.ManifestUnreadable,
        buildExtension(alloc, std.testing.io, tmp.dir, "ext", "zig"),
    );
}

test "pure skill package freezes its declared skill directory" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "risk-parity");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"skills.finance","version":"1","contributes":{"skills":["skills/risk-parity"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "risk-parity" ++ std.fs.path.sep_str ++ "SKILL.md", .data = "---\nname: risk-parity\ndescription: demo\n---\nbody\n" });

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var result = try buildExtension(alloc, io, tmp.dir, "ext", zig_exe);
    defer result.deinit(alloc);
    try std.testing.expect(result.compile_ok);
    try std.testing.expect(result.entry_rel == null);
    const skill_path = try std.fs.path.join(alloc, &.{ "ext", "versions", result.version, package_dir, "skills", "risk-parity", "SKILL.md" });
    defer alloc.free(skill_path);
    try tmp.dir.access(io, skill_path, .{});
}

test "runtime helper source changes the version id" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"demo","version":"1","runtime":{"entry":"bin/demo","mode":"oneshot"},"contributes":{"tools":[{"name":"greet","input":{}}]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "main.zig", .data = "const helper = @import(\"helper.zig\"); pub fn main() void { _ = helper.value; }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "helper.zig", .data = "pub const value = 1;\n" });

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", zig_exe);
    defer first.deinit(alloc);
    if (!first.compile_ok) return error.ExtensionBuildFailed;

    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "helper.zig", .data = "pub const value = 2;\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", zig_exe);
    defer second.deinit(alloc);
    if (!second.compile_ok) return error.ExtensionBuildFailed;

    try std.testing.expect(!std.mem.eql(u8, first.version, second.version));
}

test "skill body changes the version id" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"skills","version":"1","contributes":{"skills":["skills/demo"]}}
    });
    const skill_rel = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo" ++ std.fs.path.sep_str ++ "SKILL.md";
    try tmp.dir.writeFile(io, .{ .sub_path = skill_rel, .data = "version one\n" });

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", zig_exe);
    defer first.deinit(alloc);

    try tmp.dir.writeFile(io, .{ .sub_path = skill_rel, .data = "version two\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", zig_exe);
    defer second.deinit(alloc);

    try std.testing.expect(!std.mem.eql(u8, first.version, second.version));
}
