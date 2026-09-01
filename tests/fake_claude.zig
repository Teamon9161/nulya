//! A `claude -p` that answers the stream-json protocol and never leaves this
//! machine.
//!
//! **Why this exists.** The Claude runner (`extensions/agent/src/claude.zig`) is
//! a conversation with another harness over its stdio, and everything worth
//! pinning down about it — session naming and resume, messages queued in
//! `<d>/inbox/` until written to stdin, the interrupt marker becoming a
//! `control_request`, a read-only agent refused when the echo comes back wider
//! — is about THIS SIDE of that conversation, needing no real model.
//!
//! **What it answers.** `--version` prints one line and exits. Otherwise it reads
//! stdin as newline-delimited JSON and, for each `{"type":"user"}`, emits one
//! turn: `system/init` (the echo), an `assistant` message QUOTING what it was
//! given (so a test can tell which message produced which report), and `result`.
//!
//! **It never reads while a turn is running, and that is deliberate** — the same
//! choice `tests/fake_codex.zig` made: watching stdin mid-turn needs a thread or
//! a non-blocking read to avoid deadlocking against a client itself blocked
//! reading. What a test needs instead is EVIDENCE that the runner sent the right
//! thing at the right moment, and that is what the log is: the whole command
//! line at launch, and one line per message stdin carried — mid-turn ones as
//! soon as the turn is over. A turn's length is set from outside
//! (`FAKE_CLAUDE_HOLD`), so a test decides when it ends rather than racing it.
//!
//! **How a test bends it**, through the environment, because that is what reaches
//! a process spawned three levels down:
//!
//!   `FAKE_CLAUDE_LOG`   a file to append to: the argv once per launch, then one
//!                       line per message read from stdin.
//!   `FAKE_CLAUDE_TOOLS` what `system/init` REPORTS as the session's tools,
//!                       whatever was asked for. The lever for D10's fail-closed
//!                       check: name a writing tool and a read-only delegation
//!                       must be refused.
//!   `FAKE_CLAUDE_MODE`  the same, for `permissionMode` (default: echo the flag).
//!   `FAKE_CLAUDE_HOLD`  a path whose EXISTENCE holds the first turn open: while
//!                       it is there the turn emits lines and does not finish,
//!                       which is what gives a test a run in flight to interrupt.

const std = @import("std");

/// How long one held turn may last whatever anybody does, so a test that forgets
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
        .log = env.get("FAKE_CLAUDE_LOG"),
        .tools = env.get("FAKE_CLAUDE_TOOLS") orelse "Read,Glob,Grep",
        .mode = env.get("FAKE_CLAUDE_MODE") orelse flagOf(argv, "--permission-mode"),
        .session = sessionOf(argv),
        .hold = env.get("FAKE_CLAUDE_HOLD"),
    };
    try state.note(try joinArgv(alloc, argv));

    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(io, "0.0.0-fake (Claude Code)\n");
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
        try state.note(try std.fmt.allocPrint(alloc, "{s} {s}", .{ kind, subtypeOf(obj) }));
        // A control request read here arrived while the turn it meant to stop was
        // running; there is nothing left to stop, and the log is the evidence.
        if (!std.mem.eql(u8, kind, "user")) continue;
        try state.runTurn(userText(obj));
    }
}

const State = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    log: ?[]const u8,
    tools: []const u8,
    mode: []const u8,
    session: []const u8,
    hold: ?[]const u8,
    turns: u32 = 0,

    /// One turn: the echo, the answer, the end of it.
    fn runTurn(self: *State, heard: []const u8) !void {
        self.turns += 1;
        try self.sessionInit();

        // Held only while the file is there, and only for the first turn: the
        // round that takes up an interrupted message must not be held as well,
        // or a test could never get to the end of one.
        if (self.turns == 1) {
            if (self.hold) |path| {
                var ticks: u32 = 0;
                while (ticks < max_hold_ticks) : (ticks += 1) {
                    std.Io.Dir.cwd().access(self.io, path, .{}) catch break;
                    // Something on the wire every tick, because the runner polls
                    // the interrupt marker BETWEEN the lines it reads: a turn
                    // that says nothing while it works can be interrupted
                    // neither here nor in the real one.
                    try self.line("{\"type\":\"system\",\"subtype\":\"informational\",\"content\":\"working\"}");
                    self.io.sleep(.fromMilliseconds(20), .awake) catch {};
                }
            }
        }

        const said = try std.fmt.allocPrint(self.alloc, "heard: {s}", .{heard});
        try self.assistant(said);
        try self.result("success", said);
    }

    /// The session metadata every turn opens with — and the only thing this
    /// harness says back about what it applied, which is exactly why the
    /// read-only ceiling is checked against it.
    fn sessionInit(self: *State) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        try out.writer.print(
            "{{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":{f},\"model\":\"fake\",\"permissionMode\":{f},\"mcp_servers\":[],\"tools\":[",
            .{ std.json.fmt(self.session, .{}), std.json.fmt(self.mode, .{}) },
        );
        var first = true;
        var names = std.mem.splitScalar(u8, self.tools, ',');
        while (names.next()) |name| {
            const trimmed = std.mem.trim(u8, name, " \t");
            if (trimmed.len == 0) continue;
            if (!first) try out.writer.writeAll(",");
            first = false;
            try out.writer.print("{f}", .{std.json.fmt(trimmed, .{})});
        }
        try out.writer.writeAll("]}");
        try self.line(out.writer.buffered());
    }

    fn assistant(self: *State, text: []const u8) !void {
        try self.line(try std.fmt.allocPrint(
            self.alloc,
            "{{\"type\":\"assistant\",\"parent_tool_use_id\":null,\"message\":{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":{f}}}]}}}}",
            .{std.json.fmt(text, .{})},
        ));
    }

    fn result(self: *State, subtype: []const u8, text: []const u8) !void {
        try self.line(try std.fmt.allocPrint(
            self.alloc,
            "{{\"type\":\"result\",\"subtype\":\"{s}\",\"is_error\":{s},\"result\":{f}}}",
            .{
                subtype,
                if (std.mem.eql(u8, subtype, "success")) "false" else "true",
                std.json.fmt(text, .{}),
            },
        ));
    }

    fn line(self: *State, body: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(self.io, body);
        try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
    }

    /// One line per thing worth being evidence, appended.
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

/// The session id this launch was told to open or resume, echoed back in
/// `system/init` the way the real one does.
fn sessionOf(argv: []const [:0]const u8) []const u8 {
    const named = flagOf(argv, "--session-id");
    if (named.len != 0) return named;
    const resumed = flagOf(argv, "--resume");
    return if (resumed.len != 0) resumed else "no-session";
}

fn flagOf(argv: []const [:0]const u8, flag: []const u8) []const u8 {
    for (argv, 0..) |arg, i| {
        if (i + 1 >= argv.len) break;
        if (std.mem.eql(u8, arg, flag)) return argv[i + 1];
    }
    return "";
}

fn subtypeOf(obj: std.json.ObjectMap) []const u8 {
    const request = switch (obj.get("request") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => return stringOf(obj, "subtype") orelse "",
    };
    return stringOf(request, "subtype") orelse "";
}

fn userText(obj: std.json.ObjectMap) []const u8 {
    const message = switch (obj.get("message") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => return "",
    };
    return stringOf(message, "content") orelse "";
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
