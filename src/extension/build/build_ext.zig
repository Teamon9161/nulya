//! `nulya ext build` — compile an extension into an immutable version (DESIGN
//! §7.4, §10).
//!
//! The AI never runs `zig build` itself. This module fixes every knob (zig
//! identity, optimize, target, output location) so a given package snapshot maps
//! to the same content-addressed version id and the build is reproducible.
//!
//! The Zig executable is injected rather than resolved here: production wires in
//! `toolchain.ensureExtracted` (the managed toolchain), while tests can wire in
//! the host's own zig — so the whole close-the-loop path is testable without the
//! ~90MB embed.

const std = @import("std");
const builtin = @import("builtin");
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

/// One line per manifest shape this draft writes that the current schema no
/// longer does. Each is harmless to the build — a removed key is an unknown
/// key, and an old spelling is folded by `manifest.parse` — but silence would
/// leave the author believing something still reads what they wrote.
///
/// stderr, so `ext build`'s stdout stays the version id a caller parses, and
/// `reportBrokenActive`'s reason: the id belongs in the sentence and an error
/// code cannot carry it. Best effort — a note that cannot be printed never
/// fails a build.
fn noteLegacyShapes(alloc: std.mem.Allocator, io: std.Io, m: manifest.Manifest) !void {
    // Unit tests build packages with these shapes on purpose to assert they
    // are accepted; the real binary (e2e included) always prints them.
    if (builtin.is_test) return;
    // Reach is the person's decision now, not the author's (DESIGN §7.2.1).
    if (m.legacy_activation) try noteLegacyShape(alloc, io, m.id, "still declares \"activation\"; that key is no longer read — a package joins every session only when [extensions] with in config names it");
    // A declaration nothing enforced; the shape a sandbox needs is the
    // sandbox's to decide (PLAN §3.8).
    if (m.legacy_permissions) try noteLegacyShape(alloc, io, m.id, "still declares \"permissions\"; that key is no longer read — an unenforced footprint was ceremony, and a sandbox will define its own shape");
    if (m.legacy_command_action) try noteLegacyShape(alloc, io, m.id, "writes a command \"action\" as a string; write the object instead — {\"with\": true}, {\"run\": \"<tool>\"}, {\"skill\": \"<ref>\"}. The string is read for one more version");
    if (m.legacy_ui) try noteLegacyShape(alloc, io, m.id, "writes \"contributes.ui\" without a host; key it by front end instead — {\"tui\": {\"entry\": …, \"api\": …}}. The flat form is read as \"tui\" for one more version");
    // One wire now, so a runtime no longer picks one. The two words a draft may
    // still carry asked for different things, so each is answered in its own.
    if (m.legacy_wire) |w| {
        if (std.mem.eql(u8, w, "plain"))
            try noteLegacyShape(alloc, io, m.id, "still declares \"runtime.wire\"; that key is no longer needed — plain is the one wire every call speaks")
        else
            try noteLegacyShape(alloc, io, m.id, "still declares \"runtime.wire\"; that wire is gone and this runtime will be called the plain way: stdin is the arguments object, stdout verbatim is the result, and the exit code is success — see `nulya ext api protocol`");
    }
}

fn noteLegacyShape(alloc: std.mem.Allocator, io: std.Io, id: []const u8, what: []const u8) !void {
    const line = try std.fmt.allocPrint(alloc, "note: {s} {s}\n", .{ id, what });
    defer alloc.free(line);
    std.Io.File.stderr().writeStreamingAll(io, line) catch {};
}

pub const BuildResult = struct {
    /// The manifest's id — which `<id>/` under the store root this landed in.
    /// The draft's directory name does not have to be it (DESIGN §7.4), and a
    /// caller that has to name what it just built (`activate`, a listing) needs
    /// the id the store actually used.
    id: []u8,
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
        alloc.free(self.id);
        alloc.free(self.version);
        if (self.entry_rel) |entry_rel| alloc.free(entry_rel);
        alloc.free(self.stderr);
    }
};

/// Whether a call is allowed to WRITE. `plan` answers the same question every
/// other way — which version this draft is, whether the destination root already
/// has it, which other root could supply it — and then stops, so `ext sync
/// --dry-run` and `ext sync` cannot disagree about what a build would do.
pub const Mode = enum { build, plan };

