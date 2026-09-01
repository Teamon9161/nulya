//! Extension version store — immutable versions + one atomic `activate`.
//!
//! Every build produces an immutable version, id
//! `hash(package_snapshot + compiler + target)`; versions accumulate side by
//! side and a `current` pointer selects the active one via atomic rename, so
//! going back is just `activate` pointed at an older version.
//!
//! Layout under a store root (`.nulya/extensions`):
//!   <id>/versions/v-<hash>/{extension.json, package/{src,skills}/..., bin/<entry>}
//!   <id>/current  — plain text file: "v-<hash> apply=<auto|manual>". `apply`
//!                   is written by `activate` from the manifest it just
//!                   verified against the seal, not re-read from
//!                   `extension.json` later — an edit cannot change it.
//!   <id>/.lock    — writer lease held by build / activate / deactivate.

const std = @import("std");
const manifest = @import("manifest.zig");
const integrity = @import("integrity.zig");
const testkit = @import("testkit.zig");

pub const version_prefix = integrity.version_prefix;
/// How hard a caller wants a frozen version checked (`integrity.Level`). Every
/// read below takes one EXPLICITLY: a read-only projection asking for
/// `.structural` and a session freeze asking for `.sealed` are different
/// questions, and a default would silently answer one with the other.
pub const Level = integrity.Level;
/// The workspace-level store root, relative to the workspace — the first root
/// of every search (`Roots`) and the default for a session that names no
/// others.
pub const workspace_root_rel = ".nulya/extensions";
const current_file = "current";
const lock_file = ".lock";
const versions_dir = "versions";
const exe_suffix = integrity.exe_suffix;
/// The prefix of `current`'s second column (`apply=auto` / `apply=manual`).
/// Spelled out so a person reading the file knows what the word is about.
const apply_key = "apply=";

/// What a root's `current` pointer says — see `Store.readCurrent`, which is the
/// only thing that reads that file.
pub const Active = struct {
    /// The version `current` names. Owned by the caller.
    version: []u8,
    /// The version above declared `apply: "auto"` when `activate` verified and
    /// recorded it: this package is a member of every fresh session in this
    /// workspace. False for a pointer written without the record.
    standing: bool,
};

