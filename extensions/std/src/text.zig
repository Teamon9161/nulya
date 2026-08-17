//! Text shaping shared by the file tools: line splitting, the display path, the
//! not-found help, numbered echoes, per-line clipping and its note, the read
//! marker check, and a lossy UTF-8 pass. Pure functions over bytes, so every
//! one of them is unit-tested here; the numbers and wording are tcode's
//! (`fs/mod.rs`) unless a comment says otherwise.

const std = @import("std");

/// Ceiling on a rendered line, marker included. The host clips tool output at
/// this same threshold and would otherwise re-clip our marked line — replacing
/// our count with its own and treating the result as truncated. tcode's
/// MAX_LINE_CHARS is 16384 (fs/mod.rs); here it bounds the whole rendered line,
/// see `clip_keep_bytes`.
pub const max_line_bytes: usize = 16384;

/// Bytes of a long line that survive a clip: the ceiling minus room for the
/// longest marker a ≤ 10 MB file can need (`…[+NNNNNNNN bytes]` = 20 bytes).
pub const clip_keep_bytes: usize = max_line_bytes - 20;

/// The clip marker's opening — tcode `redact.rs` `read_marker`, and what the
/// kernel's `edit` refuses in an `old_string`. Assembled rather than written
/// literally so this file can itself be edited by the tools it describes.
pub const marker_open = "\u{2026}[+";

/// Rust `str::lines()`: split at `\n`, drop one trailing `\r` from each line, a
/// final line without a terminator still counts, an empty text has no lines.
/// The slices borrow `text`.
pub fn lines(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var rest = text;
    while (rest.len != 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
            try out.append(alloc, rest);
            break;
        };
        var line = rest[0..nl];
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try out.append(alloc, line);
        rest = rest[nl + 1 ..];
    }
    return out.toOwnedSlice(alloc);
}

/// `lines(text).len` without allocating.
pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = std.mem.count(u8, text, "\n");
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

/// The path as the model sees it: relative to `cwd` when it lies inside it,
/// otherwise unchanged. tcode `fs/mod.rs` `rel` (`Path::strip_prefix`).
pub fn rel(path: []const u8, cwd: []const u8) []const u8 {
    if (cwd.len == 0 or !std.mem.startsWith(u8, path, cwd)) return path;
    if (path.len == cwd.len) return "";
    if (std.fs.path.isSep(cwd[cwd.len - 1])) return path[cwd.len..];
    if (std.fs.path.isSep(path[cwd.len])) return path[cwd.len + 1 ..];
    return path;
}

/// Self-healing not-found: what IS there, so the model can correct the path
/// without another exploratory turn. tcode `fs/mod.rs` `not_found_help`:
/// parent directory listing (≤ 20 entries, directories with `/`, sorted) or
/// "does not exist either". `path` is absolute.
pub fn notFoundHelp(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.print("File not found: {s}", .{path});
    const parent = std.fs.path.dirname(path) orelse return out.toOwnedSlice();
    if (parent.len == 0) return out.toOwnedSlice();

    if (try listDir(alloc, io, parent, .{ .mark_dirs = true, .sorted = true, .max = 20 })) |entries| {
        try w.print("\nThe directory {s} exists and contains: ", .{parent});
        for (entries, 0..) |name, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(name);
        }
    } else {
        try w.print("\nThe directory {s} does not exist either.", .{parent});
    }
    return out.toOwnedSlice();
}

pub const ListOptions = struct {
    /// Append `/` to directory names.
    mark_dirs: bool,
    sorted: bool,
    /// Keep at most this many entries (after sorting, when sorted).
    max: usize,
};

