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
const manifest = @import("../manifest.zig");
const integrity = @import("../integrity.zig");
const ext_skills = @import("../skills.zig");
const store = @import("../store.zig");
const prompt = @import("../../prompt.zig");
const toolchain = @import("toolchain.zig");

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
    /// Index into the caller's `donors` when this version was COPIED from another
    /// store root rather than produced here (DESIGN §7.4). Null otherwise, so a
    /// caller that passed no donors never has to look at it.
    copied_from: ?usize = null,
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

/// Build the draft at `ext_dir_rel` (relative to `workspace`) into an immutable
/// version under `dest_root`, a store root (DESIGN §7.2). Stops at the "built"
/// state — activation is a separate, explicit step (DESIGN §7.4).
///
/// **Where a version lands is decided by the manifest id and the store root, not
/// by where the draft happens to sit**: `<dest_root>/<manifest.id>/versions/<v>`.
/// A draft inside a store root builds exactly where it always did (its directory
/// IS `<root>/<id>`); a draft anywhere else — a `modes/` or `extensions/`
/// directory kept in git, say — now produces a version `activate` can actually
/// find, instead of an orphan `versions/` next to the source.
///
/// Everything the compiler touches lives inside the version directory, so the
/// build runs with `dest_root` as its working directory and never needs an
/// absolute sub-path (a user root is an absolute path).
///
/// The error set is inferred: it folds manifest/source unreadability, manifest
/// parse/validate errors, compiler identity errors, and filesystem errors from
/// the version-directory writes.
pub fn buildExtension(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    dest_root: std.Io.Dir,
    zig_exe: []const u8,
) !BuildResult {
    return buildExtensionReusing(alloc, io, workspace, ext_dir_rel, dest_root, zig_exe, &.{});
}

