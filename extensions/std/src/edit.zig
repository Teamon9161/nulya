//! `edit` — exact string replacement in a UTF-8 text file, with a recovery
//! ladder for near misses and an echo of the edited region. Port of tcode
//! `fs/edit.rs` (`{path, old_string, new_string, replace_all?, target_line?}`);
//! every number and every sentence the model sees is tcode's unless a comment
//! says otherwise.
//!
//! **No read-before-edit gate.** The exact, unique match against the current
//! bytes on disk IS the verification: a stale or guessed `old_string` fails
//! safely, and a failure teaches (candidates with line numbers, similar lines,
//! the count) so the next call can succeed in one turn.
//!
//! **The recovery ladder, in order, first hit wins**: exact (with the file's
//! own line endings, so an LF `old_string` matches a CRLF file) → typographic
//! punctuation normalized → per-line whitespace normalized → all whitespace
//! including newlines normalized (reflow). Every rung splices the file's REAL
//! bytes back, and every rung refuses to choose between several matches: a
//! guess is not a self-heal.
//!
//! **Freshness**: the echoed snippet is recorded as a `read` of the new
//! version, not as a write — a write would mark the whole file seen and let a
//! later offset read return an "unchanged" stub for lines nobody has seen.

const std = @import("std");
const builtin = @import("builtin");
const rpc = @import("rpc.zig");
const text = @import("text.zig");
const freshness = @import("freshness.zig");
const write = @import("write.zig");

/// How many candidate windows a refusal renders. tcode fs/edit.rs
/// MAX_EDIT_CANDIDATES.
pub const max_edit_candidates: usize = 5;
/// Lines of context above and below each candidate. tcode fs/edit.rs.
const candidate_context_lines: usize = 2;
/// A candidate's line is shown at most this many characters. tcode fs/edit.rs.
const max_candidate_line_chars: usize = 120;
/// A normalized pass stops collecting once it has this many matches: past the
/// second one the answer is "ambiguous" either way. tcode fs/edit.rs `take(6)`.
const max_normalized_matches: usize = 6;

pub fn run(ctx: *const rpc.Ctx, args: std.json.ObjectMap) anyerror!rpc.Outcome {
    const alloc = ctx.alloc;
    const io = ctx.io;

    const path_arg = switch (try rpc.requireString(alloc, args, "path")) {
        .ok => |s| s,
        .failed => |f| return f,
    };
    const old = switch (try rpc.requireString(alloc, args, "old_string")) {
        .ok => |s| s,
        .failed => |f| return f,
    };
    const new = switch (try rpc.requireString(alloc, args, "new_string")) {
        .ok => |s| s,
        .failed => |f| return f,
    };
    if (old.len == 0) return rpc.refuse(alloc, "old_string must not be empty", .{});
    if (std.mem.eql(u8, old, new)) return rpc.refuse(alloc, "old_string and new_string are identical", .{});
    // Checked before matching, which a clipped `old_string` could never survive
    // anyway: this turns the "no match, why?" puzzle into one sentence naming
    // the cause. On `new_string` it is the real guard — that one would have
    // been written to disk.
    if (text.hasReadMarker(old)) return rpc.refuse(alloc, "{s}", .{try text.markerError(alloc, "old_string")});
    if (text.hasReadMarker(new)) return rpc.refuse(alloc, "{s}", .{try text.markerError(alloc, "new_string")});

    const replace_all = rpc.optionalBool(args, "replace_all", false) catch
        return rpc.refuse(alloc, "replace_all must be a boolean", .{});
    const target_line: ?usize = blk: {
        const raw = rpc.optionalUnsigned(args, "target_line") catch
            return rpc.refuse(alloc, "target_line must be a positive 1-based line number", .{});
        const line = raw orelse break :blk null;
        if (line == 0) return rpc.refuse(alloc, "target_line must be a positive 1-based line number", .{});
        break :blk @intCast(line);
    };
    if (replace_all and target_line != null)
        return rpc.refuse(alloc, "target_line cannot be combined with replace_all=true", .{});

    const path = try ctx.resolve(path_arg);
    const shown_path = text.rel(path, ctx.cwd);
    const cwd = std.Io.Dir.cwd();

    const bytes = cwd.readFileAlloc(io, path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return rpc.refuse(alloc, "{s}", .{try text.notFoundHelp(alloc, io, path)}),
        else => return rpc.refuse(alloc, "cannot read {s}: {s}", .{ path, @errorName(err) }),
    };

    var journal = try freshness.Journal.open(alloc, io, ctx.cwd, ctx.session_id);
    // Outside a session nothing is recorded, so "you have not read this file"
    // would be an assertion about a record that does not exist.
    const seen = if (journal) |*j| j.tracker.seenCurrent(path, freshness.contentHash(bytes)) else true;

    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return rpc.refuse(alloc, "{s} is not valid UTF-8; edit only supports text files and will not rewrite bytes lossily", .{shown_path});
    }
    const body = bytes;

    const plan: ReplacementPlan = switch (try replacementPlan(alloc, body, old, new)) {
        .found => |found| if (target_line) |line| switch (try selectExactMatchAtLine(alloc, body, found, line)) {
            .found => |p| p,
            .failed => |message| return rpc.refuse(alloc, "{s}", .{message}),
        } else found,
        .not_found => {
            var msg: std.ArrayList(u8) = .empty;
            try msg.appendSlice(alloc, try nearMissHelp(alloc, body, old));
            if (!seen) {
                try msg.appendSlice(alloc, "\nnote: you have not read the current version of this file; read it to get the exact text.");
            }
            return rpc.refuse(alloc, "{s}", .{msg.items});
        },
        .ambiguous => |candidates| blk: {
            const line = target_line orelse return rpc.refuse(alloc, "old_string has multiple whitespace/punctuation-normalized matches; add enough exact surrounding context to identify one occurrence, or pass target_line from one candidate below.\nCandidates:\n{s}", .{try joinHelp(alloc, try candidateHelp(alloc, body, candidates), "\n\n")});
            const candidate = selectCandidateAtLine(body, candidates, line) orelse
                return rpc.refuse(alloc, "target_line {d} does not identify exactly one normalized match. Re-read the candidate list and choose a unique starting line.\nCandidates:\n{s}", .{ line, try joinHelp(alloc, try candidateHelp(alloc, body, candidates), "\n\n") });
            break :blk ReplacementPlan{
                .old = body[candidate.at .. candidate.at + candidate.len],
                .new = try normalizeNewlines(alloc, new, dominantLineEnding(body)),
                .count = 1,
                .at = candidate.at,
            };
        },
    };

    if (plan.count > 1 and target_line == null and !replace_all) {
        const occurrences = try occurrenceHelp(alloc, body, plan.old, 8);
        return rpc.refuse(alloc, "old_string appears {d} times; add surrounding context to make it unique, pass target_line from one occurrence below, or set replace_all=true.\nOccurrences:\n{s}", .{ plan.count, try joinHelp(alloc, occurrences, "\n") });
    }

    const new_text = if (replace_all)
        try std.mem.replaceOwned(u8, alloc, body, plan.old, plan.new)
    else
        try replaceOnceAt(alloc, body, plan);

    putFileAtomic(io, path, new_text) catch |err| return rpc.refuse(alloc, "{s}", .{try write.writeError(alloc, path, err)});

    // Show the edited region so the model sees the result without re-reading
    // the file. Everything before the first replacement is untouched, so its
    // offset in the new text is the one the plan already found — no second
    // search of the file.
    const line_no = std.mem.count(u8, new_text[0..plan.at], "\n") + 1;
    const start = @max(line_no -| 3, 1);
    const window = text.countLines(plan.new) + 5;
    const all = try text.lines(alloc, new_text);
    const from = @min(start - 1, all.len);
    const shown = all[from..@min(from + window, all.len)];
    const snippet = try text.numbered(alloc, shown, start);

    // Record exactly what reached the model: the snippet above, under the new
    // content hash (same principle as `read`). NOT a write record — that would
    // mark the whole file as seen and let a later offset read incorrectly
    // return an unchanged stub. A read record clears the old version's ranges,
    // which is the conservative truth: line numbers after the edit point may
    // have shifted. Without it the stored hash would stay stale and the
    // `append` / `write` gates would mistake our own edit for an external one.
    if (shown.len != 0) {
        if (journal) |*j| {
            const shown_end = start + shown.len - 1;
            const range: ?freshness.Range = if (start == 1 and shown_end >= all.len) null else .{ .start = start, .end = shown_end };
            try j.recordRead(path, freshness.contentHash(new_text), range);
        }
    }

    const replacements = if (replace_all) plan.count else 1;
    return .{ .text = try std.fmt.allocPrint(alloc, "edited {s} ({d} replacement{s}). Result:\n{s}", .{
        shown_path,
        replacements,
        if (replace_all and plan.count > 1) "s" else "",
        try text.lossyUtf8(alloc, snippet),
    }) };
}

