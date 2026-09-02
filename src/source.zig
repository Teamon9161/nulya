//! Embedded self-view of nulya's own source, backing `nulya src`. build.zig
//! `@embedFile`s the whole `src/**` tree, so a read gets the REAL kernel source
//! with zero API drift. `test` blocks are stored verbatim but STRIPPED on print
//! by default; `--tests` prints them unstripped.

const std = @import("std");
const embed = @import("src_embed");
const bundled = @import("bundled.zig");

/// Every embedded source file, sorted by path, keyed by its path relative to
/// `src/` (e.g. `prompt.zig`, `extension/store.zig`).
pub const files: []const embed.Entry = &embed.files;

/// The raw embedded bytes for `path` (relative to `src/`), or null if unknown.
pub fn find(path: []const u8) ?[]const u8 {
    for (files) |f| {
        if (std.mem.eql(u8, f.path, path)) return f.bytes;
    }
    return null;
}

/// Return `src` with every top-level `test` block removed. Caller owns the result.
///
/// Relies on `zig fmt`'s invariant that a top-level declaration's closing brace
/// sits in column 0: a test block starts at a line beginning with `test` (then a
/// space, `"`, or `{`) and ends at the next line beginning with `}`. Nothing in a
/// well-formatted function body de-dents to column 0, so this needs no tokenizer.
pub fn stripTests(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    var skipping = false;
    while (i < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n');
        const end = if (nl) |n| n + 1 else src.len;
        const line = src[i..end];
        i = end;

        if (skipping) {
            if (line.len > 0 and line[0] == '}') skipping = false;
            continue;
        }
        if (isTestHeader(line)) {
            skipping = true;
            // Drop the blank separator before the test so deleting the block
            // leaves no double blank between the surrounding declarations.
            dropTrailingBlankLine(&out);
            continue;
        }
        try out.appendSlice(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}

fn isTestHeader(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "test")) return false;
    if (line.len == 4) return true; // "test" with nothing after (shouldn't happen)
    return switch (line[4]) {
        ' ', '"', '{' => true,
        else => false, // `testHelper`, `testData`, … are ordinary identifiers
    };
}

fn dropTrailingBlankLine(out: *std.ArrayList(u8)) void {
    const n = out.items.len;
    if (n >= 2 and out.items[n - 1] == '\n' and out.items[n - 2] == '\n') {
        out.items.len = n - 1;
    }
}

test "stripTests removes top-level test blocks but keeps declarations" {
    const alloc = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
        \\test "add works" {
        \\    try std.testing.expectEqual(@as(i32, 3), add(1, 2));
        \\}
        \\
        \\pub const answer = 42;
        \\
    ;
    const out = try stripTests(alloc, src);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "test \"add works\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn add") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const answer = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n\n") == null);
}

test "stripTests keeps identifiers that merely start with test, byte-for-byte" {
    const alloc = std.testing.allocator;
    const src =
        \\const testData = 1;
        \\fn testHelper() void {}
        \\
    ;
    const out = try stripTests(alloc, src);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "stripTests handles an unnamed test block and one at end of file" {
    const alloc = std.testing.allocator;
    const src =
        \\pub const x = 1;
        \\
        \\test {
        \\    _ = x;
        \\}
        \\
    ;
    const out = try stripTests(alloc, src);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("pub const x = 1;\n", out);
}

test "embedded self-view includes this file and round-trips a known path" {
    try std.testing.expect(files.len != 0);
    const me = find("source.zig") orelse return error.SourceNotEmbedded;
    try std.testing.expect(std.mem.indexOf(u8, me, "pub fn stripTests") != null);
    try std.testing.expect(find("does/not/exist.zig") == null);
}

/// The pointers a shipped comment must not carry. Split around `++` so this list
/// does not match itself: the guard covers every embedded file, its own included.
const doc_pointers = [_][]const u8{
    "DESIGN" ++ " §",
    "DESIGN" ++ ".md",
    "PLAN" ++ " §",
    "BUGS" ++ " #",
    "BUGS" ++ ".md",
    "goals" ++ "/",
    "tui" ++ ".md",
    "agents-and" ++ "-review",
    "base-tools" ++ ".md",
};

test "shipped source carries no documentation pointers" {
    // `nulya src` prints these bytes to a reader who cannot open `docs/`: a
    // section reference costs tokens and resolves to nothing.
    var offenders: usize = 0;
    for (files) |f| offenders += scanForPointers(f.path, f.bytes);
    for (bundled.files) |f| {
        if (!std.mem.endsWith(u8, f.path, ".zig")) continue;
        if (std.mem.indexOf(u8, f.path, "/vendor/") != null) continue;
        offenders += scanForPointers(f.path, f.bytes);
    }
    try std.testing.expectEqual(@as(usize, 0), offenders);
}

fn scanForPointers(path: []const u8, bytes: []const u8) usize {
    var hits: usize = 0;
    for (doc_pointers) |needle| {
        if (std.mem.indexOf(u8, bytes, needle)) |at| {
            const line = std.mem.count(u8, bytes[0..at], "\n") + 1;
            std.debug.print("{s}:{d}: documentation pointer '{s}'\n", .{ path, line, needle });
            hits += 1;
        }
    }
    return hits;
}
