//! `nulya ext build` — compile an extension into an immutable version (DESIGN
//! §7.4, §10).
//!
//! The AI never runs `zig build` itself. This module fixes every knob (zig
//! version, optimize, target, output location) so a given source always maps to
//! the same content-addressed version id and the build is reproducible.
//!
//! The Zig executable is injected rather than resolved here: production wires in
//! `toolchain.ensureExtracted` (the embedded toolchain), while the e2e test
//! wires in the host's own zig — so the whole close-the-loop path is testable
//! without the ~90MB embed.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("manifest.zig");
const store = @import("store.zig");
const toolchain = @import("../toolchain.zig");

/// Executable suffix on the host. Extensions are built for and run on the same
/// host nulya runs on, so build and run agree on this.
pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

/// Source layout convention for runtime-backed extensions.
const source_rel = "src" ++ std.fs.path.sep_str ++ "main.zig";

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
/// error set is inferred: it folds `error.ManifestUnreadable` /
/// `error.SourceUnreadable`, manifest parse/validate errors, and filesystem
/// errors from the version-directory writes.
pub fn buildExtension(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    zig_exe: []const u8,
) !BuildResult {
    const manifest_rel = try std.fs.path.join(alloc, &.{ ext_dir_rel, "extension.json" });
    defer alloc.free(manifest_rel);
    const manifest_bytes = workspace.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20)) catch
        return error.ManifestUnreadable;
    defer alloc.free(manifest_bytes);

    var m = try manifest.parse(alloc, manifest_bytes);
    defer m.deinit();
    try m.validate();

    var src_rel: ?[]u8 = null;
    defer if (src_rel) |p| alloc.free(p);
    const source_bytes = if (m.runtime != null) blk: {
        src_rel = try std.fs.path.join(alloc, &.{ ext_dir_rel, source_rel });
        break :blk workspace.readFileAlloc(io, src_rel.?, alloc, .limited(4 << 20)) catch
            return error.SourceUnreadable;
    } else try alloc.alloc(u8, 0);
    defer alloc.free(source_bytes);

    const version = try store.Store.versionId(alloc, .{
        .source = source_bytes,
        .zig_version = toolchain.pinned_version,
        .target = toolchain.host_target,
        .manifest = manifest_bytes,
    });
    errdefer alloc.free(version);

    const version_rel = try std.fs.path.join(alloc, &.{ ext_dir_rel, "versions", version });
    defer alloc.free(version_rel);

    const manifest_dst = try std.fs.path.join(alloc, &.{ version_rel, "extension.json" });
    defer alloc.free(manifest_dst);

    if (m.runtime == null) {
        const has_manifest = if (workspace.access(io, manifest_dst, .{})) |_| true else |_| false;
        if (has_manifest) {
            return .{ .version = version, .entry_rel = null, .already_built = true, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
        }

        workspace.deleteTree(io, version_rel) catch {};
        try workspace.createDirPath(io, version_rel);
        try workspace.writeFile(io, .{ .sub_path = manifest_dst, .data = manifest_bytes });
        return .{ .version = version, .entry_rel = null, .already_built = false, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
    }

    const rt = m.runtime.?;
    const entry_rel = try std.fmt.allocPrint(alloc, "{s}{s}", .{ rt.entry, exe_suffix });
    errdefer alloc.free(entry_rel);

    const bin_rel = try std.fs.path.join(alloc, &.{ version_rel, entry_rel });
    defer alloc.free(bin_rel);

    // Immutable + content-addressed: an existing complete version is a reproducible
    // no-op. If a previous run left only part of the version behind, clear it and
    // rebuild so activation never sees a half-version.
    const has_bin = if (workspace.access(io, bin_rel, .{})) |_| true else |_| false;
    const has_manifest = if (workspace.access(io, manifest_dst, .{})) |_| true else |_| false;
    if (has_bin and has_manifest) {
        return .{ .version = version, .entry_rel = entry_rel, .already_built = true, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
    }
    if (has_bin or has_manifest) workspace.deleteTree(io, version_rel) catch {};

    const bin_dir_rel = std.fs.path.dirname(bin_rel) orelse version_rel;
    try workspace.createDirPath(io, bin_dir_rel);

    const emit_arg = try std.fmt.allocPrint(alloc, "-femit-bin={s}", .{bin_rel});
    defer alloc.free(emit_arg);

    // Fixed, reproducible invocation — the AI gets no say in the flags.
    const result = std.process.run(alloc, io, .{
        .argv = &.{ zig_exe, "build-exe", src_rel.?, "-O", "ReleaseSafe", emit_arg, "--name", std.fs.path.stem(rt.entry) },
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

    // Make the version self-describing: keep its manifest alongside the binary.
    try workspace.writeFile(io, .{ .sub_path = manifest_dst, .data = manifest_bytes });

    return .{ .version = version, .entry_rel = entry_rel, .already_built = false, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
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

test "pure skill package builds by freezing only its manifest" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "extension.json", .data =
        \\{"schema":"nulya.extension/v2","id":"skills.finance","version":"1","contributes":{"skills":["skills/risk-parity"]}}
    });

    var result = try buildExtension(alloc, io, tmp.dir, "ext", "zig");
    defer result.deinit(alloc);
    try std.testing.expect(result.compile_ok);
    try std.testing.expect(result.entry_rel == null);
    const manifest_path = try std.fs.path.join(alloc, &.{ "ext", "versions", result.version, "extension.json" });
    defer alloc.free(manifest_path);
    try tmp.dir.access(io, manifest_path, .{});
}
