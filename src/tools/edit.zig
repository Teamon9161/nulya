//! Builtin tool: edit (base-tools.md §4).
//!
//! `{ path, old_string, new_string, replace_all? }`. Exact-string replacement.
//! The match itself is the validation — there is no read-before-edit gate.
//! Failures teach: no match -> say so; ambiguous match -> report the count so
//! the model can add surrounding context (base-tools.md §1).

const std = @import("std");
const tool = @import("../tool.zig");
const emit = @import("../emit.zig");

const MAX_FILE_BYTES: usize = 10 * 1024 * 1024;

pub const def: tool.Tool = .{
    .definition = .{
        .id = "builtin.edit",
        .name = "edit",
        .description = "Exact-string replace in a file.",
        .input_schema =
            \\{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}
        ,
    },
    .run = run,
};

fn run(alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.ToolResult {
    const rel_path = try tool.requireString(req.args, "path");
    const old_string = try tool.requireString(req.args, "old_string");
    const new_string = try tool.requireString(req.args, "new_string");
    const replace_all = blk: {
        if (req.args == .object) {
            if (req.args.object.get("replace_all")) |v| {
                if (v != .bool) return teach(alloc, req, "replace_all must be a boolean when provided");
                break :blk v.bool;
            }
        }
        break :blk false;
    };

    if (old_string.len == 0)
        return teach(alloc, req, "old_string is empty; give the exact text to replace");
    if (std.mem.eql(u8, old_string, new_string))
        return teach(alloc, req, "old_string equals new_string; nothing to change");
    // Reject clip markers so a copied-from-truncated-output string fails loudly.
    if (std.mem.indexOf(u8, old_string, "…[+") != null)
        return teach(alloc, req, "old_string contains a clip marker '…[+…]'; fetch the exact text with `rg`/`sed -n` first");

    const path = try resolvePath(alloc, req.ctx.cwd, rel_path);
    defer alloc.free(path);

    const cwd = std.Io.Dir.cwd();
    const contents = cwd.readFileAlloc(req.ctx.io, path, alloc, .limited(MAX_FILE_BYTES)) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "cannot read {s}: {s}", .{ path, @errorName(err) });
        defer alloc.free(msg);
        return finish(alloc, req, false, msg);
    };
    defer alloc.free(contents);

    const count = std.mem.count(u8, contents, old_string);
    if (count == 0)
        return teach(alloc, req, "old_string not found in file; check whitespace/indentation and try a larger unique snippet");
    if (count > 1 and !replace_all) {
        const msg = try std.fmt.allocPrint(alloc, "old_string matches {d} times; add surrounding context to make it unique, or pass replace_all:true", .{count});
        defer alloc.free(msg);
        return finish(alloc, req, false, msg);
    }

    const updated = try std.mem.replaceOwned(u8, alloc, contents, old_string, new_string);
    defer alloc.free(updated);

    atomicWriteFile(req.ctx.io, path, updated) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "cannot atomically write {s}: {s}", .{ path, @errorName(err) });
        defer alloc.free(msg);
        return finish(alloc, req, false, msg);
    };

    const msg = try std.fmt.allocPrint(alloc, "edited {s}: {d} replacement(s)", .{ rel_path, count });
    defer alloc.free(msg);
    return finish(alloc, req, true, msg);
}

fn atomicWriteFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var atomic = try cwd.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn resolvePath(alloc: std.mem.Allocator, cwd: []const u8, rel: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(rel)) return alloc.dupe(u8, rel);
    return std.fs.path.join(alloc, &.{ cwd, rel });
}

fn teach(alloc: std.mem.Allocator, req: tool.ToolRequest, msg: []const u8) !tool.ToolResult {
    return finish(alloc, req, false, msg);
}

fn finish(alloc: std.mem.Allocator, req: tool.ToolRequest, ok: bool, raw: []const u8) !tool.ToolResult {
    const out = try emit.emit(alloc, req.ctx.io, raw, "edit", req.ctx.event_seq, req.ctx.call_index, req.ctx.scratch_dir, req.ctx.budget);
    return .{ .ok = ok, .output = out.text, .spill_path = out.spill_path };
}