/// Replace the whole file atomically, keeping its permission bits — editing a
/// script must not silently drop its executable bit. The Windows retry is
/// `write.putFile`'s: `ERROR_USER_MAPPED_FILE` (1224) surfaces here as
/// `AccessDenied` and is normally transient.
fn putFileAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    atomicPut(io, path, data) catch |err| switch (err) {
        error.AccessDenied => if (builtin.os.tag == .windows) {
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
            return atomicPut(io, path, data);
        } else return err,
        else => return err,
    };
}

fn atomicPut(io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const permissions = (try cwd.statFile(io, path, .{})).permissions;
    var atomic = try cwd.createFileAtomic(io, path, .{ .replace = true, .permissions = permissions });
    defer atomic.deinit(io);
    // The create-time permissions pass through open(2) and get masked by the
    // process umask (0777 becomes 0755); setting them on the handle does not.
    try atomic.file.setPermissions(io, permissions);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

// ------------------------------------------------------------------- plan

pub const ReplacementPlan = struct {
    old: []const u8,
    new: []const u8,
    count: usize,
    /// Byte offset of the first match. The text before it survives the
    /// replacement unchanged, so this is also where the new text lands.
    at: usize,
};

/// A non-exact recovery match is safe only when it identifies one location. It
/// must never silently pick the first of several equivalent blocks: that would
/// violate edit's public uniqueness contract.
pub const MatchCandidate = struct { at: usize, len: usize };

pub const PlanResult = union(enum) {
    found: ReplacementPlan,
    not_found,
    ambiguous: []const MatchCandidate,
};

const NormalizedMatch = union(enum) {
    not_found,
    unique: []const u8,
    ambiguous: []const MatchCandidate,
};

/// `old` must be a substring of `text`; null when it does not occur.
fn locate(haystack: []const u8, old: []const u8, new: []const u8) ?ReplacementPlan {
    const at = std.mem.indexOf(u8, haystack, old) orelse return null;
    return .{ .old = old, .new = new, .count = std.mem.count(u8, haystack, old), .at = at };
}

pub fn replacementPlan(alloc: std.mem.Allocator, haystack: []const u8, old: []const u8, new: []const u8) !PlanResult {
    const eol = dominantLineEnding(haystack);
    var attempts: std.ArrayList([2][]const u8) = .empty;
    try attempts.append(alloc, .{ old, try normalizeNewlines(alloc, new, eol) });
    if (std.mem.indexOfAny(u8, old, "\r\n") != null) {
        try attempts.append(alloc, .{ try normalizeNewlines(alloc, old, eol), try normalizeNewlines(alloc, new, eol) });
        try attempts.append(alloc, .{ try normalizeNewlines(alloc, old, "\n"), try normalizeNewlines(alloc, new, "\n") });
        try attempts.append(alloc, .{ try normalizeNewlines(alloc, old, "\r\n"), try normalizeNewlines(alloc, new, "\r\n") });
    }
    var tried: std.ArrayList([]const u8) = .empty;
    for (attempts.items) |pair| {
        var duplicate = false;
        for (tried.items) |seen| {
            if (std.mem.eql(u8, seen, pair[0])) duplicate = true;
        }
        if (duplicate) continue;
        try tried.append(alloc, pair[0]);
        if (locate(haystack, pair[0], pair[1])) |plan| return .{ .found = plan };
    }

    // Last resort: models often emit typographic punctuation (– " " …) where
    // the file has plain ASCII, or drift a space inside an otherwise-identical
    // block. Match with those differences normalized away, but splice the
    // ACTUAL file bytes back in so nothing else is disturbed. Recovery is
    // intentionally stricter than exact replacement: a choice among several
    // normalized matches is a guess, not a self-heal.
    var normalized = try findPunctNormalized(alloc, haystack, old);
    if (normalized == .not_found) normalized = try findWsNormalized(alloc, haystack, old);
    // Reflow (a formatter joining/splitting lines) changes the line count,
    // which the line-anchored matcher cannot follow. Fall through to a
    // whitespace-insensitive match across newlines.
    if (normalized == .not_found) normalized = try findReflowNormalized(alloc, haystack, old);

    return switch (normalized) {
        .not_found => .not_found,
        .unique => |orig| if (locate(haystack, orig, try normalizeNewlines(alloc, new, eol))) |plan|
            .{ .found = plan }
        else
            .not_found,
        .ambiguous => |candidates| .{ .ambiguous = candidates },
    };
}

fn matchStartLine(haystack: []const u8, at: usize) usize {
    return std.mem.count(u8, haystack[0..at], "\n") + 1;
}

const Selected = union(enum) { found: ReplacementPlan, failed: []const u8 };

fn selectExactMatchAtLine(alloc: std.mem.Allocator, haystack: []const u8, plan_in: ReplacementPlan, target_line: usize) !Selected {
    var plan = plan_in;
    var found: ?usize = null;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, search, plan.old)) |at| {
        search = at + plan.old.len;
        if (matchStartLine(haystack, at) != target_line) continue;
        if (found != null) {
            return .{ .failed = try std.fmt.allocPrint(alloc, "target_line {d} contains multiple old_string occurrences; add surrounding context", .{target_line}) };
        }
        found = at;
    }
    const at = found orelse return .{ .failed = try std.fmt.allocPrint(alloc, "target_line {d} does not contain an exact old_string occurrence", .{target_line}) };
    plan.at = at;
    plan.count = 1;
    return .{ .found = plan };
}

