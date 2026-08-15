//! Deterministic, usage-driven tool selection policy (DESIGN §5.1 rule 3).
//!
//! Pure policy: candidate stable ids + usage journal events + weights in,
//! ranked candidates out. The module performs no I/O, reads no config, no
//! extension store, no `current` pointer, and no manifests; it never builds a
//! `Tool` or a `Binding` and never touches `SessionComposition`. The future
//! selection wiring gathers active-extension tool ids, reads the journal via
//! `tool_stats.readAll`, converts `config.RegistryWeights` into `Weights`, and
//! hands all three to `rank` — this commit's data flow stops at `RankedTool[]`.

const std = @import("std");
const tool_stats = @import("tool_stats.zig");

/// Recency window for `uses_recent`: the feature counts a tool's occurrences
/// within the last `recent_event_window` journal events (the whole journal
/// when it is shorter). Journal order is recency — no wall clock is involved.
/// Module-private v0.1 policy constant; not configurable until a real need
/// appears.
const recent_event_window: usize = 32;

/// Narrow, config-agnostic ranking weights with the same semantics as
/// `config.RegistryWeights` (`default.toml [registry.weights]`). A future
/// application/config boundary converts `config.RegistryWeights` into this
/// struct; the policy never imports the config parser.
pub const Weights = struct {
    uses_recent: f64 = 1.0,
    uses_total: f64 = 0.25,
    last_used: f64 = 0.5,
    success_rate: f64 = 1.0,
};

pub const Error = error{
    /// A candidate stable id appears more than once in `candidates`.
    DuplicateCandidateId,
    /// A weight is negative, NaN, or infinite. Zero is a legal weight.
    InvalidWeight,
    OutOfMemory,
};

/// One ranked candidate. `tool_id` borrows the caller's `candidates` input —
/// `rank` does not duplicate ids, so the caller must keep `candidates` alive
/// for as long as the returned slice is in use, and frees the slice itself.
pub const RankedTool = struct {
    tool_id: []const u8,
    score: f64,
};

/// Rank `candidates` by usage, returning only those that have at least one
/// event in the journal, ordered by score descending and stable id ascending.
///
/// Eligibility: a candidate that never appears in `events` is not returned at
/// all — "active but never used" must not be promoted. Explicit pins bypass
/// ranking in a later wiring step; they are not `rank`'s concern.
pub fn rank(
    alloc: std.mem.Allocator,
    candidates: []const []const u8,
    events: []const tool_stats.UseEvent,
    weights: Weights,
) Error![]RankedTool {
    try validateWeights(weights);
    try rejectDuplicateCandidates(candidates);

    const stats = try tool_stats.aggregate(alloc, events);
    defer tool_stats.freeStats(alloc, stats);

    var out: std.ArrayList(RankedTool) = .empty;
    errdefer out.deinit(alloc);

    for (candidates) |id| {
        const s = findStats(stats, id) orelse continue;
        try out.append(alloc, .{ .tool_id = id, .score = computeScore(s, events, weights) });
    }

    // Deterministic order, independent of candidate input order and journal
    // traversal: score descending, then stable id ascending (DESIGN §5.2).
    std.mem.sort(RankedTool, out.items, {}, struct {
        fn lessThan(_: void, a: RankedTool, b: RankedTool) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.tool_id, b.tool_id);
        }
    }.lessThan);

    return out.toOwnedSlice(alloc);
}

/// Four bounded features, each within [0, 1], so raw usage totals cannot grow
/// without bound and eventually drown the other signals.
fn computeScore(s: tool_stats.Stats, events: []const tool_stats.UseEvent, weights: Weights) f64 {
    const total_signal = boundedRatio(s.uses_total);
    const recent_signal = boundedRatio(countRecent(events, s.tool_id));
    // `s` came from `aggregate(events)`, so it has at least one event and
    // `events.len - 1` is a valid `global_last` index.
    const global_last: u64 = @intCast(events.len - 1);
    const age = global_last - s.last_used_seq;
    const last_used_signal = 1.0 / (@as(f64, @floatFromInt(age)) + 1.0);
    const success_signal = s.successRate();

    return weights.uses_recent * recent_signal +
        weights.uses_total * total_signal +
        weights.last_used * last_used_signal +
        weights.success_rate * success_signal;
}