pub const Store = struct {
    io: std.Io,
    /// The `.nulya/extensions` directory. Caller owns its lifetime.
    root: std.Io.Dir,

    pub fn init(io: std.Io, root: std.Io.Dir) Store {
        return .{ .io = io, .root = root };
    }

    /// Inputs that make a build reproducible; identical inputs -> identical
    /// version id.
    pub const VersionInputs = struct {
        snapshot: []const u8,
        compiler: []const u8,
        target: []const u8,
    };

    /// `v-<hex>`. Pure function of the inputs — no I/O. Caller owns the result.
    pub fn versionId(alloc: std.mem.Allocator, inputs: VersionInputs) ![]u8 {
        return integrity.versionId(alloc, inputs.snapshot, inputs.compiler, inputs.target);
    }

    /// Create `<id>/versions/<version>/bin/` (and parents). Idempotent.
    pub fn ensureVersionDir(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
        try validateIdentity(id, version);
        const sub = try std.fs.path.join(alloc, &.{ id, versions_dir, version, "bin" });
        defer alloc.free(sub);
        try self.root.createDirPath(self.io, sub);
    }

    /// Root-relative path of a version directory. Caller owns the result.
    pub fn versionDir(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) ![]u8 {
        _ = self;
        try validateIdentity(id, version);
        return std.fs.path.join(alloc, &.{ id, versions_dir, version });
    }

    /// Root-relative path of a version's frozen manifest. Caller owns the result.
    pub fn versionManifestPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) ![]u8 {
        _ = self;
        try validateIdentity(id, version);
        return std.fs.path.join(alloc, &.{ id, versions_dir, version, "extension.json" });
    }

    /// Root-relative path of a COMPILED version's built entry binary (`bin/<name>`
    /// plus the platform exe suffix). Caller owns the result.
    pub fn versionEntryPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, entry: []const u8) ![]u8 {
        _ = self;
        try validateIdentity(id, version);
        const entry_rel = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entry, exe_suffix });
        defer alloc.free(entry_rel);
        return std.fs.path.join(alloc, &.{ id, versions_dir, version, entry_rel });
    }

    /// Root-relative path of a SCRIPT version's frozen entry (inside `package/`,
    /// no exe suffix). Caller owns the result.
    pub fn versionScriptEntryPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, entry: []const u8) ![]u8 {
        _ = self;
        try validateIdentity(id, version);
        return std.fs.path.join(alloc, &.{ id, versions_dir, version, integrity.package_dir, entry });
    }

    /// Root-relative path of the version's entry, dispatching on runtime kind.
    /// Caller owns the result.
    ///
    /// `error.EntryUnsupportedOnHost` when the frozen manifest declares entries
    /// per OS and names none for this one — a real state of a perfectly valid
    /// version (the package simply does not run here), so its own error rather
    /// than an integrity fault.
    pub fn versionRuntimeEntryPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, rt: manifest.Runtime) ![]u8 {
        const entry = rt.entry.forHost() orelse return error.EntryUnsupportedOnHost;
        if (manifest.isScript(rt)) return self.versionScriptEntryPath(alloc, id, version, entry);
        return self.versionEntryPath(alloc, id, version, entry);
    }

    pub fn versionExists(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, level: Level) bool {
        validateBuiltVersion(self, alloc, id, version, level) catch return false;
        return true;
    }

    /// Take `<id>/.lock`, the writer lease every mutation of `<id>/` runs under
    /// (build, activate, deactivate). Blocking, and held for the whole
    /// mutation — for a compiled build that is the entire `zig build-exe`,
    /// since a second writer wants the result, not a refusal. Creates `<id>/`
    /// when missing. Closing the returned handle releases the lease.
    pub fn lease(self: Store, alloc: std.mem.Allocator, id: []const u8) !std.Io.File {
        if (!manifest.isValidId(id)) return error.InvalidId;
        try self.root.createDirPath(self.io, id);
        const sub = try std.fs.path.join(alloc, &.{ id, lock_file });
        defer alloc.free(sub);
        return self.root.createFile(self.io, sub, .{ .truncate = false, .read = true, .lock = .exclusive });
    }

    /// Point `current` at `version`, and record what that version declares about
    /// `apply` (see `Active`). Refuses to activate a version that was never fully
    /// built. The write is atomic (temp file + rename in the same directory), so
    /// a crash mid-switch leaves the previous `current` — pointer AND record —
    /// intact. One file, one rename: the two can never disagree, so there is no
    /// third state for a reader to interpret.
    pub fn activate(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
        // Lease first, then validate: validating outside the lease could read
        // a version another process is still building and report a spurious
        // refusal where waiting for the build would have succeeded.
        var held = try self.lease(alloc, id);
        defer held.close(self.io);
        // `.sealed`: this is what makes the `apply` record below trustworthy —
        // the manifest it is read from is, at this instant, proven sealed.
        var m = try self.readManifest(alloc, id, version, .sealed);
        defer m.deinit();

        const tmp_sub = try std.fs.path.join(alloc, &.{ id, ".current.tmp" });
        defer alloc.free(tmp_sub);
        const final_sub = try std.fs.path.join(alloc, &.{ id, current_file });
        defer alloc.free(final_sub);

        const record = try std.fmt.allocPrint(alloc, "{s} {s}{s}\n", .{ version, apply_key, @tagName(m.applyOf()) });
        defer alloc.free(record);
        try self.root.writeFile(self.io, .{ .sub_path = tmp_sub, .data = record });
        try self.root.rename(tmp_sub, self.root, final_sub, self.io);
    }

    pub fn deactivate(self: Store, alloc: std.mem.Allocator, id: []const u8) !void {
        var held = try self.lease(alloc, id);
        defer held.close(self.io);
        const sub = try std.fs.path.join(alloc, &.{ id, current_file });
        defer alloc.free(sub);
        self.root.deleteFile(self.io, sub) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Parse and validate the frozen manifest of a built version at `level`.
    /// Fails if the version does not pass validation at that level. Caller owns
    /// the manifest.
    ///
    /// `.structural` is what a listing wants (is this a complete version, and
    /// what does it declare); `.sealed` is what running or freezing these bytes
    /// wants. Nothing here picks for the caller.
    pub fn readManifest(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, level: Level) !manifest.Manifest {
        // Validate directly rather than through `versionExists`: that boolean
        // convenience collapses every error to `false`, including
        // `error.Canceled`, which must propagate unchanged instead.
        try validateIdentity(id, version);
        const version_rel = try self.versionDir(alloc, id, version);
        defer alloc.free(version_rel);
        return integrity.openVersion(alloc, self.io, self.root, version_rel, version, id, level);
    }

    /// Everything `<id>/current` says: which version this root activates, and
    /// whether `activate` recorded that version as declaring `apply: "auto"`
    /// (see the module doc). Null when this root has no `current` for the id.
    /// Caller owns `version`.
    ///
    /// A `current` with no `apply=` column at all — written before this column
    /// existed — reads as `false`: an unknown is not a claim, and the repair is
    /// one `nulya ext activate <id> <version>`.
    pub fn readCurrent(self: Store, alloc: std.mem.Allocator, id: []const u8) !?Active {
        if (!manifest.isValidId(id)) return error.InvalidId;
        const sub = try std.fs.path.join(alloc, &.{ id, current_file });
        defer alloc.free(sub);
        const raw = self.root.readFileAlloc(self.io, sub, alloc, .limited(256)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer alloc.free(raw);
        var fields = std.mem.tokenizeAny(u8, raw, " \t\r\n");
        const version = fields.next() orelse return null;
        var standing = false;
        while (fields.next()) |field| {
            if (!std.mem.startsWith(u8, field, apply_key)) continue;
            standing = manifest.Apply.fromString(field[apply_key.len..]) == .auto;
        }
        return .{ .version = try alloc.dupe(u8, version), .standing = standing };
    }

    /// The active version id, or null if the extension has none — `readCurrent`
    /// for the callers that only move or name versions. Caller owns the
    /// returned slice.
    pub fn activeVersion(self: Store, alloc: std.mem.Allocator, id: []const u8) !?[]u8 {
        const active = (try self.readCurrent(alloc, id)) orelse return null;
        return active.version;
    }

    /// The package digest a built version's seal records — "which package bytes
    /// these are", the key `findSealed` matches on. Caller owns the result.
    pub fn readPackageDigest(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) ![]u8 {
        try validateIdentity(id, version);
        const version_rel = try self.versionDir(alloc, id, version);
        defer alloc.free(version_rel);
        const seal_sub = try std.fs.path.join(alloc, &.{ version_rel, integrity.seal_file });
        defer alloc.free(seal_sub);
        const bytes = self.root.readFileAlloc(self.io, seal_sub, alloc, .limited(1 << 20)) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return error.VersionNotFound,
        };
        defer alloc.free(bytes);
        var seal = integrity.parseSeal(alloc, bytes) catch return error.VersionSealInvalid;
        defer seal.deinit();
        return alloc.dupe(u8, seal.package_digest);
    }

    /// The built version of `id` in this root whose seal records THESE package
    /// bytes built for `target` — and, when the caller can name one, by that
    /// compiler. Used both by a build asking about its own machine ("have I
    /// already produced this?") and by a session whose tools run elsewhere
    /// ("which of my versions can that machine run?") — same key, one matcher.
    ///
    /// Without a compiler identity several builds of one source can match, one
    /// per compiler that ever produced it, so the search runs over sorted
    /// version ids: which copy answers must not depend on directory listing
    /// order. A half-written or otherwise broken version directory is skipped
    /// rather than reported; host faults propagate. Null when this root holds
    /// no such version. Caller owns the result.
    ///
    /// The check is `.structural`, not `.sealed`: the caller that is about to
    /// run or freeze these bytes validates them itself, and re-digesting every
    /// built binary here would make `ext sync --dry-run` hash the whole store
    /// on every run.
    pub fn findSealed(
        self: Store,
        alloc: std.mem.Allocator,
        id: []const u8,
        package_digest: []const u8,
        target: []const u8,
        compiler: ?[]const u8,
    ) !?[]u8 {
        const versions = self.listVersions(alloc, id) catch |err| switch (err) {
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
            const version_rel = try self.versionDir(alloc, id, v);
            defer alloc.free(version_rel);
            const seal_sub = try std.fs.path.join(alloc, &.{ version_rel, integrity.seal_file });
            defer alloc.free(seal_sub);
            const bytes = self.root.readFileAlloc(self.io, seal_sub, alloc, .limited(1 << 20)) catch |err| switch (err) {
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
            integrity.validateVersionDir(alloc, self.io, self.root, version_rel, v, id, .structural) catch |err| {
                if (!isExtensionFault(err)) return err;
                continue;
            };
            return try alloc.dupe(u8, v);
        }
        return null;
    }

    /// All built version ids for `id`, newest-first order not guaranteed. Caller
    /// owns the outer slice and each entry.
    pub fn listVersions(self: Store, alloc: std.mem.Allocator, id: []const u8) ![]const []u8 {
        if (!manifest.isValidId(id)) return error.InvalidId;
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
            if (!integrity.isVersionId(entry.name)) continue;
            try out.append(alloc, try alloc.dupe(u8, entry.name));
        }
        return out.toOwnedSlice(alloc);
    }
};

