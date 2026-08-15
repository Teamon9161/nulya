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
//!
//! `current` is a plain file, not a symlink: symlinks need privilege on Windows
//! and buy nothing here.

const std = @import("std");
const manifest = @import("manifest.zig");
const integrity = @import("integrity.zig");
const testkit = @import("testkit.zig");

pub const version_prefix = integrity.version_prefix;
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

    /// Root-relative path of a version's built entry binary. Caller owns the result.
    pub fn versionEntryPath(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8, entry: []const u8) ![]u8 {
        _ = self;
        try validateIdentity(id, version);
        const entry_rel = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entry, exe_suffix });
        defer alloc.free(entry_rel);
        return std.fs.path.join(alloc, &.{ id, versions_dir, version, entry_rel });
    }

    pub fn versionExists(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) bool {
        validateBuiltVersion(self, alloc, id, version) catch return false;
        return true;
    }

    /// Point `current` at `version`. Refuses to activate a version that was never
    /// fully built. The write is atomic (temp file + rename in the same directory),
    /// so a crash mid-switch leaves the previous `current` intact.
    pub fn activate(self: Store, alloc: std.mem.Allocator, id: []const u8, version: []const u8) !void {
        try validateBuiltVersion(self, alloc, id, version);

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
        if (!manifest.isValidId(id)) return error.InvalidId;
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
    ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) }) catch {};

    // Cancellation is host execution control, not corruption: it must surface as
    // error.Canceled, never as VersionNotFound/VersionSealInvalid/Version*.
    try std.testing.expectError(error.Canceled, fut.cancel(io));
}
