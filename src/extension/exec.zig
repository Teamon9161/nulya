//! Turning `(id, version)` into something to spawn, on the machine that holds
//! the bytes.
//!
//! An `ExtensionRequest` names a frozen version and a tool, never a path.
//! Which file to run is an answer only the executing machine can give: the
//! entry variant is picked per OS, integrity has to be checked where the
//! bytes are (or a host would verify its own copy and run someone else's),
//! and a store root is a directory on that machine. So both execution sides
//! share this one resolver: the local backend and the remote agent.
//!
//! `.sealed` is paid once per (id, version) per resolver, not per call: a
//! resolver lives as long as the process that owns it (one `session step`,
//! one served channel), so "this process verified this version before it
//! ran it" is exactly the guarantee needed.

const std = @import("std");
const manifest = @import("manifest.zig");
const roots_mod = @import("roots.zig");
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
    /// The root specs to search, owned. Opened lazily: a process that never runs
    /// an extension never opens a directory, and — crucially — relative specs
    /// resolve against the WORKSPACE the call names, which is not known until
    /// the first call arrives.
    specs: []const []const u8,
    roots: ?roots_mod.Roots = null,
    /// Which workspace `roots` was opened against, so a resolver handed a
    /// different one notices instead of silently answering for the old one.
    opened_for: []const u8 = "",
    memo: std.ArrayList(Memo) = .empty,

    const Memo = struct {
        id: []const u8,
        version: []const u8,
        path: []const u8,
        interpreter: ?[]const u8,
    };

    /// Take a copy of the root specs. Nothing is opened and nothing can fail
    /// about the store here — an environment must be constructible on a machine
    /// with no extensions at all.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, specs: []const []const u8) !Resolver {
        const owned = try alloc.alloc([]const u8, specs.len);
        var filled: usize = 0;
        errdefer {
            for (owned[0..filled]) |s| alloc.free(s);
            alloc.free(owned);
        }
        for (specs, owned) |spec, *slot| {
            slot.* = try alloc.dupe(u8, spec);
            filled += 1;
        }
        return .{ .alloc = alloc, .io = io, .specs = owned };
    }

    pub fn deinit(self: *Resolver) void {
        if (self.roots) |*r| r.deinit();
        if (self.opened_for.len != 0) self.alloc.free(self.opened_for);
        for (self.memo.items) |m| {
            self.alloc.free(m.id);
            self.alloc.free(m.version);
            self.alloc.free(m.path);
            if (m.interpreter) |i| self.alloc.free(i);
        }
        self.memo.deinit(self.alloc);
        for (self.specs) |s| self.alloc.free(s);
        self.alloc.free(self.specs);
        self.* = undefined;
    }

    /// Where to find `<id>@<version>` on this machine, having verified it
    /// against its own seal at least once in this process.
    ///
    /// `workspace` is the directory relative root specs resolve against — the
    /// same directory the call itself runs in, so each side reads "the
    /// workspace store" as its own.
    pub fn resolve(self: *Resolver, workspace: []const u8, id: []const u8, version: []const u8) !Entry {
        for (self.memo.items) |m| {
            if (std.mem.eql(u8, m.id, id) and std.mem.eql(u8, m.version, version)) {
                return .{ .path = m.path, .interpreter = m.interpreter };
            }
        }
        const roots = try self.openRoots(workspace);

        // `.sealed`: this process is about to RUN these bytes.
        const resolved = try roots.resolveVersion(self.alloc, id, version, .sealed);
        defer resolved.deinit(self.alloc);
        if (resolved.manifest.runtime == null) return error.MissingRuntime;

        const path = try resolved.entryPathAbs(self.alloc, roots);
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

    fn openRoots(self: *Resolver, workspace: []const u8) !*const roots_mod.Roots {
        if (self.roots) |*r| {
            if (std.mem.eql(u8, self.opened_for, workspace)) return r;
            // A single environment serves one session, which has one workspace;
            // if that ever stops being true, reopening is the honest answer and
            // the memo has to go with it — every path in it names the old root.
            self.closeRoots();
        }
        const opened_for = try self.alloc.dupe(u8, workspace);
        errdefer self.alloc.free(opened_for);
        self.roots = try roots_mod.Roots.open(self.alloc, self.io, workspace, self.specs);
        self.opened_for = opened_for;
        return &self.roots.?;
    }

    fn closeRoots(self: *Resolver) void {
        if (self.roots) |*r| r.deinit();
        self.roots = null;
        if (self.opened_for.len != 0) self.alloc.free(self.opened_for);
        self.opened_for = "";
        for (self.memo.items) |m| {
            self.alloc.free(m.id);
            self.alloc.free(m.version);
            self.alloc.free(m.path);
            if (m.interpreter) |i| self.alloc.free(i);
        }
        self.memo.clearRetainingCapacity();
    }
};

const testing = std.testing;
const testkit = @import("testkit.zig");

test "a version is resolved to an entry on this machine, and verified once" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".nulya/extensions");
    var root = try tmp.dir.openDir(io, ".nulya/extensions", .{ .iterate = true });
    defer root.close(io);

    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"scripted","runtime":{"entry":"src/run.sh","interpreter":"sh"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    const version = try testkit.writeFrozenVersion(alloc, io, root, "scripted", manifest_bytes, &.{
        .{ .rel = "src/run.sh", .bytes = "#!/bin/sh\necho hi\n" },
    });
    defer alloc.free(version);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = buf[0..try tmp.dir.realPath(io, &buf)];

    var resolver = try Resolver.init(alloc, io, &.{".nulya/extensions"});
    defer resolver.deinit();

    const first = try resolver.resolve(ws, "scripted", version);
    try testing.expect(std.fs.path.isAbsolute(first.path));
    // A script's entry lives inside `package/`, and its interpreter comes off
    // the frozen manifest — both decided here, by the machine that will spawn it.
    try testing.expect(std.mem.indexOf(u8, first.path, "run.sh") != null);
    try testing.expectEqualStrings("sh", first.interpreter.?);

    // The second call is the memo: the same strings, and no second digest. That
    // is what keeps `.sealed` a per-process price rather than a per-call one.
    const second = try resolver.resolve(ws, "scripted", version);
    try testing.expectEqual(first.path.ptr, second.path.ptr);
    try testing.expectEqual(@as(usize, 1), resolver.memo.items.len);

    // A version this machine does not hold is a refusal, not a guess.
    try testing.expectError(
        error.VersionNotFound,
        resolver.resolve(ws, "scripted", "v-000000000000000000000000"),
    );
}

test "a resolver with no roots at all refuses rather than inventing one" {
    const alloc = testing.allocator;
    var resolver = try Resolver.init(alloc, testing.io, &.{});
    defer resolver.deinit();
    try testing.expectError(error.VersionNotFound, resolver.resolve(".", "nope", "v-000000000000000000000000"));
}
