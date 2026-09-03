//! `nulya ext build` — compile an extension into an immutable version.
//!
//! The AI never runs `zig build` itself. This module fixes every knob (zig
//! identity, optimize, target, output location) so a given package snapshot
//! maps to the same content-addressed version id.

const std = @import("std");
const manifest = @import("../manifest.zig");
const integrity = @import("../integrity.zig");
const ext_skills = @import("../skills.zig");
const store = @import("../store.zig");
const prompt = @import("../../prompt.zig");
const target_mod = @import("../target.zig");

pub const exe_suffix = integrity.exe_suffix;
const manifest_file = integrity.manifest_file;
const package_dir = integrity.package_dir;
const seal_file = integrity.seal_file;

pub const BuildResult = struct {
    /// Which `<id>/` under the store this landed in — not necessarily the
    /// draft's directory name.
    id: []u8,
    version: []u8,
    /// Relative to the version directory; null when there is no runtime.
    entry_rel: ?[]u8,
    /// This exact version already existed — a reproducible no-op.
    already_built: bool,
    /// False when the compiler rejected the source; `stderr` then holds its
    /// diagnostics for the model to correct against.
    compile_ok: bool,
    stderr: []u8,

    pub fn deinit(self: BuildResult, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.version);
        if (self.entry_rel) |entry_rel| alloc.free(entry_rel);
        alloc.free(self.stderr);
    }
};

/// Whether a call is allowed to WRITE; `plan` answers the same questions and stops.
pub const Mode = enum { build, plan };

pub const Options = struct {
    /// The two words enter the version id and the seal exactly as a host build's
    /// do. Refused for `data` / `script` (`error.TargetNotApplicable`): their
    /// identity is the snapshot alone, the same everywhere.
    target: ?target_mod.Target = null,
};

/// Which executable, plus its `zig version` identity asked of the host at most
/// once — that identity enters every compiled version id and cannot change
/// mid-run. The probe runs with the build's `workspace` as its cwd, because a
/// version-manager shim answers differently from different directories.
pub const Zig = struct {
    /// Empty = "this machine named none", not fatal until something compiles.
    exe: []const u8,
    probed: bool = false,
    /// Owned once probed; null means the host could not name its compiler.
    identity: ?[]u8 = null,
    /// Why the probe could not name it, in the host's own words; owned.
    failure: ?[]u8 = null,

    pub fn init(exe: []const u8) Zig {
        return .{ .exe = exe };
    }

    pub fn deinit(self: *Zig, alloc: std.mem.Allocator) void {
        if (self.identity) |id| alloc.free(id);
        if (self.failure) |why| alloc.free(why);
        self.* = undefined;
    }

    /// Null when nothing did, or when saying so ran out of memory.
    pub fn whyUnreadable(self: *const Zig) ?[]const u8 {
        return self.failure;
    }

    /// `zig <version>`, or null when this machine cannot name its compiler.
    /// Borrowed; owned by the `Zig`.
    fn resolve(self: *Zig, alloc: std.mem.Allocator, io: std.Io, workspace: std.Io.Dir) !?[]const u8 {
        if (self.probed) return self.identity;
        self.identity = compilerIdentity(alloc, io, workspace, self.exe, &self.failure) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        self.probed = true;
        return self.identity;
    }
};

/// Build the draft at `ext_dir_rel` (relative to `workspace`) into an immutable
/// version under the store root `dest_root`. Activation is a separate step.
///
/// Where a version lands follows the manifest id and the store root, never
/// where the draft sits: `<dest_root>/<manifest.id>/versions/<v>`, so a draft
/// kept anywhere still produces a version `activate` can find. Everything the
/// compiler touches is inside that directory, so `dest_root` is the cwd.
pub fn buildExtension(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    dest_root: std.Io.Dir,
    zig: *Zig,
) !BuildResult {
    return build(alloc, io, workspace, ext_dir_rel, dest_root, zig, .{}, .build);
}

