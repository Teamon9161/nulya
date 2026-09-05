//! `[extensions] with` in the user config file, edited as text.
//!
//! What `ext activate` writes down when a package's manifest declares an
//! installer default, and what `ext deactivate` takes back. Exactly one key in
//! exactly one file changes and every other byte survives — comments, ordering
//! and spacing are a person's own text, and a program that owns one key in
//! their file does not get to reformat the rest.
//!
//! Every write is read back and reverted unless the file parses to what was
//! asked for. That check is the point: this is surgery on text, and a surgery
//! that silently produced something the kernel reads differently would leave a
//! package looking installed that no session ever carries.

const std = @import("std");
const toml = @import("toml");

const table_name = "extensions";
const key_name = "with";

const RawFile = struct {
    extensions: ?RawExtensions = null,
};

const RawExtensions = struct {
    with: ?[]const []const u8 = null,
};

/// The member list this text writes, duped into `alloc`. Empty when the key is
/// absent; `error.Unparseable` when the file will not parse — a config that
/// cannot be read is not an empty one, and repairing it is not ours to do.
pub fn read(alloc: std.mem.Allocator, text: []const u8) ![][]u8 {
    var parser = toml.Parser(RawFile).init(alloc);
    defer parser.deinit();
    const parsed = parser.parseString(text) catch return error.Unparseable;
    defer parsed.deinit();

    const written = if (parsed.value.extensions) |e| e.with orelse &.{} else &.{};
    const out = try alloc.alloc([]u8, written.len);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |m| alloc.free(m);
        alloc.free(out);
    }
    for (written, out) |src, *slot| {
        slot.* = try alloc.dupe(u8, src);
        made += 1;
    }
    return out;
}

pub fn free(alloc: std.mem.Allocator, members: [][]u8) void {
    for (members) |m| alloc.free(m);
    alloc.free(members);
}

/// The id half of a member spec — everything before `@version` or `:tools`.
pub fn idOf(spec: []const u8) []const u8 {
    const cut = std.mem.indexOfAny(u8, spec, "@:") orelse spec.len;
    return spec[0..cut];
}

fn indexOfId(members: []const []const u8, id: []const u8) ?usize {
    for (members, 0..) |m, i| {
        if (std.mem.eql(u8, idOf(m), id)) return i;
    }
    return null;
}

/// A `[table]` or `[[array]]` header line, and the name it opens.
fn tableOf(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len < 2 or t[0] != '[' or t[t.len - 1] != ']') return null;
    var inner = t[1 .. t.len - 1];
    if (inner.len >= 2 and inner[0] == '[' and inner[inner.len - 1] == ']') inner = inner[1 .. inner.len - 1];
    return std.mem.trim(u8, inner, " \t");
}

fn opensKey(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, t, key_name)) return false;
    const after = std.mem.trimStart(u8, t[key_name.len..], " \t");
    return after.len > 0 and after[0] == '=';
}

/// Brackets outside of quotes, so a member containing `]` cannot end the array.
fn bracketDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (c == '\\' and q == '"') i += 1 else if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '#' => return delta,
            '[' => delta += 1,
            ']' => delta -= 1,
            else => {},
        }
    }
    return delta;
}

