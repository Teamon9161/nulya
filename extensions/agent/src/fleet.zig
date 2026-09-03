//! Which model a RUNG lands on.
//!
//! A definition may name a rung (`model: @explore`) instead of a model, and the
//! answer depends on the profile the delegation inherits: `explore` on `openai`
//! is one model id, on `deepseek` another. That is the whole point — changing
//! the model a conversation runs on changes what its delegations run on, in one
//! move and with nothing frozen anywhere.
//!
//! The table belongs to the kernel's config chain, so the answer is asked of
//! `nulya config show --json` and never read out of a file here.
//!
//! A profile that staffs no such rung answers null, and the caller reads that as
//! plain inheritance: a fleet must not stop working because the provider it just
//! moved to names fewer rungs.

const std = @import("std");

pub const Rung = struct {
    /// Empty means "the profile that was asked about": a rung value with no `/`
    /// names one of that profile's own model ids.
    profile: []const u8 = "",
    model: []const u8,
    /// This rung's own effort, for the steps of the delegated session. Empty
    /// means nobody said, and the kernel's own default decides.
    effort: []const u8 = "",
};

/// Find `rung` on `profile` in a `config show --json` payload. Null for every
/// way of not finding it — no such profile, no such rung, a payload that does
/// not parse — because they all mean the same thing to the caller.
pub fn find(
    alloc: std.mem.Allocator,
    payload: []const u8,
    profile: []const u8,
    rung: []const u8,
) ?Rung {
    if (profile.len == 0 or rung.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return null;
    if (parsed.value != .object) return null;
    const profiles = switch (parsed.value.object.get("profiles") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    for (profiles.items) |entry| {
        if (entry != .object) continue;
        if (!eqlField(entry.object, "name", profile)) continue;
        const roles = switch (entry.object.get("roles") orelse return null) {
            .array => |a| a,
            else => return null,
        };
        for (roles.items) |role| {
            if (role != .object) continue;
            if (!eqlField(role.object, "name", rung)) continue;
            const model = stringOf(role.object, "model") orelse return null;
            return split(model, stringOf(role.object, "effort") orelse "");
        }
        // The profile was found and does not staff this rung: no other profile
        // can answer for it.
        return null;
    }
    return null;
}

/// `<model-id>` on the profile asked about, or `<profile>/<model-id>` somewhere
/// else. A pair, never a mix: crossing to another profile takes its model id
/// with it.
fn split(model: []const u8, effort: []const u8) ?Rung {
    const at = std.mem.indexOfScalar(u8, model, '/') orelse
        return if (model.len == 0) null else .{ .model = model, .effort = effort };
    const other = model[0..at];
    const id = model[at + 1 ..];
    if (other.len == 0 or id.len == 0) return null;
    return .{ .profile = other, .model = id, .effort = effort };
}

/// The profile the config chain opens on — what a delegation inherits when
/// there is no session to inherit from.
pub fn activeProfile(alloc: std.mem.Allocator, payload: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return null;
    if (parsed.value != .object) return null;
    return stringOf(parsed.value.object, "active_profile");
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

fn eqlField(obj: std.json.ObjectMap, key: []const u8, want: []const u8) bool {
    const got = stringOf(obj, key) orelse return false;
    return std.mem.eql(u8, got, want);
}

const test_payload =
    \\{"profiles":[
    \\  {"name":"openai","roles":[{"name":"explore","model":"gpt-5.6-luna","effort":null},
    \\                            {"name":"review","model":"gpt-5.6-terra","effort":"high"},
    \\                            {"name":"cheap","model":"deepseek/deepseek-v4-flash","effort":null}]},
    \\  {"name":"anthropic","roles":[]}
    \\]}
;

test "a rung resolves within its own profile, and its effort comes along" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const bare = find(a, test_payload, "openai", "explore").?;
    try std.testing.expectEqualStrings("", bare.profile);
    try std.testing.expectEqualStrings("gpt-5.6-luna", bare.model);
    try std.testing.expectEqualStrings("", bare.effort);

    const dialled = find(a, test_payload, "openai", "review").?;
    try std.testing.expectEqualStrings("high", dialled.effort);
}

test "a rung value with a slash crosses to another profile, taking its model id" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const crossed = find(arena.allocator(), test_payload, "openai", "cheap").?;
    try std.testing.expectEqualStrings("deepseek", crossed.profile);
    try std.testing.expectEqualStrings("deepseek-v4-flash", crossed.model);
}

test "the active profile is read from the same payload, and a bad one is null" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("openai", activeProfile(a, "{\"active_profile\":\"openai\"}").?);
    try std.testing.expect(activeProfile(a, test_payload) == null);
    try std.testing.expect(activeProfile(a, "not json") == null);
}

test "an unstaffed rung, an unknown profile and an unparseable payload are one answer" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expect(find(a, test_payload, "anthropic", "explore") == null);
    try std.testing.expect(find(a, test_payload, "nobody", "explore") == null);
    try std.testing.expect(find(a, "not json", "openai", "explore") == null);
    try std.testing.expect(find(a, test_payload, "openai", "") == null);
}