fn selectCandidateAtLine(haystack: []const u8, candidates: []const MatchCandidate, target_line: usize) ?MatchCandidate {
    var found: ?MatchCandidate = null;
    for (candidates) |candidate| {
        if (matchStartLine(haystack, candidate.at) != target_line) continue;
        if (found != null) return null;
        found = candidate;
    }
    return found;
}

fn replaceOnceAt(alloc: std.mem.Allocator, haystack: []const u8, plan: ReplacementPlan) ![]u8 {
    const end = plan.at + plan.old.len;
    std.debug.assert(std.mem.eql(u8, haystack[plan.at..end], plan.old));
    return std.mem.concat(alloc, u8, &.{ haystack[0..plan.at], plan.new, haystack[end..] });
}

// ------------------------------------------------------- normalized passes

/// One decoded character: where it starts, what it is, how many bytes it took.
const CharPos = struct { at: usize, cp: u21, len: usize };

fn decodeChars(alloc: std.mem.Allocator, s: []const u8) ![]CharPos {
    var out: std.ArrayList(CharPos) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const cp: u21 = std.unicode.utf8Decode(s[i..end]) catch 0xFFFD;
        try out.append(alloc, .{ .at = i, .cp = cp, .len = end - i });
        i = end;
    }
    return out.toOwnedSlice(alloc);
}

/// Map common typographic punctuation to its ASCII equivalent. Only 1-char →
/// 1-char maps, so character positions stay aligned between original and
/// normalized. tcode fs/edit.rs `normalize_punct`.
fn normalizePunct(cp: u21) u21 {
    return switch (cp) {
        0x2010...0x2015, 0x2212 => '-', // hyphens, dashes, minus
        0x2018, 0x2019, 0x201B => '\'', // single quotes
        0x201C, 0x201D, 0x201F => '"', // double quotes
        else => cp,
    };
}

/// Rust's `char::is_whitespace` (the Unicode White_Space property).
fn isWhitespaceCp(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// The characters of `s` with whitespace dropped and punctuation normalized —
/// what the whitespace-insensitive rungs compare. tcode fs/edit.rs `key`.
fn normalizedKey(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const chars = try decodeChars(alloc, s);
    for (chars) |c| {
        if (isWhitespaceCp(c.cp)) continue;
        try appendCp(alloc, &out, normalizePunct(c.cp));
    }
    return out.toOwnedSlice(alloc);
}

fn appendCp(alloc: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(alloc, "\u{FFFD}");
        return;
    };
    try out.appendSlice(alloc, buf[0..n]);
}

fn oneOrMany(alloc: std.mem.Allocator, matches: []const MatchCandidate, haystack: []const u8) !NormalizedMatch {
    if (matches.len == 0) return .not_found;
    if (matches.len == 1) return .{ .unique = haystack[matches[0].at .. matches[0].at + matches[0].len] };
    _ = alloc;
    return .{ .ambiguous = matches };
}

/// Find `old` in `haystack` comparing with punctuation normalized, and return
/// the exact original substring at that location (so the real bytes are
/// replaced). Ambiguous rather than silently choosing when several file ranges
/// normalize to the same requested text. tcode fs/edit.rs.
fn findPunctNormalized(alloc: std.mem.Allocator, haystack: []const u8, old: []const u8) !NormalizedMatch {
    const pat = try decodeChars(alloc, old);
    var changed = false;
    for (pat) |c| {
        if (normalizePunct(c.cp) != c.cp) changed = true;
    }
    if (!changed) return .not_found; // the exact pass already tried this
    const hay = try decodeChars(alloc, haystack);
    if (pat.len == 0 or pat.len > hay.len) return .not_found;

    var matches: std.ArrayList(MatchCandidate) = .empty;
    var i: usize = 0;
    while (i + pat.len <= hay.len) : (i += 1) {
        var all_equal = true;
        for (pat, 0..) |p, k| {
            if (normalizePunct(hay[i + k].cp) != normalizePunct(p.cp)) {
                all_equal = false;
                break;
            }
        }
        if (!all_equal) continue;
        const last = hay[i + pat.len - 1];
        try matches.append(alloc, .{ .at = hay[i].at, .len = last.at + last.len - hay[i].at });
        if (matches.items.len == max_normalized_matches) break;
    }
    return oneOrMany(alloc, matches.items, haystack);
}