fn renderKey(w: *std.Io.Writer, members: []const []const u8) !void {
    try w.print("{s} = [", .{key_name});
    for (members, 0..) |m, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeByte('"');
        for (m) |c| {
            if (c == '"' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
        try w.writeByte('"');
    }
    try w.writeAll("]");
}

/// `text` with the member list replaced — or the key added under an existing
/// `[extensions]`, or the table appended. Every byte outside that one key is
/// copied through, line endings included.
pub fn setMembers(alloc: std.mem.Allocator, text: []const u8, members: []const []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(alloc, line);
    // A trailing newline leaves an empty last element; it is the file's ending,
    // not a line, and is put back by the join.
    const ends_with_newline = lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0;
    if (ends_with_newline) _ = lines.pop();
    const crlf = std.mem.indexOf(u8, text, "\r\n") != null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    var table: ?[]const u8 = null;
    var section_start: ?usize = null;
    var section_end: ?usize = null;
    var replace_from: ?usize = null;
    var replace_to: usize = 0;
    for (lines.items, 0..) |line, i| {
        if (tableOf(line)) |opened| {
            if (table != null and std.mem.eql(u8, table.?, table_name) and section_end == null) section_end = i;
            table = opened;
            if (std.mem.eql(u8, opened, table_name) and section_start == null) section_start = i;
            continue;
        }
        if (table == null or !std.mem.eql(u8, table.?, table_name)) continue;
        if (replace_from != null or !opensKey(line)) continue;
        // The array may span lines: consume until it closes again.
        var depth = bracketDelta(line);
        var last = i;
        while (depth > 0 and last + 1 < lines.items.len) {
            last += 1;
            depth += bracketDelta(lines.items[last]);
        }
        replace_from = i;
        replace_to = last;
    }

    const insert_at: usize = blk: {
        if (replace_from) |from| break :blk from;
        const start = section_start orelse break :blk lines.items.len;
        var at = section_end orelse lines.items.len;
        while (at > start + 1 and std.mem.trim(u8, lines.items[at - 1], " \t\r").len == 0) at -= 1;
        break :blk at;
    };
    const need_table = section_start == null;

    for (lines.items[0..insert_at], 0..) |line, i| {
        _ = i;
        try w.writeAll(line);
        try w.writeByte('\n');
    }
    if (need_table and insert_at > 0 and std.mem.trim(u8, lines.items[insert_at - 1], " \t\r").len != 0) {
        if (crlf) try w.writeByte('\r');
        try w.writeByte('\n');
    }
    if (need_table) {
        try w.print("[{s}]", .{table_name});
        if (crlf) try w.writeByte('\r');
        try w.writeByte('\n');
    }
    try renderKey(w, members);
    if (crlf) try w.writeByte('\r');
    try w.writeByte('\n');
    const tail_from = if (replace_from == null) insert_at else replace_to + 1;
    for (lines.items[tail_from..]) |line| {
        try w.writeAll(line);
        try w.writeByte('\n');
    }

    const written = out.written();
    // The file kept its own ending: only strip the newline this function adds
    // when the original had none.
    const keep = if (ends_with_newline or written.len == 0) written.len else written.len - 1;
    return alloc.dupe(u8, written[0..keep]);
}

/// What `add` did, so the caller can say it in one line.
pub const Outcome = union(enum) {
    /// The spec is now in the list; the payload is the file it went into.
    added: []const u8,
    /// An entry for this id was already written — a person's own answer, which
    /// an installer default never overwrites.
    already: []const u8,
    /// The file will not parse, or would not read back as written. Nothing on
    /// disk changed.
    refused: []const u8,
};

/// A caller's veto, asked with the whole list this write WOULD produce, before
/// anything reaches the disk — so the answer comes from the same member list
/// the kernel would compose, not from a rule this file re-derives.
pub const Fits = struct {
    ptr: *anyopaque,
    askFn: *const fn (ptr: *anyopaque, members: []const []const u8) bool,

    pub fn ask(self: Fits, members: []const []const u8) bool {
        return self.askFn(self.ptr, members);
    }
};

/// Put `spec` on the user file's member list unless its id is already there.
pub fn add(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    spec: []const u8,
    fits: ?Fits,
) !Outcome {
    const before = readFile(alloc, io, path) catch return .{ .refused = "cannot be read" };
    defer alloc.free(before);

    const current = read(alloc, before) catch return .{ .refused = "will not parse" };
    defer free(alloc, current);
    if (indexOfId(current, idOf(spec)) != null) return .{ .already = path };

    var next: std.ArrayList([]const u8) = .empty;
    defer next.deinit(alloc);
    for (current) |m| try next.append(alloc, m);
    try next.append(alloc, spec);

    if (fits) |gate| {
        if (!gate.ask(next.items)) return .{ .refused = "would not fit" };
    }
    return writeVerified(alloc, io, path, before, next.items);
}

/// Take every entry naming `id` off the list. `already` means there was none.
pub fn remove(alloc: std.mem.Allocator, io: std.Io, path: []const u8, id: []const u8) !Outcome {
    const before = readFile(alloc, io, path) catch return .{ .refused = "cannot be read" };
    defer alloc.free(before);

    const current = read(alloc, before) catch return .{ .refused = "will not parse" };
    defer free(alloc, current);
    if (indexOfId(current, id) == null) return .{ .already = path };

    var next: std.ArrayList([]const u8) = .empty;
    defer next.deinit(alloc);
    for (current) |m| {
        if (std.mem.eql(u8, idOf(m), id)) continue;
        try next.append(alloc, m);
    }
    return writeVerified(alloc, io, path, before, next.items);
}

fn writeVerified(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    before: []const u8,
    members: []const []const u8,
) !Outcome {
    const after = try setMembers(alloc, before, members);
    defer alloc.free(after);
    try writeFile(io, path, after);

    const round_bytes = readFile(alloc, io, path) catch return .{ .refused = "cannot be read back" };
    defer alloc.free(round_bytes);
    const round = read(alloc, round_bytes) catch {
        try writeFile(io, path, before);
        return .{ .refused = "would not parse after the edit" };
    };
    defer free(alloc, round);
    if (!sameList(round, members)) {
        try writeFile(io, path, before);
        return .{ .refused = "did not read back as written" };
    }
    return .{ .added = path };
}

fn sameList(got: []const []u8, want: []const []const u8) bool {
    if (got.len != want.len) return false;
    for (got, want) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

/// A file that is not there yet is an empty config, not a fault: the user layer
/// exists the moment somebody writes to it.
fn readFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var dir = parentDir(io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return alloc.dupe(u8, ""),
        else => return err,
    };
    defer dir.close(io);
    return dir.readFileAlloc(io, std.fs.path.basename(path), alloc, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => try alloc.dupe(u8, ""),
        else => err,
    };
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    var dir = parentDir(io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => blk: {
            const parent = std.fs.path.dirname(path) orelse return err;
            try std.Io.Dir.cwd().createDirPath(io, parent);
            break :blk try parentDir(io, path);
        },
        else => return err,
    };
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = std.fs.path.basename(path), .data = data });
}