/// Store/manifest faults that mean "this directory is not a usable extension".
/// What a caller does with one is the caller's rule: a read-only listing skips
/// it, session composition fails on it, and a version lookup skips that root
/// and keeps searching. Anything else — host cancellation, `OutOfMemory`, real
/// I/O failures — is a host fault and must propagate.
///
/// Derived from the error sets `manifest.zig` declares (plus the version/
/// store-integrity errors below) by reflection rather than a hand-written
/// `switch`, so a new `manifest.ValidateError` member is covered here
/// automatically instead of silently propagating as a host fault until
/// someone notices and adds a case.
pub fn isExtensionFault(err: anyerror) bool {
    // Both manifest sets, not just `ValidateError`: `ParseError` carries
    // manifest-shape refusals of its own (a mistyped field is as much a broken
    // draft as one that fails a rule). `OutOfMemory` (via `Allocator.Error`)
    // is skipped below — the doc comment's host-fault rule.
    const Faults = manifest.ParseError || manifest.ValidateError ||
        error{
            InvalidVersion,
            VersionNotFound,
            VersionSealInvalid,
            VersionManifestIdMismatch,
            VersionPackageMissing,
            VersionEntryNotFound,
        };
    inline for (@typeInfo(Faults).error_set.?) |candidate| {
        if (comptime std.mem.eql(u8, candidate.name, "OutOfMemory")) continue;
        if (err == @field(anyerror, candidate.name)) return true;
    }
    return false;
}

