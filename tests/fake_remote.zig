//! A remote agent that MISBEHAVES, so the host side can be tested against the
//! failures a real `nulya remote serve` will never produce.
//!
//! **Why this exists, and why it is not the happy path.** The offline test for
//! a working channel points `--env remote:exec:` at the real nulya binary, both
//! ends production code over a pipe. What that cannot exercise is a peer that
//! lies — answers a version it does not speak, stops talking mid-command,
//! writes half a frame, or claims a payload length nobody can honour — and only
//! a deliberately broken peer can produce those shapes.
//!
//! **The mode is argv, not an environment variable**, because that is what the
//! spec can carry: `remote:exec:<this binary> <mode>` splits on spaces and the
//! launcher appends `remote serve`, so this process sees `[<mode>, "remote",
//! "serve"]`. An environment variable would need a spawn this test does not
//! control.
//!
//!   version    answers `hello` with a version nobody speaks
//!   die        answers `hello`, then exits without replying to the next request
//!   halfframe  answers `hello`, then writes half a header line and exits
//!   liar       answers `hello`, then claims a payload larger than any reader
//!              will accept
//!   foreign    answers `hello` correctly, calling itself an os and arch that do
//!              not exist — the machine a host has no build for
//!   silent     answers nothing at all, ever
//!   stalereport  answers `hello` correctly, then answers the next request (a
//!              `task-poll`) with a WELL-FORMED `TaskSnapshot` whose `report` is
//!              present while `status` still says `running` — the window a real
//!              supervisor's `report.txt`-then-`status.json` write order opens
//!              for one poll, and that no real peer can be paused inside on
//!              purpose (`cli/task.zig`'s `pollAndDeliver`)
//!
//! The frames are written by hand rather than through `protocol.zig`: a fake
//! whose encoder is the real one could not produce a frame the real one refuses
//! to produce, which is exactly what half of these modes are.

const std = @import("std");

/// How long `silent` sits there before giving up, so a test that never kills it
/// fails rather than hangs the suite.
const silent_ticks: u32 = 1500; // 30s at 20ms

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(alloc);
    const mode: []const u8 = if (argv.len > 1) argv[1] else "die";

    var in_buf: [1 << 16]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const out = std.Io.File.stdout();

    if (std.mem.eql(u8, mode, "silent")) {
        var ticks: u32 = 0;
        while (ticks < silent_ticks) : (ticks += 1) {
            std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
        return;
    }

    // The handshake. The version is echoed back from the request (plus one in
    // `version` mode), so this file does not have to be edited every time the
    // protocol's number changes — and the mismatch it tests stays a mismatch.
    const hello = reader.interface.takeDelimiter('\n') catch return orelse return;
    const asked = versionIn(hello) orelse 1;
    const answer = if (std.mem.eql(u8, mode, "version")) asked + 1 else asked;
    const line = try std.fmt.allocPrint(
        alloc,
        "{{\"ok\":true,\"v\":{d},\"nulya\":\"fake\",\"os\":\"fake\",\"arch\":\"fake\",\"home\":\"\",\"cwd\":\"\",\"dialect\":\"bash\"}}\n",
        .{answer},
    );
    try out.writeStreamingAll(io, line);
    if (std.mem.eql(u8, mode, "version")) return;
    // `foreign`: the handshake is all a caller wanted. What makes it useful is
    // the `os` / `arch` above — a machine this store can hold no build for, so
    // the exec-version lookup has to refuse rather than guess.
    if (std.mem.eql(u8, mode, "foreign")) return;

    // One more request, answered badly (or not at all).
    const req = reader.interface.takeDelimiter('\n') catch return orelse return;
    // Whatever payload it carries is left unread on purpose: this side is about
    // to stop being a protocol peer anyway.
    _ = req;
    if (std.mem.eql(u8, mode, "halfframe")) {
        try out.writeStreamingAll(io, "{\"ok\":true,\"exit_c");
        return;
    }
    if (std.mem.eql(u8, mode, "liar")) {
        try out.writeStreamingAll(io, "{\"ok\":true,\"exit_code\":0,\"bytes\":99999999999,\"out\":0}\n");
        return;
    }
    if (std.mem.eql(u8, mode, "stalereport")) {
        // Hand-written, like the rest of this file, but WELL-FORMED — this mode
        // is not testing framing, it is testing whether the host trusts a
        // `report` present over a `status` that has not caught up to it. The
        // inner `status` string is itself JSON — `cli/task.zig`'s `Status`,
        // with every field it declares as required (`task`, `session`,
        // `command`, `cwd`, `started`) present, or the host's own parse simply
        // fails and the row vanishes instead of exercising the race at all —
        // and its quotes are escaped the way `std.json.Stringify` would escape
        // them for any string field.
        const payload = "{\"status\":\"{\\\"v\\\":1,\\\"task\\\":\\\"s-1/t1\\\",\\\"session\\\":\\\"s-1\\\"," ++
            "\\\"command\\\":\\\"echo hi\\\",\\\"cwd\\\":\\\".\\\",\\\"started\\\":\\\"2026-08-30T00:00:00Z\\\"," ++
            "\\\"state\\\":\\\"running\\\",\\\"exit_code\\\":null}\"," ++
            "\"report\":\"[background task s-1/t1 finished] echo hi \\u00b7 exit 0 \\u00b7 0.1s\\n--- output ---\\nhi\\n\"," ++
            "\"lease_held\":true}";
        const header = try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"bytes\":{d}}}\n", .{payload.len});
        try out.writeStreamingAll(io, header);
        try out.writeStreamingAll(io, payload);
        return;
    }
    // `die`: nothing at all, and the process ends. The host sees EOF where a
    // reply belongs, which is the "connection lost mid-command" case.
}

/// The `v` out of a request header, without a JSON parser: this file is testing
/// framing, and a parser here would be one more thing that could be right when
/// the host is wrong.
fn versionIn(line: []const u8) ?u32 {
    const key = "\"v\":";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    var i = at + key.len;
    while (i < line.len and line[i] == ' ') i += 1;
    var end = i;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    if (end == i) return null;
    return std.fmt.parseInt(u32, line[i..end], 10) catch null;
}
