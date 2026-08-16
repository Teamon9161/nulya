//! Extension version store — immutable versions + atomic activate/rollback
//! (DESIGN §7.4).
//!
//! Nulya never overwrites a running tool's binary. Every build produces an
//! IMMUTABLE version whose id is `hash(package_snapshot + compiler + target)`;
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
//!         package/src/...       # frozen runtime source, when runtime exists
//!         package/skills/...    # frozen declared skill directories
//!         bin/<entry>           # only when the manifest declares runtime
//!     current              # text file holding "v-<hash>"
//!     .lock                # writer lease: held while build / activate / deactivate mutate <id>/
//!
//! `current` is a plain file, not a symlink: symlinks need privilege on Windows
//! and buy nothing here.
//!
//! A root — the user store above all — is shared by every workspace on the
//! machine, so two processes can build or activate the same id at once. Every
//! mutation of `<id>/` (a build writing `versions/<v>`, an activate rewriting
//! `current` through `.current.tmp`, a deactivate) runs under `<id>/.lock`, an
//! exclusive advisory lease taken blocking for the mutation's duration — the
//! same primitive as the session writer's `<id>.lock`. Readers take nothing:
//! `current` flips atomically and a version directory is validated by its seal.

const std = @import("std");
const manifest = @import("manifest.zig");
const integrity = @import("integrity.zig");
const testkit = @import("testkit.zig");