// A reflection-driven check, not a hand-copied list: it walks the SAME
// manifest error sets `isExtensionFault` reflects over, so it can never
// itself drift the way the old hand-written `switch` did. Any future
// `ParseError` or `ValidateError` member is covered the moment it is added
// to `manifest.zig` — this test needs no edit to keep pinning the invariant.
test "isExtensionFault covers every manifest parse/validate member, but never OOM" {
    inline for (@typeInfo(manifest.ParseError || manifest.ValidateError).error_set.?) |candidate| {
        if (comptime std.mem.eql(u8, candidate.name, "OutOfMemory")) continue;
        const err = @field(anyerror, candidate.name);
        std.testing.expect(isExtensionFault(err)) catch |e| {
            std.debug.print("manifest error {s} is not treated as an extension fault\n", .{candidate.name});
            return e;
        };
    }
    try std.testing.expect(!isExtensionFault(error.OutOfMemory));
}

/// Open a store root, creating it (and its parents) if it is not there yet —
/// what the WRITE side needs (`ext init`, `ext build`): a machine with no
/// `~/.nulya/extensions` yet should get one the first time something is built
/// into it. Read paths use `openRoot` / `Roots.open`, which skip what is absent.
pub fn openOrCreateRoot(io: std.Io, cwd: []const u8, spec: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(spec)) {
        try std.Io.Dir.cwd().createDirPath(io, spec);
        return std.Io.Dir.openDirAbsolute(io, spec, .{ .iterate = true });
    }
    var workspace = if (std.fs.path.isAbsolute(cwd))
        try std.Io.Dir.openDirAbsolute(io, cwd, .{})
    else
        try std.Io.Dir.cwd().openDir(io, cwd, .{});
    defer workspace.close(io);
    try workspace.createDirPath(io, spec);
    return workspace.openDir(io, spec, .{ .iterate = true });
}

/// Open the extensions root directory (iterable) resolved against `cwd`. Shared
/// by session composition and capability-note reconciliation.
pub fn openRoot(io: std.Io, cwd: []const u8, ext_root_rel: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(ext_root_rel)) {
        return std.Io.Dir.openDirAbsolute(io, ext_root_rel, .{ .iterate = true });
    }
    var workspace = if (std.fs.path.isAbsolute(cwd))
        try std.Io.Dir.openDirAbsolute(io, cwd, .{})
    else
        try std.Io.Dir.cwd().openDir(io, cwd, .{});
    defer workspace.close(io);
    return workspace.openDir(io, ext_root_rel, .{ .iterate = true });
}