/// n / (n + 1): a monotone map from an unbounded count onto [0, 1).
fn boundedRatio(n: u64) f64 {
    return @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(n)) + 1.0);
}

/// Count occurrences of `id` in the last `recent_event_window` events, or in
/// the whole journal when it is shorter.
fn countRecent(events: []const tool_stats.UseEvent, id: []const u8) u64 {
    const start = if (events.len > recent_event_window) events.len - recent_event_window else 0;
    var count: u64 = 0;
    for (events[start..]) |e| {
        if (std.mem.eql(u8, e.tool_id, id)) count += 1;
    }
    return count;
}

fn findStats(stats: []const tool_stats.Stats, id: []const u8) ?tool_stats.Stats {
    for (stats) |s| {
        if (std.mem.eql(u8, s.tool_id, id)) return s;
    }
    return null;
}

fn validateWeights(weights: Weights) error{InvalidWeight}!void {
    if (!isValidWeight(weights.uses_recent)) return error.InvalidWeight;
    if (!isValidWeight(weights.uses_total)) return error.InvalidWeight;
    if (!isValidWeight(weights.last_used)) return error.InvalidWeight;
    if (!isValidWeight(weights.success_rate)) return error.InvalidWeight;
}

/// A weight is valid iff it is a non-negative finite number; NaN and ±inf
/// would silently poison every score, so they are rejected up front.
fn isValidWeight(w: f64) bool {
    if (std.math.isNan(w)) return false;
    if (std.math.isInf(w)) return false;
    return w >= 0;
}

/// Candidate sets are tiny; an O(n²) check keeps the module free of hash maps
/// and still rejects a doubled id loudly instead of silently deduping.
fn rejectDuplicateCandidates(candidates: []const []const u8) error{DuplicateCandidateId}!void {
    for (candidates, 0..) |a, i| {
        for (candidates[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) return error.DuplicateCandidateId;
        }
    }
}

test "a candidate with no journal usage is not eligible" {
    const candidates = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta" };
    const events = [_]tool_stats.UseEvent{
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
        .{ .tool_id = "ext:a.pkg/alpha", .ok = false },
    };

    const ranked = try rank(std.testing.allocator, &candidates, &events, .{});
    defer std.testing.allocator.free(ranked);

    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", ranked[0].tool_id);
}

test "total usage raises the score with uses_total" {
    const candidates = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta" };
    const events = [_]tool_stats.UseEvent{
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
        .{ .tool_id = "ext:b.pkg/beta", .ok = true },
    };

    const ranked = try rank(std.testing.allocator, &candidates, &events, .{ .uses_total = 1, .uses_recent = 0, .last_used = 0, .success_rate = 0 });
    defer std.testing.allocator.free(ranked);

    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", ranked[0].tool_id);
    // 3/(3+1) vs 1/(1+1); the other features are multiplied by weight 0.
    try std.testing.expectApproxEqAbs(0.75, ranked[0].score, 1e-9);
    try std.testing.expectApproxEqAbs(0.5, ranked[1].score, 1e-9);
}

test "recent usage wins with uses_recent, older history ignored" {
    const candidates = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta" };
    var events: [41]tool_stats.UseEvent = undefined;
    // alpha was used 9 times long ago; the 31 slots after it are a
    // non-candidate id; beta was used once inside the last 32-event window.
    for (0..9) |i| events[i] = .{ .tool_id = "ext:a.pkg/alpha", .ok = true };
    for (9..40) |i| events[i] = .{ .tool_id = "builtin.shell", .ok = true };
    events[40] = .{ .tool_id = "ext:b.pkg/beta", .ok = true };

    const ranked = try rank(std.testing.allocator, &candidates, &events, .{ .uses_recent = 1, .uses_total = 0, .last_used = 0, .success_rate = 0 });
    defer std.testing.allocator.free(ranked);

    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    // beta is the only candidate inside the last 32 events: 1/(1+1) vs 0.
    try std.testing.expectEqualStrings("ext:b.pkg/beta", ranked[0].tool_id);
    try std.testing.expectApproxEqAbs(0.5, ranked[0].score, 1e-9);
    try std.testing.expectApproxEqAbs(0.0, ranked[1].score, 1e-9);
}