/// `buildExtension`, plus the OTHER store roots this machine searches — in that
/// order — as places the version may already exist (DESIGN §7.2, §7.4).
///
/// A version is content-addressed, so a root that holds this exact package
/// snapshot (same digest, same target and, when this machine can name its
/// compiler, the same compiler identity) holds the bytes a local build would
/// produce. Copying that tree in and validating it again is therefore the same
/// version by construction — and it is what makes a second workspace, or a
/// machine with no toolchain at all, able to use a capability the user store
/// already carries without spending a compile.
///
/// Which roots those are is the caller's decision (nothing here knows about
/// search order); the destination root is searched first regardless, since a
/// copy already there is `already_built`.
pub fn buildExtensionReusing(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    dest_root: std.Io.Dir,
    zig_exe: []const u8,
    donors: []const std.Io.Dir,
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
    try ext_skills.validateSnapshot(alloc, m, snapshot);
    try validateSystemPrompts(alloc, m, snapshot);
    const snapshot_bytes = try snapshot.canonicalBytes(alloc);
    defer alloc.free(snapshot_bytes);

    const package_digest = try integrity.packageDigestHex(alloc, snapshot);
    defer alloc.free(package_digest);

    // Only a COMPILED extension's identity depends on the toolchain: its binary
    // is a function of the compiler and host target. `data` (no runtime) and
    // `script` (frozen, run as-is) are pure snapshots — compiler = "" and
    // target = "", so their version id is stable across platforms and needs no
    // zig at all (DESIGN §7.1, §7.4).
    const kind = manifest.implementationKind(m);
    const compiled = kind == .compiled;
    const target = if (compiled) toolchain.host_target else "";
    // Ask for the compiler identity, but do not fail on its absence yet: a
    // machine with no toolchain cannot COMPILE this package, and can still adopt
    // a copy some other root already holds. Not knowing it only widens the search
    // below, from one version id to "any build of these bytes for this target".
    const compiler: ?[]u8 = if (compiled)
        (compilerIdentity(alloc, io, workspace, zig_exe) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        })
    else
        try alloc.dupe(u8, "");
    defer if (compiler) |c| alloc.free(c);

    // From here on `<id>/` is mutated (a stale directory deleted, a version
    // written): hold the id's writer lease so two builds of one id in a shared
    // root — the user store — serialize instead of tearing each other's tree.
    var held = try store.Store.init(io, dest_root).lease(alloc, m.id);
    defer held.close(io);

    // `entry_rel` is the BUILT binary path — compiled extensions only. A script's
    // entry is frozen inside `package/` and located via `store.versionScriptEntryPath`.
    const entry_rel: ?[]u8 = if (compiled)
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ m.runtime.?.entry, exe_suffix })
    else
        null;
    errdefer if (entry_rel) |entry| alloc.free(entry);

    if (try findMatchingVersion(alloc, io, dest_root, m.id, package_digest, target, compiler)) |found| {
        return .{ .version = found, .entry_rel = entry_rel, .already_built = true, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
    }
    for (donors, 0..) |donor, donor_index| {
        const found = (try findMatchingVersion(alloc, io, donor, m.id, package_digest, target, compiler)) orelse continue;
        errdefer alloc.free(found);
        if (!try adoptVersionDir(alloc, io, donor, dest_root, m.id, found)) {
            alloc.free(found);
            continue;
        }
        return .{ .version = found, .entry_rel = entry_rel, .already_built = false, .copied_from = donor_index, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
    }

    // Nothing to adopt: this build has to produce the version itself, which for a
    // compiled package is precisely where a toolchain stops being optional.
    const compiler_id = compiler orelse return error.ZigVersionUnreadable;
    const version = try integrity.versionId(alloc, snapshot_bytes, compiler_id, target);
    errdefer alloc.free(version);

    // Store layout, not draft layout: `<id>/versions/<v>` under the store root.
    const version_rel = try std.fs.path.join(alloc, &.{ m.id, "versions", version });
    defer alloc.free(version_rel);
    dest_root.deleteTree(io, version_rel) catch {};

    // Data or script: freeze the snapshot, seal with no binary, done — nothing to
    // compile.
    if (!compiled) {
        try integrity.freezeSnapshot(alloc, io, dest_root, version_rel, manifest_bytes, snapshot);
        try writeSeal(alloc, io, dest_root, version_rel, package_digest, compiler_id, target, null);
        return .{ .version = version, .entry_rel = entry_rel, .already_built = false, .compile_ok = true, .stderr = try alloc.alloc(u8, 0) };
    }

    const rt = m.runtime.?;
    const entry = entry_rel.?;
    const bin_rel = try std.fs.path.join(alloc, &.{ version_rel, entry });
    defer alloc.free(bin_rel);
    const bin_dir_rel = std.fs.path.dirname(bin_rel) orelse version_rel;

    try integrity.freezeSnapshot(alloc, io, dest_root, version_rel, manifest_bytes, snapshot);
    try dest_root.createDirPath(io, bin_dir_rel);

    const frozen_source = try std.fs.path.join(alloc, &.{ version_rel, package_dir, "src", "main.zig" });
    defer alloc.free(frozen_source);
    const emit_arg = try std.fmt.allocPrint(alloc, "-femit-bin={s}", .{bin_rel});
    defer alloc.free(emit_arg);

    // Fixed, reproducible invocation — the AI gets no say in the flags. Compile
    // from the frozen package, never the mutable draft tree. Source and output
    // are both inside the version directory, so the store root is the cwd.
    const result = std.process.run(alloc, io, .{
        .argv = &.{ zig_exe, "build-exe", frozen_source, "-O", "ReleaseSafe", emit_arg, "--name", std.fs.path.stem(rt.entry) },
        .cwd = .{ .dir = dest_root },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        dest_root.deleteTree(io, version_rel) catch {};
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
        dest_root.deleteTree(io, version_rel) catch {};
        return .{ .version = version, .entry_rel = entry_rel, .already_built = false, .compile_ok = false, .stderr = result.stderr };
    }
    alloc.free(result.stderr);

    const binary_digest = try integrity.fileDigestHex(alloc, io, dest_root, bin_rel);
    defer alloc.free(binary_digest);
    try writeSeal(alloc, io, dest_root, version_rel, package_digest, compiler_id, target, binary_digest);

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

/// Find a built version of `id` in `root` that IS what this build would produce:
/// the same package snapshot (by digest) for the same target and, when this
/// machine can name its compiler, from that same compiler. Such a version is
/// this build's output by content addressing (DESIGN §7.4) — in the destination
/// root that makes the build a no-op, and in another root it makes the version
/// copyable. Null when the root holds no such version; a broken copy is skipped
/// rather than reported, host faults propagate. Caller owns the result.
///
/// Without a compiler identity (a compiled package on a machine with no
/// toolchain) several builds of one source can match — one per compiler that
/// ever produced it — so the search runs over sorted version ids: which copy is
/// adopted must not depend on the order a directory listing happens to arrive in.
fn findMatchingVersion(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    id: []const u8,
    package_digest: []const u8,
    target: []const u8,
    compiler: ?[]const u8,
) !?[]u8 {
    const versions = store.Store.init(io, root).listVersions(alloc, id) catch |err| switch (err) {
        error.InvalidId => return null,
        else => return err,
    };
    defer {
        for (versions) |v| alloc.free(v);
        alloc.free(versions);
    }
    const sorted = try alloc.alloc([]const u8, versions.len);
    defer alloc.free(sorted);
    @memcpy(sorted, versions);
    std.mem.sort([]const u8, sorted, {}, lessThanVersion);

    for (sorted) |v| {
        const version_rel = try std.fs.path.join(alloc, &.{ id, "versions", v });
        defer alloc.free(version_rel);
        const seal_sub = try std.fs.path.join(alloc, &.{ version_rel, seal_file });
        defer alloc.free(seal_sub);
        const bytes = root.readFileAlloc(io, seal_sub, alloc, .limited(1 << 20)) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => continue, // half-written version directory: not a candidate
        };
        defer alloc.free(bytes);
        var seal = integrity.parseSeal(alloc, bytes) catch continue;
        defer seal.deinit();
        if (!std.mem.eql(u8, seal.package_digest, package_digest)) continue;
        if (!std.mem.eql(u8, seal.target, target)) continue;
        if (compiler) |c| {
            if (!std.mem.eql(u8, seal.compiler, c)) continue;
        }
        // The seal only claims; validation checks the frozen bytes against it.
        integrity.validateVersionDir(alloc, io, root, version_rel, v, id) catch |err| {
            if (!store.isExtensionFault(err)) return err;
            continue;
        };
        return try alloc.dupe(u8, v);
    }
    return null;
}

fn lessThanVersion(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Copy `<id>/versions/<version>` from one store root into another, byte for
/// byte, and validate the copy where it landed. False when the copy does not
/// validate there (it is removed again, and the caller falls back to building) —
/// a defensive answer, since a validated source and a plain file copy should not
/// disagree.
fn adoptVersionDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    src_root: std.Io.Dir,
    dest_root: std.Io.Dir,
    id: []const u8,
    version: []const u8,
) !bool {
    const version_rel = try std.fs.path.join(alloc, &.{ id, "versions", version });
    defer alloc.free(version_rel);

    var src = try src_root.openDir(io, version_rel, .{ .iterate = true });
    defer src.close(io);
    dest_root.deleteTree(io, version_rel) catch {};
    try dest_root.createDirPath(io, version_rel);
    var dest = try dest_root.openDir(io, version_rel, .{});
    defer dest.close(io);

    var walker = try src.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dest.createDirPath(io, entry.path),
        // Permissions come from the source, so a frozen binary stays executable.
        .file => try src.copyFile(entry.path, dest, entry.path, io, .{ .make_path = true }),
        else => {},
    };

    integrity.validateVersionDir(alloc, io, dest_root, version_rel, version, id) catch |err| {
        if (!store.isExtensionFault(err)) return err;
        dest_root.deleteTree(io, version_rel) catch {};
        return false;
    };
    return true;
}

fn writeSeal(
    alloc: std.mem.Allocator,
    io: std.Io,
    dest_root: std.Io.Dir,
    version_rel: []const u8,
    package_digest: []const u8,
    compiler: []const u8,
    target: []const u8,
    binary_digest: ?[]const u8,
) !void {
    const seal = try integrity.sealJson(alloc, package_digest, compiler, target, binary_digest);
    defer alloc.free(seal);
    const seal_sub = try std.fs.path.join(alloc, &.{ version_rel, seal_file });
    defer alloc.free(seal_sub);
    try dest_root.writeFile(io, .{ .sub_path = seal_sub, .data = seal });
}

/// Static system prompts are plain text contributions; a built version must
/// stay consumable by session composition, which reads each prompt with the
/// same byte limit and needs valid UTF-8 for provider JSON serialization.
fn validateSystemPrompts(alloc: std.mem.Allocator, m: manifest.Manifest, snapshot: integrity.PackageSnapshot) !void {
    for (m.system_prompts) |prompt_path| {
        const rel = try integrity.canonicalRel(alloc, prompt_path);
        defer alloc.free(rel);
        const bytes = integrity.findSnapshotFile(snapshot, rel) orelse return error.SystemPromptFileMissing;
        if (bytes.len > prompt.max_system_prompt_bytes) return error.SystemPromptTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    }
}

fn testZigExe(alloc: std.mem.Allocator) ![]u8 {
    var host = try std.testing.environ.createMap(alloc);
    defer host.deinit();
    if (host.get("NULYA_TEST_ZIG")) |zig_exe| if (zig_exe.len != 0) return try alloc.dupe(u8, zig_exe);
    return try alloc.dupe(u8, "zig");
}

/// Fail a test on a rejected compile with the compiler's own diagnostics. A bare
/// `error.ExtensionBuildFailed` says only that `zig build-exe` exited non-zero,
/// which is unactionable when the failure is intermittent (a locked output file,
/// a toolchain that is not there) rather than a real source error.
fn expectCompiled(label: []const u8, result: BuildResult) !void {
    if (result.compile_ok) return;
    std.debug.print("{s} build did not compile:\n{s}\n", .{ label, result.stderr });
    return error.ExtensionBuildFailed;
}

/// A destination store the two COMPILING tests below share across runs. Their
/// subject is the version id, not the compile: both need two real builds of a
/// trivial program to compare, and a real build is a real `zig build-exe`
/// (~7s each, four of them in this file).
///
/// A version is content-addressed and immutable, so pointing them at a store
/// that outlives the process costs the compiles exactly once per snapshot: the
/// next run finds the same version already built and `buildExtension` answers
/// `already_built` without spending a compiler. Nothing is assumed about what is
/// in there — a version that no longer validates is deleted and rebuilt by the
/// same code path any user's store takes, a toolchain change gives every version
/// a new id, and deleting `.zig-cache` is the reset.
///
/// The DRAFT still lives in each test's own fresh tmp dir; only the store the
/// frozen version lands in is shared, and neither test looks inside it. Caller
/// closes the handle.
fn sharedVersionStore(io: std.Io) !std.Io.Dir {
    const rel = ".zig-cache" ++ std.fs.path.sep_str ++ "nulya-unit-versions";
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, rel);
    return cwd.openDir(io, rel, .{});
}