fn lessThanVersion(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn validateIdentity(id: []const u8, version: []const u8) !void {
    if (!manifest.isValidId(id)) return error.InvalidId;
    if (!integrity.isVersionId(version)) return error.InvalidVersion;
}

fn validateBuiltVersion(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, level: Level) !void {
    try validateIdentity(id, version);
    const version_rel = try self.versionDir(alloc, id, version);
    defer alloc.free(version_rel);
    try integrity.validateVersionDir(alloc, self.io, self.root, version_rel, version, id, level);
}

fn writeBuiltVersion(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, marker: []const u8) ![]u8 {
    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","runtime":{{"entry":"bin/demo"}},"contributes":{{"tools":[{{"name":"greet","input":{{}}}}],"skills":[]}}}}
    , .{id});
    defer alloc.free(manifest_bytes);
    const source_bytes = try std.fmt.allocPrint(alloc, "pub fn main() void {{}} // {s}\n", .{marker});
    defer alloc.free(source_bytes);
    return testkit.writeFrozenVersion(alloc, io, root, id, manifest_bytes, &.{.{ .rel = "src/main.zig", .bytes = source_bytes }});
}

fn freeVersions(alloc: std.mem.Allocator, versions: []const []u8) void {
    for (versions) |v| alloc.free(v);
    alloc.free(versions);
}

test "version id is deterministic and inputs-sensitive" {
    const alloc = std.testing.allocator;
    const base: Store.VersionInputs = .{ .snapshot = "extension.json\x02{}", .compiler = "zig 0.16.0", .target = "x86_64-windows" };

    const a = try Store.versionId(alloc, base);
    defer alloc.free(a);
    const b = try Store.versionId(alloc, base);
    defer alloc.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.startsWith(u8, a, "v-"));

    var changed = base;
    changed.snapshot = "extension.json\x02{\"changed\":true}";
    const c = try Store.versionId(alloc, changed);
    defer alloc.free(c);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "current records the apply the activated version declared, and only activate can write it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(io, tmp.dir);

    // Two packages differing in one manifest key.
    const standing_manifest =
        \\{"schema":"nulya.extension/v2","id":"mode","apply":"auto","contributes":{"skills":["skills/demo"]}}
    ;
    const standing = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "mode", standing_manifest, &.{.{ .rel = "skills/demo/SKILL.md", .bytes = "body" }});
    defer alloc.free(standing);
    const plain = try testkit.writeSkillVersion(alloc, io, tmp.dir, "plain", "body");
    defer alloc.free(plain);

    try store.activate(alloc, "mode", standing);
    try store.activate(alloc, "plain", plain);
    {
        const active = (try store.readCurrent(alloc, "mode")).?;
        defer alloc.free(active.version);
        try std.testing.expectEqualStrings(standing, active.version);
        try std.testing.expect(active.standing);
    }
    {
        const active = (try store.readCurrent(alloc, "plain")).?;
        defer alloc.free(active.version);
        try std.testing.expect(!active.standing);
    }

    // Editing the frozen manifest cannot change the record — that is the whole
    // point of recording it. What such an edit DOES do is break
    // the seal, so the version stops resolving, loudly, for whoever composes it.
    const manifest_sub = try store.versionManifestPath(alloc, "mode", standing);
    defer alloc.free(manifest_sub);
    try tmp.dir.writeFile(io, .{ .sub_path = manifest_sub, .data =
        \\{"schema":"nulya.extension/v2","id":"mode","apply":"manual","contributes":{"skills":["skills/demo"]}}
    });
    {
        const active = (try store.readCurrent(alloc, "mode")).?;
        defer alloc.free(active.version);
        try std.testing.expect(active.standing);
    }
    try std.testing.expectError(error.VersionSealInvalid, store.readManifest(alloc, "mode", standing, .sealed));

    // A pointer written before the record existed still names its version, and
    // claims nothing: an unknown is not a claim.
    try tmp.dir.writeFile(io, .{ .sub_path = "plain/current", .data = plain });
    const active = (try store.readCurrent(alloc, "plain")).?;
    defer alloc.free(active.version);
    try std.testing.expectEqualStrings(plain, active.version);
    try std.testing.expect(!active.standing);
}

