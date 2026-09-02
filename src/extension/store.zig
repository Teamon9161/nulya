//! Extension version store — immutable versions + one atomic `activate`.
//!
//! A version id is `hash(package_snapshot + compiler + target)`; versions
//! accumulate side by side and `current` selects one by atomic rename, so
//! going back is `activate` pointed at an older version.
//!
//! Layout under the store (`<NULYA_HOME | ~/.nulya>/store`):
//!   <id>/versions/v-<hash>/{extension.json, package/{src,skills}/..., bin/<entry>}
//!   <id>/current  — plain text file naming one version: "v-<hash>".
//!   <id>/.lock    — the writer lease (`lease.extensionStore`).
//!
//! A `current` file also lives in the workspace pointer layer, which holds no
//! versions; the pointer half of this file works on either directory.

const std = @import("std");
const lease_mod = @import("../lease.zig");
const manifest = @import("manifest.zig");
const integrity = @import("integrity.zig");
const testkit = @import("testkit.zig");

pub const version_prefix = integrity.version_prefix;
/// Every read below takes one EXPLICITLY: `.structural` and `.sealed` are
/// different questions, and a default would answer one with the other.
pub const Level = integrity.Level;
const current_file = "current";
const versions_dir = "versions";
const exe_suffix = integrity.exe_suffix;

