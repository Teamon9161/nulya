//! Builtin tool: edit (base-tools.md §4).
//!
//! `{ path, old_string, new_string, replace_all? }`. Exact-string replacement.
//! The match itself is the validation — there is no read-before-edit gate.
//! Failures teach: no match -> say so; ambiguous match -> report the count so
//! the model can add surrounding context (base-tools.md §1).

const std = @import("std");
const tool = @import("../tool.zig");

const MAX_FILE_BYTES: usize = 10 * 1024 * 1024;

pub const def: tool.Tool = .{
    .name = "edit",
    .description = "Exact-string replace in a file. Args: {path, old_string, new_string, replace_all?}.",
    .run = run,
};

fn run(alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.ToolResult {
    const rel_path = try tool.requireString(req.args, "path");
    const old_string = try tool.requireString(req.args, "old_string");
    const new_string = try tool.requireString(req.args, "new_string");
    const replace_all = blk: {
        if (req.args == .object) {
            if (req.args.object.get("replace_all")) |v| {
                if (v == .bool) break :blk v.bool;
            }
        }
        break :blk false;
    };

    if (old_string.len == 0)
        return teach(alloc, "old_string is empty; give the exact text to replace");
    if (std.mem.eql(u8, old_string, new_string))
        return teach(alloc, "old_string equals new_string; nothing to change");
    // Reject clip markers so a copied-from-truncated-output string fails loudly.
    if (std.mem.indexOf(u8, old_string, "…[+") != null)
        return teach(alloc, "old_string contains a clip marker '…[+…]'; fetch the exact text with `rg`/`sed -n` first");

    const path = try resolvePath(alloc, req.ctx.cwd, rel_path);
    defer alloc.free(path);

    const cwd = std.Io.Dir.cwd();
    const contents = cwd.readFileAlloc(req.ctx.io, path, alloc, .limited(MAX_FILE_BYTES)) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "cannot read {s}: {s}", .{ path, @errorName(err) });
        return .{ .ok = false, .output = msg };
    };
    defer alloc.free(contents);

    const count = std.mem.count(u8, contents, old_string);
    if (count == 0)
        return teach(alloc, "old_string not found in file; check whitespace/indentation and try a larger unique snippet");
    if (count > 1 and !replace_all) {
        const msg = try std.fmt.allocPrint(alloc, "old_string matches {d} times; add surrounding context to make it unique, or pass replace_all:true", .{count});
        return .{ .ok = false, .output = msg };
    }

    const updated = try std.mem.replaceOwned(u8, alloc, contents, old_string, new_string);
    defer alloc.free(updated);

    cwd.writeFile(req.ctx.io, .{ .sub_path = path, .data = updated }) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "cannot write {s}: {s}", .{ path, @errorName(err) });
        return .{ .ok = false, .output = msg };
    };

    const msg = try std.fmt.allocPrint(alloc, "edited {s}: {d} replacement(s)", .{ rel_path, count });
    return .{ .ok = true, .output = msg };
}

fn resolvePath(alloc: std.mem.Allocator, cwd: []const u8, rel: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(rel)) return alloc.dupe(u8, rel);
    return std.fs.path.join(alloc, &.{ cwd, rel });
}

fn teach(alloc: std.mem.Allocator, msg: []const u8) !tool.ToolResult {
    return .{ .ok = false, .output = try alloc.dupe(u8, msg) };
}
