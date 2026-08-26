//! A `codex app-server` that answers the protocol and never leaves this machine.
//!
//! **Why this exists.** The Codex runner (`extensions/agent/src/codex.zig`) is a
//! JSON-RPC conversation with another harness. Everything worth pinning down
//! about it — that a delegation opens a thread and reports back through the
//! parent's inbox, that a message sent while it is idle waits in `<d>/inbox/`
//! and is taken up next round, that the interrupt marker becomes
//! `turn/interrupt`, that a read-only agent is refused when the sandbox comes
//! back wrong — is about THIS SIDE of that conversation. None of it needs a
//! model, and a test that needed one would be a test nobody runs.
//!
//! So this speaks the smallest subset the runner actually sends, with fixed
//! answers, and the e2e test points `NULYA_CODEX_EXE` at it.
//!
//! **It never reads while a turn is running, and that is deliberate.** A fake
//! that watched its stdin mid-turn would need a thread or a non-blocking read to
//! avoid deadlocking against a client that is itself blocked reading — and the
//! only thing it would buy is folding a steer into the answer. What a test needs
//! instead is EVIDENCE that the runner sent the right request at the right
//! moment, and that is what `FAKE_CODEX_LOG` is: every request lands in it, the
//! ones sent mid-turn as soon as the turn is over. A turn's length is set from
//! outside (`FAKE_CODEX_HOLD`), so a test decides when it ends rather than
//! racing it.
//!
//! **What it answers.** `initialize`, `thread/start`, `thread/resume`,
//! `turn/start`, `turn/steer`, `turn/interrupt` — the six the runner sends. A
//! turn replies, emits one `item/completed` carrying an agent message that
//! QUOTES the input it was given (so a test can tell which message produced
//! which report), and ends with `turn/completed`.
//!
//! **How a test bends it**, through the environment, because that is what
//! reaches a process spawned three levels down:
//!
//!   `FAKE_CODEX_SANDBOX`  what `thread/start` and `thread/resume` REPORT
//!                         applying, whatever was asked for. The lever for
//!                         D10's fail-closed check: set it to `workspaceWrite`
//!                         and a read-only delegation must be refused.
//!   `FAKE_CODEX_LOG`      a file to append one line per request to — the whole
//!                         request, so the sandbox a thread ASKED for can be
//!                         read as well as the one it was told it got.
//!   `FAKE_CODEX_HOLD`     a path whose EXISTENCE holds the first turn open:
//!                         while it is there the turn emits deltas and does not
//!                         finish, which is what gives a test a run in flight to
//!                         steer and to interrupt. Only the first turn, so the
//!                         round that follows an interrupt is not held too.

const std = @import("std");

/// How long one held turn may last whatever anybody does, so a test that forgets
/// to release it fails rather than hangs.
const max_hold_ticks: u32 = 3000; // 60s at 20ms

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    const env = init.environ_map;

    var in_buf: [1 << 16]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);

    var state: State = .{
        .alloc = alloc,
        .io = io,
        .sandbox = env.get("FAKE_CODEX_SANDBOX") orelse "readOnly",
        .log = env.get("FAKE_CODEX_LOG"),
        .hold = env.get("FAKE_CODEX_HOLD"),
    };

    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch break orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch continue;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const method = stringOf(obj, "method") orelse continue;
        // The WHOLE request, not just its method: the sandbox a thread was
        // asked for is a parameter, and it is the one fact the permission
        // ladder's mapping can be checked against from outside.
        try state.note(trimmed);
        try state.handle(method, idOf(obj), obj);
    }
}