pub const Store = struct {
    io: std.Io,
    /// The `.nulya/extensions` directory. Caller owns its lifetime.
    root: std.Io.Dir,

    pub fn init(io: std.Io, root: std.Io.Dir) Store {
        return .{ .io = io, .root = root };
    }

    /// Identical inputs -> identical version id.
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

    /// A COMPILED version's built entry (`bin/…` plus the exe suffix). Owned.
    pub fn versionEntryPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, entry: []const u8) ![]u8 {
        _ = self;
        try validateIdentity(id, version);
        const entry_rel = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entry, exe_suffix });
        defer alloc.free(entry_rel);
        return std.fs.path.join(alloc, &.{ id, versions_dir, version, entry_rel });
    }

    /// A SCRIPT version's frozen entry, inside `package/` and with no exe
    /// suffix. Caller owns the result.
    pub fn versionScriptEntryPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, entry: []const u8) ![]u8 {
        _ = self;
        try validateIdentity(id, version);
        return std.fs.path.join(alloc, &.{ id, versions_dir, version, integrity.package_dir, entry });
    }

    /// The version's entry, dispatching on runtime kind. Caller owns it.
    ///
    /// `error.EntryUnsupportedOnHost` when the frozen manifest declares entries
    /// per OS and names none for this one — a valid version that simply does
    /// not run here, so its own error rather than an integrity fault.
    pub fn versionRuntimeEntryPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, rt: manifest.Runtime) ![]u8 {
        const entry = rt.entry.forHost() orelse return error.EntryUnsupportedOnHost;
        if (manifest.isScript(rt)) return self.versionScriptEntryPath(alloc, id, version, entry);
        return self.versionEntryPath(alloc, id, version, entry);
    }

    pub fn versionExists(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, level: Level) bool {
        validateBuiltVersion(self, alloc, id, version, level) catch return false;
        return true;
    }

    /// Held for the whole of a build, activate or deactivate; closing the
    /// returned handle releases it.
    pub fn lease(self: Store, alloc: std.mem.Allocator, id: []const u8) !std.Io.File {
        if (!manifest.isValidId(id)) return error.InvalidId;
        return lease_mod.extensionStore(alloc, self.io, self.root, id);
    }

    /// Refuses a version that was never fully built.
    pub fn activate(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
        return self.activateInto(alloc, id, version, self.root);
    }

    /// The same, recording the choice in `pointer_root` — the workspace pointer
    /// layer. The lease and the `.sealed` check always belong to the store
    /// holding the BYTES, and leasing comes FIRST so a version another process
    /// is still building parks the caller instead of drawing a spurious refusal.
    pub fn activateInto(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, pointer_root: std.Io.Dir) !void {
        var held = try self.lease(alloc, id);
        defer held.close(self.io);
        var m = try self.readManifest(alloc, id, version, .sealed);
        defer m.deinit();
        return pointTo(self.io, alloc, pointer_root, id, version);
    }

    /// Drop THIS store's `current` under its writer lease. The versions stay.
    pub fn deactivate(self: Store, alloc: std.mem.Allocator, id: []const u8) !void {
        var held = try self.lease(alloc, id);
        defer held.close(self.io);
        return self.dropPointer(alloc, id);
    }

    /// Takes no lease — for a caller that already holds the store's.
    pub fn dropPointer(self: Store, alloc: std.mem.Allocator, id: []const u8) !void {
        if (!manifest.isValidId(id)) return error.InvalidId;
        const sub = try std.fs.path.join(alloc, &.{ id, current_file });
        defer alloc.free(sub);
        self.root.deleteFile(self.io, sub) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Parse and validate a built version's frozen manifest at `level`; caller
    /// owns it. `.structural` is what a listing wants (is this complete, and
    /// what does it declare), `.sealed` what running or freezing these bytes
    /// wants. Nothing here picks for the caller.
    pub fn readManifest(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, level: Level) !manifest.Manifest {
        // Not through `versionExists`: that boolean collapses every error to
        // `false`, including `error.Canceled`, which must propagate.
        try validateIdentity(id, version);
        const version_rel = try self.versionDir(alloc, id, version);
        defer alloc.free(version_rel);
        return integrity.openVersion(alloc, self.io, self.root, version_rel, version, id, level);
    }

    /// The only reader of that file; null if this root has none. Trailing
    /// columns a later build may add are ignored, so an old binary reads a new
    /// pointer. Caller owns the result.
    pub fn activeVersion(self: Store, alloc: std.mem.Allocator, id: []const u8) !?[]u8 {
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
        return try alloc.dupe(u8, version);
    }

    /// "Which package bytes these are" — the key `findSealed` matches on.
    /// Caller owns the result.
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
    /// bytes built for `target` — and, when the caller names one, by that
    /// compiler. Null when this root holds no such version; caller owns it.
    ///
    /// Without a compiler identity several builds of one source can match, so
    /// the search runs over SORTED version ids: which copy answers must not
    /// depend on directory listing order. A half-written or broken version
    /// directory is skipped; host faults propagate.
    ///
    /// The check is `.structural`, not `.sealed`: whoever is about to run or
    /// freeze these bytes validates them itself, and re-digesting every built
    /// binary here would hash the whole store on every `ext sync --dry-run`.
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

    /// All built version ids for `id`, in no guaranteed order. Caller owns the
    /// outer slice and each entry.
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

/// Faults meaning "this directory is not a usable extension". What a caller
/// does with one is its own rule: a listing skips it, composition fails on it,
/// a lookup keeps searching. Anything else — cancellation, `OutOfMemory`, real
/// I/O failures — is a host fault and must propagate.
///
/// Derived by reflection from `manifest.zig`'s error sets, so a new
/// `ValidateError` member is covered the moment it is added.
pub fn isExtensionFault(err: anyerror) bool {
    // Both manifest sets: a mistyped field is as broken a draft as one failing
    // a rule. `OutOfMemory` arrives via `Allocator.Error` and is a host fault.
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

/// Creating it and its parents if absent — what the WRITE side needs, so a
/// machine with no store gets one the first time something is built into it.
/// Read paths use `openRoot`, which skips what is absent.
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

/// Open the extensions root directory (iterable) resolved against `cwd`.
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

/// Atomic: temp file plus a rename in the same directory, so a crash mid-switch
/// leaves the previous pointer intact. Creates `<id>/` when the layer has never
/// held this id.
fn pointTo(io: std.Io, alloc: std.mem.Allocator, root: std.Io.Dir, id: []const u8, version: []const u8) !void {
    try root.createDirPath(io, id);
    const tmp_sub = try std.fs.path.join(alloc, &.{ id, ".current.tmp" });
    defer alloc.free(tmp_sub);
    const final_sub = try std.fs.path.join(alloc, &.{ id, current_file });
    defer alloc.free(final_sub);

    const record = try std.fmt.allocPrint(alloc, "{s}\n", .{version});
    defer alloc.free(record);
    try root.writeFile(io, .{ .sub_path = tmp_sub, .data = record });
    try root.rename(tmp_sub, root, final_sub, io);
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

test "current names one version, and a pointer with extra columns still names it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(io, tmp.dir);

    const plain = try testkit.writeSkillVersion(alloc, io, tmp.dir, "plain", "body");
    defer alloc.free(plain);
    try store.activate(alloc, "plain", plain);
    {
        const active = (try store.activeVersion(alloc, "plain")).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings(plain, active);
    }

    // The first field is the pointer; trailing columns are not this reader's.
    const with_columns = try std.fmt.allocPrint(alloc, "{s} something=else\n", .{plain});
    defer alloc.free(with_columns);
    try tmp.dir.writeFile(io, .{ .sub_path = "plain/current", .data = with_columns });
    const active = (try store.activeVersion(alloc, "plain")).?;
    defer alloc.free(active);
    try std.testing.expectEqualStrings(plain, active);
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

    // Tampered: the directory is still COMPLETE (all a listing asks), but no
    // longer the bytes that were sealed.
    try tmp.dir.writeFile(io, .{ .sub_path = entry_sub, .data = "tampered" });
    try std.testing.expect(store.versionExists(alloc, "demo", version, .structural));
    try std.testing.expect(!store.versionExists(alloc, "demo", version, .sealed));
    {
        var m = try store.readManifest(alloc, "demo", version, .structural);
        defer m.deinit();
        try std.testing.expectEqualStrings("demo", m.id);
    }
    try std.testing.expectError(error.VersionSealInvalid, store.readManifest(alloc, "demo", version, .sealed));

    // Missing entirely: incomplete, so BOTH refuse. Structural is about
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

    {
        var dir = try openOrCreateRoot(io, base, "nested" ++ std.fs.path.sep_str ++ "extensions");
        dir.close(io);
        try tmp.dir.access(io, "nested" ++ std.fs.path.sep_str ++ "extensions", .{});
    }
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

/// Test-only: consume the first cancelation at a deterministic gate, re-arm it
/// via `io.recancel()`, then call `readManifest` so the pending cancelation
/// lands on its first filesystem syscall. `recancel` must never appear in
/// production control flow, which propagates `error.Canceled` instead.
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

    // `.sealed` does the most I/O, the widest surface to land on.
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
    // Cancel only once the worker is known to sit at the gate.
    try ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) });

    // Cancellation is host execution control, not corruption: it must surface
    // as error.Canceled, never as a Version* integrity error.
    try std.testing.expectError(error.Canceled, fut.cancel(io));
}