test "missing manifest is a clear error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "ext");
    try std.testing.expectError(
        error.ManifestUnreadable,
        buildExtension(alloc, std.testing.io, tmp.dir, "ext", tmp.dir, "zig"),
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
    var result = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, zig_exe);
    defer result.deinit(alloc);
    try std.testing.expect(result.compile_ok);
    try std.testing.expect(result.entry_rel == null);
    const skill_path = try std.fs.path.join(alloc, &.{ "skills.finance", "versions", result.version, package_dir, "skills", "risk-parity", "SKILL.md" });
    defer alloc.free(skill_path);
    try tmp.dir.access(io, skill_path, .{});
}

test "skill package build rejects missing SKILL.md" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"skills","contributes":{"skills":["skills/demo"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo" ++ std.fs.path.sep_str ++ "notes.txt", .data = "not a skill\n" });

    try std.testing.expectError(error.SkillFileMissing, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, "zig"));
}

test "skill package build rejects frontmatter name mismatch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"skills","contributes":{"skills":["skills/demo"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo" ++ std.fs.path.sep_str ++ "SKILL.md", .data = "---\nname: other\ndescription: demo\n---\nbody\n" });

    try std.testing.expectError(error.SkillNameDoesNotMatchDirectory, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, "zig"));
}

test "skill package build rejects duplicate skill names" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "a" ++ std.fs.path.sep_str ++ "foo");
    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "b" ++ std.fs.path.sep_str ++ "foo");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"skills","contributes":{"skills":["skills/a/foo","skills/b/foo"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "a" ++ std.fs.path.sep_str ++ "foo" ++ std.fs.path.sep_str ++ "SKILL.md", .data = "---\nname: foo\ndescription: first\n---\nbody\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "b" ++ std.fs.path.sep_str ++ "foo" ++ std.fs.path.sep_str ++ "SKILL.md", .data = "---\nname: foo\ndescription: second\n---\nbody\n" });

    try std.testing.expectError(error.DuplicateSkillName, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, "zig"));
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
    var dest = try sharedVersionStore(io);
    defer dest.close(io);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", dest, zig_exe);
    defer first.deinit(alloc);
    try expectCompiled("first", first);

    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "helper.zig", .data = "pub const value = 2;\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", dest, zig_exe);
    defer second.deinit(alloc);
    try expectCompiled("second", second);

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
    try tmp.dir.writeFile(io, .{ .sub_path = skill_rel, .data = "---\nname: demo\ndescription: demo skill\n---\nversion one\n" });

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, zig_exe);
    defer first.deinit(alloc);

    try tmp.dir.writeFile(io, .{ .sub_path = skill_rel, .data = "---\nname: demo\ndescription: demo skill\n---\nversion two\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, zig_exe);
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
    var dest = try sharedVersionStore(io);
    defer dest.close(io);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", dest, zig_exe);
    defer first.deinit(alloc);
    try expectCompiled("first", first);

    try tmp.dir.writeFile(io, .{ .sub_path = test_rel, .data = "two\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", dest, zig_exe);
    defer second.deinit(alloc);
    try expectCompiled("second", second);

    try std.testing.expect(!std.mem.eql(u8, first.version, second.version));
}

test "prompt-only package builds without runtime and freezes prompt files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "prompts");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"prompts.finance","contributes":{"system_prompts":["prompts/finance.md"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "finance.md", .data = "finance prompt\n" });

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var result = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, zig_exe);
    defer result.deinit(alloc);
    try std.testing.expect(result.compile_ok);
    try std.testing.expect(result.entry_rel == null);
    const prompt_path = try std.fs.path.join(alloc, &.{ "prompts.finance", "versions", result.version, package_dir, "prompts", "finance.md" });
    defer alloc.free(prompt_path);
    try tmp.dir.access(io, prompt_path, .{});
}