/// The compiler a run of builds uses: which executable, plus its identity
/// (`zig version`) asked of the host AT MOST ONCE.
///
/// The identity enters every compiled version id (DESIGN §7.4), so every build
/// needs it — and getting it is a subprocess. `ext sync` builds every draft in a
/// root, which used to mean one `zig version` spawn per compiled draft for an
/// answer that cannot change mid-run.
///
/// The probe runs with the build's `workspace` as its cwd, and a version-manager
/// shim answers differently from different directories (DESIGN §10) — so one
/// value belongs to one run over one workspace, which is exactly how `ext build`
/// (one draft) and `ext sync` (every draft under one root) use it.
pub const Zig = struct {
    /// The executable to invoke. Empty means "this machine named none", which is
    /// not fatal until something actually has to compile.
    exe: []const u8,
    probed: bool = false,
    /// Owned once probed; null means the host could not name its compiler.
    identity: ?[]u8 = null,
    /// Why the probe could not name it, in the host's own words — owned, and
    /// null unless `identity` is null for a reason worth repeating.
    ///
    /// `ZigVersionUnreadable` is one name over three different walls: the
    /// executable would not run, it ran and failed, or it ran and said nothing.
    /// Each wants a different thing done about it, and the caller prints a
    /// sentence a person is supposed to act on — so the reason travels with the
    /// failure instead of dying at the `catch` that noticed it.
    failure: ?[]u8 = null,

    pub fn init(exe: []const u8) Zig {
        return .{ .exe = exe };
    }

    pub fn deinit(self: *Zig, alloc: std.mem.Allocator) void {
        if (self.identity) |id| alloc.free(id);
        if (self.failure) |why| alloc.free(why);
        self.* = undefined;
    }

    /// What stopped the probe, or null when nothing did (or when saying so ran
    /// out of memory — a missing note never turns into a missing failure).
    pub fn whyUnreadable(self: *const Zig) ?[]const u8 {
        return self.failure;
    }

    /// `zig <version>`, or null when this machine cannot name its compiler —
    /// which only widens the search for an existing version, and is fatal just
    /// where a compile is unavoidable. Borrowed; owned by the `Zig`.
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
    zig: *Zig,
) !BuildResult {
    return buildExtensionReusing(alloc, io, workspace, ext_dir_rel, dest_root, zig, &.{});
}

/// What `buildExtensionReusing` WOULD do, without doing any of it: the same
/// manifest, the same snapshot, the same searches, no writes. `already_built`
/// then means "the destination root already holds it", `copied_from` "that donor
/// could supply it", and neither set means "this would be produced here".
/// `error.ZigVersionUnreadable` still means what it means at build time — a
/// compiled draft this machine can neither name nor adopt.
pub fn planExtension(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    dest_root: std.Io.Dir,
    zig: *Zig,
    donors: []const std.Io.Dir,
) !BuildResult {
    return build(alloc, io, workspace, ext_dir_rel, dest_root, zig, donors, .plan);
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
    zig: *Zig,
    donors: []const std.Io.Dir,
) !BuildResult {
    return build(alloc, io, workspace, ext_dir_rel, dest_root, zig, donors, .build);
}

