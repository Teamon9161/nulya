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
//!   2. byte budget       — head+tail kept, middle elided
//!   3. auto-spill        — the full raw output is ALWAYS written to disk when
//!                          anything was truncated, so the model never loses data
//!   4. determinism       — spill filename derives from `seq`, never a runtime
//!                          counter, so a replayed ledger reproduces byte-for-byte

const std = @import("std");

pub const OutputBudget = struct {
    /// Byte ceiling for a single tool result entering context.
    max_bytes: usize = 128 * 1024,
    /// Per-line character ceiling. Deliberately huge: prose/config/markdown are
    /// legitimately long; a low cap mis-fires and costs the model a round-trip.
    max_line_chars: usize = 16384,
    /// Lines kept from the head on byte overflow (command/context lives up top).
    head_lines: usize = 20,
    /// Lines kept from the tail on byte overflow (results/errors live at the end).
    tail_lines: usize = 80,
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

/// Pass `raw` through the output discipline. `tool` and `seq` name the spill
/// file; `scratch_dir` is where it lands; `io` performs the spill write.
pub fn emit(
    alloc: std.mem.Allocator,
    io: std.Io,
    raw: []const u8,
    tool: []const u8,
    seq: u64,
    scratch_dir: []const u8,
    budget: OutputBudget,
) !Emitted {
    var truncated = false;

    // --- Step 1: per-line clipping ---------------------------------------
    var clipped: std.ArrayList(u8) = .empty;
    defer clipped.deinit(alloc);

    var it = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try clipped.append(alloc, '\n');
        first = false;
        if (line.len > budget.max_line_chars) {
            truncated = true;
            try clipped.appendSlice(alloc, line[0..budget.max_line_chars]);
            try clipped.print(alloc, "…[+{d} chars]", .{line.len - budget.max_line_chars});
        } else {
            try clipped.appendSlice(alloc, line);
        }
    }

    // --- Step 2: byte budget (head + tail, middle elided) ----------------
    var body: []const u8 = clipped.items;
    var elided: std.ArrayList(u8) = .empty;
    defer elided.deinit(alloc);

    if (body.len > budget.max_bytes) {
        truncated = true;
        const head = takeHeadLines(body, budget.head_lines);
        const tail = takeTailLines(body, budget.tail_lines);
        try elided.appendSlice(alloc, head);
        try elided.print(alloc, "\n[… {d} bytes elided; full output spilled to {s}/{s} — retrieve with `sed -n` / `rg` …]\n", .{
            body.len - head.len - tail.len,
            scratch_dir,
            try spillName(alloc, tool, seq),
        });
        try elided.appendSlice(alloc, tail);
        body = elided.items;
    }

    // --- Step 3: auto-spill (always, whenever anything was truncated) -----
    var spill_path: ?[]const u8 = null;
    if (truncated) {
        spill_path = try writeSpill(alloc, io, raw, tool, seq, scratch_dir);
    }

    return .{
        .text = try alloc.dupe(u8, body),
        .spill_path = spill_path,
    };
}

fn spillName(alloc: std.mem.Allocator, tool: []const u8, seq: u64) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}-{d}.txt", .{ tool, seq });
}

fn writeSpill(
    alloc: std.mem.Allocator,
    io: std.Io,
    raw: []const u8,
    tool: []const u8,
    seq: u64,
    scratch_dir: []const u8,
) ![]const u8 {
    const dir = try std.fs.path.join(alloc, &.{ scratch_dir, "tool-output" });
    defer alloc.free(dir);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};
    const name = try spillName(alloc, tool, seq);
    defer alloc.free(name);
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    errdefer alloc.free(path);
    try cwd.writeFile(io, .{ .sub_path = path, .data = raw });
    return path;
}

/// Byte slice of the first `n` lines of `s`.
fn takeHeadLines(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\n') {
            count += 1;
            if (count == n) return s[0..i];
        }
    }
    return s;
}

/// Byte slice of the last `n` lines of `s`.
fn takeTailLines(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var i: usize = s.len;
    while (i > 0) : (i -= 1) {
        if (s[i - 1] == '\n') {
            count += 1;
            if (count == n + 1) return s[i..];
        }
    }
    return s;
}

test "emit passes small output through untouched, no spill" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const out = try emit(alloc, io, "hello\nworld\n", "shell", 1, ".", .{});
    defer out.deinit(alloc);
    try std.testing.expectEqualStrings("hello\nworld\n", out.text);
    try std.testing.expect(out.spill_path == null);
}

test "emit clips an over-long line with a self-describing marker" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const long = "x" ** 40;
    const out = try emit(alloc, io, long, "shell", 2, ".", .{ .max_line_chars = 10 });
    defer out.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, out.text, "xxxxxxxxxx…[+30 chars]"));
    try std.testing.expect(out.spill_path != null);
    // clean up the spill file the test produced
    if (out.spill_path) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
}
