//! Vendored from https://github.com/piranha/zeegrep — `src/core/glob.zig` (master, fetched
//! 2026-08-18). MIT License, Copyright (c) 2026 Oleksandr Solovyov.
//!
//! Glob matching for file names and `/`-separated relative paths: `*` (one path segment),
//! `**` (anything, across separators), `?`, `[...]` / `[!...]` classes, `\` escapes.
//!
//! Changes from the original, all for `std`'s `grep` / `glob` (nulya `extensions/std`):
//!   - the SUBJECT side accepts both `/` and `\` as path separators. The original compared
//!     against `std.fs.path.sep`, so its own tests failed on Windows and a walker's paths
//!     matched on one platform only. The PATTERN side keeps `/` as the separator and `\`
//!     as the escape character (a model writes `src/**/*.zig`, never a backslash path);
//!   - `**/` matches zero or more WHOLE segments (`**/foo` matches `foo` at the root as well
//!     as `a/b/foo`; `src/**/*.zig` matches `src/a.zig`), the way gitignore and globset
//!     define it. The original required at least one segment, and its single backtrack
//!     point could not recover once a later `*` overwrote it — `**/` now recurses on each
//!     segment boundary instead (depth = number of `**/` in the pattern);
//!   - `{a,b,...}` brace alternation, expanded recursively on the stack (globset supports it
//!     and models write `**/*.{ts,tsx}`). `{` counts as a glob metacharacter in `isGlob` /
//!     `classify`. An unclosed `{` is literal; an expansion over `max_pattern_bytes` never
//!     matches;
//!   - `matchPath` strips a leading `./` as well as a leading `/`, and finds the basename
//!     across either separator.

const std = @import("std");

pub const PatKind = enum { literal, ext_only, prefix, suffix, glob };

/// Characters that make a pattern a glob rather than a literal name.
const meta = "*?[{";

/// A brace expansion larger than this is treated as "no match" rather than
/// allocating; model-written patterns are a few dozen bytes.
pub const max_pattern_bytes = 1024;

pub fn classify(pat: []const u8) PatKind {
    if (!isGlob(pat)) return .literal;
    // *.foo - extension only
    if (pat.len > 2 and pat[0] == '*' and pat[1] == '.' and
        std.mem.indexOfAny(u8, pat[2..], meta) == null) return .ext_only;
    // foo* - prefix match
    if (pat[pat.len - 1] == '*' and
        std.mem.indexOfAny(u8, pat[0 .. pat.len - 1], meta) == null) return .prefix;
    // *foo - suffix match
    if (pat[0] == '*' and std.mem.indexOfAny(u8, pat[1..], meta) == null) return .suffix;
    return .glob;
}

pub fn fastMatch(kind: PatKind, pat: []const u8, s: []const u8) bool {
    return switch (kind) {
        .literal => std.mem.eql(u8, pat, s),
        .ext_only => std.mem.endsWith(u8, s, pat[1..]), // *.foo -> .foo
        .prefix => std.mem.startsWith(u8, s, pat[0 .. pat.len - 1]),
        .suffix => std.mem.endsWith(u8, s, pat[1..]),
        .glob => match(pat, s),
    };
}

pub fn isGlob(pat: []const u8) bool {
    return std.mem.indexOfAny(u8, pat, meta) != null;
}

/// Match the whole of `s` against `pat`.
pub fn match(pat: []const u8, s: []const u8) bool {
    if (findBrace(pat)) |b| return matchBraces(pat, b, s);
    return matchAt(pat, 0, s, 0);
}

/// Match a path the way a search tool wants: a pattern with no `/` matches the
/// basename anywhere in the tree; one with a `/` matches the whole relative path.
pub fn matchPath(pat: []const u8, path: []const u8) bool {
    var p = pat;
    if (std.mem.startsWith(u8, p, "./")) p = p[2..];
    if (p.len > 0 and p[0] == '/') p = p[1..];
    if (std.mem.indexOfScalar(u8, p, '/') == null) return match(p, basename(path));
    return match(p, path);
}

/// The last path component, splitting on either separator.
pub fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and isSep(path[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and !isSep(path[start - 1])) start -= 1;
    return path[start..end];
}