/// Locate `old` line by line, ignoring EVERY whitespace difference
/// (indentation, trailing, internal runs) plus typographic punctuation, and
/// return the exact original file substring spanning the matched lines. This is
/// the most common near miss: the model reproduces a block verbatim but drifts
/// one space, so nothing else in the block differs.
///
/// Only whole-line blocks match — a sub-line fragment falls through (its
/// whitespace rarely differs, and the exact pass already tried it). Because the
/// real file bytes are spliced back, the file's true formatting survives; the
/// model's whitespace guess is discarded. tcode fs/edit.rs.
fn findWsNormalized(alloc: std.mem.Allocator, haystack: []const u8, old: []const u8) !NormalizedMatch {
    const old_lines = try text.lines(alloc, old);
    var old_keys: std.ArrayList([]const u8) = .empty;
    var any_content = false;
    for (old_lines) |line| {
        const key = try normalizedKey(alloc, line);
        if (key.len != 0) any_content = true;
        try old_keys.append(alloc, key);
    }
    // Need at least one line with real content to anchor on; an all-blank
    // needle would match anywhere.
    if (!any_content) return .not_found;

    const Piece = struct { off: usize, content_len: usize, piece_len: usize, key: []const u8 };
    var pieces: std.ArrayList(Piece) = .empty;
    var off: usize = 0;
    while (off < haystack.len) {
        const nl = std.mem.indexOfScalarPos(u8, haystack, off, '\n');
        const piece_end = if (nl) |n| n + 1 else haystack.len;
        var content = haystack[off..piece_end];
        if (content.len != 0 and content[content.len - 1] == '\n') content = content[0 .. content.len - 1];
        if (content.len != 0 and content[content.len - 1] == '\r') content = content[0 .. content.len - 1];
        try pieces.append(alloc, .{
            .off = off,
            .content_len = content.len,
            .piece_len = piece_end - off,
            // The key is computed once per line, not once per (window, line):
            // re-keying inside the sliding comparison makes a failed edit on a
            // large file quadratic in allocations.
            .key = try normalizedKey(alloc, content),
        });
        off = piece_end;
    }

    const m = old_keys.items.len;
    if (m == 0 or m > pieces.items.len) return .not_found;
    const include_trailing = old[old.len - 1] == '\n';

    var matches: std.ArrayList(MatchCandidate) = .empty;
    var w: usize = 0;
    while (w + m <= pieces.items.len) : (w += 1) {
        var matched = true;
        for (old_keys.items, 0..) |key, k| {
            if (!std.mem.eql(u8, pieces.items[w + k].key, key)) {
                matched = false;
                break;
            }
        }
        if (!matched) continue;
        const start = pieces.items[w].off;
        const last = pieces.items[w + m - 1];
        const end = if (include_trailing) last.off + last.piece_len else last.off + last.content_len;
        try matches.append(alloc, .{ .at = start, .len = end - start });
        if (matches.items.len == max_normalized_matches) break;
    }
    return oneOrMany(alloc, matches.items, haystack);
}

/// Match `old` ignoring ALL whitespace, newlines included, plus typographic
/// punctuation. This is the reflow case the line-anchored pass cannot reach: a
/// formatter joined a call onto one line or split it across several, so the
/// line COUNT changed and nothing lines up.
///
/// Deliberately the loosest rung, hence last: collapsing newlines lets a needle
/// straddle token boundaries. It stays safe because the exact / punct / ws
/// passes ran first, the ambiguity guard rejects a looks-unique-but-isn't
/// match, and only the real file bytes are spliced back. tcode fs/edit.rs.
fn findReflowNormalized(alloc: std.mem.Allocator, haystack: []const u8, old: []const u8) !NormalizedMatch {
    var hay: std.ArrayList(CharPos) = .empty;
    for (try decodeChars(alloc, haystack)) |c| {
        if (isWhitespaceCp(c.cp)) continue;
        try hay.append(alloc, .{ .at = c.at, .cp = normalizePunct(c.cp), .len = c.len });
    }
    var needle: std.ArrayList(u21) = .empty;
    for (try decodeChars(alloc, old)) |c| {
        if (isWhitespaceCp(c.cp)) continue;
        try needle.append(alloc, normalizePunct(c.cp));
    }
    const m = needle.items.len;
    // An all-whitespace needle carries no anchor and would match anywhere.
    if (m == 0 or m > hay.items.len) return .not_found;

    var matches: std.ArrayList(MatchCandidate) = .empty;
    var i: usize = 0;
    while (i + m <= hay.items.len) : (i += 1) {
        var all_equal = true;
        for (needle.items, 0..) |cp, k| {
            if (hay.items[i + k].cp != cp) {
                all_equal = false;
                break;
            }
        }
        if (!all_equal) continue;
        const start = hay.items[i].at;
        const last = hay.items[i + m - 1];
        try matches.append(alloc, .{ .at = start, .len = last.at + last.len - start });
        if (matches.items.len == max_normalized_matches) break;
    }
    return oneOrMany(alloc, matches.items, haystack);
}

// ------------------------------------------------------------- line endings

fn normalizeNewlines(alloc: std.mem.Allocator, s: []const u8, eol: []const u8) ![]const u8 {
    const crlf_to_lf = try std.mem.replaceOwned(u8, alloc, s, "\r\n", "\n");
    const lf = try std.mem.replaceOwned(u8, alloc, crlf_to_lf, "\r", "\n");
    if (std.mem.eql(u8, eol, "\n")) return lf;
    return std.mem.replaceOwned(u8, alloc, lf, "\n", eol);
}

fn dominantLineEnding(haystack: []const u8) []const u8 {
    const crlf = std.mem.count(u8, haystack, "\r\n");
    const lf = std.mem.count(u8, haystack, "\n") -| crlf;
    return if (crlf > lf) "\r\n" else "\n";
}

// ------------------------------------------------------------------- help

fn joinHelp(alloc: std.mem.Allocator, parts: []const []const u8, sep: []const u8) ![]const u8 {
    return std.mem.join(alloc, sep, parts);
}

/// Show a small, line-numbered window around each rejected exact occurrence.
/// The model still has to submit a unique `old_string`; line numbers are
/// evidence for disambiguation, never an alternate edit addressing scheme.
pub fn occurrenceHelp(alloc: std.mem.Allocator, haystack: []const u8, needle: []const u8, limit: usize) ![]const []const u8 {
    var candidates: std.ArrayList(MatchCandidate) = .empty;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, search, needle)) |at| {
        try candidates.append(alloc, .{ .at = at, .len = needle.len });
        search = at + needle.len;
        if (candidates.items.len == limit) break;
    }
    return candidateHelp(alloc, haystack, candidates.items);
}