fn build(
    alloc: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    ext_dir_rel: []const u8,
    dest_root: std.Io.Dir,
    zig: *Zig,
    donors: []const std.Io.Dir,
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
    try noteLegacyShapes(alloc, io, m);

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
    const compiler: ?[]const u8 = if (compiled) try zig.resolve(alloc, io, workspace) else "";

    // From here on `<id>/` is mutated (a stale directory deleted, a version
    // written): hold the id's writer lease so two builds of one id in a shared
    // root — the user store — serialize instead of tearing each other's tree.
    // A plan writes nothing, and taking the lease would itself create `<id>/`.
    var held: ?std.Io.File = if (mode == .build) try store.Store.init(io, dest_root).lease(alloc, m.id) else null;
    defer if (held) |*h| h.close(io);

    // `entry_rel` is the BUILT binary path — compiled extensions only. A script's
    // entry is frozen inside `package/` and located via `store.versionScriptEntryPath`.
    // A compiled entry is never per-OS (`manifest.validate` refuses the object
    // form for `bin/` paths), so the host's variant is the one that was written.
    const declared_entry: []const u8 = if (compiled)
        m.runtime.?.entry.forHost() orelse return error.EntryUnsupportedOnHost
    else
        "";
    const entry_rel: ?[]u8 = if (compiled)
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ declared_entry, exe_suffix })
    else
        null;
    errdefer if (entry_rel) |entry| alloc.free(entry);

    if (try findMatchingVersion(alloc, io, dest_root, m.id, package_digest, target, compiler)) |found| {
        return sealed(alloc, m.id, found, entry_rel, true, null);
    }
    for (donors, 0..) |donor, donor_index| {
        const found = (try findMatchingVersion(alloc, io, donor, m.id, package_digest, target, compiler)) orelse continue;
        errdefer alloc.free(found);
        if (mode == .plan) return sealed(alloc, m.id, found, entry_rel, false, donor_index);
        if (!try adoptVersionDir(alloc, io, donor, dest_root, m.id, found)) {
            alloc.free(found);
            continue;
        }
        return sealed(alloc, m.id, found, entry_rel, false, donor_index);
    }

    // Nothing to adopt: this build has to produce the version itself, which for a
    // compiled package is precisely where a toolchain stops being optional.
    const compiler_id = compiler orelse return error.ZigVersionUnreadable;
    const version = try integrity.versionId(alloc, snapshot_bytes, compiler_id, target);
    errdefer alloc.free(version);
    if (mode == .plan) return sealed(alloc, m.id, version, entry_rel, false, null);

    // Store layout, not draft layout: `<id>/versions/<v>` under the store root.
    const version_rel = try std.fs.path.join(alloc, &.{ m.id, "versions", version });
    defer alloc.free(version_rel);
    dest_root.deleteTree(io, version_rel) catch {};

    // Data or script: freeze the snapshot, seal with no binary, done — nothing to
    // compile.
    if (!compiled) {
        try integrity.freezeSnapshot(alloc, io, dest_root, version_rel, manifest_bytes, snapshot);
        try writeSeal(alloc, io, dest_root, version_rel, package_digest, compiler_id, target, null);
        return sealed(alloc, m.id, version, entry_rel, false, null);
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

    // Fixed, reproducible invocation — the AI gets no say in the flags. Compile
    // from the frozen package, never the mutable draft tree. Source and output
    // are both inside the version directory, so the store root is the cwd.
    const result = std.process.run(alloc, io, .{
        .argv = &.{ zig.exe, "build-exe", frozen_source, "-O", "ReleaseSafe", emit_arg, "--name", std.fs.path.stem(declared_entry) },
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

    return sealed(alloc, m.id, version, entry_rel, false, null);
}

/// A successful result, taking ownership of `version` and `entry_rel`.
fn sealed(
    alloc: std.mem.Allocator,
    id: []const u8,
    version: []u8,
    entry_rel: ?[]u8,
    already_built: bool,
    copied_from: ?usize,
) !BuildResult {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    return .{
        .id = owned_id,
        .version = version,
        .entry_rel = entry_rel,
        .already_built = already_built,
        .copied_from = copied_from,
        .compile_ok = true,
        .stderr = try alloc.alloc(u8, 0),
    };
}

/// The first line of `text`, trimmed and clipped — enough of a subprocess's
/// complaint to recognize it by, on one line of somebody's terminal.
fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    // Trimmed again: the line a CRLF host hands over ends in a carriage
    // return, and that byte inside a sentence is a mangled terminal.
    const line = std.mem.trim(u8, trimmed[0..end], " \t\r");
    return line[0..@min(line.len, 200)];
}

/// One `access`, kept as the error it actually was — `null` when the path
/// answered. The error NAME is the part worth keeping: "not there" and "there,
/// but this process cannot reach it" are different facts about the machine.
fn accessError(io: std.Io, dir: std.Io.Dir, path: []const u8) ?anyerror {
    if (dir.access(io, path, .{})) |_| return null else |e| return e;
}

/// What a failed spawn actually means, asked of the filesystem rather than
/// guessed from the error name.
///
/// Windows answers `FileNotFound` for BOTH a missing executable and a missing
/// working directory, and those are opposite repairs — install a toolchain,
/// versus find out why the directory this build runs in went away. The name
/// alone cannot separate them, so the two get looked up.
///
/// The lookup is then reported as what it found, never rounded to the likeliest
/// story. "Not there at all" and "there, but this process cannot reach it" are
/// different facts and different repairs, and a person told the wrong one goes
/// and looks, finds the opposite, and starts distrusting the sentence instead
/// of the machine. So the answers stay separate — including the one where the
/// probe finds nothing wrong and hands back the bare error name.
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
        // Missing for real. Whether its directory is there too decides between
        // "nothing was ever unpacked" and "the toolchain lost its executable".
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
/// with `why` set to what stopped it.
///
/// The three failures are three different repairs — the executable would not
/// run at all (a path that is not there, a file something else has open, a
/// spawn the OS refused), it ran and exited non-zero (a version-manager shim
/// that wants a `build.zig.zon` it cannot find from this cwd says exactly
/// this, and says so ON STDERR), or it ran and printed nothing. One error name
/// covers all three, so the account travels out through `why`: without it the
/// person reading `could not report its version` cannot tell "install a
/// toolchain" from "something is holding your zig.exe", and both sentences end
/// in the same shrug.
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
        // past 4 KB never reaches the exit code, and that is worth telling
        // apart from a spawn the OS refused.
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
        // The seal claims these are our bytes; `.structural` checks the version
        // directory is complete enough to be that answer. The full re-digest is
        // not this lookup's job: in the DESTINATION root the answer is "already
        // built" and whatever consumes it (composition, `ext run`) validates
        // `.sealed` itself, and a DONOR's copy is re-validated `.sealed` after
        // it is copied in (`adoptVersionDir`). Digesting here instead would make
        // `ext sync --dry-run` re-hash every built binary on every run.
        integrity.validateVersionDir(alloc, io, root, version_rel, v, id, .structural) catch |err| {
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

    // `.sealed`: this is a WRITE of bytes that came from somewhere else. The one
    // moment worth the full digest — it is what lets every later read of this
    // copy be structural.
    integrity.validateVersionDir(alloc, io, dest_root, version_rel, version, id, .sealed) catch |err| {
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

/// Every `contributes.ui` entry names a module some front end loads (DESIGN
/// §7.2.1, tui-plugin D10) — a declared path this build must actually be able
/// to freeze, the same existence half `validateSystemPrompts` checks for a
/// system prompt file. EVERY host's, not just the one this machine happens to
/// run: one version serves them all, so the build is the only chance to notice
/// that a declared module was never written (`validateScriptEntries`' reason).
/// No size ceiling here: `prompt.max_system_prompt_bytes` bounds what is fed to
/// a MODEL, and this file never is (it is front-end source, read by a plugin
/// host, not by `prompt.zig`).
fn validateUi(alloc: std.mem.Allocator, m: manifest.Manifest, snapshot: integrity.PackageSnapshot) !void {
    for (m.ui) |u| {
        const rel = try integrity.canonicalRel(alloc, u.entry);
        defer alloc.free(rel);
        _ = integrity.findSnapshotFile(snapshot, rel) orelse return error.UiEntryFileMissing;
    }
}

/// EVERY declared script entry is in the snapshot — not just this host's
/// (DESIGN §7.1, §7.4). `validateSystemPrompts`' existence half, applied to a
/// field that can now name several files: a per-OS entry freezes one version for
/// all platforms, so the machine that builds it is the only chance to notice
/// that the Windows variant was never written. A compiled entry is skipped here
/// because it does not exist yet — the build is what produces it.
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

// `firstLine` is what a person actually reads when a toolchain probe fails,
// so it has to survive whatever a subprocess prints: nothing, several lines,
// or a wall of them. It clips rather than wraps because the caller puts it
// inside one sentence on one line.
test "the probe quotes one line of a subprocess complaint, however it arrives" {
    try std.testing.expectEqualStrings("", firstLine(""));
    try std.testing.expectEqualStrings("", firstLine(" \n\t\n "));
    try std.testing.expectEqualStrings("no build.zig", firstLine("no build.zig\n  you can:\n  1. run"));
    // Trimmed first, so a leading blank line is not the "first" line.
    try std.testing.expectEqualStrings("real complaint", firstLine("\n\nreal complaint\nrest"));
    // CRLF: the carriage return goes with the trim, not into the quote.
    try std.testing.expectEqualStrings("windows says", firstLine("windows says\r\nmore"));
    // One very long line is clipped, never wrapped into the sentence around it.
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

    // A spawn that failed for a nameable reason is quoted, not investigated:
    // the filesystem has nothing to add to `AccessDenied`.
    {
        const note = spawnNote(alloc, io, tmp.dir, "whatever", error.AccessDenied).?;
        defer alloc.free(note);
        try std.testing.expectEqualStrings("could not run it: AccessDenied", note);
    }
    // Nothing unpacked: the directory is missing too, and saying so separates
    // "install a toolchain" from "the toolchain lost its executable".
    {
        const gone = try std.fs.path.join(alloc, &.{ base, "nowhere", "zig" });
        defer alloc.free(gone);
        const note = spawnNote(alloc, io, tmp.dir, gone, error.FileNotFound).?;
        defer alloc.free(note);
        try std.testing.expectEqualStrings("neither that file nor the directory it belongs in exists", note);
    }
    // The directory is there and empty — a different repair, a different line.
    {
        const missing = try std.fs.path.join(alloc, &.{ base, "zig" });
        defer alloc.free(missing);
        const note = spawnNote(alloc, io, tmp.dir, missing, error.FileNotFound).?;
        defer alloc.free(note);
        try std.testing.expectEqualStrings("that directory is there, but it holds no file by that name", note);
    }
    // The file IS there and the cwd is fine, yet the spawn said FileNotFound.
    // The probe must not invent an absence: it hands back the plain error, and
    // whoever reads it goes looking for what holds the file open.
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

    // No toolchain at all: a data extension never compiles, so build succeeds.
    var zig = Zig.init("");
    defer zig.deinit(alloc);
    var without = try buildExtension(alloc, io, tmp.dir, "ext", tmp.dir, &zig);
    defer without.deinit(alloc);
    try std.testing.expect(without.compile_ok);

    // Building again with a real compiler present yields the SAME version id: the
    // compiler is not part of a data version's identity.
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
