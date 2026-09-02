//! Turning `(id, version)` into something to spawn, on the machine that holds
//! the bytes.
//!
//! An `ExtensionRequest` names a frozen version and a tool, never a path.
//! Which file to run is an answer only the executing machine can give: the
//! entry variant is picked per OS, integrity has to be checked where the
//! bytes are (or a host would verify its own copy and run someone else's),
//! and the store is a directory on that machine. So both execution sides
//! share this one resolver: the local backend and the remote agent.
//!
//! `.sealed` is paid once per (id, version) per resolver, not per call: a
//! resolver lives as long as the process that owns it (one `session step`,
//! one served channel), so "this process verified this version before it
//! ran it" is exactly the guarantee needed.

const std = @import("std");
const manifest = @import("manifest.zig");
const site_mod = @import("site.zig");
const store = @import("store.zig");

/// Is this a failure to resolve the version on this machine, rather than a
/// fault of the host trying to run it?
///
/// A package this machine does not hold, holds broken, or declares no entry
/// variant for, is the caller's business — something to be told about and
/// possibly fixed (`nulya ext build`, `nulya ext push`) — while an
/// out-of-memory or a cancellation is the step's. So the first kind becomes
/// an ordinary failed call and the second propagates, on both sides of the
/// seam: the remote agent answers such a version with a refusal that the
/// host turns into exactly the same failed call.
pub fn isUnrunnableHere(err: anyerror) bool {
    return store.isExtensionFault(err) or
        err == error.EntryUnsupportedOnHost or
        err == error.MissingRuntime;
}

/// What to spawn. Both strings are owned by the resolver and stay valid for its
/// lifetime — a caller only needs them for the duration of one spawn.
pub const Entry = struct {
    /// Absolute path of the frozen entry ON THIS MACHINE.
    path: []const u8,
    /// The interpreter a script entry runs through (argv[0], the entry argv[1]);
    /// null for a compiled entry, which runs directly.
    interpreter: ?[]const u8,
};

pub const Resolver = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// This machine's one store, owned; empty when it has none. Opened lazily,
    /// so a process that never runs an extension never opens a directory.
    store_path: []const u8,
    /// Where the resolver says what an error cannot carry (which package has no
    /// entry for this OS). Reports nothing by default.
    diag: site_mod.Diag = .{},
    site: ?site_mod.Site = null,
    memo: std.ArrayList(Memo) = .empty,

    const Memo = struct {
        id: []const u8,
        version: []const u8,
        path: []const u8,
        interpreter: ?[]const u8,
    };

    /// Take a copy of the store path. Nothing is opened and nothing can fail
    /// about the store here — an environment must be constructible on a machine
    /// with no extensions at all.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, store_path: []const u8, diag: site_mod.Diag) !Resolver {
        return .{ .alloc = alloc, .io = io, .store_path = try alloc.dupe(u8, store_path), .diag = diag };
    }

    pub fn deinit(self: *Resolver) void {
        if (self.site) |*s| s.deinit();
        for (self.memo.items) |m| {
            self.alloc.free(m.id);
            self.alloc.free(m.version);
            self.alloc.free(m.path);
            if (m.interpreter) |i| self.alloc.free(i);
        }
        self.memo.deinit(self.alloc);
        self.alloc.free(self.store_path);
        self.* = undefined;
    }

    /// Where to find `<id>@<version>` on this machine, having verified it
    /// against its own seal at least once in this process.
    pub fn resolve(self: *Resolver, id: []const u8, version: []const u8) !Entry {
        for (self.memo.items) |m| {
            if (std.mem.eql(u8, m.id, id) and std.mem.eql(u8, m.version, version)) {
                return .{ .path = m.path, .interpreter = m.interpreter };
            }
        }
        const site = try self.openSite();

        // `.sealed`: this process is about to RUN these bytes.
        const resolved = try site.resolveVersion(self.alloc, id, version, .sealed);
        defer resolved.deinit(self.alloc);
        if (resolved.manifest.runtime == null) return error.MissingRuntime;

        const path = try resolved.entryPathAbs(self.alloc, site);
        errdefer self.alloc.free(path);
        const interpreter: ?[]const u8 = if (resolved.manifest.runtime.?.interpreter) |ip|
            if (ip.forHost()) |value| try self.alloc.dupe(u8, value) else null
        else
            null;
        errdefer if (interpreter) |i| self.alloc.free(i);

        const owned_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(owned_id);
        const owned_version = try self.alloc.dupe(u8, version);
        errdefer self.alloc.free(owned_version);
        try self.memo.append(self.alloc, .{
            .id = owned_id,
            .version = owned_version,
            .path = path,
            .interpreter = interpreter,
        });
        return .{ .path = path, .interpreter = interpreter };
    }

    /// The store, opened once and kept for the resolver's life — one `session
    /// step` or one served channel, which is exactly the span `.sealed` is paid
    /// over.
    fn openSite(self: *Resolver) !*const site_mod.Site {
        if (self.site) |*s| return s;
        self.site = try site_mod.Site.openStore(self.alloc, self.io, self.store_path, self.diag);
        return &self.site.?;
    }
};

const testing = std.testing;
const testkit = @import("testkit.zig");

test "a version is resolved to an entry on this machine, and verified once" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var root = try store.openOrCreateRoot(io, base, "store");
    defer root.close(io);

    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"scripted","runtime":{"entry":"src/run.sh","interpreter":"sh"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    const version = try testkit.writeFrozenVersion(alloc, io, root, "scripted", manifest_bytes, &.{
        .{ .rel = "src/run.sh", .bytes = "#!/bin/sh\necho hi\n" },
    });
    defer alloc.free(version);

    const store_path = try std.fs.path.join(alloc, &.{ base, "store" });
    defer alloc.free(store_path);
    var resolver = try Resolver.init(alloc, io, store_path, .{});
    defer resolver.deinit();

    const first = try resolver.resolve("scripted", version);
    try testing.expect(std.fs.path.isAbsolute(first.path));
    // A script's entry lives inside `package/`, and its interpreter comes off
    // the frozen manifest — both decided here, by the machine that will spawn it.
    try testing.expect(std.mem.indexOf(u8, first.path, "run.sh") != null);
    try testing.expectEqualStrings("sh", first.interpreter.?);

    // The second call is the memo: the same strings, and no second digest. That
    // is what keeps `.sealed` a per-process price rather than a per-call one.
    const second = try resolver.resolve("scripted", version);
    try testing.expectEqual(first.path.ptr, second.path.ptr);
    try testing.expectEqual(@as(usize, 1), resolver.memo.items.len);

    // A version this machine does not hold is a refusal, not a guess.
    try testing.expectError(
        error.VersionNotFound,
        resolver.resolve("scripted", "v-000000000000000000000000"),
    );
}

test "a resolver with no store at all refuses rather than inventing one" {
    const alloc = testing.allocator;
    var resolver = try Resolver.init(alloc, testing.io, "", .{});
    defer resolver.deinit();
    try testing.expectError(error.VersionNotFound, resolver.resolve("nope", "v-000000000000000000000000"));
}
