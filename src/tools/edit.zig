//! Builtin tool: edit (base-tools.md §4).
//!
//! `{ path, old_string, new_string, replace_all? }`. Exact-string replacement.
//! The match itself is the validation — there is no read-before-edit gate.
//! Failures teach: no match -> say so; ambiguous match -> report the count so
//! the model can add surrounding context (base-tools.md §1).

const std = @import("std");
const tool = @import("../tool.zig");
const environment = @import("../environment.zig");

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
    .executor = tool.functionExecutor(run),
};

fn run(alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
    const parsed = try tool.parseArgs(alloc, req.args_json);
    defer parsed.deinit();
    const args = parsed.value;

    const rel_path = try tool.requireString(args, "path");
    const old_string = try tool.requireString(args, "old_string");
    const new_string = try tool.requireString(args, "new_string");
    const replace_all = blk: {
        if (args == .object) {
            if (args.object.get("replace_all")) |v| {
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

    const contents = req.ctx.fs.readFileAlloc(alloc, path, MAX_FILE_BYTES) catch |err| switch (err) {
        // Cancellation propagates to the step boundary; it must never be wrapped
        // into an ordinary "cannot read" tool failure (DESIGN §4).
        error.Canceled => return error.Canceled,
        else => {
            const msg = try std.fmt.allocPrint(alloc, "cannot read {s}: {s}", .{ path, @errorName(err) });
            defer alloc.free(msg);
            return finish(alloc, req, false, msg);
        },
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

    req.ctx.fs.atomicWriteFile(path, updated) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            const msg = try std.fmt.allocPrint(alloc, "cannot atomically write {s}: {s}", .{ path, @errorName(err) });
            defer alloc.free(msg);
            return finish(alloc, req, false, msg);
        },
    };

    const msg = try std.fmt.allocPrint(alloc, "edited {s}: {d} replacement(s)", .{ rel_path, count });
    defer alloc.free(msg);
    return finish(alloc, req, true, msg);
}

fn resolvePath(alloc: std.mem.Allocator, cwd: []const u8, rel: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(rel)) return alloc.dupe(u8, rel);
    return std.fs.path.join(alloc, &.{ cwd, rel });
}

fn teach(alloc: std.mem.Allocator, req: tool.ToolRequest, msg: []const u8) !tool.RawToolResult {
    _ = req;
    return .{ .ok = false, .output = try alloc.dupe(u8, msg) };
}

fn finish(alloc: std.mem.Allocator, req: tool.ToolRequest, ok: bool, raw: []const u8) !tool.RawToolResult {
    _ = req;
    return .{ .ok = ok, .output = try alloc.dupe(u8, raw) };
}

test "edit preserves executable file permissions" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "script.sh", .data = "echo old\n" });
    try tmp.dir.setFilePermissions(io, "script.sh", .executable_file, .{});

    var before_file = try tmp.dir.openFile(io, "script.sh", .{});
    const before = (try before_file.stat(io)).permissions;
    before_file.close(io);

    const tmp_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer alloc.free(tmp_path);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const res = try run(alloc, .{
        .args_json = "{\"path\":\"script.sh\",\"old_string\":\"old\",\"new_string\":\"new\"}",
        .ctx = .{
            .environment = lenv.environment(),
            .fs = lenv.workspaceFs(),
            .cwd = tmp_path,
        },
    });
    defer {
        alloc.free(res.output);
    }
    try std.testing.expect(res.ok);

    var after_file = try tmp.dir.openFile(io, "script.sh", .{});
    defer after_file.close(io);
    const after = (try after_file.stat(io)).permissions;
    try std.testing.expectEqual(before, after);
}

test "edit reads and writes through workspace fs" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const FakeFs = struct {
        alloc: std.mem.Allocator,
        contents: []const u8,
        read_count: usize = 0,
        write_count: usize = 0,
        read_path: ?[]u8 = null,
        write_path: ?[]u8 = null,
        written: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.read_path) |p| self.alloc.free(p);
            if (self.write_path) |p| self.alloc.free(p);
            if (self.written) |p| self.alloc.free(p);
        }

        fn fs(self: *@This()) environment.WorkspaceFs {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn readFileAlloc(ptr: *anyopaque, a: std.mem.Allocator, path: []const u8, max_bytes: usize) anyerror![]u8 {
            _ = max_bytes;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.read_count += 1;
            if (self.read_path) |p| self.alloc.free(p);
            self.read_path = try self.alloc.dupe(u8, path);
            return a.dupe(u8, self.contents);
        }

        fn atomicWriteFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.write_count += 1;
            if (self.write_path) |p| self.alloc.free(p);
            self.write_path = try self.alloc.dupe(u8, path);
            if (self.written) |p| self.alloc.free(p);
            self.written = try self.alloc.dupe(u8, data);
        }

        const vtable: environment.WorkspaceFs.VTable = .{
            .readFileAlloc = readFileAlloc,
            .atomicWriteFile = atomicWriteFile,
        };
    };

    var fake = FakeFs{ .alloc = alloc, .contents = "alpha old beta\n" };
    defer fake.deinit();

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const res = try run(alloc, .{
        .args_json = "{\"path\":\"dir/file.txt\",\"old_string\":\"old\",\"new_string\":\"new\"}",
        .ctx = .{
            .environment = lenv.environment(),
            .fs = fake.fs(),
            .cwd = "workspace",
        },
    });
    defer alloc.free(res.output);

    try std.testing.expect(res.ok);
    try std.testing.expectEqual(@as(usize, 1), fake.read_count);
    try std.testing.expectEqual(@as(usize, 1), fake.write_count);
    try std.testing.expectEqualStrings("alpha new beta\n", fake.written.?);
    try std.testing.expectEqualStrings(fake.read_path.?, fake.write_path.?);
    try std.testing.expect(std.mem.endsWith(u8, fake.write_path.?, "dir/file.txt"));
}