pub const version_prefix = integrity.version_prefix;
/// The workspace-level store root, relative to the workspace — the first root
/// of every search (`Roots`, DESIGN §7.2) and the default for a session that
/// names no others.
pub const workspace_root_rel = ".nulya/extensions";
const current_file = "current";
const lock_file = ".lock";
const versions_dir = "versions";
const exe_suffix = integrity.exe_suffix;

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
    pub fn versionRuntimeEntryPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, rt: manifest.Runtime) ![]u8 {
        if (manifest.isScript(rt)) return self.versionScriptEntryPath(alloc, id, version, rt.entry);
        return self.versionEntryPath(alloc, id, version, rt.entry);
    }

    pub fn versionExists(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) bool {
        validateBuiltVersion(self, alloc, id, version) catch return false;
        return true;
    }

    /// Take `<id>/.lock`, the writer lease every mutation of `<id>/` runs under
    /// (build, activate, rollback, deactivate). Blocking: the critical sections
    /// are short and a second writer wants the result, not a refusal. Creates
    /// `<id>/` when missing. Closing the returned handle releases the lease.
    pub fn lease(self: Store, alloc: std.mem.Allocator, id: []const u8) !std.Io.File {
        if (!manifest.isValidId(id)) return error.InvalidId;
        try self.root.createDirPath(self.io, id);
        const sub = try std.fs.path.join(alloc, &.{ id, lock_file });
        defer alloc.free(sub);
        return self.root.createFile(self.io, sub, .{ .truncate = false, .read = true, .lock = .exclusive });
    }

    /// Point `current` at `version`. Refuses to activate a version that was never
    /// fully built. The write is atomic (temp file + rename in the same directory),
    /// so a crash mid-switch leaves the previous `current` intact.
    pub fn activate(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
        try validateBuiltVersion(self, alloc, id, version);
        var held = try self.lease(alloc, id);
        defer held.close(self.io);

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
        var held = try self.lease(alloc, id);
        defer held.close(self.io);
        const sub = try std.fs.path.join(alloc, &.{ id, current_file });
        defer alloc.free(sub);
        self.root.deleteFile(self.io, sub) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Parse and validate the frozen manifest of a built version. Fails if the
    /// version does not pass integrity validation. Caller owns the manifest.
    pub fn readManifest(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !manifest.Manifest {
        // Validate directly rather than through `versionExists`: that boolean
        // convenience collapses EVERY error to `false`, including `error.Canceled`,
        // which would then surface as a spurious `VersionIntegrityInvalid`. On a
        // cancellation-sensitive path the real error must propagate unchanged.
        try validateBuiltVersion(self, alloc, id, version);
        const manifest_rel = try self.versionManifestPath(alloc, id, version);
        defer alloc.free(manifest_rel);
        const bytes = try self.root.readFileAlloc(self.io, manifest_rel, alloc, .limited(1 << 20));
        defer alloc.free(bytes);
        var m = try manifest.parse(alloc, bytes);
        errdefer m.deinit();
        try m.validate();
        return m;
    }

    /// The active version id, or null if the extension has none. Caller owns the
    /// returned slice.
    pub fn activeVersion(self: Store, alloc: std.mem.Allocator, id: []const u8) !?[]u8 {
        if (!manifest.isValidId(id)) return error.InvalidId;
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

/// The ordered set of store roots a process searches (DESIGN §7.2): the
/// workspace's `.nulya/extensions`, then the user's `~/.nulya/extensions`, then
/// any `extensions.paths` from a TRUSTED config layer. Order is the whole
/// semantics — **the first root holding an ACTIVE version of an id wins**, so a
/// workspace copy shadows a user-wide one, and a checkout can never add a root
/// (DESIGN §9.5). "Holding" means a `current` pointer: a bare `<id>/` directory
/// with no `current` (a draft, a deactivated copy) shadows nothing — otherwise
/// deactivating in the workspace would silently hide, not reveal, the copy in
/// the next root.
///
/// A root that does not exist is simply absent, not an error: having no
/// user-level store is the normal case. Roots own their opened handles and
/// resolved absolute paths; every id/version below is content-addressed, so
/// which root a frozen version came from never changes what runs — only where
/// it was found.
pub const Roots = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    entries: []Entry,

    pub const Entry = struct {
        /// The configured spec (workspace-relative or absolute), for messages.
        spec: []const u8,
        dir: std.Io.Dir,
        /// Absolute real path — a frozen entry path must survive being spawned
        /// with the workspace as cwd.
        real: []const u8,
    };

    /// One extension as the search order resolves it.
    pub const ActiveEntry = struct {
        id: []const u8,
        /// Index into `entries` of the root that won.
        root: usize,
        version: []const u8,
    };

    /// Open each spec in order, skipping the ones that are not there. `cwd` is
    /// what relative specs resolve against.
    pub fn open(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, specs: []const []const u8) !Roots {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |*e| {
                e.dir.close(io);
                alloc.free(e.real);
            }
            entries.deinit(alloc);
        }
        for (specs) |spec| {
            if (spec.len == 0) continue;
            var dir = openRoot(io, cwd, spec) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => return err,
            };
            errdefer dir.close(io);
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const real = try alloc.dupe(u8, buf[0..try dir.realPath(io, &buf)]);
            errdefer alloc.free(real);
            try entries.append(alloc, .{ .spec = spec, .dir = dir, .real = real });
        }
        return .{ .alloc = alloc, .io = io, .entries = try entries.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Roots) void {
        for (self.entries) |*e| {
            e.dir.close(self.io);
            self.alloc.free(e.real);
        }
        self.alloc.free(self.entries);
    }

    pub fn store(self: *const Roots, index: usize) Store {
        return Store.init(self.io, self.entries[index].dir);
    }

    /// Every extension with an active version, first-root-wins, sorted by id.
    /// Only `current` is read here (cheap); whether that version is usable is
    /// the caller's concern. A directory whose name is not a valid extension id
    /// is not an extension and is skipped; host faults propagate.
    /// Caller owns the slice and each `id`/`version`.
    pub fn listActive(self: *const Roots, alloc: std.mem.Allocator) ![]ActiveEntry {
        var out: std.ArrayList(ActiveEntry) = .empty;
        errdefer freeActive(alloc, out.items);
        for (self.entries, 0..) |entry, root_index| {
            const st = Store.init(self.io, entry.dir);
            var it = entry.dir.iterate();
            while (try it.next(self.io)) |dir_entry| {
                if (dir_entry.kind != .directory) continue;
                if (hasId(out.items, dir_entry.name)) continue; // an earlier root won
                const active = (st.activeVersion(alloc, dir_entry.name) catch |err| switch (err) {
                    error.InvalidId => continue,
                    else => return err,
                }) orelse continue;
                errdefer alloc.free(active);
                const id = try alloc.dupe(u8, dir_entry.name);
                errdefer alloc.free(id);
                try out.append(alloc, .{ .id = id, .root = root_index, .version = active });
            }
        }
        std.mem.sort(ActiveEntry, out.items, {}, struct {
            fn lessThan(_: void, a: ActiveEntry, b: ActiveEntry) bool {
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.lessThan);
        return out.toOwnedSlice(alloc);
    }

    pub fn freeActive(alloc: std.mem.Allocator, list: []ActiveEntry) void {
        for (list) |e| {
            alloc.free(e.id);
            alloc.free(e.version);
        }
        alloc.free(list);
    }

    /// Index of the first root holding a BUILT `version` of `id` (integrity
    /// checked). Content addressing makes every root's copy the same bytes, so
    /// the first one found is as good as any.
    pub fn firstWithVersion(self: *const Roots, alloc: std.mem.Allocator, id: []const u8, version: []const u8) ?usize {
        for (self.entries, 0..) |_, i| {
            if (self.store(i).versionExists(alloc, id, version)) return i;
        }
        return null;
    }

    /// Which root and version an id's `current` resolves to, or null if no root
    /// has one. Caller owns `version`.
    pub const ActiveVersion = struct { root: usize, version: []const u8 };

    pub fn firstActive(self: *const Roots, alloc: std.mem.Allocator, id: []const u8) !?ActiveVersion {
        for (self.entries, 0..) |_, i| {
            const active = try self.store(i).activeVersion(alloc, id) orelse continue;
            return .{ .root = i, .version = active };
        }
        return null;
    }

    fn hasId(list: []const ActiveEntry, id: []const u8) bool {
        for (list) |e| {
            if (std.mem.eql(u8, e.id, id)) return true;
        }
        return false;
    }
};

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

fn validateIdentity(id: []const u8, version: []const u8) !void {
    if (!manifest.isValidId(id)) return error.InvalidId;
    if (!integrity.isVersionId(version)) return error.InvalidVersion;
}

fn validateBuiltVersion(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
    try validateIdentity(id, version);
    const version_rel = try self.versionDir(alloc, id, version);
    defer alloc.free(version_rel);
    try integrity.validateVersionDir(alloc, self.io, self.root, version_rel, version, id);
}

fn writeBuiltVersion(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, marker: []const u8) ![]u8 {
    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","runtime":{{"entry":"bin/demo"}},"contributes":{{"tools":[{{"name":"greet","input":{{}}}}],"skills":[]}},"permissions":{{}}}}
    , .{id});
    defer alloc.free(manifest_bytes);
    const source_bytes = try std.fmt.allocPrint(alloc, "pub fn main() void {{}} // {s}\n", .{marker});
    defer alloc.free(source_bytes);
    return testkit.writeFrozenVersion(alloc, io, root, id, manifest_bytes, &.{.{ .rel = "src/main.zig", .bytes = source_bytes }});
}

fn writeSkillVersion(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, body: []const u8) ![]u8 {
    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","contributes":{{"skills":["skills/demo"]}}}}
    , .{id});
    defer alloc.free(manifest_bytes);
    return testkit.writeFrozenVersion(alloc, io, root, id, manifest_bytes, &.{.{ .rel = "skills/demo/SKILL.md", .bytes = body }});
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

test "activate and rollback move the current pointer atomically" {
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

    // Rollback is just repointing current at the old version.
    try store.rollback(alloc, id, first);
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

    const version = try writeSkillVersion(alloc, io, tmp.dir, "skills", "demo");
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

test "roots search in order: the first root holding an id wins, a missing root is simply absent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two real store roots plus one that does not exist at all.
    try tmp.dir.createDirPath(io, "workspace");
    try tmp.dir.createDirPath(io, "user");
    var ws_root = try tmp.dir.openDir(io, "workspace", .{ .iterate = true });
    defer ws_root.close(io);
    var user_root = try tmp.dir.openDir(io, "user", .{ .iterate = true });
    defer user_root.close(io);

    // `shared` exists in both roots (different bodies -> different versions);
    // `only-user` exists in the user root alone.
    const ws_shared = try writeSkillVersion(alloc, io, ws_root, "shared", "workspace body");
    defer alloc.free(ws_shared);
    const user_shared = try writeSkillVersion(alloc, io, user_root, "shared", "user body");
    defer alloc.free(user_shared);
    const only_user = try writeSkillVersion(alloc, io, user_root, "only-user", "user only");
    defer alloc.free(only_user);
    try Store.init(io, ws_root).activate(alloc, "shared", ws_shared);
    try Store.init(io, user_root).activate(alloc, "shared", user_shared);
    try Store.init(io, user_root).activate(alloc, "only-user", only_user);
    try std.testing.expect(!std.mem.eql(u8, ws_shared, user_shared));

    var tmp_real: [std.fs.max_path_bytes]u8 = undefined;
    const base = tmp_real[0..try tmp.dir.realPath(io, &tmp_real)];
    var roots = try Roots.open(alloc, io, base, &.{ "workspace", "nowhere", "user" });
    defer roots.deinit();
    try std.testing.expectEqual(@as(usize, 2), roots.entries.len); // the absent one is skipped

    const active = try roots.listActive(alloc);
    defer Roots.freeActive(alloc, active);
    try std.testing.expectEqual(@as(usize, 2), active.len);
    // Sorted by id; `shared` resolves to the WORKSPACE copy (first root wins),
    // and the user root still contributes what the workspace does not have.
    try std.testing.expectEqualStrings("only-user", active[0].id);
    try std.testing.expectEqual(@as(usize, 1), active[0].root);
    try std.testing.expectEqualStrings("shared", active[1].id);
    try std.testing.expectEqual(@as(usize, 0), active[1].root);
    try std.testing.expectEqualStrings(ws_shared, active[1].version);

    // Same order for the single-id lookup.
    {
        const found = (try roots.firstActive(alloc, "shared")).?;
        defer alloc.free(found.version);
        try std.testing.expectEqual(@as(usize, 0), found.root);
        try std.testing.expectEqualStrings(ws_shared, found.version);
    }
    try std.testing.expect((try roots.firstActive(alloc, "absent")) == null);
    // A frozen version resolves from whichever root actually holds it — the
    // user root's version is found even though the workspace shadows the id.
    try std.testing.expectEqual(@as(usize, 1), roots.firstWithVersion(alloc, "shared", user_shared).?);
    try std.testing.expectEqual(@as(usize, 0), roots.firstWithVersion(alloc, "shared", ws_shared).?);
    try std.testing.expect(roots.firstWithVersion(alloc, "shared", "v-000000000000000000000000") == null);

    // Shadowing is by ACTIVE copy, not by directory: deactivate the workspace's
    // `shared` (its `<id>/` and versions stay) and the user root's active copy
    // is the one in effect — for the whole listing and for the single lookup.
    try Store.init(io, ws_root).deactivate(alloc, "shared");
    const after = try roots.listActive(alloc);
    defer Roots.freeActive(alloc, after);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    try std.testing.expectEqualStrings("shared", after[1].id);
    try std.testing.expectEqual(@as(usize, 1), after[1].root);
    try std.testing.expectEqualStrings(user_shared, after[1].version);
    {
        const found = (try roots.firstActive(alloc, "shared")).?;
        defer alloc.free(found.version);
        try std.testing.expectEqual(@as(usize, 1), found.root);
    }
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

    return st.readManifest(alloc, id, version);
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