pub fn candidateHelp(alloc: std.mem.Allocator, haystack: []const u8, candidates: []const MatchCandidate) ![]const []const u8 {
    const all = try text.lines(alloc, haystack);
    var rendered: std.ArrayList([]const u8) = .empty;
    for (candidates[0..@min(candidates.len, max_edit_candidates)], 0..) |candidate, index| {
        const start_line = matchStartLine(haystack, candidate.at);
        const matched_lines = @max(text.countLines(haystack[candidate.at .. candidate.at + candidate.len]), 1);
        const end_line = start_line + matched_lines - 1;
        const first = start_line -| (candidate_context_lines + 1);
        const last = @min(end_line + candidate_context_lines, all.len);

        var window: std.ArrayList(u8) = .empty;
        for (all[first..last], 0..) |line, offset| {
            if (offset != 0) try window.append(alloc, '\n');
            try window.print(alloc, "{d:>6}\t{s}", .{ first + offset + 1, try candidateLine(alloc, line) });
        }
        const range = if (start_line == end_line)
            try std.fmt.allocPrint(alloc, "line {d}", .{start_line})
        else
            try std.fmt.allocPrint(alloc, "lines {d}\u{2013}{d}", .{ start_line, end_line });
        try rendered.append(alloc, try std.fmt.allocPrint(alloc, "  candidate {d} ({s}):\n{s}", .{ index + 1, range, window.items }));
    }
    if (candidates.len > max_edit_candidates) {
        try rendered.append(alloc, try std.fmt.allocPrint(alloc, "  \u{2026} {d} additional candidate matches omitted", .{candidates.len - max_edit_candidates}));
    }
    return rendered.toOwnedSlice(alloc);
}

fn candidateLine(alloc: std.mem.Allocator, line: []const u8) ![]const u8 {
    const chars = try decodeChars(alloc, line);
    if (chars.len <= max_candidate_line_chars) return line;
    const cut = chars[max_candidate_line_chars].at;
    return std.fmt.allocPrint(alloc, "{s}\u{2026}", .{line[0..cut]});
}

/// Self-healing "old_string not found": show every bounded diagnostic hint
/// rather than biasing the model toward the first matching region in the file.
pub fn nearMissHelp(alloc: std.mem.Allocator, haystack: []const u8, old: []const u8) ![]const u8 {
    const no_similar = "old_string not found in file. No similar line found — the content may differ more than expected; re-read the relevant range.";

    var probe: ?[]const u8 = null;
    for (try text.lines(alloc, old)) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n\x0B\x0C");
        if (line.len < 8) continue;
        // Rust's `max_by_key` keeps the LAST of equal maxima.
        if (probe == null or line.len >= probe.?.len) probe = line;
    }
    const needle = probe orelse return no_similar;

    const similar = try similarLineCandidates(alloc, haystack, needle);
    if (similar.candidates.len == 0) return no_similar;

    var msg: std.ArrayList(u8) = .empty;
    try msg.appendSlice(alloc, "old_string not found in file. Similar locations below are diagnostic hints, not replacement targets. Add unique exact surrounding context and retry:\n");
    try msg.appendSlice(alloc, try joinHelp(alloc, try candidateHelp(alloc, haystack, similar.candidates), "\n\n"));
    if (similar.omitted > 0) {
        try msg.print(alloc, "\n  \u{2026} {d} additional similar location{s} omitted", .{ similar.omitted, if (similar.omitted == 1) "" else "s" });
    }
    try msg.appendSlice(alloc, "\nRe-read the relevant range if none of these is the intended edit.");
    return msg.toOwnedSlice(alloc);
}

const Similar = struct { candidates: []const MatchCandidate, omitted: usize };

fn similarLineCandidates(alloc: std.mem.Allocator, haystack: []const u8, probe: []const u8) !Similar {
    var candidates: std.ArrayList(MatchCandidate) = .empty;
    var total: usize = 0;
    var at: usize = 0;
    while (at < haystack.len) {
        const nl = std.mem.indexOfScalarPos(u8, haystack, at, '\n');
        const piece_end = if (nl) |n| n + 1 else haystack.len;
        var line = haystack[at..piece_end];
        if (line.len != 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.indexOf(u8, line, probe) != null or std.mem.eql(u8, std.mem.trim(u8, line, " \t\r\n\x0B\x0C"), probe)) {
            total += 1;
            if (candidates.items.len < max_edit_candidates) try candidates.append(alloc, .{ .at = at, .len = line.len });
        }
        at = piece_end;
    }
    return .{ .candidates = candidates.items, .omitted = total -| candidates.items.len };
}

// ------------------------------------------------------------------ tests
// The plan / help tests are tcode's `fs/tests.rs` `edit_*`, one for one; the
// end-to-end ones run through `run` against a real temp directory.

test {
    std.testing.refAllDecls(@This());
}

const TestFixture = @import("read.zig").TestFixture;
const read = @import("read.zig");

fn expectPlan(arena: std.mem.Allocator, haystack: []const u8, old: []const u8, new: []const u8) !ReplacementPlan {
    const result = try replacementPlan(arena, haystack, old, new);
    if (result != .found) {
        std.debug.print("expected a plan, got {s}\n", .{@tagName(result)});
        return error.TestUnexpectedResult;
    }
    return result.found;
}

test "edit plan: an LF old_string matches a CRLF file and the replacement keeps CRLF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body = "one\r\ntwo\r\nthree\r\n";
    const plan = try expectPlan(alloc, body, "two\nthree\n", "deux\ntrois\n");
    try std.testing.expectEqualStrings("two\r\nthree\r\n", plan.old);
    try std.testing.expectEqualStrings("deux\r\ntrois\r\n", plan.new);
    try std.testing.expectEqualStrings("one\r\ndeux\r\ntrois\r\n", try replaceOnceAt(alloc, body, plan));
}

test "edit plan: typographic punctuation is normalized and the file's real bytes are spliced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body = "let x = a - b; // \"note\"\n";
    const old = "a \u{2013} b; // \u{201C}note\u{201D}";
    const plan = try expectPlan(alloc, body, old, "a + b; // ok");
    try std.testing.expectEqual(@as(usize, 1), plan.count);
    try std.testing.expectEqualStrings("a - b; // \"note\"", plan.old);
    try std.testing.expectEqualStrings("let x = a + b; // ok\n", try replaceOnceAt(alloc, body, plan));
}