/// The same manifest, snapshot and lookup, no writes. `already_built` then
/// means "the store already holds it".
pub fn planExtension(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    dest_root: std.Io.Dir,
    zig: *Zig,
) !BuildResult {
    return build(alloc, io, workspace, ext_dir_rel, dest_root, zig, .{}, .plan);
}

pub fn buildExtensionFor(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    dest_root: std.Io.Dir,
    zig: *Zig,
    opts: Options,
) !BuildResult {
    return build(alloc, io, workspace, ext_dir_rel, dest_root, zig, opts, .build);
}

fn build(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    dest_root: std.Io.Dir,
    zig: *Zig,
    opts: Options,
    mode: Mode,
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
    try validateUi(alloc, m, snapshot);
    try validateScriptEntries(alloc, m, snapshot);
    const snapshot_bytes = try snapshot.canonicalBytes(alloc);
    defer alloc.free(snapshot_bytes);

    const package_digest = try integrity.packageDigestHex(alloc, snapshot);
    defer alloc.free(package_digest);

    // Only a compiled extension's identity depends on the toolchain: `data` and
    // `script` are pure snapshots (compiler = "", target = ""), stable anywhere.
    const kind = manifest.implementationKind(m);
    const compiled = kind == .compiled;
    // Refused before anything is written or leased.
    if (opts.target != null and !compiled) return error.TargetNotApplicable;
    const target = if (compiled) (if (opts.target) |t| t.words() else target_mod.host) else "";
    // Not fatal yet: not knowing it widens the search below from one version id
    // to "any build of these bytes for this target".
    const compiler: ?[]const u8 = if (compiled) try zig.resolve(alloc, io, workspace) else "";

    // From here `<id>/` is mutated, so hold the id's writer lease and let two
    // builds of one id in a shared root serialize instead of tearing each
    // other's tree. A plan writes nothing, and the lease would create `<id>/`.
    var held: ?std.Io.File = if (mode == .build) try store.Store.init(io, dest_root).lease(alloc, m.id) else null;
    defer if (held) |*h| h.close(io);

    // A compiled entry is never per-OS, so the host's variant is the one written.
    const declared_entry: []const u8 = if (compiled)
        m.runtime.?.entry.forHost() orelse return error.EntryUnsupportedOnHost
    else
        "";
    // The suffix belongs to the TARGET, not this machine.
    const entry_rel: ?[]u8 = if (compiled)
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ declared_entry, target_mod.exeSuffixFor(target) })
    else
        null;
    errdefer if (entry_rel) |entry| alloc.free(entry);

    if (try findMatchingVersion(alloc, io, dest_root, m.id, package_digest, target, compiler)) |found| {
        return sealed(alloc, m.id, found, entry_rel, true);
    }

    // Nothing already there: a compiled package's toolchain stops being optional.
    const compiler_id = compiler orelse return error.ZigVersionUnreadable;
    const version = try integrity.versionId(alloc, snapshot_bytes, compiler_id, target);
    errdefer alloc.free(version);
    if (mode == .plan) return sealed(alloc, m.id, version, entry_rel, false);

    const version_rel = try std.fs.path.join(alloc, &.{ m.id, "versions", version });
    defer alloc.free(version_rel);
    dest_root.deleteTree(io, version_rel) catch {};

    // Data or script: freeze, seal with no binary — nothing to compile.
    if (!compiled) {
        try integrity.freezeSnapshot(alloc, io, dest_root, version_rel, manifest_bytes, snapshot);
        try writeSeal(alloc, io, dest_root, version_rel, package_digest, compiler_id, target, null);
        return sealed(alloc, m.id, version, entry_rel, false);
    }

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

    // Fixed, reproducible invocation — the AI gets no say in the flags — and
    // compiled from the FROZEN package, never the mutable draft tree.
    //
    // `-target` comes from `effectiveTriple`, which answers for a host build
    // too: a build that named nothing must compile the way a cross build for
    // those same words would, or one id could name two different compiles
    // (glibc here, musl over there). Null for a host outside that vocabulary.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ zig.exe, "build-exe", frozen_source, "-O", "ReleaseSafe", emit_arg, "--name", std.fs.path.stem(declared_entry) });
    if (target_mod.effectiveTriple(opts.target)) |triple| try argv.appendSlice(alloc, &.{ "-target", triple });

    const result = std.process.run(alloc, io, .{
        .argv = argv.items,
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
        const owned_id = try alloc.dupe(u8, m.id);
        errdefer alloc.free(owned_id);
        return .{ .id = owned_id, .version = version, .entry_rel = entry_rel, .already_built = false, .compile_ok = false, .stderr = result.stderr };
    }
    alloc.free(result.stderr);

    const binary_digest = try integrity.fileDigestHex(alloc, io, dest_root, bin_rel);
    defer alloc.free(binary_digest);
    try writeSeal(alloc, io, dest_root, version_rel, package_digest, compiler_id, target, binary_digest);

    return sealed(alloc, m.id, version, entry_rel, false);
}