inline fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn matchAt(pat: []const u8, pi0: usize, s: []const u8, si0: usize) bool {
    var pi = pi0;
    var si = si0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;
    var star_slash = false;

    while (true) {
        if (si == s.len) break;

        if (pi < pat.len and pat[pi] == '\\' and pi + 1 < pat.len) {
            if (pat[pi + 1] == s[si]) {
                pi += 2;
                si += 1;
                continue;
            }
        }

        if (pi < pat.len and pat[pi] == '[') {
            if (classEnd(pat, pi)) |end| {
                if (!isSep(s[si]) and classHas(pat[pi + 1 .. end], s[si])) {
                    pi = end + 1;
                    si += 1;
                    continue;
                }
            }
        }

        if (pi < pat.len and pat[pi] == '?') {
            if (!isSep(s[si])) {
                pi += 1;
                si += 1;
                continue;
            }
        }

        if (pi < pat.len and pat[pi] == '*') {
            const double = pi + 1 < pat.len and pat[pi + 1] == '*';
            if (double and pi + 2 < pat.len and pat[pi + 2] == '/') {
                // `**/`: zero or more whole segments. Try the rest of the
                // pattern at this segment boundary, then at each following one.
                var start = si;
                while (true) {
                    if (matchAt(pat, pi + 3, s, start)) return true;
                    while (start < s.len and !isSep(s[start])) start += 1;
                    if (start >= s.len) return false;
                    start += 1;
                }
            }
            star_slash = double;
            star_pi = if (double) pi + 2 else pi + 1;
            pi = star_pi.?;
            star_si = si;
            continue;
        }

        if (pi < pat.len and (pat[pi] == s[si] or (pat[pi] == '/' and isSep(s[si])))) {
            pi += 1;
            si += 1;
            continue;
        }

        if (star_pi) |spi| {
            if (!star_slash and star_si < s.len and isSep(s[star_si])) return false;
            star_si += 1;
            if (star_si > s.len) return false;
            si = star_si;
            pi = spi;
            continue;
        }

        return false;
    }

    while (pi < pat.len) {
        if (pat[pi] == '*') {
            pi += 1;
            if (pi < pat.len and pat[pi] == '*') {
                pi += 1;
                // A trailing `**/` still matches nothing more.
                if (pi < pat.len and pat[pi] == '/') pi += 1;
            }
            continue;
        }
        if (pat[pi] == '\\' and pi + 1 < pat.len) return false;
        break;
    }
    return pi == pat.len;
}

const Brace = struct { open: usize, close: usize };

/// The first top-level `{...}` group, honoring `\` escapes, `[...]` classes and
/// nesting. An unclosed `{` is a literal character.
fn findBrace(pat: []const u8) ?Brace {
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        switch (pat[i]) {
            '\\' => i += 1,
            '[' => {
                if (classEnd(pat, i)) |end| i = end;
            },
            '{' => {
                var depth: usize = 1;
                var j = i + 1;
                while (j < pat.len) : (j += 1) {
                    switch (pat[j]) {
                        '\\' => j += 1,
                        '{' => depth += 1,
                        '}' => {
                            depth -= 1;
                            if (depth == 0) return .{ .open = i, .close = j };
                        },
                        else => {},
                    }
                }
                return null;
            },
            else => {},
        }
    }
    return null;
}

/// Expand `{a,b}` into `<head>a<tail>` / `<head>b<tail>` on the stack and match
/// each; nested groups are expanded by the recursive `match`.
fn matchBraces(pat: []const u8, b: Brace, s: []const u8) bool {
    var buf: [max_pattern_bytes]u8 = undefined;
    const head = pat[0..b.open];
    const tail = pat[b.close + 1 ..];
    var alt_start = b.open + 1;
    var depth: usize = 0;
    var i = alt_start;
    while (i <= b.close) : (i += 1) {
        const c = pat[i];
        if (c == '\\' and i + 1 < b.close) {
            i += 1;
            continue;
        }
        if (c == '{') {
            depth += 1;
            continue;
        }
        if (c == '}' and i != b.close) {
            depth -= 1;
            continue;
        }
        if ((c == ',' and depth == 0) or i == b.close) {
            const alt = pat[alt_start..i];
            const len = head.len + alt.len + tail.len;
            if (len <= buf.len) {
                @memcpy(buf[0..head.len], head);
                @memcpy(buf[head.len..][0..alt.len], alt);
                @memcpy(buf[head.len + alt.len ..][0..tail.len], tail);
                if (match(buf[0..len], s)) return true;
            }
            alt_start = i + 1;
        }
    }
    return false;
}

