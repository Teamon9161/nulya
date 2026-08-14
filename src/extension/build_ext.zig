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
const manifest = @import("manifest.zig");
const integrity = @import("integrity.zig");
const toolchain = @import("../toolchain.zig");

pub const exe_suffix = integrity.exe_suffix;
const manifest_file = integrity.manifest_file;
const package_dir = integrity.package_dir;
const seal_file = integrity.seal_file;

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

    const snapshot = try integrity.collectPackageSnapshot(alloc, io, workspace, ext_dir_rel, manifest_bytes, m);
    defer snapshot.deinit(alloc);
    const snapshot_bytes = try snapshot.canonicalBytes(alloc);
    defer alloc.free(snapshot_bytes);

    const compiler = try compilerIdentity(alloc, io, workspace, zig_exe);
    defer alloc.free(compiler);

    const version = try integrity.versionId(alloc, snapshot_bytes, compiler, toolchain.host_target);
    errdefer alloc.free(version);

    const version_rel = try std.fs.path.join(alloc, &.{ ext_dir_rel, "versions", version });
    defer alloc.free(version_rel);

    const entry_rel: ?[]u8 = if (m.runtime) |rt|
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ rt.entry, exe_suffix })
    else
        null;
    errdefer if (entry_rel) |entry| alloc.free(entry);

    const version_is_valid = if (workspace.access(io, version_rel, .{})) |_| blk: {
        integrity.validateVersionDir(alloc, io, workspace, version_rel, version, m.id) catch break :blk false;
        break :blk true;
    } else |_| false;

    if (version_is_valid) {
        return .{ .version = version, .entry_rel = entry_rel, .already_built = true, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
    }
    workspace.deleteTree(io, version_rel) catch {};

    if (m.runtime == null) {
        try integrity.freezeSnapshot(alloc, io, workspace, version_rel, manifest_bytes, snapshot);
        try writeSeal(alloc, io, workspace, version_rel, snapshot, compiler, toolchain.host_target, null);
        return .{ .version = version, .entry_rel = null, .already_built = false, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
    }

    const rt = m.runtime.?;
    const entry = entry_rel.?;
    const bin_rel = try std.fs.path.join(alloc, &.{ version_rel, entry });
    defer alloc.free(bin_rel);
    const bin_dir_rel = std.fs.path.dirname(bin_rel) orelse version_rel;

    try integrity.freezeSnapshot(alloc, io, workspace, version_rel, manifest_bytes, snapshot);
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

    const binary_digest = try integrity.fileDigestHex(alloc, io, workspace, bin_rel);
    defer alloc.free(binary_digest);
    try writeSeal(alloc, io, workspace, version_rel, snapshot, compiler, toolchain.host_target, binary_digest);

    return .{ .version = version, .entry_rel = entry_rel, .already_built = false, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
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

fn writeSeal(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    version_rel: []const u8,
    snapshot: integrity.PackageSnapshot,
    compiler: []const u8,
    target: []const u8,
    binary_digest: ?[]const u8,
) !void {
    const package_digest = try integrity.packageDigestHex(alloc, snapshot);
    defer alloc.free(package_digest);
    const seal = try integrity.sealJson(alloc, package_digest, compiler, target, binary_digest);
    defer alloc.free(seal);
    const seal_sub = try std.fs.path.join(alloc, &.{ version_rel, seal_file });
    defer alloc.free(seal_sub);
    try workspace.writeFile(io, .{ .sub_path = seal_sub, .data = seal });
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
        \\{"schema":"nulya.extension/v2","id":"skills.finance","contributes":{"skills":["skills/risk-parity"]}}
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
        \\{"schema":"nulya.extension/v2","id":"demo","runtime":{"entry":"bin/demo"},"contributes":{"tools":[{"name":"greet","input":{}}]}}
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
        \\{"schema":"nulya.extension/v2","id":"skills","contributes":{"skills":["skills/demo"]}}
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


test "source tests directory participates in the version id" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "tests");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"demo","runtime":{"entry":"bin/demo"},"contributes":{"tools":[{"name":"greet","input":{}}]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "main.zig", .data = "pub fn main() void {}\n" });
    const test_rel = "ext" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "tests" ++ std.fs.path.sep_str ++ "case.txt";
    try tmp.dir.writeFile(io, .{ .sub_path = test_rel, .data = "one\n" });

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", zig_exe);
    defer first.deinit(alloc);
    if (!first.compile_ok) return error.ExtensionBuildFailed;

    try tmp.dir.writeFile(io, .{ .sub_path = test_rel, .data = "two\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", zig_exe);
    defer second.deinit(alloc);
    if (!second.compile_ok) return error.ExtensionBuildFailed;

    try std.testing.expect(!std.mem.eql(u8, first.version, second.version));
}