/// The names in the directory at `path` (absolute), or null when it is not a
/// directory that can be listed. Names are made valid UTF-8 (see `lossyUtf8`)
/// so they can travel in a JSON string.
pub fn listDir(alloc: std.mem.Allocator, io: std.Io, path: []const u8, options: ListOptions) !?[]const []const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch return null) |entry| {
        if (!options.sorted and names.items.len >= options.max) break;
        const is_dir = options.mark_dirs and switch (entry.kind) {
            .directory => true,
            // tcode asks `is_dir()` on the full path, which follows a link.
            .sym_link => blk: {
                const target = try std.fs.path.join(alloc, &.{ path, entry.name });
                const st = std.Io.Dir.cwd().statFile(io, target, .{}) catch break :blk false;
                break :blk st.kind == .directory;
            },
            else => false,
        };
        const name = try lossyUtf8(alloc, entry.name);
        try names.append(alloc, if (is_dir) try std.fmt.allocPrint(alloc, "{s}/", .{name}) else try alloc.dupe(u8, name));
    }
    if (options.sorted) std.mem.sort([]const u8, names.items, {}, lessThan);
    const kept = names.items[0..@min(names.items.len, options.max)];
    return kept;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A line that lost content on the way out: which line, how many bytes were
/// kept, how long it really is. tcode `fs/mod.rs` `Numbered.clipped`.
pub const ClippedLine = struct { line: usize, kept: usize, total: usize };

/// What rendering a window of lines produced. tcode `fs/mod.rs` `Numbered`.
pub const Rendered = struct {
    text: []const u8,
    /// How many lines made it out (the byte budget can stop early).
    emitted: usize,
    clipped: []const ClippedLine,
};

/// Render lines until they run out or the byte budget is hit — always at least
/// one, so a single huge line still makes progress. `number` prefixes each
/// line with `{d:>6}\t` (the echo `append` gives back); `read` leaves it off.
/// tcode `fs/mod.rs` `numbered_capped`.
pub fn render(alloc: std.mem.Allocator, all: []const []const u8, start: usize, budget: usize, number: bool) !Rendered {
    var text: std.ArrayList(u8) = .empty;
    var clipped: std.ArrayList(ClippedLine) = .empty;
    var emitted: usize = 0;
    // A numbered row is the number, a tab, the line and a newline; a plain row
    // is the line and a newline.
    const overhead: usize = if (number) 8 else 1;
    for (all, 0..) |line, i| {
        const shown = try clip(alloc, line);
        if (emitted > 0 and text.items.len + shown.text.len + overhead > budget) break;
        if (shown.kept) |kept| try clipped.append(alloc, .{ .line = start + i, .kept = kept, .total = line.len });
        if (number) {
            try text.print(alloc, "{d:>6}\t{s}\n", .{ start + i, shown.text });
        } else {
            try text.appendSlice(alloc, shown.text);
            try text.append(alloc, '\n');
        }
        emitted += 1;
    }
    return .{
        .text = try text.toOwnedSlice(alloc),
        .emitted = emitted,
        .clipped = try clipped.toOwnedSlice(alloc),
    };
}

/// `{d:>6}\t` numbered lines, unbudgeted. tcode `fs/mod.rs` `numbered`.
pub fn numbered(alloc: std.mem.Allocator, all: []const []const u8, start: usize) ![]const u8 {
    return (try render(alloc, all, start, std.math.maxInt(usize), true)).text;
}

pub const Clip = struct {
    text: []const u8,
    /// Bytes kept when the line was clipped; null when it came through whole.
    kept: ?usize,
};

/// A long line is cut on a UTF-8 boundary and marked `…[+N bytes]` — the same
/// self-describing shape the host uses, because a bare `…` is
/// indistinguishable from file content and would be copied into an `edit`.
/// tcode `fs/mod.rs` `clip` (chars there; bytes here, marker inside the limit).
pub fn clip(alloc: std.mem.Allocator, line: []const u8) !Clip {
    if (line.len <= max_line_bytes) return .{ .text = line, .kept = null };
    const cut = validUtf8PrefixLen(line, clip_keep_bytes);
    const text = try std.fmt.allocPrint(alloc, "{s}{s}{d} bytes]", .{ line[0..cut], marker_open, line.len - cut });
    std.debug.assert(text.len <= max_line_bytes);
    return .{ .text = text, .kept = cut };
}

