//! The single output-discipline primitive.
//!
//! Every tool's output — shell, edit echo, and any future native tool — passes
//! through `emit`. There is exactly ONE truncation/spill code path in the whole
//! kernel, so the "dirty details" (line clipping, byte budget, head+tail
//! retention, auto-spill) are concentrated in one testable function instead of
//! being re-implemented per tool.
//!
//! Guarantees:
//!   1. per-line clip     — no single line blows up a result
//!   2. byte budget       — returned text is bounded by `max_bytes`
//!   3. auto-spill        — the full raw output is ALWAYS written to the
//!                          WORKSPACE when anything was truncated, and the
//!                          model-visible text contains the spill path. Both
//!                          halves matter: the path is workspace-relative and
//!                          the bytes go through `FileSink`, so in a session
//!                          whose workspace lives on another machine the file
//!                          lands where the reader's hands are, not where the
//!                          harness happens to run.
//!   4. determinism       — spill filename derives from `seq`, never a runtime
//!                          counter, so a replayed ledger reproduces byte-for-byte
//!   5. valid UTF-8       — the returned text is valid UTF-8 whatever the tool
//!                          wrote, because the ledger's strings have to be
//!                          (`utf8Lossy`)

const std = @import("std");

/// Where a spill's bytes go. `emit` writes no files itself: it hands the
/// workspace-relative path and the bytes to the session's environment
/// (`Environment.putWorkspaceFile`), which is the thing that knows which
/// machine the workspace is on. The interface lives here rather than in
/// `environment.zig` because `emit` must stay importable by everything and
/// know nothing about processes — and there is no adapter between the two:
/// this IS the shape of a vtable entry, so `Environment.fileSink()` just hands
/// over the pointer and that function.
pub const FileSink = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, rel_path: []const u8, bytes: []const u8) anyerror!void,

    /// Write `bytes` at `rel_path`, creating parents. Implementations own that
    /// promise — `emit` never creates a directory of its own.
    pub fn write(self: FileSink, rel_path: []const u8, bytes: []const u8) anyerror!void {
        return self.writeFn(self.ptr, rel_path, bytes);
    }
};

pub const OutputBudget = struct {
    /// Hard byte ceiling for a single tool result entering context.
    max_bytes: usize = 128 * 1024,
    /// Per-line byte ceiling. Deliberately huge: prose/config/markdown are
    /// legitimately long; a low cap mis-fires and costs the model a round-trip.
    max_line_bytes: usize = 16384,
    /// Percentage of the body budget reserved for the head on byte overflow.
    head_percent: u8 = 25,
    /// Percentage of the body budget reserved for the tail on byte overflow.
    tail_percent: u8 = 75,
};

pub const StepOutputBudget = struct {
    /// Hard byte ceiling for all tool result text returned by one model step.
    max_bytes: usize = 128 * 1024,
};

pub const Emitted = struct {
    /// Owned text to return to the model.
    text: []const u8,
    /// Owned path to the full raw output, if it was spilled.
    spill_path: ?[]const u8,

    pub fn deinit(self: Emitted, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        if (self.spill_path) |p| alloc.free(p);
    }
};

