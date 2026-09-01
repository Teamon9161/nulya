//! The regex `grep` searches with: the vendored mvzr (byte-level backtracking,
//! no lookaround/backreferences/Unicode classes/case-insensitive flag) behind
//! a wrapper that adds a bigger program budget (`SizedRegex(256, 32)` — the
//! default 64 ops/8 sets is too small for a model's `foo|bar|baz|...`) and
//! case handling.
//!
//! The `(?…` family must be handled BEFORE mvzr sees it: mvzr misparses it
//! into a pattern that compiles and silently matches the wrong text (`(?i)AAA`
//! matched the literal `iAAA`). Non-capturing `(?:` is rewritten to a plain
//! `(`; every other `(?…` is refused up front with a message naming the way out.
//!
//! Smart case: no uppercase literal in the pattern searches case-insensitively,
//! any uppercase literal makes it exact, `case_insensitive=true` forces it.
//! With no engine flag for this, insensitivity is done by lowering both sides;
//! backslash escapes (`\d \D \w \W \s \S \b \B`) stay untouched — lowering
//! `\D` would turn "not a digit" into "a digit".

const std = @import("std");
const mvzr = @import("vendor/mvzr.zig");

/// 256 ops / 32 sets: room for a long alternation of identifiers.
pub const Regex = mvzr.SizedRegex(256, 32);

pub const Compiled = struct {
    matcher: union(enum) {
        regex: Regex,
        /// A fixed needle (`fixed=true`), already lowered when `fold_case`.
        literal: []const u8,
    },
    /// True when the search is case-insensitive. The caller must then hand
    /// `isMatch` an already-lowercased line (`lowerInto`); the pattern side
    /// was lowered at compile time.
    fold_case: bool,

    pub fn isMatch(self: *const Compiled, line: []const u8) bool {
        return switch (self.matcher) {
            .regex => |*r| r.isMatch(line),
            .literal => |needle| std.mem.indexOf(u8, line, needle) != null,
        };
    }
};

/// The teaching text for a pattern mvzr will not compile — tcode search.rs's
/// message, with the engine's own vocabulary in place of the regex crate's
/// diagnostic (mvzr reports no position).
pub fn invalidMessage(alloc: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "invalid regex: /{s}/ did not compile (byte-level regex: classes, alternation, groups, quantifiers, anchors and \\b work; lookaround and backreferences do not)\nRemember this is regex syntax — escape literal ( ) [ ] {{ }} . * + ? with a backslash, or pass fixed=true to search the text literally.",
        .{pattern},
    );
}

/// Compile `pattern` under smart case, or null when mvzr rejects it. The lowered
/// pattern, when one is needed, is allocated from `alloc`. A pattern with an
/// inline `(?…` construct is null too — the caller checks `hasInlineConstruct`
/// first for the message that names the way out; this is the backstop that
/// keeps mvzr's silent misparse unreachable.
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, case_insensitive: bool) !?Compiled {
    if (hasInlineConstruct(pattern)) return null;
    const plain = try stripNonCapturing(alloc, pattern);
    const fold = case_insensitive or !hasUppercaseLiteral(plain);
    const source = if (fold) try lowerPattern(alloc, plain) else plain;
    const regex = Regex.compile(source) orelse return null;
    return .{ .matcher = .{ .regex = regex }, .fold_case = fold };
}

/// A `fixed=true` pattern: the pattern IS the needle — no compilation, nothing
/// to escape, and it cannot fail. Smart case works as for a regex: an
/// all-lowercase needle folds (the caller lowers each haystack line),
/// `case_insensitive` forces it, and folding lowers the needle here.
pub fn compileLiteral(alloc: std.mem.Allocator, pattern: []const u8, case_insensitive: bool) !Compiled {
    var has_upper = false;
    for (pattern) |c| {
        if (std.ascii.isUpper(c)) {
            has_upper = true;
            break;
        }
    }
    const fold = case_insensitive or !has_upper;
    const needle = if (fold) std.ascii.lowerString(try alloc.alloc(u8, pattern.len), pattern) else pattern;
    return .{ .matcher = .{ .literal = needle }, .fold_case = fold };
}

