//! Ordered store-root search (DESIGN §7.2).
//!
//! `store.zig` owns ONE root — its version directories, its `current` pointer,
//! its writer lease. This file owns the order in which a process consults
//! SEVERAL of them, and nothing else: which root answers for an id, which root
//! holds a named frozen version, and the single `Resolved` every caller shares,
//! so session composition, `nulya ext run` and the skill loader cannot drift on
//! search order or on where a frozen entry lives.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("manifest.zig");
// `Roots.store` is a method, so the module import carries a distinct name
// rather than being shadowed inside the struct body.
const ext_store = @import("store.zig");
const testkit = @import("testkit.zig");

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
        /// What the winning root's `current` recorded about `apply`
        /// (`store.Active.standing`): this version was activated here as a
        /// member of every fresh session (DESIGN §5.1). Carried along because
        /// it comes from the same read as the version and is the ONLY
        /// trustworthy answer to that question — see `Store.readCurrent`.
        /// Defaults to false for the callers that assemble an entry to resolve
        /// ONE named id: that path is not asking this question.
        standing: bool = false,
    };

    /// The single answer to `id[@version] -> root -> manifest -> entry path`.
    /// Session composition, `nulya ext run`, and the skill loader all ask for it
    /// through `resolveActive` / `resolveVersion`, so none of them can drift on
    /// search order (DESIGN §7.2) or on where a frozen entry lives (§7.4).
    pub const Resolved = struct {
        /// Owned.
        id: []const u8,
        /// Owned.
        version: []const u8,
        /// Owned; parsed AND validated, from a version directory checked to the
        /// `Level` the caller asked for.
        manifest: manifest.Manifest,
        /// Index into `Roots.entries` of the root this version was taken from.
        root: usize,

        pub fn deinit(self: Resolved, alloc: std.mem.Allocator) void {
            alloc.free(self.id);
            alloc.free(self.version);
            var m = self.manifest;
            m.deinit();
        }

        /// Absolute path of this version's runtime entry — a compiled binary
        /// under `bin/` or a frozen script under `package/`, per the runtime
        /// kind. Absolute because an extension is spawned with the WORKSPACE as
        /// cwd, which is not this process's cwd. Caller owns the result.
        pub fn entryPathAbs(self: Resolved, alloc: std.mem.Allocator, roots: *const Roots) ![]u8 {
            const rt = self.manifest.runtime orelse return error.MissingRuntime;
            const entry_rel = roots.store(self.root).versionRuntimeEntryPath(alloc, self.id, self.version, rt) catch |err| {
                // The one line that carries what `EntryUnsupportedOnHost` cannot
                // (the `reportBrokenActive` precedent in `composition.zig`): a
                // Zig error has no payload, and "which package, and on which
                // host" is the whole of what the reader has to know. Best
                // effort — a failure to say it never changes the failure.
                if (err == error.EntryUnsupportedOnHost) reportEntryUnsupported(roots.io, self.id, self.version);
                return err;
            };
            defer alloc.free(entry_rel);
            return std.fs.path.join(alloc, &.{ roots.entries[self.root].real, entry_rel });
        }
    };

    /// Name the package a per-OS `runtime.entry` does not cover on this machine
    /// (DESIGN §7.1). stderr, so `session step --stream` keeps stdout pure JSON —
    /// the channel `composition.reportBrokenActive` and the kernel-drift warning
    /// already use. Silent under `builtin.is_test` for that function's reason:
    /// unit tests construct this state on purpose and assert the error, and a
    /// repair line about a tmp store reads as advice about a real one.
    fn reportEntryUnsupported(io: std.Io, id: []const u8, version: []const u8) void {
        if (builtin.is_test) return;
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "extension {s}@{s} declares no runtime entry for {s}; see `nulya ext inspect {s}@{s}`\n",
            .{ id, version, @tagName(builtin.os.tag), id, version },
        ) catch return;
        std.Io.File.stderr().writeStreamingAll(io, line) catch {};
    }

    /// The version an id's `current` selects, first active root winning
    /// (`firstActive`), with its validated manifest. Null when no root points at
    /// one. Host faults — cancellation above all — propagate unchanged: only a
    /// missing `current` is "not there".
    pub fn resolveActive(self: *const Roots, alloc: std.mem.Allocator, id: []const u8, level: ext_store.Level) !?Resolved {
        const active = (try self.firstActive(alloc, id)) orelse return null;
        defer alloc.free(active.version);
        return try self.resolveAt(alloc, active.root, id, active.version, level);
    }

    /// A named built version, taken from the first root that holds a USABLE
    /// copy (root order, as `firstWithVersion`) — versions are content-addressed,
    /// so every root's copy is the same bytes and only "where it was found"
    /// differs. A root whose copy is absent or broken (any `isExtensionFault`:
    /// a half-written `versions/<v>/` left by a crash, a bad seal) is skipped
    /// rather than allowed to shadow a good copy further down the search order.
    /// If no root yields one, the FIRST such fault is returned — the most
    /// specific thing known about why — or `error.VersionNotFound` when no root
    /// held it at all. Host faults (cancellation, OOM, real I/O) propagate at
    /// once and are never softened into "not found".
    pub fn resolveVersion(self: *const Roots, alloc: std.mem.Allocator, id: []const u8, version: []const u8, level: ext_store.Level) !Resolved {
        var first_fault: ?anyerror = null;
        for (self.entries, 0..) |_, i| {
            return self.resolveAt(alloc, i, id, version, level) catch |err| {
                if (!ext_store.isExtensionFault(err)) return err;
                // "Absent here" is the ordinary case and says nothing; a broken
                // copy is worth reporting if no later root saves the lookup.
                if (err != error.VersionNotFound and first_fault == null) first_fault = err;
                continue;
            };
        }
        return first_fault orelse error.VersionNotFound;
    }

    /// The `Resolved` for an entry `listActive` already decided, without asking
    /// the search order a second time: no repeated `current` read, and no window
    /// in which an activate between listing and lookup swaps the version under
    /// the caller.
    pub fn resolveEntry(self: *const Roots, alloc: std.mem.Allocator, entry: ActiveEntry, level: ext_store.Level) !Resolved {
        return self.resolveAt(alloc, entry.root, entry.id, entry.version, level);
    }

    fn resolveAt(self: *const Roots, alloc: std.mem.Allocator, root: usize, id: []const u8, version: []const u8, level: ext_store.Level) !Resolved {
        var m = try self.store(root).readManifest(alloc, id, version, level);
        errdefer m.deinit();
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_version = try alloc.dupe(u8, version);
        return .{ .id = owned_id, .version = owned_version, .manifest = m, .root = root };
    }

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
            var dir = ext_store.openRoot(io, cwd, spec) catch |err| switch (err) {
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

    pub fn store(self: *const Roots, index: usize) ext_store.Store {
        return ext_store.Store.init(self.io, self.entries[index].dir);
    }

    /// Every extension with an active version, first-root-wins, sorted by id.
    /// Only `current` is read here (cheap) — the version it names and the
    /// `apply` it recorded; whether that version is usable is the caller's
    /// concern. A directory whose name is not a valid extension id
    /// is not an extension and is skipped; host faults propagate.
    /// Caller owns the slice and each `id`/`version`.
    pub fn listActive(self: *const Roots, alloc: std.mem.Allocator) ![]ActiveEntry {
        var out: std.ArrayList(ActiveEntry) = .empty;
        errdefer freeActive(alloc, out.items);
        for (self.entries, 0..) |entry, root_index| {
            const st = ext_store.Store.init(self.io, entry.dir);
            var it = entry.dir.iterate();
            while (try it.next(self.io)) |dir_entry| {
                if (dir_entry.kind != .directory) continue;
                if (hasId(out.items, dir_entry.name)) continue; // an earlier root won
                const active = (st.readCurrent(alloc, dir_entry.name) catch |err| switch (err) {
                    error.InvalidId => continue,
                    else => return err,
                }) orelse continue;
                errdefer alloc.free(active.version);
                const id = try alloc.dupe(u8, dir_entry.name);
                errdefer alloc.free(id);
                try out.append(alloc, .{ .id = id, .root = root_index, .version = active.version, .standing = active.standing });
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

    /// The sibling of `<id>@<version>` built for ANOTHER machine: the version,
    /// in root order, whose seal records the same package bytes for
    /// `target_words`. Null when no root holds one; caller owns the result.
    ///
    /// This is how a session whose tools run elsewhere learns which frozen
    /// implementation will actually serve its calls (`exec_version`, DESIGN §3.4,
    /// goals/remote-env.md §3.1). The two versions are ONE package that differs
    /// only in what it was compiled for, and `(package_digest, target)` is
    /// already the key a donor copy matches on — so this asks `Store.findSealed`,
    /// the same matcher a build asks about its own machine.
    ///
    /// No compiler is named: which zig produced the copy for that machine is not
    /// something this session gets to require, and the sorted search inside
    /// `findSealed` keeps the answer deterministic when several qualify.
    pub fn resolveForTarget(
        self: *const Roots,
        alloc: std.mem.Allocator,
        id: []const u8,
        version: []const u8,
        target_words: []const u8,
    ) !?[]u8 {
        var digest: ?[]u8 = null;
        defer if (digest) |d| alloc.free(d);
        for (self.entries, 0..) |_, i| {
            digest = self.store(i).readPackageDigest(alloc, id, version) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory => return err,
                else => continue,
            };
            break;
        }
        const package_digest = digest orelse return null;

        for (self.entries, 0..) |_, i| {
            if (try self.store(i).findSealed(alloc, id, package_digest, target_words, null)) |found| return found;
        }
        return null;
    }

    /// Index of the first root holding a BUILT `version` of `id`, validated to
    /// `level`. Content addressing makes every root's copy the same bytes, so
    /// the first one found is as good as any.
    pub fn firstWithVersion(self: *const Roots, alloc: std.mem.Allocator, id: []const u8, version: []const u8, level: ext_store.Level) ?usize {
        for (self.entries, 0..) |_, i| {
            if (self.store(i).versionExists(alloc, id, version, level)) return i;
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
    const ws_shared = try testkit.writeSkillVersion(alloc, io, ws_root, "shared", "workspace body");
    defer alloc.free(ws_shared);
    const user_shared = try testkit.writeSkillVersion(alloc, io, user_root, "shared", "user body");
    defer alloc.free(user_shared);
    const only_user = try testkit.writeSkillVersion(alloc, io, user_root, "only-user", "user only");
    defer alloc.free(only_user);
    try ext_store.Store.init(io, ws_root).activate(alloc, "shared", ws_shared);
    try ext_store.Store.init(io, user_root).activate(alloc, "shared", user_shared);
    try ext_store.Store.init(io, user_root).activate(alloc, "only-user", only_user);
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
    try std.testing.expectEqual(@as(usize, 1), roots.firstWithVersion(alloc, "shared", user_shared, .sealed).?);
    try std.testing.expectEqual(@as(usize, 0), roots.firstWithVersion(alloc, "shared", ws_shared, .sealed).?);
    try std.testing.expect(roots.firstWithVersion(alloc, "shared", "v-000000000000000000000000", .sealed) == null);

    // Shadowing is by ACTIVE copy, not by directory: deactivate the workspace's
    // `shared` (its `<id>/` and versions stay) and the user root's active copy
    // is the one in effect — for the whole listing and for the single lookup.
    try ext_store.Store.init(io, ws_root).deactivate(alloc, "shared");
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

    // `Resolved` is the same order plus the validated manifest — the one lookup
    // every caller shares.
    {
        const r = (try roots.resolveActive(alloc, "shared", .sealed)).?;
        defer r.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), r.root);
        try std.testing.expectEqualStrings(user_shared, r.version);
        try std.testing.expectEqualStrings("shared", r.manifest.id);
    }
    {
        // A named version comes from whichever root holds it, active or not.
        const r = try roots.resolveVersion(alloc, "shared", ws_shared, .sealed);
        defer r.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), r.root);
        try std.testing.expectEqualStrings(ws_shared, r.version);
    }
    try std.testing.expect((try roots.resolveActive(alloc, "absent", .sealed)) == null);
    try std.testing.expectError(error.VersionNotFound, roots.resolveVersion(alloc, "shared", "v-000000000000000000000000", .sealed));

    // A BROKEN copy in an earlier root does not shadow a good one further down:
    // a crash can leave a half-written `versions/<v>/` (here: no seal at all),
    // and the content-addressed copy in the next root is the same bytes.
    try ext_store.Store.init(io, ws_root).ensureVersionDir(alloc, "shared", user_shared);
    {
        const r = try roots.resolveVersion(alloc, "shared", user_shared, .sealed);
        defer r.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), r.root);
    }
    // When NO root yields a usable copy, the broken one's own fault is what the
    // caller hears — not a bare "not found".
    try ext_store.Store.init(io, ws_root).ensureVersionDir(alloc, "shared", "v-111111111111111111111111");
    try std.testing.expectError(error.VersionSealInvalid, roots.resolveVersion(alloc, "shared", "v-111111111111111111111111", .sealed));
}