/// Pass `raw` through the output discipline. `tool`, `event_seq`, and
/// `call_index` name the spill file; `scratch_dir` is where it lands; `sink`
/// performs the spill write, wherever this session's workspace is.
pub fn emit(
    alloc: std.mem.Allocator,
    sink: FileSink,
    raw: []const u8,
    tool: []const u8,
    event_seq: u64,
    call_index: usize,
    scratch_dir: []const u8,
    budget: OutputBudget,
) !Emitted {
    var truncated = false;

    // Replacing bytes is a loss like a clip, so it forces the spill too.
    const clean = try utf8Lossy(alloc, raw);
    defer if (clean) |c| alloc.free(c.text);
    if (clean != null) truncated = true;
    const body = if (clean) |c| c.text else raw;

    var clipped: std.ArrayList(u8) = .empty;
    defer clipped.deinit(alloc);
    if (clean) |c| try clipped.print(alloc, invalid_utf8_note, .{c.replaced});
    try clipLongLines(alloc, body, budget.max_line_bytes, &clipped, &truncated);

    if (clipped.items.len > budget.max_bytes) truncated = true;

    var spill_path: ?[]const u8 = null;
    if (truncated) spill_path = try writeSpill(alloc, sink, raw, tool, event_seq, call_index, scratch_dir);
    errdefer if (spill_path) |p| alloc.free(p);

    var final_text: std.ArrayList(u8) = .empty;
    errdefer final_text.deinit(alloc);

    if (spill_path) |path| {
        const footer = try std.fmt.allocPrint(alloc, "\n[full output: {s}]", .{path});
        defer alloc.free(footer);
        const body_budget = budget.max_bytes -| footer.len;

        if (footer.len >= budget.max_bytes) {
            try final_text.appendSlice(alloc, validUtf8Prefix(footer, budget.max_bytes));
        } else {
            if (clipped.items.len > body_budget) {
                try appendHeadTail(alloc, &final_text, clipped.items, body_budget, budget);
            } else {
                try final_text.appendSlice(alloc, clipped.items);
            }
            try final_text.appendSlice(alloc, footer);
        }
    } else {
        try final_text.appendSlice(alloc, clipped.items);
    }

    std.debug.assert(final_text.items.len <= budget.max_bytes);
    return .{
        .text = try final_text.toOwnedSlice(alloc),
        .spill_path = spill_path,
    };
}

/// A header, not a footer: survives head+tail elision, stays clear of `[exit N]`.
const invalid_utf8_note = "[note: {d} byte(s) of this output were not valid UTF-8 and were replaced with \u{FFFD}]\n";

pub const Lossy = struct {
    /// Owned, valid UTF-8.
    text: []u8,
    /// Input bytes replaced, one U+FFFD each.
    replaced: usize,
};

/// `raw` as valid UTF-8, or null when it already is (no copy). Caller owns `text`.
///
/// Why it has to happen: `std.json.Stringify` writes a `[]const u8` that is not
/// valid UTF-8 as an ARRAY OF NUMBERS, so one stray byte from a subprocess
/// changes the shape of the session file and of every request built from it.
pub fn utf8Lossy(alloc: std.mem.Allocator, raw: []const u8) !?Lossy {
    if (std.unicode.utf8ValidateSlice(raw)) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, raw.len);

    var replaced: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const good: usize = blk: {
            const len = std.unicode.utf8ByteSequenceLength(raw[i]) catch break :blk 0;
            if (i + len > raw.len) break :blk 0;
            _ = std.unicode.utf8Decode(raw[i..][0..len]) catch break :blk 0;
            break :blk len;
        };
        if (good > 0) {
            try out.appendSlice(alloc, raw[i..][0..good]);
            i += good;
            continue;
        }
        try out.appendSlice(alloc, "\u{FFFD}");
        replaced += 1;
        i += 1;
    }
    return .{ .text = try out.toOwnedSlice(alloc), .replaced = replaced };
}

/// The head+tail discipline on its own, without the spill: `body` trimmed to
/// `budget.max_bytes` by keeping a head and a tail around the same self-
/// describing elision marker `emit` uses, on UTF-8 (and where it can, line)
/// boundaries. Caller owns the result.
///
/// The second consumer of that discipline (`emit` is the first): a background
/// task's report quotes the tail of a log that is ALREADY the complete bytes on
/// disk, so it needs the trimming and must not spill a second copy. Everything
/// the two share stays in one implementation here.
pub fn headTail(alloc: std.mem.Allocator, body: []const u8, budget: OutputBudget) ![]u8 {
    if (body.len <= budget.max_bytes) return alloc.dupe(u8, body);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendHeadTail(alloc, &out, body, budget.max_bytes, budget);
    std.debug.assert(out.items.len <= budget.max_bytes);
    return out.toOwnedSlice(alloc);
}

fn clipLongLines(
    alloc: std.mem.Allocator,
    raw: []const u8,
    max_line_bytes: usize,
    out: *std.ArrayList(u8),
    truncated: *bool,
) !void {
    var it = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(alloc, '\n');
        first = false;

        if (line.len > max_line_bytes) {
            truncated.* = true;
            const end = validUtf8PrefixLen(line, max_line_bytes);
            try out.appendSlice(alloc, line[0..end]);
            try out.print(alloc, "\u{2026}[+{d} bytes]", .{line.len - end});
        } else {
            try out.appendSlice(alloc, line);
        }
    }
}