test "last_used ranks the most recently called tool first" {
    const candidates = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta" };
    var events: [11]tool_stats.UseEvent = undefined;
    events[0] = .{ .tool_id = "ext:a.pkg/alpha", .ok = true };
    for (1..10) |i| events[i] = .{ .tool_id = "builtin.shell", .ok = true };
    events[10] = .{ .tool_id = "ext:b.pkg/beta", .ok = true };

    const ranked = try rank(std.testing.allocator, &candidates, &events, .{ .last_used = 1, .uses_recent = 0, .uses_total = 0, .success_rate = 0 });
    defer std.testing.allocator.free(ranked);

    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    // beta's last call is the journal tail (age 0); alpha's is 10 events back.
    try std.testing.expectEqualStrings("ext:b.pkg/beta", ranked[0].tool_id);
    try std.testing.expectApproxEqAbs(1.0, ranked[0].score, 1e-9);
    try std.testing.expectApproxEqAbs(1.0 / 11.0, ranked[1].score, 1e-9);
}

test "success_rate ranks the higher-success tool first" {
    const candidates = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta" };
    const events = [_]tool_stats.UseEvent{
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
        .{ .tool_id = "ext:b.pkg/beta", .ok = true },
        .{ .tool_id = "ext:a.pkg/alpha", .ok = false },
    };

    const ranked = try rank(std.testing.allocator, &candidates, &events, .{ .success_rate = 1, .uses_recent = 0, .uses_total = 0, .last_used = 0 });
    defer std.testing.allocator.free(ranked);

    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", ranked[0].tool_id); // 1/1
    try std.testing.expectApproxEqAbs(1.0, ranked[0].score, 1e-9);
    try std.testing.expectApproxEqAbs(0.5, ranked[1].score, 1e-9); // 1/2
}

test "default weights produce a deterministic combined ranking" {
    // Deliberately scrambled candidate input order: gamma, alpha, beta.
    const candidates = [_][]const u8{ "ext:gamma/three", "ext:alpha/one", "ext:beta/two" };
    const events = [_]tool_stats.UseEvent{
        .{ .tool_id = "ext:alpha/one", .ok = true },
        .{ .tool_id = "ext:beta/two", .ok = true },
        .{ .tool_id = "ext:alpha/one", .ok = true },
        .{ .tool_id = "ext:gamma/three", .ok = false },
        .{ .tool_id = "ext:beta/two", .ok = true },
        .{ .tool_id = "ext:gamma/three", .ok = true },
    };

    const ranked = try rank(std.testing.allocator, &candidates, &events, .{});
    defer std.testing.allocator.free(ranked);

    // Hand-computed with default weights (uses_recent=1, uses_total=0.25,
    // last_used=0.5, success_rate=1). All three have 2 uses and 2 recent hits:
    //   beta/two:    2/3 + (2/3)/4 + 0.5*0.5   + 1.0 = 25/12
    //   alpha/one:   2/3 + (2/3)/4 + 0.5*0.25  + 1.0 = 47/24
    //   gamma/three: 2/3 + (2/3)/4 + 0.5*1.0   + 0.5 = 11/6
    try std.testing.expectEqual(@as(usize, 3), ranked.len);
    try std.testing.expectEqualStrings("ext:beta/two", ranked[0].tool_id);
    try std.testing.expectEqualStrings("ext:alpha/one", ranked[1].tool_id);
    try std.testing.expectEqualStrings("ext:gamma/three", ranked[2].tool_id);
    try std.testing.expectApproxEqAbs(25.0 / 12.0, ranked[0].score, 1e-9);
    try std.testing.expectApproxEqAbs(47.0 / 24.0, ranked[1].score, 1e-9);
    try std.testing.expectApproxEqAbs(11.0 / 6.0, ranked[2].score, 1e-9);

    // Running again yields the identical slice — no hidden state, no order
    // dependence on the caller's candidate arrangement.
    const again = try rank(std.testing.allocator, &candidates, &events, .{});
    defer std.testing.allocator.free(again);
    for (ranked, again) |r, a| {
        try std.testing.expectEqualStrings(r.tool_id, a.tool_id);
        try std.testing.expectApproxEqAbs(r.score, a.score, 1e-12);
    }
}

