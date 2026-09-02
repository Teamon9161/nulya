//! One store, two pointer layers.
//!
//! Built version BYTES live in exactly one directory per machine:
//! `<NULYA_HOME | ~/.nulya>/store/<id>/versions/<v>/`. A workspace holds only
//! drafts and, optionally, a `current` pointer of its own under
//! `.nulya/extensions/<id>/`; it never holds versions.
//!
//! A workspace pointer wins over the store's; with neither, the id is not
//! activated here. So a pointer answers exactly one question — which version
//! `<id>` means — and never "whose bytes", which content addressing already
//! settled.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("manifest.zig");
const ext_store = @import("store.zig");
const testkit = @import("testkit.zig");
const integrity = @import("integrity.zig");

/// The workspace's drafts and its pointer layer, relative to the workspace.
pub const workspace_rel = ".nulya/extensions";

/// Which `current` a pointer is written to or read from. `workspace` is
/// `.nulya/extensions/<id>/current`, `user` is `<store>/<id>/current`.
pub const Layer = enum {
    workspace,
    user,

    /// The word `ext list` prints and `ext activate --user` selects.
    pub fn label(self: Layer) []const u8 {
        return @tagName(self);
    }
};

/// Where a repair line goes.
///
/// A Zig error carries no payload, so which package, which version and the verb
/// that fixes it have to be SAID separately or lost. The kernel never picks a
/// destination for that sentence: a shell that has one passes a sink in, and the
/// default reports nothing — which is what a unit test wants, since it builds a
/// broken store on purpose and asserts the error.
///
/// Stateless sinks are the point of passing `io` at report time rather than
/// holding it: the one the CLI installs is a constant, so nothing here owns a
/// lifetime that could outlive the `Site` it was copied into.
pub const Diag = struct {
    ptr: ?*anyopaque = null,
    reportFn: ?*const fn (ptr: ?*anyopaque, io: std.Io, line: []const u8) void = null,

    pub fn report(self: Diag, io: std.Io, line: []const u8) void {
        const f = self.reportFn orelse return;
        f(self.ptr, io, line);
    }
};

