//! The single output-discipline primitive (base-tools.md §2).
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
//!   3. auto-spill        — the full raw output is ALWAYS written to disk when
//!                          anything was truncated, and the model-visible text
//!                          contains the spill path
//!   4. determinism       — spill filename derives from `seq`, never a runtime
//!                          counter, so a replayed ledger reproduces byte-for-byte

const std = @import("std");

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
    max_bytes: usize = 256 * 1024,
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
/// `call_index` name the spill file; `scratch_dir` is where it lands; `io`
/// performs the spill write.
pub fn emit(
    alloc: std.mem.Allocator,
    io: std.Io,
    raw: []const u8,
    tool: []const u8,
    event_seq: u64,
    call_index: usize,
    scratch_dir: []const u8,
    budget: OutputBudget,
) !Emitted {
    var truncated = false;

    var clipped: std.ArrayList(u8) = .empty;
    defer clipped.deinit(alloc);
    try clipLongLines(alloc, raw, budget.max_line_bytes, &clipped, &truncated);

    if (clipped.items.len > budget.max_bytes) truncated = true;

    var spill_path: ?[]const u8 = null;
    if (truncated) spill_path = try writeSpill(alloc, io, raw, tool, event_seq, call_index, scratch_dir);
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

pub const StepOutputLimiter = struct {
    io: std.Io,
    scratch_dir: []const u8,
    event_seq: u64,
    budget: StepOutputBudget,
    used: usize = 0,

    pub fn init(io: std.Io, scratch_dir: []const u8, event_seq: u64, budget: StepOutputBudget) StepOutputLimiter {
        return .{
            .io = io,
            .scratch_dir = scratch_dir,
            .event_seq = event_seq,
            .budget = budget,
        };
    }

    pub fn apply(
        self: *StepOutputLimiter,
        alloc: std.mem.Allocator,
        tool_name: []const u8,
        call_index: usize,
        output: *[]const u8,
        spill_path: *?[]const u8,
    ) !void {
        const max = self.budget.max_bytes;
        if (self.used >= max) {
            if (spill_path.* == null) spill_path.* = try writeStepSpill(alloc, self.io, output.*, tool_name, self.event_seq, call_index, self.scratch_dir);
            alloc.free(output.*);
            output.* = try alloc.dupe(u8, "");
            return;
        }

        const remaining = max - self.used;
        if (output.*.len <= remaining) {
            self.used += output.*.len;
            return;
        }

        const path = if (spill_path.*) |path| path else blk: {
            const path = try writeStepSpill(alloc, self.io, output.*, tool_name, self.event_seq, call_index, self.scratch_dir);
            spill_path.* = path;
            break :blk path;
        };

        const footer = try std.fmt.allocPrint(alloc, "\n[tool result clipped by step output budget; full output: {s}]", .{path});
        defer alloc.free(footer);

        const replacement = if (footer.len >= remaining) blk: {
            break :blk try alloc.dupe(u8, validUtf8Prefix(footer, remaining));
        } else blk: {
            const prefix = validUtf8Prefix(output.*, remaining - footer.len);
            const out = try alloc.alloc(u8, prefix.len + footer.len);
            @memcpy(out[0..prefix.len], prefix);
            @memcpy(out[prefix.len..], footer);
            break :blk out;
        };

        alloc.free(output.*);
        output.* = replacement;
        self.used = max;
    }
};

fn writeStepSpill(
    alloc: std.mem.Allocator,
    io: std.Io,
    output: []const u8,
    tool_name: []const u8,
    event_seq: u64,
    call_index: usize,
    scratch_dir: []const u8,
) ![]const u8 {
    const dir = try std.fs.path.join(alloc, &.{ scratch_dir, "tool-output" });
    defer alloc.free(dir);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};
    const name = try std.fmt.allocPrint(alloc, "step-{s}-{d}-{d}.txt", .{ tool_name, event_seq, call_index });
    defer alloc.free(name);
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    errdefer alloc.free(path);
    try cwd.writeFile(io, .{ .sub_path = path, .data = output });
    return path;
}

fn writeSpill(
    alloc: std.mem.Allocator,
    io: std.Io,
    raw: []const u8,
    tool: []const u8,
    event_seq: u64,
    call_index: usize,
    scratch_dir: []const u8,
) ![]const u8 {
    const dir = try std.fs.path.join(alloc, &.{ scratch_dir, "tool-output" });
    defer alloc.free(dir);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};
    const name = try spillName(alloc, tool, event_seq, call_index);
    defer alloc.free(name);
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    errdefer alloc.free(path);
    try cwd.writeFile(io, .{ .sub_path = path, .data = raw });
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

test "emit passes small output through untouched, no spill" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const out = try emit(alloc, io, "hello\nworld\n", "shell", 1, 0, ".", .{});
    defer out.deinit(alloc);
    try std.testing.expectEqualStrings("hello\nworld\n", out.text);
    try std.testing.expect(out.spill_path == null);
}

test "emit clips an over-long line with a self-describing marker and footer" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const long = "x" ** 40;
    const out = try emit(alloc, io, long, "shell", 2, 0, ".", .{ .max_line_bytes = 10 });
    defer out.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, out.text, "xxxxxxxxxx\u{2026}[+30 bytes]"));
    try std.testing.expect(std.mem.indexOf(u8, out.text, "[full output: ") != null);
    try std.testing.expect(out.spill_path != null);
    if (out.spill_path) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
}

test "emit keeps hard byte budget on whole-output truncation" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const raw = ("0123456789abcdef\n" ** 40);
    const out = try emit(alloc, io, raw, "shell", 3, 0, ".", .{ .max_bytes = 160 });
    defer out.deinit(alloc);
    try std.testing.expect(out.text.len <= 160);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "[full output: ") != null);
    try std.testing.expect(out.spill_path != null);
    if (out.spill_path) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
}

test "emit does not split utf-8 while clipping a line" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const out = try emit(alloc, io, "你好世界", "shell", 4, 0, ".", .{ .max_line_bytes = 5 });
    defer out.deinit(alloc);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.text));
    try std.testing.expect(std.mem.startsWith(u8, out.text, "你"));
    if (out.spill_path) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
}

test "step output limiter clips an oversized aggregate result and spills it" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const long = "x" ** 300;
    var output: []const u8 = try alloc.dupe(u8, long);
    var spill_path: ?[]const u8 = null;
    defer {
        alloc.free(output);
        if (spill_path) |p| {
            std.Io.Dir.cwd().deleteFile(io, p) catch {};
            alloc.free(p);
        }
    }

    var limiter = StepOutputLimiter.init(io, ".", 7, .{ .max_bytes = 160 });
    try limiter.apply(alloc, "shell", 2, &output, &spill_path);

    try std.testing.expect(output.len <= 160);
    try std.testing.expectEqual(@as(usize, 160), limiter.used);
    try std.testing.expect(spill_path != null);
}