fn appendHeadTail(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: []const u8,
    body_budget: usize,
    budget: OutputBudget,
) !void {
    if (body_budget == 0) return;

    const marker = "\n[\u{2026} output elided; use full output path below \u{2026}]\n";
    if (marker.len >= body_budget) {
        try out.appendSlice(alloc, validUtf8Prefix(marker, body_budget));
        return;
    }

    const keep_budget = body_budget - marker.len;
    const total_percent = @as(usize, budget.head_percent) + @as(usize, budget.tail_percent);
    const head_budget = if (total_percent == 0) keep_budget / 4 else keep_budget * @as(usize, budget.head_percent) / total_percent;
    const tail_budget = keep_budget - head_budget;

    const head = takeHeadBytes(body, head_budget);
    const tail = takeTailBytes(body, tail_budget);

    try out.appendSlice(alloc, head);
    try out.appendSlice(alloc, marker);
    try out.appendSlice(alloc, tail);
}

fn spillName(alloc: std.mem.Allocator, tool: []const u8, event_seq: u64, call_index: usize) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}-{d}-{d}.txt", .{ tool, event_seq, call_index });
}

/// Join the parts of a workspace-relative path the MODEL will read — a spill
/// footer, a background task's log — with `/` on every OS, never the native
/// separator. Two reasons, both about the reader rather than the file system
/// (which accepts `/` on Windows just the same): a
/// backslash path pasted into a bash command is mangled the moment it is read
/// (`\t` is a tab), and every other relative path the harness shows is already
/// spelled with `/` (`.nulya/sessions/…`, `.nulya/handoffs/…`) — one spelling,
/// so the same place is never written two ways in one transcript. Callers pass
/// parts without separators of their own; this does no normalisation.
pub fn joinRel(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.join(alloc, "/", parts);
}

pub const StepOutputLimiter = struct {
    sink: FileSink,
    scratch_dir: []const u8,
    event_seq: u64,
    budget: StepOutputBudget,
    used: usize = 0,

    pub fn init(sink: FileSink, scratch_dir: []const u8, event_seq: u64, budget: StepOutputBudget) StepOutputLimiter {
        return .{
            .sink = sink,
            .scratch_dir = scratch_dir,
            .event_seq = event_seq,
            .budget = budget,
        };
    }

    /// Charge one result against the step budget, in batch order. The budget
    /// bounds result BODIES; it never decides which results the model gets to
    /// see — a batch's most important error may be its last. A result that no
    /// longer fits keeps, whichever is smaller, its own text verbatim or a head
    /// prefix ending in a COMPLETE pointer to the full bytes on disk. The
    /// footer is the per-result floor and is not charged to the budget, so one
    /// step's visible tool text is bounded by `max_bytes` plus at most one
    /// footer per call.
    pub fn apply(
        self: *StepOutputLimiter,
        alloc: std.mem.Allocator,
        tool_name: []const u8,
        call_index: usize,
        output: *[]const u8,
        spill_path: *?[]const u8,
    ) !void {
        const remaining = self.budget.max_bytes -| self.used;
        if (output.*.len <= remaining) {
            self.used += output.*.len;
            return;
        }

        // Point the footer at the per-call spill when `emit` already wrote one
        // (it holds the raw bytes); otherwise at a step spill written below.
        var path_owned = spill_path.* == null;
        const path = spill_path.* orelse try stepSpillPath(alloc, self.scratch_dir, tool_name, self.event_seq, call_index);
        errdefer if (path_owned) alloc.free(path);
        const footer = try std.fmt.allocPrint(alloc, "\n[tool result clipped by step output budget; full output: {s}]", .{path});
        defer alloc.free(footer);

        // A replacement must never cost more than what it replaces: a result
        // no longer than its would-be prefix+footer stays verbatim — same
        // bound, nothing hidden behind an indirection, no spill file.
        if (output.*.len <= remaining + footer.len) {
            if (path_owned) alloc.free(path);
            self.used += output.*.len;
            return;
        }

        if (path_owned) {
            try self.sink.write(path, output.*);
            spill_path.* = path;
            path_owned = false;
        }

        const prefix = validUtf8Prefix(output.*, remaining);
        const replacement = try alloc.alloc(u8, prefix.len + footer.len);
        @memcpy(replacement[0..prefix.len], prefix);
        @memcpy(replacement[prefix.len..], footer);
        alloc.free(output.*);
        output.* = replacement;
        self.used += prefix.len;
    }
};