fn classEnd(pat: []const u8, start: usize) ?usize {
    if (start >= pat.len or pat[start] != '[') return null;
    var i = start + 1;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) i += 1;
    if (i < pat.len and pat[i] == ']') i += 1;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '\\' and i + 1 < pat.len) {
            i += 1;
            continue;
        }
        if (pat[i] == ']') return i;
    }
    return null;
}

fn classHas(body: []const u8, c: u8) bool {
    if (body.len == 0) return false;
    var i: usize = 0;
    var neg = false;
    if (body[0] == '!' or body[0] == '^') {
        neg = true;
        i = 1;
    }

    var ok = false;
    while (i < body.len) : (i += 1) {
        var a = body[i];
        if (a == '\\' and i + 1 < body.len) {
            i += 1;
            a = body[i];
        }

        if (i + 2 < body.len and body[i + 1] == '-') {
            var b = body[i + 2];
            if (b == '\\' and i + 3 < body.len) b = body[i + 3];
            if (a <= c and c <= b) ok = true;
        } else if (a == c) {
            ok = true;
        }
    }
    return if (neg) !ok else ok;
}

test {
    std.testing.refAllDecls(@This());
}

test "classify" {
    try std.testing.expectEqual(PatKind.literal, classify("foo"));
    try std.testing.expectEqual(PatKind.literal, classify("foo.bar"));
    try std.testing.expectEqual(PatKind.ext_only, classify("*.log"));
    try std.testing.expectEqual(PatKind.ext_only, classify("*.tar.gz"));
    try std.testing.expectEqual(PatKind.prefix, classify("foo*"));
    try std.testing.expectEqual(PatKind.prefix, classify("node_modules*"));
    try std.testing.expectEqual(PatKind.suffix, classify("*_test"));
    try std.testing.expectEqual(PatKind.glob, classify("*.log.*"));
    try std.testing.expectEqual(PatKind.glob, classify("foo*bar"));
    try std.testing.expectEqual(PatKind.glob, classify("**/*.zig"));
    try std.testing.expectEqual(PatKind.glob, classify("src/*/test"));
    // Braces are alternation, not a literal name.
    try std.testing.expectEqual(PatKind.glob, classify("*.{ts,tsx}"));
    try std.testing.expectEqual(PatKind.glob, classify("{a,b}"));
}

test "fastMatch" {
    try std.testing.expect(fastMatch(.literal, "foo", "foo"));
    try std.testing.expect(!fastMatch(.literal, "foo", "bar"));
    try std.testing.expect(fastMatch(.ext_only, "*.log", "test.log"));
    try std.testing.expect(!fastMatch(.ext_only, "*.log", "test.txt"));
    try std.testing.expect(fastMatch(.prefix, "foo*", "foobar"));
    try std.testing.expect(!fastMatch(.prefix, "foo*", "barfoo"));
    try std.testing.expect(fastMatch(.suffix, "*_test", "foo_test"));
    try std.testing.expect(!fastMatch(.suffix, "*_test", "test_foo"));
}

test "glob basics" {
    try std.testing.expect(matchPath("*.zig", "src/main.zig"));
    try std.testing.expect(!matchPath("*.zig", "src/main.c"));
    try std.testing.expect(match("src/**", "src/core/opt.zig"));
    try std.testing.expect(match("src/*/opt.zig", "src/core/opt.zig"));
    try std.testing.expect(!match("src/*/opt.zig", "src/core/x/opt.zig"));
    // A single star stays inside one segment; a name-only pattern goes by basename.
    try std.testing.expect(!match("*.zig", "src/main.zig"));
    try std.testing.expect(match("src/*.zig", "src/main.zig"));
    try std.testing.expect(!match("src/*.zig", "src/a/main.zig"));
    try std.testing.expect(match("m?in.zig", "main.zig"));
    try std.testing.expect(!match("m?in.zig", "m/in.zig"));
}

test "glob classes" {
    try std.testing.expect(match("file[0-9].txt", "file7.txt"));
    try std.testing.expect(!match("file[0-9].txt", "filex.txt"));
    try std.testing.expect(match("file[!0-9].txt", "filex.txt"));
    try std.testing.expect(!match("file[!0-9].txt", "file/.txt"));
}

