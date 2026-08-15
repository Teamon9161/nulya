//! Session-setup promotion boundary (DESIGN §5.1 rule 3).
//!
//! Usage-driven automatic native promotion lives entirely at the session-setup
//! boundary: read the usage journal, rank the extension stable ids that have
//! real usage, and hand a plain best-first id list to `SessionComposition`. The
//! composition never sees the journal, the weights, or the score model — it only
//! receives already-resolved ids and copies what it selects into owned bindings.
//!
//! This is a thin, reusable glue layer, not a session factory: every frontend
//! (the `runDemo` walking skeleton today, the e2e harness, later ACP/TUI) runs
//! the identical production ranking path instead of re-deriving it. Ranking
//! itself stays a pure function in `tool_selection.zig`; this module only wires
//! the journal and the candidate set into it.

const std = @import("std");
const tool_stats = @import("tool_stats.zig");
const tool_selection = @import("tool_selection.zig");

/// Read the usage journal at `cwd` and return the extension stable ids ranked
/// best-first for automatic native promotion. Builtin usage is deliberately
/// ignored — v0.1 automatic promotion considers only `ext:<extension-id>/<tool-name>`
/// ids. Each returned id is an owned copy (free with `freeRankedIds`), so the
/// journal/candidate/score slices can die inside this call. A missing journal is
/// a normal empty ranking; a malformed journal, OOM, or a real filesystem fault
/// propagates — never silently downgraded to "no stats".
pub fn rankExtensionTools(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    weights: tool_selection.Weights,
) ![]const []const u8 {
    const events = try tool_stats.readAll(alloc, io, cwd);
    defer tool_stats.freeEvents(alloc, events);

    const candidates = try collectExtensionCandidates(alloc, events);
    defer alloc.free(candidates);

    const ranked = try tool_selection.rank(alloc, candidates, events, weights);
    defer alloc.free(ranked);

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer freeRankedIds(alloc, ids.items);
    for (ranked) |r| {
        const id = try alloc.dupe(u8, r.tool_id);
        errdefer alloc.free(id);
        try ids.append(alloc, id);
    }
    return ids.toOwnedSlice(alloc);
}

/// Collect unique extension stable ids from `events`. Candidate ids borrow the
/// event strings (the caller keeps `events` alive through ranking); the
/// returned slice owns only the array. O(n²) dedupe: candidate sets are tiny.
fn collectExtensionCandidates(alloc: std.mem.Allocator, events: []const tool_stats.UseEvent) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (events) |e| {
        if (!std.mem.startsWith(u8, e.tool_id, "ext:")) continue;
        if (sliceContains(out.items, e.tool_id)) continue;
        try out.append(alloc, e.tool_id);
    }
    return out.toOwnedSlice(alloc);
}

fn sliceContains(slice: []const []const u8, needle: []const u8) bool {
    for (slice) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// Free a slice returned by `rankExtensionTools` (each id is owned).
pub fn freeRankedIds(alloc: std.mem.Allocator, ids: []const []const u8) void {
    for (ids) |id| alloc.free(id);
    alloc.free(ids);
}

fn boundaryTmpCwd(alloc: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

test "promotion boundary reads a missing journal as an empty ranking" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try boundaryTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    // No journal yet: a normal empty ranking, not an error.
    const ids = try rankExtensionTools(alloc, io, cwd, .{});
    defer freeRankedIds(alloc, ids);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "promotion boundary propagates a malformed journal instead of pins-only fallback" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try boundaryTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    try tmp.dir.createDirPath(io, tool_stats.journal_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = tool_stats.journal_rel, .data = "not json\n" });
    try std.testing.expectError(error.InvalidStatsJournal, rankExtensionTools(alloc, io, cwd, .{}));
}

test "promotion boundary ranks only extension ids, best first, builtin usage ignored" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try boundaryTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    try tool_stats.append(alloc, io, cwd, "builtin.shell", true);
    try tool_stats.append(alloc, io, cwd, "ext:a.pkg/alpha", true);
    try tool_stats.append(alloc, io, cwd, "ext:b.pkg/beta", true);
    try tool_stats.append(alloc, io, cwd, "ext:b.pkg/beta", true);

    const ids = try rankExtensionTools(alloc, io, cwd, .{ .uses_total = 1, .uses_recent = 0, .last_used = 0, .success_rate = 0 });
    defer freeRankedIds(alloc, ids);
    // beta has 2 uses vs alpha's 1; builtin.shell is never a promotion candidate.
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", ids[0]);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", ids[1]);
}

test "promotion boundary propagates invalid weights" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try boundaryTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    try tool_stats.append(alloc, io, cwd, "ext:a.pkg/alpha", true);
    try std.testing.expectError(error.InvalidWeight, rankExtensionTools(alloc, io, cwd, .{ .uses_total = std.math.nan(f64) }));
}