test "edit plan: one drifted internal space still matches, and the file's spacing survives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body =
        \\fn rate_limits_from() {
        \\    Some(RateLimits {
        \\        primary: parse(&value["primary"])?,
        \\        secondary: parse(&value["secondary"]),
        \\    })
        \\}
        \\
    ;
    const old =
        \\fn rate_limits_from() {
        \\    Some(RateLimits {
        \\        primary: parse(&value["primary"] )?,
        \\        secondary: parse(&value["secondary"]),
        \\    })
        \\}
        \\
    ;
    const new = "fn rate_limits_from() { None }\n";
    const plan = try expectPlan(alloc, body, old, new);
    try std.testing.expectEqual(@as(usize, 1), plan.count);
    try std.testing.expect(std.mem.indexOf(u8, plan.old, "[\"primary\"])?") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.old, "[\"primary\"] )?") == null);
    try std.testing.expectEqualStrings(new, try replaceOnceAt(alloc, body, plan));
}

test "edit plan: a tab-vs-spaces indentation guess matches and restores the real bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const plan = try expectPlan(alloc, "fn f() {\n\treturn 1;\n}\n", "fn f() {\n    return 1;\n}\n", "fn f() {\n\treturn 2;\n}\n");
    try std.testing.expectEqual(@as(usize, 1), plan.count);
    try std.testing.expectEqualStrings("fn f() {\n\treturn 1;\n}\n", plan.old);
}

test "edit plan: the whitespace rung refuses a content mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try replacementPlan(alloc, "fn f() {\n    return 1;\n}\n", "fn f() {\n    return 2;\n}\n", "x");
    try std.testing.expect(result == .not_found);
}

test "edit plan: two whitespace-equivalent blocks are ambiguous, not a guess" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body = "fn f() {\n\treturn 1;\n}\n\nfn f() {\n    return 1;\n}\n";
    const result = try replacementPlan(alloc, body, "fn f() {\n  return 1;\n}\n", "x");
    try std.testing.expect(result == .ambiguous);
    try std.testing.expectEqual(@as(usize, 2), result.ambiguous.len);
    try std.testing.expectEqual(std.mem.indexOf(u8, body, "fn f").?, result.ambiguous[0].at);
    const help = try candidateHelp(alloc, body, result.ambiguous);
    try std.testing.expect(std.mem.indexOf(u8, help[0], "candidate 1") != null);
}

test "edit plan: a single-line old_string recovers against a reflowed block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body =
        \\fn t() {
        \\    assert_eq!(
        \\        left,
        \\        right
        \\    );
        \\}
        \\
    ;
    const plan = try expectPlan(alloc, body, "assert_eq!(left, right);", "assert_eq!(left, expected);");
    try std.testing.expectEqual(@as(usize, 1), plan.count);
    try std.testing.expect(std.mem.indexOfScalar(u8, plan.old, '\n') != null);
    try std.testing.expect(std.mem.startsWith(u8, plan.old, "assert_eq!("));
    try std.testing.expectEqualStrings("fn t() {\n    assert_eq!(left, expected);\n}\n", try replaceOnceAt(alloc, body, plan));
}

test "edit plan: a multi-line old_string recovers against a collapsed line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const plan = try expectPlan(alloc, "    assert_eq!(left, right);\n", "assert_eq!(\n    left,\n    right\n);", "assert_eq!(left, expected);");
    try std.testing.expectEqual(@as(usize, 1), plan.count);
    try std.testing.expectEqualStrings("assert_eq!(left, right);", plan.old);
}

test "edit plan: the reflow rung reports ambiguity when the block repeats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body =
        \\fn a() {
        \\    assert_eq!(
        \\        a,
        \\        b
        \\    );
        \\}
        \\fn c() {
        \\    assert_eq!(a,
        \\        b);
        \\}
        \\
    ;
    const result = try replacementPlan(alloc, body, "assert_eq!(a, b);", "x");
    try std.testing.expect(result == .ambiguous);
}

test "edit plan: an exact match short-circuits before the reflow rung" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body =
        \\assert_eq!(a, b);
        \\assert_eq!(
        \\    a,
        \\    b
        \\);
        \\
    ;
    const old = "assert_eq!(a, b);";
    const plan = try expectPlan(alloc, body, old, "assert_eq!(a, c);");
    try std.testing.expectEqual(@as(usize, 1), plan.count);
    try std.testing.expectEqualStrings(old, plan.old);
}

test "edit help: occurrences show bounded line-numbered context and mark the omitted ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body = "header\nfirst section\nalpha\nbeta\nsecond section\nalpha\nbeta\nfooter\n";
    const help = try occurrenceHelp(alloc, body, "alpha\nbeta\n", 8);
    try std.testing.expectEqual(@as(usize, 2), help.len);
    try std.testing.expect(std.mem.indexOf(u8, help[0], "candidate 1 (lines 3\u{2013}4):") != null);
    try std.testing.expect(std.mem.indexOf(u8, help[0], "     2\tfirst section") != null);
    try std.testing.expect(std.mem.indexOf(u8, help[1], "candidate 2 (lines 6\u{2013}7):") != null);
    try std.testing.expect(std.mem.indexOf(u8, help[1], "     5\tsecond section") != null);

    var many: std.ArrayList(u8) = .empty;
    for (0..max_edit_candidates + 1) |_| try many.appendSlice(alloc, "match\n");
    const capped = try occurrenceHelp(alloc, many.items, "match\n", max_edit_candidates + 1);
    try std.testing.expectEqual(max_edit_candidates + 1, capped.len);
    try std.testing.expect(std.mem.indexOf(u8, capped[capped.len - 1], "1 additional candidate matches omitted") != null);
}