pub const Site = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// The workspace everything relative resolves against, owned.
    cwd: []const u8,
    /// Where the one store is, owned: the resolved real path once the
    /// directory exists, and the configured path until then. Empty only when
    /// this machine has no home directory at all, so nothing can be built.
    store_path: []const u8,
    store_dir: ?std.Io.Dir,
    ws_dir: ?std.Io.Dir,
    /// Where this site says what an error cannot carry. Reports nothing by
    /// default.
    diag: Diag = .{},

    pub const Pointer = struct { layer: Layer, version: []const u8 };
    pub const ActiveEntry = struct { id: []const u8, layer: Layer, version: []const u8 };

    /// The single answer to `id[@version] -> manifest -> entry path`. Session
    /// composition, `nulya ext run` and the skill loader all ask for it here,
    /// so none of them can drift on where a frozen entry lives.
    pub const Resolved = struct {
        /// Owned.
        id: []const u8,
        /// Owned.
        version: []const u8,
        /// Owned; parsed AND validated to the `Level` the caller asked for.
        manifest: manifest.Manifest,

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
        pub fn entryPathAbs(self: Resolved, alloc: std.mem.Allocator, site: *const Site) ![]u8 {
            const rt = self.manifest.runtime orelse return error.MissingRuntime;
            const st = site.store() orelse return error.VersionNotFound;
            const entry_rel = st.versionRuntimeEntryPath(alloc, self.id, self.version, rt) catch |err| {
                if (err == error.EntryUnsupportedOnHost) site.report(
                    alloc,
                    "extension {s}@{s} declares no runtime entry for {s}; see `nulya ext inspect {s}@{s}`\n",
                    .{ self.id, self.version, @tagName(builtin.os.tag), self.id, self.version },
                );
                return err;
            };
            defer alloc.free(entry_rel);
            return std.fs.path.join(alloc, &.{ site.store_path, entry_rel });
        }
    };

    /// Open what is there, creating nothing: a machine with no store and a
    /// workspace with no `.nulya/extensions` are both ordinary. `store_path`
    /// empty means this machine has no store at all.
    pub fn open(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, store_path: []const u8, diag: Diag) !Site {
        const owned_cwd = try alloc.dupe(u8, cwd);
        errdefer alloc.free(owned_cwd);

        var store_dir: ?std.Io.Dir = null;
        var real: []const u8 = try alloc.dupe(u8, store_path);
        errdefer alloc.free(real);
        if (store_path.len != 0) {
            if (ext_store.openRoot(io, cwd, store_path)) |dir| {
                store_dir = dir;
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const resolved = try alloc.dupe(u8, buf[0..try dir.realPath(io, &buf)]);
                alloc.free(real);
                real = resolved;
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => return err,
            }
        }
        errdefer if (store_dir) |*d| d.close(io);

        const ws_dir: ?std.Io.Dir = ext_store.openRoot(io, cwd, workspace_rel) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        };
        return .{
            .alloc = alloc,
            .io = io,
            .cwd = owned_cwd,
            .store_path = real,
            .store_dir = store_dir,
            .ws_dir = ws_dir,
            .diag = diag,
        };
    }

    /// Say what an error cannot carry. Silent when nobody is listening, and
    /// silent when the line cannot be built — failing to SAY something never
    /// changes what happened.
    pub fn report(self: *const Site, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        if (self.diag.reportFn == null) return;
        const line = std.fmt.allocPrint(alloc, fmt, args) catch return;
        defer alloc.free(line);
        self.diag.report(self.io, line);
    }

    /// The store alone, for a caller with no pointer question — an execution
    /// resolver, which is only ever handed an exact version.
    pub fn openStore(alloc: std.mem.Allocator, io: std.Io, store_path: []const u8, diag: Diag) !Site {
        var site = try open(alloc, io, ".", store_path, diag);
        if (site.ws_dir) |*d| {
            d.close(io);
            site.ws_dir = null;
        }
        return site;
    }

    pub fn deinit(self: *Site) void {
        if (self.store_dir) |*d| d.close(self.io);
        if (self.ws_dir) |*d| d.close(self.io);
        self.alloc.free(self.store_path);
        self.alloc.free(self.cwd);
    }

    /// The one store's bytes, or null when this machine has none.
    pub fn store(self: *const Site) ?ext_store.Store {
        const dir = self.store_dir orelse return null;
        return ext_store.Store.init(self.io, dir);
    }

    /// The store, created if it is not there yet — what a build or an activate
    /// needs. Fails when this machine has no home to put one in.
    pub fn ensureStore(self: *Site) !ext_store.Store {
        if (self.store()) |st| return st;
        if (self.store_path.len == 0) return error.NoExtensionStore;
        const dir = try ext_store.openOrCreateRoot(self.io, self.cwd, self.store_path);
        self.store_dir = dir;
        // Now that it exists, `store_path` can be what every absolute entry
        // path is joined onto.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = try self.alloc.dupe(u8, buf[0..try dir.realPath(self.io, &buf)]);
        self.alloc.free(self.store_path);
        self.store_path = resolved;
        return ext_store.Store.init(self.io, dir);
    }

    /// The directory holding a layer's `current` files, created if needed.
    pub fn ensurePointerDir(self: *Site, layer: Layer) !std.Io.Dir {
        switch (layer) {
            .user => return (try self.ensureStore()).root,
            .workspace => {
                if (self.ws_dir) |d| return d;
                const dir = try ext_store.openOrCreateRoot(self.io, self.cwd, workspace_rel);
                self.ws_dir = dir;
                return dir;
            },
        }
    }

    fn pointerDir(self: *const Site, layer: Layer) ?std.Io.Dir {
        return switch (layer) {
            .workspace => self.ws_dir,
            .user => self.store_dir,
        };
    }

    /// Whether this workspace has a `<id>/` of its own — a draft, a pointer, or
    /// both. The rule `ext activate` defaults on: a package this workspace
    /// already has a directory for belongs to this workspace.
    pub fn workspaceHas(self: *const Site, id: []const u8) bool {
        const dir = self.ws_dir orelse return false;
        if (!manifest.isValidId(id)) return false;
        dir.access(self.io, id, .{}) catch return false;
        return true;
    }

    /// Which version `<id>` means here and which layer said so — the workspace
    /// pointer first. Null when neither layer points at one. Caller owns
    /// `version`.
    pub fn activePointer(self: *const Site, alloc: std.mem.Allocator, id: []const u8) !?Pointer {
        for ([_]Layer{ .workspace, .user }) |layer| {
            const dir = self.pointerDir(layer) orelse continue;
            const version = try ext_store.Store.init(self.io, dir).activeVersion(alloc, id) orelse continue;
            return .{ .layer = layer, .version = version };
        }
        return null;
    }

    /// The version in effect for `id`, with its validated manifest. Null when no
    /// layer points at one. Host faults — cancellation above all — propagate
    /// unchanged: only a missing `current` is "not there".
    pub fn resolveActive(self: *const Site, alloc: std.mem.Allocator, id: []const u8, level: ext_store.Level) !?Resolved {
        const active = (try self.activePointer(alloc, id)) orelse return null;
        defer alloc.free(active.version);
        return try self.resolveVersion(alloc, id, active.version, level);
    }

    /// A named built version, from the store. `error.VersionNotFound` when this
    /// machine does not hold it; the store's own integrity faults otherwise.
    pub fn resolveVersion(self: *const Site, alloc: std.mem.Allocator, id: []const u8, version: []const u8, level: ext_store.Level) !Resolved {
        const st = self.store() orelse return error.VersionNotFound;
        var m = try st.readManifest(alloc, id, version, level);
        errdefer m.deinit();
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_version = try alloc.dupe(u8, version);
        return .{ .id = owned_id, .version = owned_version, .manifest = m };
    }

    /// The `Resolved` for an entry `listActive` already decided.
    pub fn resolveEntry(self: *const Site, alloc: std.mem.Allocator, entry: ActiveEntry, level: ext_store.Level) !Resolved {
        return self.resolveVersion(alloc, entry.id, entry.version, level);
    }

    /// Every extension with a pointer in either layer, workspace winning,
    /// sorted by id. Only `current` is read here (cheap); whether the version it
    /// names is usable is the caller's concern. Caller owns the slice and each
    /// `id`/`version`.
    pub fn listActive(self: *const Site, alloc: std.mem.Allocator) ![]ActiveEntry {
        var out: std.ArrayList(ActiveEntry) = .empty;
        errdefer freeActive(alloc, out.items);
        for ([_]Layer{ .workspace, .user }) |layer| {
            const dir = self.pointerDir(layer) orelse continue;
            const st = ext_store.Store.init(self.io, dir);
            var it = dir.iterate();
            while (try it.next(self.io)) |dir_entry| {
                if (dir_entry.kind != .directory) continue;
                if (hasId(out.items, dir_entry.name)) continue; // the workspace layer won
                const version = (st.activeVersion(alloc, dir_entry.name) catch |err| switch (err) {
                    error.InvalidId => continue,
                    else => return err,
                }) orelse continue;
                errdefer alloc.free(version);
                const id = try alloc.dupe(u8, dir_entry.name);
                errdefer alloc.free(id);
                try out.append(alloc, .{ .id = id, .layer = layer, .version = version });
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

    /// Point a layer's `current` at a built version. The writer lease and the
    /// `.sealed` check always belong to the store that holds the bytes,
    /// whichever layer records the choice.
    pub fn activate(self: *Site, alloc: std.mem.Allocator, layer: Layer, id: []const u8, version: []const u8) !void {
        const st = try self.ensureStore();
        const dir = try self.ensurePointerDir(layer);
        return st.activateInto(alloc, id, version, dir);
    }

    /// Drop a layer's `current`. The versions stay.
    pub fn deactivate(self: *const Site, alloc: std.mem.Allocator, layer: Layer, id: []const u8) !void {
        const dir = self.pointerDir(layer) orelse return;
        const st = self.store() orelse {
            // No store to lease against: the pointer is still this layer's to
            // drop, and a dangling one is exactly what wants dropping.
            return ext_store.Store.init(self.io, dir).dropPointer(alloc, id);
        };
        var held = try st.lease(alloc, id);
        defer held.close(self.io);
        return ext_store.Store.init(self.io, dir).dropPointer(alloc, id);
    }

    /// The sibling of `<id>@<version>` built for another machine: the version
    /// whose seal records the same package bytes for `target_words`. Null when
    /// the store holds none; caller owns the result.
    ///
    /// This is how a session whose tools run elsewhere learns which frozen
    /// implementation will actually serve its calls. The two versions are one
    /// package that differs only in what it was compiled for, and
    /// `(package_digest, target)` is the key `Store.findSealed` already matches
    /// on — the same matcher a build asks about its own machine.
    ///
    /// No compiler is named: which zig produced the copy for that machine is
    /// not something this session gets to require, and the sorted search inside
    /// `findSealed` keeps the answer deterministic when several qualify.
    pub fn resolveForTarget(
        self: *const Site,
        alloc: std.mem.Allocator,
        id: []const u8,
        version: []const u8,
        target_words: []const u8,
    ) !?[]u8 {
        const st = self.store() orelse return null;
        const package_digest = try st.readPackageDigest(alloc, id, version);
        defer alloc.free(package_digest);
        return st.findSealed(alloc, id, package_digest, target_words, null);
    }

    fn hasId(list: []const ActiveEntry, id: []const u8) bool {
        for (list) |e| {
            if (std.mem.eql(u8, e.id, id)) return true;
        }
        return false;
    }
};

test "a workspace pointer wins over the store's, and dropping it reveals the store's again" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try alloc.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    defer alloc.free(base);
    const store_path = try std.fs.path.join(alloc, &.{ base, "home", "store" });
    defer alloc.free(store_path);

    // Both versions of `shared` live in the ONE store; only the pointers differ.
    var store_dir = try ext_store.openOrCreateRoot(io, base, store_path);
    defer store_dir.close(io);
    const old = try testkit.writeSkillVersion(alloc, io, store_dir, "shared", "older body");
    defer alloc.free(old);
    const new = try testkit.writeSkillVersion(alloc, io, store_dir, "shared", "newer body");
    defer alloc.free(new);
    const user_only = try testkit.writeSkillVersion(alloc, io, store_dir, "only-user", "user only");
    defer alloc.free(user_only);
    try std.testing.expect(!std.mem.eql(u8, old, new));

    var site = try Site.open(alloc, io, base, store_path, .{});
    defer site.deinit();

    try site.activate(alloc, .user, "shared", old);
    try site.activate(alloc, .user, "only-user", user_only);
    try site.activate(alloc, .workspace, "shared", new);

    {
        const active = try site.listActive(alloc);
        defer Site.freeActive(alloc, active);
        try std.testing.expectEqual(@as(usize, 2), active.len);
        try std.testing.expectEqualStrings("only-user", active[0].id);
        try std.testing.expectEqual(Layer.user, active[0].layer);
        try std.testing.expectEqualStrings("shared", active[1].id);
        try std.testing.expectEqual(Layer.workspace, active[1].layer);
        try std.testing.expectEqualStrings(new, active[1].version);
    }
    {
        const p = (try site.activePointer(alloc, "shared")).?;
        defer alloc.free(p.version);
        try std.testing.expectEqual(Layer.workspace, p.layer);
        try std.testing.expectEqualStrings(new, p.version);
    }
    {
        // The manifest comes from the store either way: bytes have one home.
        const r = (try site.resolveActive(alloc, "shared", .sealed)).?;
        defer r.deinit(alloc);
        try std.testing.expectEqualStrings(new, r.version);
        try std.testing.expectEqualStrings("shared", r.manifest.id);
    }

    // Dropping the workspace pointer reveals the user one — for the listing and
    // for the single lookup.
    try site.deactivate(alloc, .workspace, "shared");
    {
        const p = (try site.activePointer(alloc, "shared")).?;
        defer alloc.free(p.version);
        try std.testing.expectEqual(Layer.user, p.layer);
        try std.testing.expectEqualStrings(old, p.version);
    }

    // A named version resolves whether or not any pointer names it.
    {
        const r = try site.resolveVersion(alloc, "shared", new, .sealed);
        defer r.deinit(alloc);
        try std.testing.expectEqualStrings(new, r.version);
    }
    try std.testing.expectError(error.VersionNotFound, site.resolveVersion(alloc, "shared", "v-000000000000000000000000", .sealed));
    try std.testing.expect((try site.resolveActive(alloc, "absent", .sealed)) == null);
}

test "a machine with no store answers 'not here' rather than inventing one" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];

    var site = try Site.open(alloc, io, base, "", .{});
    defer site.deinit();
    try std.testing.expect(site.store() == null);
    try std.testing.expectError(error.VersionNotFound, site.resolveVersion(alloc, "any", "v-000000000000000000000000", .sealed));
    const active = try site.listActive(alloc);
    defer Site.freeActive(alloc, active);
    try std.testing.expectEqual(@as(usize, 0), active.len);
    try std.testing.expectError(error.NoExtensionStore, site.activate(alloc, .user, "any", "v-000000000000000000000000"));
}

