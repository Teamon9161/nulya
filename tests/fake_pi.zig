//! A `pi --mode rpc` that answers the protocol and never leaves this machine.
//!
//! **Why this exists.** The Pi runner (`extensions/agent/src/pi.zig`) is a
//! conversation with another harness over its stdio: which flags it passes,
//! when it writes a prompt, that the interrupt marker becomes `abort`, and that
//! a tool outside a read-only ceiling stops the run — all on THIS side of that
//! conversation, needing no real model.
//!
//! **What it answers.** `--version` prints one line and exits. Otherwise it reads
//! stdin as newline-delimited JSON and, for each `{"type":"prompt"}`, emits the
//! command response, an optional `tool_execution_start`, a `message_end` carrying
//! an assistant message that QUOTES what it was given (so a test can tell which
//! message produced which report), and `agent_settled`.
//!
//! **It never reads while a run is going**, the same choice `tests/fake_codex.zig`
//! and `tests/fake_claude.zig` made: watching stdin mid-run needs a thread or a
//! non-blocking read to avoid deadlocking against a client itself blocked
//! reading. The evidence a test needs is the log — the argv at launch and one
//! line per message stdin carried, mid-run ones as soon as the run is over.
//!
//! **How a test bends it**, through the environment:
//!
//!   `FAKE_PI_LOG`   a file to append to: the argv once per launch, then one line
//!                   per message read from stdin.
//!   `FAKE_PI_TOOL`  a tool name to announce with `tool_execution_start` before
//!                   answering. The lever for D10's check: name a writing tool and
//!                   a read-only delegation must stop the run and refuse.
//!   `FAKE_PI_HOLD`  a path whose EXISTENCE holds the first run open: while it is
//!                   there the run emits events and does not settle, which is what
//!                   gives a test a run in flight to interrupt.

const std = @import("std");

/// How long one held run may last whatever anybody does, so a test that forgets
/// to release it fails rather than hangs.
const max_hold_ticks: u32 = 3000; // 60s at 20ms

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    const env = init.environ_map;

    const argv = try init.minimal.args.toSlice(alloc);
    var state: State = .{
        .alloc = alloc,
        .io = io,
        .log = env.get("FAKE_PI_LOG"),
        .tool = env.get("FAKE_PI_TOOL"),
        .hold = env.get("FAKE_PI_HOLD"),
    };
    try state.note(try joinArgv(alloc, argv));

    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(io, "0.0.0-fake\n");
            return;
        }
    }

    var in_buf: [1 << 16]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch break orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch continue;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const kind = stringOf(obj, "type") orelse continue;
        try state.note(kind);
        // An abort read here arrived while the run it meant to stop was going;
        // there is nothing left to stop, and the log is the evidence.
        if (!std.mem.eql(u8, kind, "prompt")) continue;
        try state.runPrompt(stringOf(obj, "message") orelse "");
    }
}

const State = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    log: ?[]const u8,
    tool: ?[]const u8,
    hold: ?[]const u8,
    runs: u32 = 0,

    fn runPrompt(self: *State, heard: []const u8) !void {
        self.runs += 1;
        try self.line("{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}");
        try self.line("{\"type\":\"agent_start\"}");

        // Held only while the file is there, and only for the first run: the
        // round that takes up an interrupted message must not be held as well.
        if (self.runs == 1) {
            if (self.hold) |path| {
                var ticks: u32 = 0;
                while (ticks < max_hold_ticks) : (ticks += 1) {
                    std.Io.Dir.cwd().access(self.io, path, .{}) catch break;
                    // Something on the wire every tick, because the runner polls
                    // the interrupt marker BETWEEN the lines it reads.
                    try self.line("{\"type\":\"turn_start\"}");
                    self.io.sleep(.fromMilliseconds(20), .awake) catch {};
                }
            }
        }

        if (self.tool) |name| {
            try self.line(try std.fmt.allocPrint(
                self.alloc,
                "{{\"type\":\"tool_execution_start\",\"toolCallId\":\"c1\",\"toolName\":{f},\"args\":{{}}}}",
                .{std.json.fmt(name, .{})},
            ));
        }

        try self.line(try std.fmt.allocPrint(
            self.alloc,
            "{{\"type\":\"message_end\",\"message\":{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":{f}}}]}}}}",
            .{std.json.fmt(try std.fmt.allocPrint(self.alloc, "heard: {s}", .{heard}), .{})},
        ));
        try self.line("{\"type\":\"agent_end\",\"messages\":[],\"willRetry\":false}");
        try self.line("{\"type\":\"agent_settled\"}");
    }

    fn line(self: *State, body: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(self.io, body);
        try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
    }

    fn note(self: *State, what: []const u8) !void {
        const path = self.log orelse return;
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false, .read = true }) catch return;
        defer file.close(self.io);
        const size = (file.stat(self.io) catch return).size;
        const body = try std.fmt.allocPrint(self.alloc, "{s}\n", .{what});
        file.writePositionalAll(self.io, body, size) catch return;
    }
};

fn joinArgv(alloc: std.mem.Allocator, argv: []const [:0]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (argv, 0..) |arg, i| {
        if (i != 0) try out.writer.writeAll(" ");
        try out.writer.writeAll(arg);
    }
    return out.writer.buffered();
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