test "edit help: not found lists similar locations, bounds them, and always says re-read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body =
        \\pub fn helper() {
        \\    actual();
        \\}
        \\
        \\#[cfg(test)]
        \\mod tests {
        \\    fn helper() {
        \\        actual();
        \\    }
        \\}
        \\
    ;
    const help = try nearMissHelp(alloc, body, "fn helper() {\n    expected();\n}");
    try std.testing.expect(std.mem.indexOf(u8, help, "diagnostic hints, not replacement targets") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "candidate 1 (line 1):") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "candidate 2 (line 7):") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "#[cfg(test)]") != null);

    var many: std.ArrayList(u8) = .empty;
    for (0..max_edit_candidates + 1) |_| try many.appendSlice(alloc, "target marker\n");
    const bounded = try nearMissHelp(alloc, many.items, "target marker\nmiss");
    try std.testing.expectEqual(max_edit_candidates, std.mem.count(u8, bounded, "candidate "));
    try std.testing.expect(std.mem.indexOf(u8, bounded, "1 additional similar location omitted") != null);

    const nothing = try nearMissHelp(alloc, "actual content\n", "expected content\n");
    try std.testing.expect(std.mem.indexOf(u8, nothing, "No similar line found") != null);
    try std.testing.expect(std.mem.indexOf(u8, nothing, "re-read the relevant range") != null);
}

test "edit: an empty old_string and a non-UTF-8 file are refused without touching the file" {
    const f = try TestFixture.init("s-edit-guard");
    defer f.deinit();
    const io = std.testing.io;

    try f.tmp.dir.writeFile(io, .{ .sub_path = "text.txt", .data = "unchanged" });
    const empty = try f.call(run, "{{\"path\":\"text.txt\",\"old_string\":\"\",\"new_string\":\"x\",\"replace_all\":true}}", .{});
    try std.testing.expectEqualStrings("old_string must not be empty", empty.failed);
    try std.testing.expectEqualStrings("unchanged", try f.tmp.dir.readFileAlloc(io, "text.txt", f.arena.allocator(), .unlimited));

    try f.tmp.dir.writeFile(io, .{ .sub_path = "data.bin", .data = "before\xffafter" });
    const binary = try f.call(run, "{{\"path\":\"data.bin\",\"old_string\":\"before\",\"new_string\":\"changed\"}}", .{});
    try std.testing.expect(std.mem.indexOf(u8, binary.failed, "not valid UTF-8") != null);
    try std.testing.expectEqualStrings("before\xffafter", try f.tmp.dir.readFileAlloc(io, "data.bin", f.arena.allocator(), .unlimited));

    const same = try f.call(run, "{{\"path\":\"text.txt\",\"old_string\":\"a\",\"new_string\":\"a\"}}", .{});
    try std.testing.expectEqualStrings("old_string and new_string are identical", same.failed);

    const marked = try f.call(run, "{{\"path\":\"text.txt\",\"old_string\":\"un{s}9 bytes]\",\"new_string\":\"x\"}}", .{text.marker_open});
    try std.testing.expect(std.mem.startsWith(u8, marked.failed, "old_string contains a truncation marker"));
}

test "edit: target_line picks one exact and one normalized occurrence, and refuses a miss or replace_all" {
    const f = try TestFixture.init("s-edit-target");
    defer f.deinit();
    const io = std.testing.io;
    const alloc = f.arena.allocator();

    try f.tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "header\nneedle\nseparator\nneedle\n" });
    const exact = try f.call(run, "{{\"path\":\"a.txt\",\"old_string\":\"needle\",\"new_string\":\"changed\",\"target_line\":4}}", .{});
    try std.testing.expect(exact == .text);
    try std.testing.expectEqualStrings("header\nneedle\nseparator\nchanged\n", try f.tmp.dir.readFileAlloc(io, "a.txt", alloc, .unlimited));

    try f.tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "call - x;\nseparator\ncall - x;\n" });
    const normalized = try f.call(run, "{{\"path\":\"b.txt\",\"old_string\":\"call \u{2013} x;\",\"new_string\":\"changed();\",\"target_line\":3}}", .{});
    try std.testing.expect(normalized == .text);
    try std.testing.expectEqualStrings("call - x;\nseparator\nchanged();\n", try f.tmp.dir.readFileAlloc(io, "b.txt", alloc, .unlimited));

    try f.tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "needle\nseparator\nneedle\n" });
    const miss = try f.call(run, "{{\"path\":\"c.txt\",\"old_string\":\"needle\",\"new_string\":\"changed\",\"target_line\":2}}", .{});
    try std.testing.expect(std.mem.indexOf(u8, miss.failed, "does not contain an exact old_string") != null);
    try std.testing.expectEqualStrings("needle\nseparator\nneedle\n", try f.tmp.dir.readFileAlloc(io, "c.txt", alloc, .unlimited));

    try f.tmp.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "needle\nneedle\n" });
    const both = try f.call(run, "{{\"path\":\"d.txt\",\"old_string\":\"needle\",\"new_string\":\"changed\",\"target_line\":1,\"replace_all\":true}}", .{});
    try std.testing.expectEqualStrings("target_line cannot be combined with replace_all=true", both.failed);
    try std.testing.expectEqualStrings("needle\nneedle\n", try f.tmp.dir.readFileAlloc(io, "d.txt", alloc, .unlimited));
}

test "edit: an ambiguous exact match reports the count and the occurrences; replace_all takes them all" {
    const f = try TestFixture.init("s-edit-many");
    defer f.deinit();
    const io = std.testing.io;
    const alloc = f.arena.allocator();

    try f.tmp.dir.writeFile(io, .{ .sub_path = "m.txt", .data = "a x\nb\na x\n" });
    const many = try f.call(run, "{{\"path\":\"m.txt\",\"old_string\":\"a x\",\"new_string\":\"a y\"}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, many.failed, "old_string appears 2 times; add surrounding context to make it unique, pass target_line from one occurrence below, or set replace_all=true.\nOccurrences:\n"));
    try std.testing.expect(std.mem.indexOf(u8, many.failed, "candidate 2 (line 3):") != null);
    try std.testing.expectEqualStrings("a x\nb\na x\n", try f.tmp.dir.readFileAlloc(io, "m.txt", alloc, .unlimited));

    const all = try f.call(run, "{{\"path\":\"m.txt\",\"old_string\":\"a x\",\"new_string\":\"a y\",\"replace_all\":true}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, all.text, "edited m.txt (2 replacements). Result:\n"));
    try std.testing.expectEqualStrings("a y\nb\na y\n", try f.tmp.dir.readFileAlloc(io, "m.txt", alloc, .unlimited));
}

test "edit: the result snippet is anchored at the replacement, not at a lookalike earlier in the file" {
    const f = try TestFixture.init("s-edit-snippet");
    defer f.deinit();
    const io = std.testing.io;
    const alloc = f.arena.allocator();

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(alloc, "target\n");
    var i: usize = 1;
    while (i <= 200) : (i += 1) try body.print(alloc, "line {d}\n", .{i});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "many.rs", .data = body.items });

    const out = try f.call(run, "{{\"path\":\"many.rs\",\"old_string\":\"line 150\",\"new_string\":\"target\"}}", .{});
    try std.testing.expect(out == .text);
    // Anchored at line 151 (the file's line 1 is "target"), not at line 1.
    try std.testing.expect(std.mem.indexOf(u8, out.text, "   151\ttarget") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "   148\tline 147") != null);
}