test "activate moves the current pointer atomically, forwards and back" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(std.testing.io, tmp.dir);

    const id = "demo";
    const first = try writeBuiltVersion(alloc, std.testing.io, tmp.dir, id, "one");
    defer alloc.free(first);
    const second = try writeBuiltVersion(alloc, std.testing.io, tmp.dir, id, "two");
    defer alloc.free(second);

    // No current pointer yet.
    try std.testing.expect((try store.activeVersion(alloc, id)) == null);

    try store.activate(alloc, id, first);
    {
        const active = (try store.activeVersion(alloc, id)).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings(first, active);
    }

    try store.activate(alloc, id, second);
    {
        const active = (try store.activeVersion(alloc, id)).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings(second, active);
    }

    // Going back is the same verb pointed at the older version: there is nothing
    // a separate `rollback` could have done that this does not.
    try store.activate(alloc, id, first);
    {
        const active = (try store.activeVersion(alloc, id)).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings(first, active);
    }
}

test "the id's writer lease serializes mutation: a held lease parks activate until released" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(io, tmp.dir);

    const version = try writeBuiltVersion(alloc, io, tmp.dir, "demo", "one");
    defer alloc.free(version);

    var held = try store.lease(alloc, "demo");
    var fut = try io.concurrent(Store.activate, .{ store, alloc, "demo", version });
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    try std.testing.expect((try store.activeVersion(alloc, "demo")) == null); // still parked

    held.close(io);
    try fut.await(io);
    const active = (try store.activeVersion(alloc, "demo")).?;
    defer alloc.free(active);
    try std.testing.expectEqualStrings(version, active);
}

test "activate refuses an unbuilt version" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(std.testing.io, tmp.dir);
    const built = try writeBuiltVersion(alloc, std.testing.io, tmp.dir, "demo", "one");
    defer alloc.free(built);
    try std.testing.expectError(error.VersionNotFound, store.activate(alloc, "demo", "v-000000000000000000000000"));
}

test "activate refuses an incomplete version directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(std.testing.io, tmp.dir);
    try store.ensureVersionDir(alloc, "demo", "v-111111111111111111111111");
    try std.testing.expectError(error.VersionSealInvalid, store.activate(alloc, "demo", "v-111111111111111111111111"));
}

test "activate accepts a runtime-less skill version" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(io, tmp.dir);

    const version = try testkit.writeSkillVersion(alloc, io, tmp.dir, "skills", "demo");
    defer alloc.free(version);

    try store.activate(alloc, "skills", version);
    const active = (try store.activeVersion(alloc, "skills")).?;
    defer alloc.free(active);
    try std.testing.expectEqualStrings(version, active);
}

test "activate refuses a sealed version whose binary changed" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(io, tmp.dir);

    const version = try writeBuiltVersion(alloc, io, tmp.dir, "demo", "original");
    defer alloc.free(version);
    const exe_name = try std.fmt.allocPrint(alloc, "demo{s}", .{exe_suffix});
    defer alloc.free(exe_name);
    const entry_sub = try std.fs.path.join(alloc, &.{ "demo", versions_dir, version, "bin", exe_name });
    defer alloc.free(entry_sub);
    try tmp.dir.writeFile(io, .{ .sub_path = entry_sub, .data = "tampered" });

    try std.testing.expectError(error.VersionSealInvalid, store.activate(alloc, "demo", version));
}

test "the two levels answer different questions: a tampered binary passes structural and fails sealed; a missing one fails both" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(io, tmp.dir);

    const version = try writeBuiltVersion(alloc, io, tmp.dir, "demo", "original");
    defer alloc.free(version);
    const exe_name = try std.fmt.allocPrint(alloc, "demo{s}", .{exe_suffix});
    defer alloc.free(exe_name);
    const entry_sub = try std.fs.path.join(alloc, &.{ "demo", versions_dir, version, "bin", exe_name });
    defer alloc.free(entry_sub);

    try std.testing.expect(store.versionExists(alloc, "demo", version, .structural));
    try std.testing.expect(store.versionExists(alloc, "demo", version, .sealed));

    // Tampered: the version directory is still COMPLETE (that is all a listing
    // asks), but it is no longer the bytes that were sealed.
    try tmp.dir.writeFile(io, .{ .sub_path = entry_sub, .data = "tampered" });
    try std.testing.expect(store.versionExists(alloc, "demo", version, .structural));
    try std.testing.expect(!store.versionExists(alloc, "demo", version, .sealed));
    // A structural read still yields the frozen manifest — what `ext list` and
    // the skill catalog project.
    {
        var m = try store.readManifest(alloc, "demo", version, .structural);
        defer m.deinit();
        try std.testing.expectEqualStrings("demo", m.id);
    }
    try std.testing.expectError(error.VersionSealInvalid, store.readManifest(alloc, "demo", version, .sealed));

    // Missing entirely: incomplete, so BOTH levels refuse. Structural is about
    // completeness, never about trust.
    try tmp.dir.deleteFile(io, entry_sub);
    try std.testing.expect(!store.versionExists(alloc, "demo", version, .structural));
    try std.testing.expect(!store.versionExists(alloc, "demo", version, .sealed));
}