test "a data extension builds with no compiler and its version ignores compiler identity" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"skills","contributes":{"skills":["skills/demo"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo" ++ std.fs.path.sep_str ++ "SKILL.md", .data = "---\nname: demo\ndescription: demo\n---\nbody\n" });

    // No toolchain at all: a data extension never compiles, so build succeeds.
    var without = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, "");
    defer without.deinit(alloc);
    try std.testing.expect(without.compile_ok);

    // Building again with a real compiler present yields the SAME version id: the
    // compiler is not part of a data version's identity.
    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var with = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, zig_exe);
    defer with.deinit(alloc);
    try std.testing.expect(with.already_built);
    try std.testing.expectEqualStrings(without.version, with.version);
}

test "a script extension builds with no compiler and its version ignores compiler identity" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"demo","runtime":{"entry":"src/run.sh","interpreter":"sh"},"contributes":{"tools":[{"name":"greet","input":{}}]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "run.sh", .data = "echo hi\n" });

    var without = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, "");
    defer without.deinit(alloc);
    try std.testing.expect(without.compile_ok);
    try std.testing.expect(without.entry_rel == null); // a script has no built binary

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var with = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, zig_exe);
    defer with.deinit(alloc);
    try std.testing.expect(with.already_built);
    try std.testing.expectEqualStrings(without.version, with.version);
}