test "edit: the snippet is recorded as a read of only the shown lines, never the whole file" {
    const f = try TestFixture.init("s-edit-fresh");
    defer f.deinit();
    const io = std.testing.io;
    const alloc = f.arena.allocator();

    var body: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i <= 300) : (i += 1) try body.print(alloc, "line {d}\n", .{i});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "many.txt", .data = body.items });

    const edited = try f.call(run, "{{\"path\":\"many.txt\",\"old_string\":\"line 1\\n\",\"new_string\":\"changed 1\\n\"}}", .{});
    try std.testing.expect(edited == .text);

    const unseen = try f.call(read.run, "{{\"path\":\"many.txt\",\"offset\":200,\"limit\":120}}", .{});
    try std.testing.expect(std.mem.indexOf(u8, unseen.text, "line 200") != null);
    try std.testing.expect(!std.mem.startsWith(u8, unseen.text, "unchanged:"));

    const repeated = try f.call(read.run, "{{\"path\":\"many.txt\",\"offset\":200,\"limit\":120}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, repeated.text, "unchanged:"));
}

test "edit: our own edit keeps the write gate open — no re-read demanded for a file we just changed" {
    const f = try TestFixture.init("s-edit-gate");
    defer f.deinit();
    const io = std.testing.io;
    const alloc = f.arena.allocator();

    try f.tmp.dir.writeFile(io, .{ .sub_path = "g.txt", .data = "one\ntwo\n" });
    _ = try f.call(read.run, "{{\"path\":\"g.txt\"}}", .{});
    const edited = try f.call(run, "{{\"path\":\"g.txt\",\"old_string\":\"two\",\"new_string\":\"deux\"}}", .{});
    try std.testing.expectEqualStrings("edited g.txt (1 replacement). Result:\n     1\tone\n     2\tdeux\n", edited.text);
    // The kernel's edit did not report here; this one does, so `write` sees the
    // current version as seen in full and passes.
    const overwritten = try f.call(write.run, "{{\"path\":\"g.txt\",\"content\":\"fresh\\n\"}}", .{});
    try std.testing.expectEqualStrings("wrote g.txt (1 lines)", overwritten.text);
    try std.testing.expectEqualStrings("fresh\n", try f.tmp.dir.readFileAlloc(io, "g.txt", alloc, .unlimited));
}

test "edit: without a session there is no freshness note and the edit still happens" {
    const f = try TestFixture.init(null);
    defer f.deinit();
    const io = std.testing.io;
    const alloc = f.arena.allocator();

    try f.tmp.dir.writeFile(io, .{ .sub_path = "n.txt", .data = "alpha\n" });
    const ok = try f.call(run, "{{\"path\":\"n.txt\",\"old_string\":\"alpha\",\"new_string\":\"beta\"}}", .{});
    try std.testing.expectEqualStrings("edited n.txt (1 replacement). Result:\n     1\tbeta\n", ok.text);
    try std.testing.expectEqualStrings("beta\n", try f.tmp.dir.readFileAlloc(io, "n.txt", alloc, .unlimited));

    const missing = try f.call(run, "{{\"path\":\"n.txt\",\"old_string\":\"gamma\",\"new_string\":\"x\"}}", .{});
    // No record exists, so the tool must not claim the file was never read.
    try std.testing.expect(std.mem.indexOf(u8, missing.failed, "you have not read the current version") == null);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, ".nulya", .{}));
}

test "edit: in a session an unread file's failed match adds the read-it note" {
    const f = try TestFixture.init("s-edit-note");
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "u.txt", .data = "alpha\n" });
    const missing = try f.call(run, "{{\"path\":\"u.txt\",\"old_string\":\"gamma\",\"new_string\":\"x\"}}", .{});
    try std.testing.expect(std.mem.endsWith(u8, missing.failed, "\nnote: you have not read the current version of this file; read it to get the exact text."));
}

test "edit: a missing file gets the directory listing, and bad argument types are named" {
    const f = try TestFixture.init("s-edit-args");
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "here.txt", .data = "x\n" });

    const gone = try f.call(run, "{{\"path\":\"nope.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, gone.failed, "File not found: "));
    try std.testing.expect(std.mem.indexOf(u8, gone.failed, "here.txt") != null);

    const no_old = try f.call(run, "{{\"path\":\"here.txt\",\"new_string\":\"b\"}}", .{});
    try std.testing.expectEqualStrings("missing required parameter: old_string", no_old.failed);

    const bad_line = try f.call(run, "{{\"path\":\"here.txt\",\"old_string\":\"a\",\"new_string\":\"b\",\"target_line\":0}}", .{});
    try std.testing.expectEqualStrings("target_line must be a positive 1-based line number", bad_line.failed);

    const bad_all = try f.call(run, "{{\"path\":\"here.txt\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":\"yes\"}}", .{});
    try std.testing.expectEqualStrings("replace_all must be a boolean", bad_all.failed);
}

test "edit: an executable file keeps its permission bits" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const f = try TestFixture.init(null);
    defer f.deinit();
    const io = std.testing.io;

    try f.tmp.dir.writeFile(io, .{ .sub_path = "script.sh", .data = "echo old\n" });
    try f.tmp.dir.setFilePermissions(io, "script.sh", .executable_file, .{});
    var before_file = try f.tmp.dir.openFile(io, "script.sh", .{});
    const before = (try before_file.stat(io)).permissions;
    before_file.close(io);

    const ok = try f.call(run, "{{\"path\":\"script.sh\",\"old_string\":\"old\",\"new_string\":\"new\"}}", .{});
    try std.testing.expect(ok == .text);

    var after_file = try f.tmp.dir.openFile(io, "script.sh", .{});
    defer after_file.close(io);
    try std.testing.expectEqual(before, (try after_file.stat(io)).permissions);
}