/// The config path may be absolute (the user layer) or workspace-relative (a
/// test, a project file), and the two need different doors.
fn parentDir(io: std.Io, path: []const u8) !std.Io.Dir {
    const dir = std.fs.path.dirname(path) orelse ".";
    if (std.fs.path.isAbsolute(dir)) return std.Io.Dir.openDirAbsolute(io, dir, .{});
    return std.Io.Dir.cwd().openDir(io, if (dir.len == 0) "." else dir, .{});
}

test "the key is replaced in place and every other byte survives" {
    const alloc = std.testing.allocator;
    const before =
        \\# mine
        \\[provider]
        \\active_profile = "deepseek"
        \\
        \\[extensions]
        \\# the members of every session
        \\with = ["kong"]
        \\
        \\[registry]
        \\max_tools = 20
        \\
    ;
    const after = try setMembers(alloc, before, &.{ "kong", "std:read,grep" });
    defer alloc.free(after);

    try std.testing.expect(std.mem.indexOf(u8, after, "# mine") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "# the members of every session") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "max_tools = 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "with = [\"kong\", \"std:read,grep\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "with = [\"kong\"]") == null);

    const round = try read(alloc, after);
    defer free(alloc, round);
    try std.testing.expectEqual(@as(usize, 2), round.len);
    try std.testing.expectEqualStrings("std:read,grep", round[1]);
}

test "a multi-line array is one span, and a member holding a bracket does not end it" {
    const alloc = std.testing.allocator;
    const before =
        \\[extensions]
        \\with = [
        \\  "a]b",
        \\  "kong",
        \\]
        \\[registry]
        \\max_tools = 20
        \\
    ;
    const after = try setMembers(alloc, before, &.{"kong"});
    defer alloc.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"a]b\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "max_tools = 20") != null);

    const round = try read(alloc, after);
    defer free(alloc, round);
    try std.testing.expectEqual(@as(usize, 1), round.len);
}

test "the key is added under an existing table, and the table when there is none" {
    const alloc = std.testing.allocator;
    const under = try setMembers(alloc, "[extensions]\n# nothing yet\n\n[registry]\nmax_tools = 6\n", &.{"kong"});
    defer alloc.free(under);
    const at = std.mem.indexOf(u8, under, "with = [\"kong\"]").?;
    try std.testing.expect(at < std.mem.indexOf(u8, under, "[registry]").?);
    try std.testing.expect(at > std.mem.indexOf(u8, under, "# nothing yet").?);

    const fresh = try setMembers(alloc, "", &.{"kong"});
    defer alloc.free(fresh);
    try std.testing.expectEqualStrings("[extensions]\nwith = [\"kong\"]\n", fresh);

    const appended = try setMembers(alloc, "[registry]\nmax_tools = 6\n", &.{"kong"});
    defer alloc.free(appended);
    const round = try read(alloc, appended);
    defer free(alloc, round);
    try std.testing.expectEqual(@as(usize, 1), round.len);
    try std.testing.expect(std.mem.indexOf(u8, appended, "max_tools = 6") != null);
}

test "an id already written is a person's own answer" {
    const members = [_][]const u8{ "std:read", "kong@v-1" };
    try std.testing.expect(indexOfId(&members, "std") != null);
    try std.testing.expect(indexOfId(&members, "kong") != null);
    try std.testing.expect(indexOfId(&members, "dogfood") == null);
}