test "system prompt file changes the version id" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "prompts");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"prompts","contributes":{"system_prompts":["prompts/base.md"]}}
    });
    const prompt_rel = "ext" ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "base.md";
    try tmp.dir.writeFile(io, .{ .sub_path = prompt_rel, .data = "version one\n" });

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, zig_exe);
    defer first.deinit(alloc);

    try tmp.dir.writeFile(io, .{ .sub_path = prompt_rel, .data = "version two\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, zig_exe);
    defer second.deinit(alloc);

    try std.testing.expect(!std.mem.eql(u8, first.version, second.version));
}

test "frozen prompt tampering fails integrity validation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "prompts");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"prompts","contributes":{"system_prompts":["prompts/base.md"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "base.md", .data = "original\n" });

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var result = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, zig_exe);
    defer result.deinit(alloc);

    const prompt_path = try std.fs.path.join(alloc, &.{ "prompts", "versions", result.version, package_dir, "prompts", "base.md" });
    defer alloc.free(prompt_path);
    try tmp.dir.writeFile(io, .{ .sub_path = prompt_path, .data = "tampered\n" });
    const version_rel = try std.fs.path.join(alloc, &.{ "prompts", "versions", result.version });
    defer alloc.free(version_rel);
    try std.testing.expectError(error.VersionSealInvalid, integrity.validateVersionDir(alloc, io, tmp.dir, version_rel, result.version, "prompts"));
}

