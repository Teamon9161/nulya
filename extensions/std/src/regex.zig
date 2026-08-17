//! The regex `grep` searches with: the vendored mvzr behind a wrapper that adds
//! the two things mvzr lacks and a search tool needs — a bigger program budget
//! and case handling.
//!
//! mvzr (`vendor/mvzr.zig`, unmodified) is a byte-level backtracking engine:
//! classes, alternation, groups, greedy / lazy / possessive / bounded
//! quantifiers, anchors, `\b`. No lookaround, no backreferences, no Unicode
//! classes, and no case-insensitive flag. The default `mvzr.Regex` is sized for
//! 64 ops / 8 character sets, which a model's `foo|bar|baz|...` alternation
//! outgrows quickly, so this compiles into `SizedRegex(256, 32)`.
//!
//! Case handling is tcode's smart case (tcode search.rs: `case_smart(true)` +
//! `case_insensitive(...)`): a pattern with no uppercase LITERAL letter searches
//! case-insensitively, any uppercase literal makes it exact, and
//! `case_insensitive=true` forces insensitivity outright. With no engine flag to
//! set, insensitivity is done by lowering both sides: the caller lowercases each
//! haystack line, and `compile` lowercases the pattern's literal letters —
//! only those. `\d \D \w \W \s \S \b \B` and every other backslash escape stay
//! exactly as written (lowering `\D` would silently turn "not a digit" into
//! "a digit"); letters inside `[...]` are literals and are lowered too.

const std = @import("std");
const mvzr = @import("vendor/mvzr.zig");

/// 256 ops / 32 sets: room for a long alternation of identifiers.
pub const Regex = mvzr.SizedRegex(256, 32);

pub const Compiled = struct {
    regex: Regex,
    /// True when the search is case-insensitive. The caller must then hand
    /// `isMatch` an already-lowercased line (`lowerInto`); the pattern side
    /// was lowered at compile time.
    fold_case: bool,

    pub fn isMatch(self: *const Compiled, line: []const u8) bool {
        return self.regex.isMatch(line);
    }
};

/// The teaching text for a pattern mvzr will not compile — tcode search.rs's
/// message, with the engine's own vocabulary in place of the regex crate's
/// diagnostic (mvzr reports no position).
pub fn invalidMessage(alloc: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "invalid regex: /{s}/ did not compile (byte-level regex: classes, alternation, groups, quantifiers, anchors and \\b work; lookaround and backreferences do not)\nRemember this is regex syntax — escape literal ( ) [ ] {{ }} . * + ? with a backslash.",
        .{pattern},
    );
}

/// Compile `pattern` under smart case, or null when mvzr rejects it. The lowered
/// pattern, when one is needed, is allocated from `alloc`.
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, case_insensitive: bool) !?Compiled {
    const fold = case_insensitive or !hasUppercaseLiteral(pattern);
    const source = if (fold) try lowerPattern(alloc, pattern) else pattern;
    const regex = Regex.compile(source) orelse return null;
    return .{ .regex = regex, .fold_case = fold };
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