/// Takes ownership of `version` and `entry_rel`.
fn sealed(
    alloc: std.mem.Allocator,
    id: []const u8,
    version: []u8,
    entry_rel: ?[]u8,
    already_built: bool,
) !BuildResult {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    return .{
        .id = owned_id,
        .version = version,
        .entry_rel = entry_rel,
        .already_built = already_built,
        .compile_ok = true,
        .stderr = try alloc.alloc(u8, 0),
    };
}

/// Trimmed and clipped to one line of somebody's terminal.
fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    // A CRLF host's line ends in a carriage return; that byte mangles a terminal.
    const line = std.mem.trim(u8, trimmed[0..end], " \t\r");
    return line[0..@min(line.len, 200)];
}

/// Kept as the error it actually was — `null` when the path answered. "Not
/// there" and "there, but unreachable" are different facts about the machine.
fn accessError(io: std.Io, dir: std.Io.Dir, path: []const u8) ?anyerror {
    if (dir.access(io, path, .{})) |_| return null else |e| return e;
}

/// What a failed spawn means, asked of the filesystem rather than guessed from
/// the error name: Windows answers `FileNotFound` for BOTH a missing executable
/// and a missing working directory, and those are opposite repairs.
fn spawnNote(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    zig_exe: []const u8,
    err: anyerror,
) ?[]u8 {
    const plain = std.fmt.allocPrint(alloc, "could not run it: {s}", .{@errorName(err)}) catch null;
    if (err != error.FileNotFound) return plain;

    const exe_err = accessError(io, std.Io.Dir.cwd(), zig_exe);
    const dir_err = accessError(io, workspace, ".");
    if (exe_err == null and dir_err == null) return plain; // both there: the OS refused the spawn itself
    if (plain) |p| alloc.free(p);

    if (exe_err) |e| {
        if (e != error.FileNotFound) {
            return std.fmt.allocPrint(
                alloc,
                "that file cannot be reached from here right now: {s}",
                .{@errorName(e)},
            ) catch null;
        }
        // Its directory decides between "nothing was ever unpacked" and "the
        // toolchain lost its executable".
        const parent = std.fs.path.dirname(zig_exe) orelse
            return alloc.dupe(u8, "there is no file at that path") catch null;
        const parent_there = accessError(io, std.Io.Dir.cwd(), parent) == null;
        return alloc.dupe(u8, if (parent_there)
            "that directory is there, but it holds no file by that name"
        else
            "neither that file nor the directory it belongs in exists") catch null;
    }
    return alloc.dupe(u8, "that file is there, but the directory this build runs in is not") catch null;
}

