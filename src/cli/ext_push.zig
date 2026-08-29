//! `nulya ext push <id>@<version> --env <spec>` — copy one immutable extension
//! version into another machine's user store (DESIGN §7.4, §8.2).
//!
//! It is `build_ext.adoptVersionDir` with a channel where the second directory
//! handle used to be: read a version this machine holds, write it somewhere it
//! is not yet, and let the destination validate the copy against its own seal
//! before that copy becomes a version anyone can compose. Content addressing
//! does the rest — the hash IS the check, so pushing twice is a no-op and there
//! is nothing to negotiate about staleness.
//!
//! **Only `remote:` specs.** An exec target (`--env ssh:me@box`) runs commands
//! elsewhere but keeps the workspace and the store HERE, so pushing to one would
//! be copying a version into the store it just came out of.
//!
//! **What this does not do.** It does not activate anything over there, and it
//! does not decide when a version should travel. Which machines hold which
//! capabilities is a person's decision, and the record of it is the store's own
//! contents (goals/remote-env.md §3.5) — not a fourth journal.

const std = @import("std");
const integrity = @import("../extension/integrity.zig");
const protocol = @import("../environment/remote/protocol.zig");
const remote = @import("../environment/remote/mod.zig");
const launch = @import("../launch.zig");
const common = @import("common.zig");

const RootSearch = common.RootSearch;
const cwdRealPath = common.cwdRealPath;
const flagValue = common.flagValue;
const printErr = common.printErr;
const printErrFmt = common.printErrFmt;
const printOut = common.printOut;
const withRef = common.withRef;

const usage = "usage: nulya ext push <id>@<version> --env remote:…\n";

pub fn extPush(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const spec = flagValue(args, "--env") orelse {
        try printErr(io, usage);
        return 1;
    };
    var ref_arg: ?[]const u8 = null;
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--env")) {
                i += 1;
                continue;
            }
            if (std.mem.startsWith(u8, args[i], "--")) continue;
            ref_arg = args[i];
            break;
        }
    }
    const ref = withRef(ref_arg orelse {
        try printErr(io, usage);
        return 1;
    });
    // The version is required, not defaulted to `current`. What "the version in
    // effect" means is a property of THIS machine, and a push is about the other
    // one: naming it is how the two ends can be talked about in one sentence.
    const version = ref.version orelse {
        try printErrFmt(alloc, io, "ext push: name the exact version, as <id>@<version> ({s} has none)\n", .{ref.id});
        return 1;
    };

    if (!remote.isSpec(spec)) {
        try printErrFmt(
            alloc,
            io,
            "ext push --env {s}: only a remote workspace has a store of its own to push into ({s}); wsl / ssh exec targets move the command and keep this machine's store\n",
            .{ spec, remote.spec_syntax },
        );
        return 1;
    }

    // Validate the local copy at `.sealed` BEFORE opening a channel: bytes this
    // machine has not verified are not bytes to hand another machine, and the
    // failure is about this store, so it should not arrive dressed as a
    // connection problem.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const resolved = search.roots.resolveVersion(alloc, ref.id, version, .sealed) catch |err| {
        try printErrFmt(alloc, io, "ext push: {s}@{s} is not usable here ({s}); `nulya ext build` it first\n", .{ ref.id, version, @errorName(err) });
        return 1;
    };
    defer resolved.deinit(alloc);

    const version_rel = try search.roots.store(resolved.root).versionDir(alloc, ref.id, version);
    defer alloc.free(version_rel);
    var version_dir = try search.roots.entries[resolved.root].dir.openDir(io, version_rel, .{ .iterate = true });
    defer version_dir.close(io);

    const launcher = remote.parseSpec(spec) catch {
        try printErrFmt(alloc, io, "--env {s}: unrecognized (want {s})\n", .{ spec, remote.spec_syntax });
        return 1;
    };
    var ch = remote.Channel.connect(alloc, io, launcher, launch.version, .default) catch |err| {
        switch (err) {
            error.RemoteVersionMismatch => try printErrFmt(alloc, io, "{s}: the nulya there speaks a different remote protocol; install a matching build on that machine\n", .{spec}),
            error.RemoteSpecUnsupportedOnHost => try printErrFmt(alloc, io, "{s}: cannot be reached from this host (wsl needs Windows)\n", .{spec}),
            else => try printErrFmt(alloc, io, "{s}: could not open a channel ({s})\n", .{ spec, @errorName(err) }),
        }
        return 1;
    };
    defer ch.deinit();

    const stat = try round(alloc, io, &ch, spec, .{
        .op = protocol.Op.store_stat.wire(),
        .id = ref.id,
        .version = version,
    }, "") orelse return 1;
    if (stat.held) {
        try printOut(alloc, io, "{s}@{s}: already there ({s})\n", .{ ref.id, version, spec });
        return 0;
    }

    var walker = try version_dir.walk(alloc);
    defer walker.deinit();
    var sent: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue; // directories arrive with their files
        const rel = try integrity.canonicalRel(alloc, entry.path);
        defer alloc.free(rel);
        const bytes = version_dir.readFileAlloc(io, entry.path, alloc, .limited(protocol.max_payload_bytes)) catch |err| {
            try printErrFmt(alloc, io, "ext push: could not read '{s}' ({s}); nothing was installed on {s}\n", .{ rel, @errorName(err), spec });
            return 1;
        };
        defer alloc.free(bytes);
        _ = try round(alloc, io, &ch, spec, .{
            .op = protocol.Op.store_put.wire(),
            .path = rel,
            // The store's layout is the whole rule: `bin/` holds the compiled
            // entry and nothing else does (DESIGN §7.4). No manifest read, and
            // no second answer to "which file is the program".
            .exec = std.mem.startsWith(u8, rel, "bin/"),
            .bytes = bytes.len,
        }, bytes) orelse return 1;
        sent += 1;
    }

    _ = try round(alloc, io, &ch, spec, .{ .op = protocol.Op.store_commit.wire() }, "") orelse return 1;
    try printOut(alloc, io, "{s}@{s}: pushed, {d} files ({s})\n", .{ ref.id, version, sent, spec });
    return 0;
}

/// One request, with both ways it can fail already spoken: a channel that broke
/// (this machine's account of it) and a refusal (that machine's own sentence).
/// Null means "already reported, exit 1" — the caller then stops, which is what
/// leaves the far side's staging directory unnamed under `versions/`.
fn round(
    alloc: std.mem.Allocator,
    io: std.Io,
    ch: *remote.Channel,
    spec: []const u8,
    req: protocol.Request,
    payload: []const u8,
) !?protocol.Reply {
    const rep = ch.controlRound(req, payload) catch |err| {
        try printErrFmt(alloc, io, "{s}: {s} ({s})\n", .{ spec, req.op, @errorName(err) });
        return null;
    };
    if (!rep.ok) {
        try printErrFmt(alloc, io, "{s}: {s}\n", .{ spec, rep.message });
        return null;
    }
    return rep;
}