/// Does the pattern contain a `(?…` construct other than non-capturing `(?:`?
/// Inline flags (`(?i)`), lookaround (`(?=`, `(?!`, `(?<`) and the rest of the
/// family. An escaped `\(` and a `(` inside a `[...]` class are literals and do
/// not count.
pub fn hasInlineConstruct(pattern: []const u8) bool {
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        if (c == '[') {
            in_class = true;
            continue;
        }
        if (c == '(' and i + 1 < pattern.len and pattern[i + 1] == '?') {
            if (i + 2 >= pattern.len or pattern[i + 2] != ':') return true;
        }
    }
    return false;
}

/// The teaching text for an inline `(?…)` construct the engine does not have.
pub fn inlineMessage(alloc: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "unsupported (?...) construct in /{s}/: this byte-level engine has no inline flags or lookaround. For case-insensitive matching pass case_insensitive=true; for grouping use ( ) or (?: ).",
        .{pattern},
    );
}

/// `(?:` rewritten to `(`: this wrapper only ever asks whether a line matches,
/// never which group captured what, so a non-capturing group and a plain group
/// are indistinguishable here — and models write `(?:` by reflex.
fn stripNonCapturing(alloc: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, pattern, "(?:") == null) return pattern;
    var out: std.ArrayList(u8) = .empty;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        try out.append(alloc, c);
        if (c == '\\' and i + 1 < pattern.len) {
            try out.append(alloc, pattern[i + 1]);
            i += 1;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        if (c == '[') {
            in_class = true;
            continue;
        }
        if (c == '(' and i + 2 < pattern.len and pattern[i + 1] == '?' and pattern[i + 2] == ':') i += 2;
    }
    return out.toOwnedSlice(alloc);
}

/// Does the pattern contain an uppercase ASCII letter that is a literal — not
/// the name of a backslash class or escape? `[A-Z]` counts (its letters are
/// literals); `\D`, `\W`, `\S`, `\B` do not.
pub fn hasUppercaseLiteral(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1; // whatever follows a backslash is an escape, never a literal
            continue;
        }
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

/// A copy of `pattern` with its literal ASCII letters lowered; backslash escapes
/// (both bytes) are copied through untouched.
pub fn lowerPattern(alloc: std.mem.Allocator, pattern: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, pattern.len);
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\' and i + 1 < pattern.len) {
            out[i] = c;
            out[i + 1] = pattern[i + 1];
            i += 1;
            continue;
        }
        out[i] = std.ascii.toLower(c);
    }
    return out;
}

/// Lowercase `line` into `buf` (which must be at least `line.len` long) and
/// return the written slice — the haystack side of a case-insensitive search.
pub fn lowerInto(buf: []u8, line: []const u8) []const u8 {
    for (line, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..line.len];
}

test {
    std.testing.refAllDecls(@This());
}

test "smart case: an all-lowercase pattern folds, an uppercase literal keeps it exact, the knob forces folding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [64]u8 = undefined;

    const lower = (try compile(alloc, "target", false)).?;
    try std.testing.expect(lower.fold_case);
    try std.testing.expect(lower.isMatch(lowerInto(&buf, "Target")));
    try std.testing.expect(lower.isMatch(lowerInto(&buf, "TARGET")));
    try std.testing.expect(lower.isMatch(lowerInto(&buf, "target")));

    const mixed = (try compile(alloc, "Target", false)).?;
    try std.testing.expect(!mixed.fold_case);
    try std.testing.expect(mixed.isMatch("Target"));
    try std.testing.expect(!mixed.isMatch("TARGET"));
    try std.testing.expect(!mixed.isMatch("target"));

    const forced = (try compile(alloc, "Target", true)).?;
    try std.testing.expect(forced.fold_case);
    try std.testing.expect(forced.isMatch(lowerInto(&buf, "TARGET")));
    try std.testing.expect(forced.isMatch(lowerInto(&buf, "target")));
}

test "lowering the pattern leaves backslash classes alone: \\D survives, and is not an uppercase literal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expect(!hasUppercaseLiteral("x\\Dy"));
    try std.testing.expect(!hasUppercaseLiteral("\\W+\\S\\B"));
    try std.testing.expect(hasUppercaseLiteral("[A-Z]"));
    try std.testing.expect(hasUppercaseLiteral("\\\\A")); // escaped backslash, then a literal A
    try std.testing.expect(!hasUppercaseLiteral("abc\\d+"));

    const lowered = try lowerPattern(alloc, "X\\Dy\\W[A-C]\\\\Q");
    try std.testing.expectEqualStrings("x\\Dy\\W[a-c]\\\\q", lowered);

    // `\D` still means "not a digit" after folding: "X-Y" matches, "X1Y" does not.
    var buf: [64]u8 = undefined;
    const r = (try compile(alloc, "x\\Dy", false)).?;
    try std.testing.expect(r.fold_case);
    try std.testing.expect(r.isMatch(lowerInto(&buf, "X-Y")));
    try std.testing.expect(!r.isMatch(lowerInto(&buf, "X1Y")));

    // A class of uppercase letters is exact unless forced.
    const exact = (try compile(alloc, "[A-Z]{3}", false)).?;
    try std.testing.expect(!exact.fold_case);
    try std.testing.expect(exact.isMatch("ABC"));
    try std.testing.expect(!exact.isMatch("abc"));
    const folded = (try compile(alloc, "[A-Z]{3}", true)).?;
    try std.testing.expect(folded.isMatch(lowerInto(&buf, "abc")));
}