/// `zig <version>` as this host reports it, or `error.ZigVersionUnreadable`
/// with `why` set to what stopped it: it did not run, it exited non-zero, or it
/// printed nothing — one error name over three different repairs.
fn compilerIdentity(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    zig_exe: []const u8,
    why: *?[]u8,
) ![]u8 {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ zig_exe, "version" },
        .cwd = .{ .dir = workspace },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| {
        // The output limits above land here too: a shim whose complaint runs
        // past 4 KB never reaches the exit code.
        why.* = spawnNote(alloc, io, workspace, zig_exe, err);
        return error.ZigVersionUnreadable;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => {
            why.* = alloc.dupe(u8, "it did not exit normally") catch null;
            return error.ZigVersionUnreadable;
        },
    };
    const complaint = firstLine(result.stderr);
    if (exit_code != 0) {
        why.* = if (complaint.len != 0)
            std.fmt.allocPrint(alloc, "it exited {d}: {s}", .{ exit_code, complaint }) catch null
        else
            std.fmt.allocPrint(alloc, "it exited {d} without saying why", .{exit_code}) catch null;
        return error.ZigVersionUnreadable;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        why.* = if (complaint.len != 0)
            std.fmt.allocPrint(alloc, "it printed no version: {s}", .{complaint}) catch null
        else
            alloc.dupe(u8, "it exited 0 but printed no version") catch null;
        return error.ZigVersionUnreadable;
    }
    return try std.fmt.allocPrint(alloc, "zig {s}", .{trimmed});
}

/// A built version of `id` in `root` that IS what this build would produce: the
/// same package snapshot (by digest) for the same target and, when this machine
/// can name its compiler, from that compiler. Caller owns the result.
fn findMatchingVersion(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    id: []const u8,
    package_digest: []const u8,
    target: []const u8,
    compiler: ?[]const u8,
) !?[]u8 {
    return store.Store.init(io, root).findSealed(alloc, id, package_digest, target, compiler);
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

/// A built version must stay consumable by session composition, which reads
/// each prompt with the same byte limit and needs valid UTF-8 for provider JSON.
fn validateSystemPrompts(alloc: std.mem.Allocator, m: manifest.Manifest, snapshot: integrity.PackageSnapshot) !void {
    for (m.system_prompts) |p| {
        const rel = try integrity.canonicalRel(alloc, p.path);
        defer alloc.free(rel);
        const bytes = integrity.findSnapshotFile(snapshot, rel) orelse return error.SystemPromptFileMissing;
        if (bytes.len > prompt.max_system_prompt_bytes) return error.SystemPromptTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    }
}

/// A declared front-end module this build must be able to freeze. No size
/// ceiling: `prompt.max_system_prompt_bytes` bounds what is fed to a model, and
/// front-end source never is.
fn validateUi(alloc: std.mem.Allocator, m: manifest.Manifest, snapshot: integrity.PackageSnapshot) !void {
    for (m.ui) |u| {
        const rel = try integrity.canonicalRel(alloc, u.entry);
        defer alloc.free(rel);
        _ = integrity.findSnapshotFile(snapshot, rel) orelse return error.UiEntryFileMissing;
    }
}

/// Every declared script entry is in the snapshot — not just this host's: one
/// version serves every platform, so the building machine is the only chance to
/// notice a missing variant. A compiled entry is skipped: it does not exist yet.
fn validateScriptEntries(alloc: std.mem.Allocator, m: manifest.Manifest, snapshot: integrity.PackageSnapshot) !void {
    const rt = m.runtime orelse return;
    if (!manifest.isScript(rt)) return;
    for (rt.entry.variants) |v| {
        const rel = try integrity.canonicalRel(alloc, v.value);
        defer alloc.free(rel);
        _ = integrity.findSnapshotFile(snapshot, rel) orelse return error.EntryFileMissing;
    }
}

fn testZigExe(alloc: std.mem.Allocator) ![]u8 {
    var host = try std.testing.environ.createMap(alloc);
    defer host.deinit();
    if (host.get("NULYA_TEST_ZIG")) |zig_exe| if (zig_exe.len != 0) return try alloc.dupe(u8, zig_exe);
    return try alloc.dupe(u8, "zig");
}

/// Fail with the compiler's own diagnostics: `ExtensionBuildFailed` alone is
/// unactionable when the failure is intermittent.
fn expectCompiled(label: []const u8, result: BuildResult) !void {
    if (result.compile_ok) return;
    std.debug.print("{s} build did not compile:\n{s}\n", .{ label, result.stderr });
    return error.ExtensionBuildFailed;
}

/// Shared across runs, so a real `zig build-exe` (~7s each) is paid once per
/// snapshot: the next run finds the version already built. Each test's draft
/// still lives in its own tmp dir. Caller closes the handle.
fn sharedVersionStore(io: std.Io) !std.Io.Dir {
    const rel = ".zig-cache" ++ std.fs.path.sep_str ++ "nulya-unit-versions";
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, rel);
    return cwd.openDir(io, rel, .{});
}