/// Deterministic step-spill location, mirroring `spillName`'s scheme:
/// `<scratch>/tool-output/step-<tool>-<seq>-<index>.txt`. Caller owns the path.
fn stepSpillPath(
    alloc: std.mem.Allocator,
    scratch_dir: []const u8,
    tool_name: []const u8,
    event_seq: u64,
    call_index: usize,
) ![]const u8 {
    const name = try std.fmt.allocPrint(alloc, "step-{s}-{d}-{d}.txt", .{ tool_name, event_seq, call_index });
    defer alloc.free(name);
    return joinRel(alloc, &.{ scratch_dir, "tool-output", name });
}

fn writeSpill(
    alloc: std.mem.Allocator,
    sink: FileSink,
    raw: []const u8,
    tool: []const u8,
    event_seq: u64,
    call_index: usize,
    scratch_dir: []const u8,
) ![]const u8 {
    const dir = try joinRel(alloc, &.{ scratch_dir, "tool-output" });
    defer alloc.free(dir);
    const name = try spillName(alloc, tool, event_seq, call_index);
    defer alloc.free(name);
    const path = try joinRel(alloc, &.{ dir, name });
    errdefer alloc.free(path);
    try sink.write(path, raw);
    return path;
}

fn takeHeadBytes(s: []const u8, budget: usize) []const u8 {
    if (budget >= s.len) return s;
    const limit = validUtf8PrefixLen(s, budget);
    if (limit == 0) return s[0..0];
    if (std.mem.lastIndexOfScalar(u8, s[0..limit], '\n')) |idx| {
        if (idx >= limit / 2) return s[0..idx];
    }
    return s[0..limit];
}

fn takeTailBytes(s: []const u8, budget: usize) []const u8 {
    if (budget >= s.len) return s;
    var start = s.len - budget;
    while (start < s.len and isUtf8Continuation(s[start])) start += 1;
    if (start >= s.len) return s[s.len..];

    if (std.mem.indexOfScalar(u8, s[start..], '\n')) |idx| {
        if (idx <= budget / 2 and start + idx + 1 <= s.len) return s[start + idx + 1 ..];
    }
    return s[start..];
}

fn validUtf8Prefix(s: []const u8, max_len: usize) []const u8 {
    return s[0..validUtf8PrefixLen(s, max_len)];
}

fn validUtf8PrefixLen(s: []const u8, max_len: usize) usize {
    var end = @min(s.len, max_len);
    while (end > 0 and end < s.len and isUtf8Continuation(s[end])) end -= 1;
    return end;
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
}

// ── tests ───────────────────────────────────────────────────────────────────

/// A sink that keeps what it was handed instead of writing it. Every test here
/// wants the same two answers — WHICH path was spilled to and WHAT bytes went
/// there — and asking a file system for them would put a second "bytes become a
/// file" implementation in the repository, which is the one thing `FileSink`
/// exists to prevent.
const RecordingSink = struct {
    alloc: std.mem.Allocator,
    path: ?[]u8 = null,
    data: ?[]u8 = null,

    fn writeImpl(ptr: *anyopaque, rel_path: []const u8, bytes: []const u8) anyerror!void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.path = try self.alloc.dupe(u8, rel_path);
        self.data = try self.alloc.dupe(u8, bytes);
    }

    fn sink(self: *RecordingSink) FileSink {
        return .{ .ptr = self, .writeFn = writeImpl };
    }

    fn deinit(self: *RecordingSink) void {
        if (self.path) |p| self.alloc.free(p);
        if (self.data) |d| self.alloc.free(d);
        self.path = null;
        self.data = null;
    }
};

