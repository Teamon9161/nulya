//! `nulya ext push <id>@<version> --env <spec>` — copy one immutable extension
//! version into another machine's store.
//!
//! Read a version this machine holds, write it where it is not yet, and let the
//! destination validate the copy against its own seal before it becomes a
//! version anyone can compose. Content addressing does the rest: pushing twice
//! is a no-op.
//!
//! Only `remote:` specs. An exec target (`--env wsl`) runs commands elsewhere
//! but keeps the workspace and the store HERE, so pushing to one would copy a
//! version into the store it came out of. Nothing is activated on the far
//! side.

const std = @import("std");
const integrity = @import("../extension/integrity.zig");
const protocol = @import("../environment/remote/protocol.zig");
const remote = @import("../environment/remote/mod.zig");
const launch = @import("../launch.zig");
const common = @import("common.zig");

const StoreView = common.StoreView;
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
    // Required, never defaulted to `current`: "the version in effect" is a
    // property of THIS machine, and a push is about the other one.
    const version = ref.version orelse {
        try printErrFmt(alloc, io, "ext push: name the exact version, as <id>@<version> ({s} has none)\n", .{ref.id});
        return 1;
    };

    if (!remote.isSpec(spec)) {
        try printErrFmt(
            alloc,
            io,
            "ext push --env {s}: only a remote workspace has a store of its own to push into ({s}); a wsl exec target moves the command and keeps this machine's store\n",
            .{ spec, remote.spec_syntax },
        );
        return 1;
    }

    // Validate the local copy at `.sealed` BEFORE opening a channel: unverified
    // bytes are not bytes to hand another machine, and a failure about this
    // store should not arrive dressed as a connection problem.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    var view = try StoreView.open(alloc, io, cwd_path);
    defer view.deinit(alloc);
    const resolved = view.site.resolveVersion(alloc, ref.id, version, .sealed) catch |err| {
        try printErrFmt(alloc, io, "ext push: {s}@{s} is not usable here ({s}); `nulya ext build` it first\n", .{ ref.id, version, @errorName(err) });
        return 1;
    };
    defer resolved.deinit(alloc);

    const st = view.site.store().?; // resolving it proved the store is there
    const version_rel = try st.versionDir(alloc, ref.id, version);
    defer alloc.free(version_rel);
    var version_dir = try st.root.openDir(io, version_rel, .{ .iterate = true });
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
            // The store layout is the whole rule: `bin/` holds the compiled
            // entry and nothing else does. No manifest read, so there is no
            // second answer to "which file is the program".
            .exec = std.mem.startsWith(u8, rel, "bin/"),
            .bytes = bytes.len,
        }, bytes) orelse return 1;
        sent += 1;
    }

    _ = try round(alloc, io, &ch, spec, .{ .op = protocol.Op.store_commit.wire() }, "") orelse return 1;
    try printOut(alloc, io, "{s}@{s}: pushed, {d} files ({s})\n", .{ ref.id, version, sent, spec });
    return 0;
}

/// One request, with both failure modes already reported: a broken channel and
/// a refusal from the far side. Null means "already reported, exit 1".
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
