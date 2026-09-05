//! `nulya skill list|load`: the skill catalog contributed by the extensions a
//! pointer names here, and the frozen `SKILL.md` behind a frozen ref. Both are
//! shell-level reads; neither is a model-facing tool.

const std = @import("std");
const ext_skills = @import("../extension/skills.zig");
const skill_mod = @import("../skill.zig");
const manifest = @import("../extension/manifest.zig");
const common = @import("common.zig");
const StoreView = common.StoreView;
const cwdRealPath = common.cwdRealPath;
const printOut = common.printOut;
const printErr = common.printErr;

pub fn dispatchSkill(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return common.usageSection(io, common.skill_usage);
    if (std.mem.eql(u8, args[0], "list")) return skillList(alloc, io);
    if (std.mem.eql(u8, args[0], "load")) return skillLoad(alloc, io, args[1..]);
    try common.printErrFmt(alloc, io, "unknown `skill` subcommand '{s}'; run `nulya help`\n", .{args[0]});
    return 1;
}

/// The word `skill list` prints for a skill's surface. The vocabulary is the
/// manifest's own, so a reader who has seen one has seen the other.
fn surfaceWord(s: skill_mod.SkillDescriptor) manifest.SkillSurface {
    return if (s.reference) .reference else .auto;
}

fn skillList(alloc: std.mem.Allocator, io: std.Io) !u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var view = try StoreView.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer view.deinit(alloc);

    const skills = try ext_skills.listActive(alloc, &view.site);
    defer skills.deinit(alloc);
    if (skills.skills.len == 0) {
        try printOut(alloc, io, "no skills\n", .{});
        return 0;
    }
    for (skills.skills) |s| {
        try printOut(alloc, io, "{s}\t{s}\t{s}\t{s}\n", .{ s.ref, s.name, s.description, @tagName(surfaceWord(s)) });
    }
    return 0;
}

fn skillLoad(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya skill load <skill-ref>\n");
        return 1;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var view = try StoreView.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer view.deinit(alloc);
    const body = ext_skills.loadFrozenInStore(alloc, &view.site, args[0]) catch |err| {
        try printOut(alloc, io, "skill load failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer alloc.free(body);
    try printOut(alloc, io, "{s}\n", .{body});
    return 0;
}