test "the probe quotes one line of a subprocess complaint, however it arrives" {
    try std.testing.expectEqualStrings("", firstLine(""));
    try std.testing.expectEqualStrings("", firstLine(" \n\t\n "));
    try std.testing.expectEqualStrings("no build.zig", firstLine("no build.zig\n  you can:\n  1. run"));
    try std.testing.expectEqualStrings("real complaint", firstLine("\n\nreal complaint\nrest"));
    try std.testing.expectEqualStrings("windows says", firstLine("windows says\r\nmore"));
    const long = "x" ** 300;
    try std.testing.expectEqual(@as(usize, 200), firstLine(long).len);
}

test "the spawn probe says what it found, not what it guessed" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    {
        const note = spawnNote(alloc, io, tmp.dir, "whatever", error.AccessDenied).?;
        defer alloc.free(note);
        try std.testing.expectEqualStrings("could not run it: AccessDenied", note);
    }
    {
        const gone = try std.fs.path.join(alloc, &.{ base, "nowhere", "zig" });
        defer alloc.free(gone);
        const note = spawnNote(alloc, io, tmp.dir, gone, error.FileNotFound).?;
        defer alloc.free(note);
        try std.testing.expectEqualStrings("neither that file nor the directory it belongs in exists", note);
    }
    {
        const missing = try std.fs.path.join(alloc, &.{ base, "zig" });
        defer alloc.free(missing);
        const note = spawnNote(alloc, io, tmp.dir, missing, error.FileNotFound).?;
        defer alloc.free(note);
        try std.testing.expectEqualStrings("that directory is there, but it holds no file by that name", note);
    }
    // File there, cwd fine, yet FileNotFound: the probe must not invent absence.
    {
        try tmp.dir.writeFile(io, .{ .sub_path = "zig", .data = "" });
        const present = try std.fs.path.join(alloc, &.{ base, "zig" });
        defer alloc.free(present);
        const note = spawnNote(alloc, io, tmp.dir, present, error.FileNotFound).?;
        defer alloc.free(note);
        try std.testing.expectEqualStrings("could not run it: FileNotFound", note);
    }
}