test "structural validation refuses a version missing a path its manifest declares" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(io, tmp.dir);

    const version = try testkit.writeSkillVersion(alloc, io, tmp.dir, "skills", "demo");
    defer alloc.free(version);
    try std.testing.expect(store.versionExists(alloc, "skills", version, .structural));

    const skill_dir = try std.fs.path.join(alloc, &.{ "skills", versions_dir, version, integrity.package_dir, "skills" });
    defer alloc.free(skill_dir);
    try tmp.dir.deleteTree(io, skill_dir);
    try std.testing.expectError(error.VersionPackageMissing, store.readManifest(alloc, "skills", version, .structural));
}

test "openOrCreateRoot creates a missing root, by absolute path as well as relative" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];

    // Relative to a workspace…
    {
        var dir = try openOrCreateRoot(io, base, "nested" ++ std.fs.path.sep_str ++ "extensions");
        dir.close(io);
        try tmp.dir.access(io, "nested" ++ std.fs.path.sep_str ++ "extensions", .{});
    }
    // …and by absolute path, which is how the user root (`~/.nulya/extensions`)
    // arrives. Both are idempotent.
    const abs = try std.fs.path.join(alloc, &.{ base, "home", "extensions" });
    defer alloc.free(abs);
    for (0..2) |_| {
        var dir = try openOrCreateRoot(io, base, abs);
        dir.close(io);
    }
    try tmp.dir.access(io, "home" ++ std.fs.path.sep_str ++ "extensions", .{});
}

test "listVersions returns every built version" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(std.testing.io, tmp.dir);

    try store.ensureVersionDir(alloc, "demo", "v-aaaaaaaaaaaaaaaaaaaaaaaa");
    try store.ensureVersionDir(alloc, "demo", "v-bbbbbbbbbbbbbbbbbbbbbbbb");

    const versions = try store.listVersions(alloc, "demo");
    defer freeVersions(alloc, versions);
    try std.testing.expectEqual(@as(usize, 2), versions.len);

    const none = try store.listVersions(alloc, "missing");
    defer freeVersions(alloc, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

/// Test-only coordination: consume the first cancelation at a deterministic gate,
/// re-arm it via `io.recancel()`, then call `readManifest` so the pending
/// cancelation lands on its first filesystem syscall. `recancel` must never
/// appear in production control flow, which propagates `error.Canceled` instead.
fn readManifestAfterRecancel(
    alloc: std.mem.Allocator,
    st: Store,
    id: []const u8,
    version: []const u8,
    io: std.Io,
    ready: *std.Io.Event,
    release: *std.Io.Event,
) anyerror!manifest.Manifest {
    ready.set(io);

    release.wait(io) catch |err| switch (err) {
        error.Canceled => io.recancel(),
    };

    // `.sealed` — the level that does the most I/O, so the pending cancelation
    // has the widest surface to land on.
    return st.readManifest(alloc, id, version, .sealed);
}

test "readManifest propagates cancellation instead of folding it into an integrity error" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const version = try writeBuiltVersion(alloc, io, tmp.dir, "demo", "marker");
    defer alloc.free(version);
    const st = Store.init(io, tmp.dir);

    var ready: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    var fut = io.async(readManifestAfterRecancel, .{ alloc, st, "demo", version, io, &ready, &release });
    // Determinism contract: cancel only after the worker is known to sit at the
    // gate. A timeout here means the worker never arrived — fail, don't proceed.
    try ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) });

    // Cancellation is host execution control, not corruption: it must surface as
    // error.Canceled, never as VersionNotFound/VersionSealInvalid/Version*.
    try std.testing.expectError(error.Canceled, fut.cancel(io));
}