test "a fixed literal needle: no compilation, smart case folds it, metacharacters are plain text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [64]u8 = undefined;

    const folded = try compileLiteral(alloc, "foo(bar", false);
    try std.testing.expect(folded.fold_case);
    try std.testing.expect(folded.isMatch(lowerInto(&buf, "call FOO(BAR) now")));
    try std.testing.expect(!folded.isMatch(lowerInto(&buf, "foobar")));

    const exact = try compileLiteral(alloc, "Foo.bar", false);
    try std.testing.expect(!exact.fold_case);
    try std.testing.expect(exact.isMatch("a Foo.bar b"));
    try std.testing.expect(!exact.isMatch("a foo.bar b"));
    try std.testing.expect(!exact.isMatch("a FooXbar b")); // `.` is not a wildcard here

    const forced = try compileLiteral(alloc, "Foo.bar", true);
    try std.testing.expect(forced.fold_case);
    try std.testing.expect(forced.isMatch(lowerInto(&buf, "A FOO.BAR B")));
}

test "the (?... family: non-capturing groups are rewritten and work, everything else is refused before mvzr" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [128]u8 = undefined;

    try std.testing.expect(hasInlineConstruct("(?i)foo"));
    try std.testing.expect(hasInlineConstruct("a(?=b)"));
    try std.testing.expect(hasInlineConstruct("x(?")); // trailing, still not a group
    try std.testing.expect(!hasInlineConstruct("(?:foo)"));
    try std.testing.expect(!hasInlineConstruct("\\(?i")); // escaped paren: `?` quantifies a literal `(`
    try std.testing.expect(!hasInlineConstruct("[(?]a")); // class members are literals
    try std.testing.expect((try compile(alloc, "(?i)foo", false)) == null);

    const r = (try compile(alloc, "(?:abc)+x", false)).?;
    try std.testing.expect(r.fold_case);
    try std.testing.expect(r.isMatch(lowerInto(&buf, "ABCabcX")));
    try std.testing.expect(!r.isMatch(lowerInto(&buf, "abx")));
    const nested = (try compile(alloc, "(?:a(?:b|c))d", false)).?;
    try std.testing.expect(nested.isMatch(lowerInto(&buf, "acd")));

    const msg = try inlineMessage(alloc, "(?i)foo");
    try std.testing.expect(std.mem.indexOf(u8, msg, "case_insensitive=true") != null);
}

test "an invalid pattern is null and its message teaches escaping; a long alternation fits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // mvzr logs a warning for the pattern it rejects; that is expected here,
    // and would otherwise be reported as stderr noise by the build runner.
    std.testing.log_level = .err;
    try std.testing.expect((try compile(alloc, "foo(bar", false)) == null);
    const msg = try invalidMessage(alloc, "foo(bar");
    try std.testing.expect(std.mem.startsWith(u8, msg, "invalid regex: /foo(bar/"));
    try std.testing.expect(std.mem.indexOf(u8, msg, "escape literal ( ) [ ] { } . * + ? with a backslash") != null);

    // Sixteen alternatives of identifiers — well past the default 64-op budget.
    const long = "alpha_one|beta_two|gamma_three|delta_four|epsilon_five|zeta_six|eta_seven|theta_eight|iota_nine|kappa_ten|lambda_eleven|mu_twelve|nu_thirteen|xi_fourteen|omicron_fifteen|pi_sixteen";
    const r = (try compile(alloc, long, false)).?;
    var buf: [64]u8 = undefined;
    try std.testing.expect(r.isMatch(lowerInto(&buf, "call PI_SIXTEEN()")));
    try std.testing.expect(!r.isMatch(lowerInto(&buf, "nothing here")));
}