test "emit passes small output through untouched, no spill" {
    const alloc = std.testing.allocator;
    var rec: RecordingSink = .{ .alloc = alloc };
    defer rec.deinit();
    const out = try emit(alloc, rec.sink(), "hello\nworld\n", "shell", 1, 0, ".", .{});
    defer out.deinit(alloc);
    try std.testing.expectEqualStrings("hello\nworld\n", out.text);
    try std.testing.expect(out.spill_path == null);
    try std.testing.expect(rec.path == null);
}

test "emit clips an over-long line with a self-describing marker and footer" {
    const alloc = std.testing.allocator;
    var rec: RecordingSink = .{ .alloc = alloc };
    defer rec.deinit();
    const long = "x" ** 40;
    const out = try emit(alloc, rec.sink(), long, "shell", 2, 0, ".", .{ .max_line_bytes = 10 });
    defer out.deinit(alloc);
    // The path the model reads is spelled with `/` on every OS (`joinRel`): a
    // relative scratch dir yields no native separator anywhere in it.
    try std.testing.expectEqualStrings("./tool-output/shell-2-0.txt", out.spill_path.?);
    try std.testing.expect(std.mem.startsWith(u8, out.text, "xxxxxxxxxx\u{2026}[+30 bytes]"));
    try std.testing.expect(std.mem.indexOf(u8, out.text, "[full output: ") != null);
    // The footer's path and the sink's destination are ONE string: that is the
    // whole promise of guarantee 3, and what makes it survive a workspace that
    // lives on another machine.
    try std.testing.expectEqualStrings(out.spill_path.?, rec.path.?);
}

test "emit keeps hard byte budget on whole-output truncation" {
    const alloc = std.testing.allocator;
    var rec: RecordingSink = .{ .alloc = alloc };
    defer rec.deinit();
    const raw = ("0123456789abcdef\n" ** 40);
    const out = try emit(alloc, rec.sink(), raw, "shell", 3, 0, ".", .{ .max_bytes = 160 });
    defer out.deinit(alloc);
    try std.testing.expect(out.text.len <= 160);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "[full output: ") != null);
    try std.testing.expect(out.spill_path != null);
}

test "emit does not split utf-8 while clipping a line" {
    const alloc = std.testing.allocator;
    var rec: RecordingSink = .{ .alloc = alloc };
    defer rec.deinit();
    const out = try emit(alloc, rec.sink(), "你好世界", "shell", 4, 0, ".", .{ .max_line_bytes = 5 });
    defer out.deinit(alloc);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.text));
    try std.testing.expect(std.mem.startsWith(u8, out.text, "你"));
}

test "utf8Lossy leaves valid input alone and repairs the rest byte for byte" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try utf8Lossy(alloc, "plain ascii and 你好") == null);

    // The shape that motivated this: a CP936 console banner.
    const gbk = "Microsoft Windows [\xb0\xe6\xb1\xbe 10.0.26200]\n";
    const fixed = (try utf8Lossy(alloc, gbk)).?;
    defer alloc.free(fixed.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(fixed.text));
    // GBK and UTF-8 overlap by accident, so the count is not the byte count.
    try std.testing.expect(fixed.replaced > 0);
    try std.testing.expect(std.mem.startsWith(u8, fixed.text, "Microsoft Windows ["));
    try std.testing.expect(std.mem.endsWith(u8, fixed.text, " 10.0.26200]\n"));

    // A character cut in half: the valid prefix survives, the orphans count.
    const torn = (try utf8Lossy(alloc, "ok \xe4\xbd")).?;
    defer alloc.free(torn.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(torn.text));
    try std.testing.expectEqual(@as(usize, 2), torn.replaced);
}