test "escapes make metacharacters literal" {
    try std.testing.expect(match("a\\*b", "a*b"));
    try std.testing.expect(!match("a\\*b", "axb"));
    try std.testing.expect(match("a\\{b", "a{b"));
    try std.testing.expect(match("\\[x\\]", "[x]"));
}

test "**/ matches zero or more whole segments" {
    try std.testing.expect(match("**/foo", "foo"));
    try std.testing.expect(match("**/foo", "a/foo"));
    try std.testing.expect(match("**/foo", "a/b/foo"));
    try std.testing.expect(!match("**/foo", "afoo"));
    try std.testing.expect(!match("**/foo", "a/xfoo"));
    try std.testing.expect(match("src/**/*.zig", "src/a.zig"));
    try std.testing.expect(match("src/**/*.zig", "src/x/y/b.zig"));
    try std.testing.expect(!match("src/**/*.zig", "lib/x/b.zig"));
    try std.testing.expect(match("**/*.zig", "a/b/c.zig"));
    try std.testing.expect(match("**/*.zig", "c.zig"));
    try std.testing.expect(match("a/**/b", "a/b"));
    try std.testing.expect(match("a/**/b", "a/x/y/b"));
    try std.testing.expect(!match("a/**/b", "a/x/y/c"));
    try std.testing.expect(match("**", "anything/at/all"));
    try std.testing.expect(match("**/", "a/"));
    try std.testing.expect(match("docs/**", "docs/goals/std.md"));
}

test "brace alternation" {
    try std.testing.expect(match("*.{ts,tsx}", "app.tsx"));
    try std.testing.expect(match("*.{ts,tsx}", "app.ts"));
    try std.testing.expect(!match("*.{ts,tsx}", "app.js"));
    try std.testing.expect(matchPath("**/*.{ts,tsx}", "src/ui/app.tsx"));
    try std.testing.expect(match("{src,lib}/**/*.zig", "lib/x/y.zig"));
    try std.testing.expect(!match("{src,lib}/**/*.zig", "bin/x/y.zig"));
    // Nested groups and a group with an empty alternative.
    try std.testing.expect(match("a{b,{c,d}}e", "ade"));
    try std.testing.expect(match("a{b,{c,d}}e", "abe"));
    try std.testing.expect(!match("a{b,{c,d}}e", "aze"));
    try std.testing.expect(match("x{,y}z", "xz"));
    try std.testing.expect(match("x{,y}z", "xyz"));
    // An unclosed brace is a literal.
    try std.testing.expect(match("a{b", "a{b"));
    try std.testing.expect(!isGlob("plain.txt"));
    try std.testing.expect(isGlob("{a,b}"));
}

test "the subject may use either separator; the pattern uses /" {
    try std.testing.expect(match("src/*.zig", "src\\main.zig"));
    try std.testing.expect(match("src/**/*.zig", "src\\a\\b.zig"));
    try std.testing.expect(!match("*.zig", "src\\main.zig"));
    try std.testing.expect(matchPath("*.zig", "src\\main.zig"));
    try std.testing.expect(matchPath("src/*.zig", "src\\main.zig"));
    try std.testing.expect(!matchPath("src/*.zig", "src\\a\\main.zig"));
    try std.testing.expectEqualStrings("main.zig", basename("src\\main.zig"));
    try std.testing.expectEqualStrings("main.zig", basename("src/main.zig"));
    try std.testing.expectEqualStrings("main.zig", basename("main.zig"));
}

test "matchPath: name-only patterns match by basename, others by relative path" {
    try std.testing.expect(matchPath("app.rs", "src/app.rs"));
    try std.testing.expect(!matchPath("app.rs", "src/app.rss"));
    try std.testing.expect(matchPath("/src/*.zig", "src/main.zig"));
    try std.testing.expect(matchPath("./src/*.zig", "src/main.zig"));
    try std.testing.expect(matchPath("**/SKILL.md", "SKILL.md"));
    try std.testing.expect(matchPath("**/SKILL.md", "arbor/SKILL.md"));
    try std.testing.expect(matchPath("**/*.d.ts", "dist/index.d.ts"));
}