test "missing manifest is a clear error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "ext");
    var zig = Zig.init("zig");
    defer zig.deinit(alloc);
    try std.testing.expectError(
        error.ManifestUnreadable,
        buildExtension(alloc, std.testing.io, tmp.dir, "ext", tmp.dir, &zig),
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
    var zig = Zig.init(zig_exe);
    defer zig.deinit(alloc);
    var result = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
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

    var zig = Zig.init("zig");
    defer zig.deinit(std.testing.allocator);
    try std.testing.expectError(error.SkillFileMissing, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, &zig));
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

    var zig = Zig.init("zig");
    defer zig.deinit(std.testing.allocator);
    try std.testing.expectError(error.SkillNameDoesNotMatchDirectory, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, &zig));
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

    var zig = Zig.init("zig");
    defer zig.deinit(std.testing.allocator);
    try std.testing.expectError(error.DuplicateSkillName, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, &zig));
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
    var zig = Zig.init(zig_exe);
    defer zig.deinit(alloc);
    var dest = try sharedVersionStore(io);
    defer dest.close(io);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", dest, &zig);
    defer first.deinit(alloc);
    try expectCompiled("first", first);

    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "helper.zig", .data = "pub const value = 2;\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", dest, &zig);
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
    var zig = Zig.init(zig_exe);
    defer zig.deinit(alloc);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
    defer first.deinit(alloc);

    try tmp.dir.writeFile(io, .{ .sub_path = skill_rel, .data = "---\nname: demo\ndescription: demo skill\n---\nversion two\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
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
    var zig = Zig.init(zig_exe);
    defer zig.deinit(alloc);
    var dest = try sharedVersionStore(io);
    defer dest.close(io);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", dest, &zig);
    defer first.deinit(alloc);
    try expectCompiled("first", first);

    try tmp.dir.writeFile(io, .{ .sub_path = test_rel, .data = "two\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", dest, &zig);
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
    var zig = Zig.init(zig_exe);
    defer zig.deinit(alloc);
    var result = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
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

    var zig = Zig.init("");
    defer zig.deinit(alloc);
    var without = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
    defer without.deinit(alloc);
    try std.testing.expect(without.compile_ok);

    // The SAME version id: the compiler is not part of a data identity.
    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var real_zig = Zig.init(zig_exe);
    defer real_zig.deinit(alloc);
    var with = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &real_zig);
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

    var zig = Zig.init("");
    defer zig.deinit(alloc);
    var without = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
    defer without.deinit(alloc);
    try std.testing.expect(without.compile_ok);
    try std.testing.expect(without.entry_rel == null); // a script has no built binary

    const zig_exe = try testZigExe(alloc);
    defer alloc.free(zig_exe);
    var real_zig = Zig.init(zig_exe);
    defer real_zig.deinit(alloc);
    var with = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &real_zig);
    defer with.deinit(alloc);
    try std.testing.expect(with.already_built);
    try std.testing.expectEqualStrings(without.version, with.version);
}

test "naming a target for a package that has no binary is refused" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ manifest_file, .data =
        \\{"schema":"nulya.extension/v2","id":"skills","contributes":{"skills":["skills/demo"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ext" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "demo" ++ std.fs.path.sep_str ++ "SKILL.md", .data = "---\nname: demo\ndescription: demo\n---\nbody\n" });

    var zig = Zig.init("");
    defer zig.deinit(alloc);
    try std.testing.expectError(error.TargetNotApplicable, buildExtensionFor(
        alloc,
        io,
        tmp.dir,
        "ext",
        tmp.dir,
        &zig,
        .{ .target = .{ .arch = .x86_64, .os = .linux } },
    ));
    // Nothing was written on the way to refusing.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "skills", .{}));
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
    var zig = Zig.init(zig_exe);
    defer zig.deinit(alloc);
    var first = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
    defer first.deinit(alloc);

    try tmp.dir.writeFile(io, .{ .sub_path = prompt_rel, .data = "version two\n" });
    var second = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
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
    var zig = Zig.init(zig_exe);
    defer zig.deinit(alloc);
    var result = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
    defer result.deinit(alloc);

    const prompt_path = try std.fs.path.join(alloc, &.{ "prompts", "versions", result.version, package_dir, "prompts", "base.md" });
    defer alloc.free(prompt_path);
    try tmp.dir.writeFile(io, .{ .sub_path = prompt_path, .data = "tampered\n" });
    const version_rel = try std.fs.path.join(alloc, &.{ "prompts", "versions", result.version });
    defer alloc.free(version_rel);
    try std.testing.expectError(error.VersionSealInvalid, integrity.validateVersionDir(alloc, io, tmp.dir, version_rel, result.version, "prompts", .sealed));
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

    var zig = Zig.init("zig");
    defer zig.deinit(alloc);
    try std.testing.expectError(error.SkillFileTooLarge, buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig));
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

    var zig = Zig.init("zig");
    defer zig.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidUtf8, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, &zig));
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

    var zig = Zig.init("zig");
    defer zig.deinit(alloc);
    try std.testing.expectError(error.SystemPromptTooLarge, buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig));
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

    var zig = Zig.init("zig");
    defer zig.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidUtf8, buildExtension(std.testing.allocator, io, tmp.dir, "ext", tmp.dir, &zig));
}