const State = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    sandbox: []const u8,
    log: ?[]const u8,
    hold: ?[]const u8,
    threads: u32 = 0,
    turns: u32 = 0,

    /// One line per request, appended. A test reads this to see what the runner
    /// actually sent — which is the only way to tell a steer that happened from
    /// a report that would have looked the same without one.
    fn note(self: *State, what: []const u8) !void {
        const path = self.log orelse return;
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false, .read = true }) catch return;
        defer file.close(self.io);
        const size = (file.stat(self.io) catch return).size;
        const line = try std.fmt.allocPrint(self.alloc, "{s}\n", .{what});
        file.writePositionalAll(self.io, line, size) catch return;
    }

    fn handle(self: *State, method: []const u8, id: ?i64, obj: std.json.ObjectMap) !void {
        const params: ?std.json.ObjectMap = switch (obj.get("params") orelse std.json.Value{ .null = {} }) {
            .object => |o| o,
            else => null,
        };
        if (std.mem.eql(u8, method, "initialize")) {
            return self.reply(id, "{\"userAgent\":\"fake-codex\"}");
        }
        if (std.mem.eql(u8, method, "initialized")) return;
        if (std.mem.eql(u8, method, "thread/start")) {
            self.threads += 1;
            return self.openThread(id, try std.fmt.allocPrint(self.alloc, "t-{d:0>4}", .{self.threads}));
        }
        if (std.mem.eql(u8, method, "thread/resume")) {
            const named = if (params) |p| stringOf(p, "threadId") orelse "t-0000" else "t-0000";
            return self.openThread(id, named);
        }
        if (std.mem.eql(u8, method, "turn/start")) {
            return self.runTurn(id, params);
        }
        // Sent mid-turn, read here once the turn is over. Answered so nothing is
        // left waiting, and otherwise nothing to do: the log is the evidence.
        if (std.mem.eql(u8, method, "turn/steer")) return self.reply(id, "{\"turnId\":\"over\"}");
        if (std.mem.eql(u8, method, "turn/interrupt")) return self.reply(id, "{}");
        return self.fail(id, "fake codex does not implement that method");
    }

    /// Both `thread/start` and `thread/resume` report the sandbox they applied —
    /// which is exactly what the read-only ceiling is checked against (D10).
    fn openThread(self: *State, id: ?i64, thread: []const u8) !void {
        return self.reply(id, try std.fmt.allocPrint(
            self.alloc,
            "{{\"sandbox\":{{\"type\":\"{s}\"}},\"thread\":{{\"id\":\"{s}\"}}}}",
            .{ self.sandbox, thread },
        ));
    }

    fn runTurn(self: *State, id: ?i64, params: ?std.json.ObjectMap) !void {
        self.turns += 1;
        const turn = try std.fmt.allocPrint(self.alloc, "turn-{d}", .{self.turns});
        try self.reply(id, try std.fmt.allocPrint(
            self.alloc,
            "{{\"turn\":{{\"id\":\"{s}\",\"status\":\"inProgress\",\"items\":[]}}}}",
            .{turn},
        ));

        // Held only while the file is there, and only for the first turn: the
        // round that takes up an interrupted message must not be held as well,
        // or a test could never get to the end of one.
        if (self.turns == 1) {
            if (self.hold) |path| {
                var ticks: u32 = 0;
                while (ticks < max_hold_ticks) : (ticks += 1) {
                    std.Io.Dir.cwd().access(self.io, path, .{}) catch break;
                    // Something on the wire every tick, because the runner polls
                    // the interrupt marker and the delegation's inbox BETWEEN
                    // the lines it reads: a turn that says nothing while it
                    // works can be neither steered nor interrupted, here or in
                    // the real one.
                    try self.notify("item/reasoning/textDelta", "{\"delta\":\"…\"}");
                    self.io.sleep(.fromMilliseconds(20), .awake) catch {};
                }
            }
        }

        const heard = try std.mem.join(self.alloc, " + ", if (params) |p| try inputTexts(self.alloc, p) else &.{});
        try self.notify("item/completed", try std.fmt.allocPrint(
            self.alloc,
            "{{\"item\":{{\"id\":\"m-{d}\",\"type\":\"agentMessage\",\"text\":{f}}}}}",
            .{ self.turns, std.json.fmt(try std.fmt.allocPrint(self.alloc, "heard: {s}", .{heard}), .{}) },
        ));
        try self.notify("turn/completed", try std.fmt.allocPrint(
            self.alloc,
            "{{\"turn\":{{\"id\":\"{s}\",\"status\":\"completed\",\"items\":[]}}}}",
            .{turn},
        ));
    }

    fn reply(self: *State, id: ?i64, result: []const u8) !void {
        const n = id orelse return;
        try self.write(try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"result\":{s}}}\n", .{ n, result }));
    }

    fn fail(self: *State, id: ?i64, message: []const u8) !void {
        const n = id orelse return;
        try self.write(try std.fmt.allocPrint(
            self.alloc,
            "{{\"id\":{d},\"error\":{{\"code\":-32601,\"message\":{f}}}}}\n",
            .{ n, std.json.fmt(message, .{}) },
        ));
    }

    fn notify(self: *State, method: []const u8, params: []const u8) !void {
        try self.write(try std.fmt.allocPrint(self.alloc, "{{\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, params }));
    }

    fn write(self: *State, line: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(self.io, line);
    }
};

fn inputTexts(alloc: std.mem.Allocator, params: std.json.ObjectMap) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const input = switch (params.get("input") orelse std.json.Value{ .null = {} }) {
        .array => |a| a,
        else => return &.{},
    };
    for (input.items) |item| {
        if (item != .object) continue;
        const text = stringOf(item.object, "text") orelse continue;
        try out.append(alloc, text);
    }
    return out.items;
}

fn idOf(obj: std.json.ObjectMap) ?i64 {
    return switch (obj.get("id") orelse std.json.Value{ .null = {} }) {
        .integer => |i| i,
        else => null,
    };
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