test "resolveForTarget finds the sibling built for another machine, from the one store" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];

    var store_dir = try ext_store.openOrCreateRoot(io, base, "store");
    defer store_dir.close(io);
    const host_version = try testkit.writeSkillVersion(alloc, io, store_dir, "pkg", "sibling body");
    defer alloc.free(host_version);
    const digest = try ext_store.Store.init(io, store_dir).readPackageDigest(alloc, "pkg", host_version);
    defer alloc.free(digest);

    // The genuine cross-compiled sibling: the SAME package digest, sealed for
    // another target — what a remote session's `exec_version` lookup is after.
    const sibling = "v-" ++ ("a" ** 24);
    {
        const st = ext_store.Store.init(io, store_dir);
        try st.ensureVersionDir(alloc, "pkg", sibling);
        const version_rel = try st.versionDir(alloc, "pkg", sibling);
        defer alloc.free(version_rel);
        const manifest_dst = try std.fs.path.join(alloc, &.{ version_rel, integrity.manifest_file });
        defer alloc.free(manifest_dst);
        try store_dir.writeFile(io, .{ .sub_path = manifest_dst, .data =
            \\{"schema":"nulya.extension/v2","id":"pkg","contributes":{"skills":["skills/demo"]}}
        });
        const skill_dst = try std.fs.path.join(alloc, &.{ version_rel, "package", "skills", "demo", "SKILL.md" });
        defer alloc.free(skill_dst);
        try store_dir.createDirPath(io, std.fs.path.dirname(skill_dst).?);
        try store_dir.writeFile(io, .{ .sub_path = skill_dst, .data = "sibling body" });
        const seal = try integrity.sealJson(alloc, digest, "zig test", "aarch64-linux", null);
        defer alloc.free(seal);
        const seal_dst = try std.fs.path.join(alloc, &.{ version_rel, integrity.seal_file });
        defer alloc.free(seal_dst);
        try store_dir.writeFile(io, .{ .sub_path = seal_dst, .data = seal });
    }

    var site = try Site.open(alloc, io, base, "store", .{});
    defer site.deinit();
    const found = try site.resolveForTarget(alloc, "pkg", host_version, "aarch64-linux");
    defer if (found) |f| alloc.free(f);
    try std.testing.expectEqualStrings(sibling, found.?);
    try std.testing.expect((try site.resolveForTarget(alloc, "pkg", host_version, "riscv64-linux")) == null);
}