test "skill package build rejects oversized SKILL.md" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"skills","contributes":{"skills":["skills/demo"]}}
    });
    const prefix = "---\nname: demo\ndescription: demo\n---\n";
    const body = try alloc.alloc(u8, 2 * 1024 * 1024 + 1);
    defer alloc.free(body);
    @memset(body, 'a');
    const skill_md = try std.mem.concat(alloc, u8, &.{ prefix, body });
    defer alloc.free(skill_md);
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo" ++ std.fs.path.sep_str ++ "SKILL.md", .data = skill_md });

    try std.testing.expectError(error.SkillFileTooLarge, buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, "zig"));
}

test "skill package build rejects invalid UTF-8 SKILL.md" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"skills","contributes":{"skills":["skills/demo"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo" ++ std.fs.path.sep_str ++ "SKILL.md", .data = "---\nname: demo\ndescription: demo\n---\n\xff body\n" });

    try std.testing.expectError(error.InvalidUtf8, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, "zig"));
}

test "prompt package build rejects oversized system prompt" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "prompts");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"prompts","contributes":{"system_prompts":["prompts/base.md"]}}
    });
    const body = try alloc.alloc(u8, 2 * 1024 * 1024 + 1);
    defer alloc.free(body);
    @memset(body, 'a');
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "base.md", .data = body });

    try std.testing.expectError(error.SystemPromptTooLarge, buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, "zig"));
}

test "prompt package build rejects invalid UTF-8 system prompt" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "prompts");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"prompts","contributes":{"system_prompts":["prompts/base.md"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "base.md", .data = "\xff\xfe not text\n" });

    try std.testing.expectError(error.InvalidUtf8, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, "zig"));
}