test "an exact score tie breaks lexically by stable id, independent of input order" {
    const events = [_]tool_stats.UseEvent{
        .{ .tool_id = "ext:b.pkg/beta", .ok = true },
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
    };

    const first = try rank(std.testing.allocator, &.{ "ext:b.pkg/beta", "ext:a.pkg/alpha" }, &events, .{ .uses_total = 1, .uses_recent = 0, .last_used = 0, .success_rate = 0 });
    defer std.testing.allocator.free(first);
    const second = try rank(std.testing.allocator, &.{ "ext:a.pkg/alpha", "ext:b.pkg/beta" }, &events, .{ .uses_total = 1, .uses_recent = 0, .last_used = 0, .success_rate = 0 });
    defer std.testing.allocator.free(second);

    for ([_][]const RankedTool{ first, second }) |r| {
        try std.testing.expectEqual(@as(usize, 2), r.len);
        try std.testing.expectEqualStrings("ext:a.pkg/alpha", r[0].tool_id);
        try std.testing.expectEqualStrings("ext:b.pkg/beta", r[1].tool_id);
        try std.testing.expectApproxEqAbs(0.5, r[0].score, 1e-9);
        try std.testing.expectApproxEqAbs(0.5, r[1].score, 1e-9);
    }
}

test "events for ids outside the candidate list are ignored" {
    const candidates = [_][]const u8{"ext:a.pkg/alpha"};
    const events = [_]tool_stats.UseEvent{
        .{ .tool_id = "builtin.shell", .ok = true },
        .{ .tool_id = "ext:other.pkg/tool", .ok = true },
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
    };

    const ranked = try rank(std.testing.allocator, &candidates, &events, .{});
    defer std.testing.allocator.free(ranked);

    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", ranked[0].tool_id);
}

test "a duplicated candidate id is rejected, not silently deduped" {
    const candidates = [_][]const u8{ "ext:a.pkg/alpha", "ext:a.pkg/alpha" };
    const events = [_]tool_stats.UseEvent{.{ .tool_id = "ext:a.pkg/alpha", .ok = true }};

    try std.testing.expectError(error.DuplicateCandidateId, rank(std.testing.allocator, &candidates, &events, .{}));
}

test "negative, NaN, and infinite weights are rejected; zero is legal" {
    const candidates = [_][]const u8{"ext:a.pkg/alpha"};
    const events = [_]tool_stats.UseEvent{.{ .tool_id = "ext:a.pkg/alpha", .ok = true }};

    try std.testing.expectError(error.InvalidWeight, rank(std.testing.allocator, &candidates, &events, .{ .uses_recent = -1.0 }));
    try std.testing.expectError(error.InvalidWeight, rank(std.testing.allocator, &candidates, &events, .{ .uses_total = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidWeight, rank(std.testing.allocator, &candidates, &events, .{ .last_used = std.math.inf(f64) }));
    try std.testing.expectError(error.InvalidWeight, rank(std.testing.allocator, &candidates, &events, .{ .success_rate = -std.math.inf(f64) }));

    const ranked = try rank(std.testing.allocator, &candidates, &events, .{ .uses_total = 0 });
    defer std.testing.allocator.free(ranked);
    try std.testing.expectEqual(@as(usize, 1), ranked.len);
}

test "ranking does not mutate events or candidates" {
    const candidates = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta" };
    const events = [_]tool_stats.UseEvent{
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
        .{ .tool_id = "ext:b.pkg/beta", .ok = false },
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
    };

    const ranked = try rank(std.testing.allocator, &candidates, &events, .{});
    defer std.testing.allocator.free(ranked);
    try std.testing.expectEqual(@as(usize, 2), ranked.len);

    // rank receives const slices and only reads them; the observable input
    // content is untouched after the call.
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", candidates[0]);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", candidates[1]);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[0].tool_id);
    try std.testing.expect(events[0].ok);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", events[1].tool_id);
    try std.testing.expect(!events[1].ok);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[2].tool_id);
    try std.testing.expect(events[2].ok);
}