test "emit repairs invalid utf-8, says so, and hands the RAW bytes to the sink" {
    const alloc = std.testing.allocator;
    var rec: RecordingSink = .{ .alloc = alloc };
    defer rec.deinit();
    const raw = "before \xb0\xe6 after\n[exit 0]";
    const out = try emit(alloc, rec.sink(), raw, "shell", 91, 0, ".", .{});
    defer out.deinit(alloc);

    try std.testing.expect(std.unicode.utf8ValidateSlice(out.text));
    try std.testing.expect(std.mem.indexOf(u8, out.text, "not valid UTF-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "[exit 0]\n[full output: ") != null);

    // What the model reads was repaired; what was kept is the original, down to
    // the bytes that could not be shown.
    try std.testing.expectEqualStrings(raw, rec.data.?);
    try std.testing.expectEqualStrings(out.spill_path.?, rec.path.?);
}

test "step output limiter clips an oversized aggregate result and spills it" {
    const alloc = std.testing.allocator;
    var rec: RecordingSink = .{ .alloc = alloc };
    defer rec.deinit();
    const long = "x" ** 600;
    var output: []const u8 = try alloc.dupe(u8, long);
    var spill_path: ?[]const u8 = null;
    defer {
        alloc.free(output);
        if (spill_path) |p| alloc.free(p);
    }

    var limiter = StepOutputLimiter.init(rec.sink(), ".", 7, .{ .max_bytes = 160 });
    try limiter.apply(alloc, "shell", 2, &output, &spill_path);

    // The body is clipped to the budget; the pointer footer rides on top of it
    // (the floor is not charged), always complete, never truncated.
    try std.testing.expect(std.mem.startsWith(u8, output, "x" ** 160));
    try std.testing.expect(!std.mem.startsWith(u8, output, "x" ** 161));
    try std.testing.expect(std.mem.indexOf(u8, output, "clipped by step output budget; full output: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "]"));
    try std.testing.expectEqual(@as(usize, 160), limiter.used);
    try std.testing.expectEqualStrings(spill_path.?, rec.path.?);
    // The whole result is kept, not the prefix the model was shown.
    try std.testing.expectEqualStrings(long, rec.data.?);
}

test "step budget exhaustion never blanks a later result: the pointer floor survives" {
    const alloc = std.testing.allocator;
    var rec: RecordingSink = .{ .alloc = alloc };
    defer rec.deinit();

    var limiter = StepOutputLimiter.init(rec.sink(), ".", 9, .{ .max_bytes = 8 });

    var first: []const u8 = try alloc.dupe(u8, "aaaaaaaa"); // exactly the budget
    defer alloc.free(first);
    var first_spill: ?[]const u8 = null;
    try limiter.apply(alloc, "shell", 0, &first, &first_spill);
    try std.testing.expectEqualStrings("aaaaaaaa", first);
    try std.testing.expect(first_spill == null);

    // The second result finds the budget spent. Before the floor existed it
    // became the empty string — order decided what the model got to see.
    var second: []const u8 = try alloc.dupe(u8, "e" ** 600);
    var second_spill: ?[]const u8 = null;
    defer {
        alloc.free(second);
        if (second_spill) |p| alloc.free(p);
    }
    try limiter.apply(alloc, "shell", 1, &second, &second_spill);

    try std.testing.expect(second.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, second, "clipped by step output budget; full output: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, second, "]"));
    try std.testing.expect(second_spill != null);
}

test "a short result over the spent budget stays verbatim instead of becoming a longer pointer" {
    const alloc = std.testing.allocator;
    var rec: RecordingSink = .{ .alloc = alloc };
    defer rec.deinit();

    var limiter = StepOutputLimiter.init(rec.sink(), ".", 9, .{ .max_bytes = 8 });

    var first: []const u8 = try alloc.dupe(u8, "aaaaaaaa");
    defer alloc.free(first);
    var first_spill: ?[]const u8 = null;
    try limiter.apply(alloc, "shell", 0, &first, &first_spill);

    // Shorter than the footer that would replace it: keeping the real status
    // line beats pointing at a file holding the same eleven bytes.
    var second: []const u8 = try alloc.dupe(u8, "ok [exit 0]");
    defer alloc.free(second);
    var second_spill: ?[]const u8 = null;
    try limiter.apply(alloc, "shell", 1, &second, &second_spill);

    try std.testing.expectEqualStrings("ok [exit 0]", second);
    try std.testing.expect(second_spill == null);
    // Nothing was written for it, either.
    try std.testing.expect(rec.path == null);
}