/// Tail note naming every clipped line, so the model knows which lines it must
/// not reuse verbatim and how to get the real text. tcode `fs/mod.rs`
/// `clip_note`.
pub fn clipNote(alloc: std.mem.Allocator, clipped: []const ClippedLine) !?[]const u8 {
    if (clipped.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.writeAll("note: ");
    if (clipped.len == 1) {
        try w.print("line {d} was clipped at {d} of {d} bytes", .{ clipped[0].line, clipped[0].kept, clipped[0].total });
    } else {
        try w.writeAll("lines ");
        for (clipped, 0..) |c, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{d}", .{c.line});
        }
        try w.print(" were clipped at {d} bytes", .{clip_keep_bytes});
    }
    try w.print("; the {s}N bytes] marker is not file content, so a clipped line cannot be used as an edit old_string. Fetch such a line verbatim with grep (narrow pattern) or shell if you need it.", .{marker_open});
    return try out.toOwnedSlice();
}

/// Does `s` carry a clip marker (`…[+`)? A `write` of such content would put
/// the marker into the file as if it were text. Same test the kernel's `edit`
/// applies to an `old_string`.
pub fn hasReadMarker(s: []const u8) bool {
    return std.mem.indexOf(u8, s, marker_open) != null;
}

/// The teaching text for a marker in `field`. tcode `redact.rs` `marker_error`,
/// minus the redaction clause (there is no redaction here).
pub fn markerError(alloc: std.mem.Allocator, field: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s} contains a truncation marker that `read`/`grep` added to their output — it is not the file's actual content, and writing it would corrupt the file. Get the real text first: `grep` with a narrow pattern for a clipped line, or `shell`.", .{field});
}

/// `bytes` as valid UTF-8, each undecodable byte replaced by U+FFFD (Rust
/// `String::from_utf8_lossy`). Returns `bytes` itself when already valid — and
/// it has to be valid: the answer travels as a JSON string.
pub fn lossyUtf8(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(alloc, bytes.len + 16);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(alloc, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try out.appendSlice(alloc, bytes[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(alloc, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Length of the longest prefix of `s` that is at most `max_len` bytes and does
/// not end inside a multi-byte sequence.
pub fn validUtf8PrefixLen(s: []const u8, max_len: usize) usize {
    if (s.len <= max_len) return s.len;
    var end = max_len;
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

// ------------------------------------------------------------------ tests

test {
    std.testing.refAllDecls(@This());
}

test "lines follow str::lines(): CRLF stripped, final terminator optional, empty text has none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cases = [_]struct { text: []const u8, want: []const []const u8 }{
        .{ .text = "", .want = &.{} },
        .{ .text = "a", .want = &.{"a"} },
        .{ .text = "a\n", .want = &.{"a"} },
        .{ .text = "a\n\n", .want = &.{ "a", "" } },
        .{ .text = "a\r\nb\r\n", .want = &.{ "a", "b" } },
        .{ .text = "a\rb", .want = &.{"a\rb"} },
        .{ .text = "a\r", .want = &.{"a\r"} },
        .{ .text = "\n", .want = &.{""} },
    };
    for (cases) |c| {
        const got = try lines(alloc, c.text);
        try std.testing.expectEqual(c.want.len, got.len);
        for (c.want, got) |w, g| try std.testing.expectEqualStrings(w, g);
        try std.testing.expectEqual(c.want.len, countLines(c.text));
    }
}

test "rel strips the cwd prefix on a component boundary and leaves foreign paths alone" {
    const sep = std.fs.path.sep_str;
    const cwd = "/work" ++ sep ++ "ws";
    try std.testing.expectEqualStrings("a.txt", rel(cwd ++ sep ++ "a.txt", cwd));
    try std.testing.expectEqualStrings("d" ++ sep ++ "b", rel(cwd ++ sep ++ "d" ++ sep ++ "b", cwd));
    try std.testing.expectEqualStrings("/work" ++ sep ++ "wsx" ++ sep ++ "a", rel("/work" ++ sep ++ "wsx" ++ sep ++ "a", cwd));
    try std.testing.expectEqualStrings("/elsewhere/a", rel("/elsewhere/a", cwd));
    try std.testing.expectEqualStrings("a", rel("/" ++ "a", "/"));
}

test "clip keeps the rendered line within max_line_bytes, cuts on a UTF-8 boundary and marks the remainder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const short = "x" ** 100;
    const whole = try clip(alloc, short);
    try std.testing.expect(whole.kept == null);
    try std.testing.expectEqualStrings(short, whole.text);

    // Two-byte characters straddling the cut: nothing is split.
    const long = try alloc.alloc(u8, 40_000);
    var i: usize = 0;
    while (i + 1 < long.len) : (i += 2) {
        long[i] = 0xC3;
        long[i + 1] = 0xA9; // é
    }
    long[long.len - 1] = 'z';
    const cut = try clip(alloc, long);
    try std.testing.expect(cut.kept != null);
    try std.testing.expect(cut.text.len <= max_line_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut.text));
    const marker = try std.fmt.allocPrint(alloc, "{s}{d} bytes]", .{ marker_open, long.len - cut.kept.? });
    try std.testing.expect(std.mem.endsWith(u8, cut.text, marker));
    try std.testing.expect(hasReadMarker(cut.text));
    try std.testing.expect(!hasReadMarker(short));
}

test "render budgets by bytes but always emits at least one line, and numbers when asked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const all: []const []const u8 = &.{ "aaaa", "bbbb", "cccc" };
    const capped = try render(alloc, all, 5, 9, false);
    // "aaaa\n" is 5; a second line would be 10 > 9.
    try std.testing.expectEqual(@as(usize, 1), capped.emitted);
    try std.testing.expectEqualStrings("aaaa\n", capped.text);

    const tiny = try render(alloc, all, 1, 1, false);
    try std.testing.expectEqual(@as(usize, 1), tiny.emitted);

    const echo = try numbered(alloc, all, 41);
    try std.testing.expectEqualStrings("    41\taaaa\n    42\tbbbb\n    43\tcccc\n", echo);
}

test "clipNote names one line with its counts, several by number, and explains the marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expect((try clipNote(alloc, &.{})) == null);
    const one = (try clipNote(alloc, &.{.{ .line = 7, .kept = 16364, .total = 40000 }})).?;
    try std.testing.expect(std.mem.startsWith(u8, one, "note: line 7 was clipped at 16364 of 40000 bytes; the "));
    try std.testing.expect(std.mem.indexOf(u8, one, "cannot be used as an edit old_string") != null);
    const two = (try clipNote(alloc, &.{ .{ .line = 7, .kept = 1, .total = 2 }, .{ .line = 9, .kept = 1, .total = 2 } })).?;
    try std.testing.expect(std.mem.startsWith(u8, two, "note: lines 7, 9 were clipped at "));
}

test "lossyUtf8 passes valid text through untouched and replaces stray bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ok = "héllo";
    try std.testing.expect((try lossyUtf8(alloc, ok)).ptr == ok.ptr);
    const bad = try lossyUtf8(alloc, "a\xffb\xc3");
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}", bad);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bad));
}

test "notFoundHelp lists a present parent (sorted, dirs marked, ≤ 20) or says the parent is missing too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.createDirPath(io, "sub");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    const missing = try std.fs.path.join(alloc, &.{ root, "zzz.txt" });
    const help = try notFoundHelp(alloc, io, missing);
    const want_tail = try std.fmt.allocPrint(alloc, "\nThe directory {s} exists and contains: a.txt, b.txt, sub/", .{root});
    try std.testing.expect(std.mem.startsWith(u8, help, "File not found: "));
    try std.testing.expect(std.mem.endsWith(u8, help, want_tail));

    const deeper = try std.fs.path.join(alloc, &.{ root, "nope", "zzz.txt" });
    const help2 = try notFoundHelp(alloc, io, deeper);
    try std.testing.expect(std.mem.endsWith(u8, help2, "does not exist either."));
}
