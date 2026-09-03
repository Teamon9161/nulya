//! The Claude runner: a delegation held by a Claude Code session.
//!
//! `claude -p --input-format stream-json --output-format stream-json --verbose`
//! is a bidirectional, newline-delimited JSON stream over the child's stdio,
//! verified against Claude Code 2.1.246. IN, one object per line:
//! `{"type":"user","message":{"role":"user","content":…},"parent_tool_use_id":
//! null}` is a turn (stdin stays open, so a session takes as many as it is
//! given); `{"type":"control_request","request_id":…,"request":{"subtype":
//! "interrupt"}}` is the stop. OUT, the members this reads:
//!
//!   `system/init`  session metadata opening every turn: `session_id`, `model`,
//!                  `tools[]`, `mcp_servers[]`, `permissionMode`. THE ECHO the
//!                  read-only ceiling is checked against.
//!   `assistant`    one per content block; non-null `parent_tool_use_id` is a
//!                  subagent's own message, not this conversation's answer.
//!   `result`       end of a turn: `subtype`, `is_error`, `result` (final text).
//!
//! The session id is minted HERE — `--session-id <uuid>` opens, `--resume
//! <uuid>` picks up in a later process — and which a round uses is decided by
//! `<d>/claude.started`, so an attempt that died before opening anything retries
//! as a creation. ONE TURN PER ROUND: Claude's own queue dies with the process.
//!
//! `readonly` is FAIL-CLOSED: ask for the narrow shape, then CHECK the
//! `system/init` echo — a tool outside the read-only set, a wider permission
//! mode, or any MCP server refuses the round before a single tool has run.

const std = @import("std");
const proc = @import("proc.zig");
const record = @import("record.zig");
const mailbox = @import("mailbox.zig");

/// Which binary to talk to. `claude` on PATH is the answer on a real machine; the
/// variable lets a test point at one that answers the protocol without a network.
pub const exe_var = "NULYA_CLAUDE_EXE";

pub fn executable(env: *const std.process.Environ.Map) []const u8 {
    const named = env.get(exe_var) orelse return "claude";
    const trimmed = std.mem.trim(u8, named, " \t\r\n");
    return if (trimmed.len == 0) "claude" else trimmed;
}

/// How long one line of the stream may be. An `assistant` line carries a whole
/// content block and a tool call's arguments with it.
const max_line_bytes: usize = 8 << 20;

/// The fact that decides `--session-id` from `--resume`: written the first time a
/// session reported itself, so a round that died before opening one retries as a
/// creation instead of resuming something that is not there.
const started_name = "claude.started";

/// A persona longer than this is refused rather than truncated. It rides as a
/// command-line argument (`--append-system-prompt`), and Windows caps a command
/// line at 32767 bytes: a persona that silently lost its second half would be a
/// sub-agent quietly running as somebody else. `--append-system-prompt-file`
/// exists and takes a path, but it is hidden from `--help`.
const max_persona_bytes: usize = 16 << 10;

/// What a read-only delegation may have in its session. Named tools rather than
/// "not the writing ones": a tool this list has never heard of might do anything.
const readonly_tools = [_][]const u8{ "Read", "Glob", "Grep", "NotebookRead", "TodoWrite" };

/// The permission mode a read-only delegation asks for, and the only one its echo
/// may come back with. `dontAsk` denies anything outside the allow rules and the
/// read-only command set, so with nobody at the keyboard a turn never stalls on
/// a prompt.
const readonly_mode = "dontAsk";

/// …and what an ordinary one runs as. `acceptEdits` writes files without asking;
/// anything beyond the read-only command set still needs a rule.
const default_mode = "acceptEdits";

/// …and what `permissions: unsafe` asks for: everything the harness can do, guard
/// rails off. Reached only by a definition or an `agent` call that says the word
/// — never by omission, never inherited from anything about the parent.
const unsafe_mode = "bypassPermissions";

/// Claude's own word for each of the three. Only `readonly` also narrows the
/// tool face and is checked against the echo (`checkInit`); the other two are
/// permission modes and nothing else.
fn modeWord(permissions: record.Permissions) []const u8 {
    return switch (permissions) {
        .readonly => readonly_mode,
        .default => default_mode,
        .unsafe => unsafe_mode,
    };
}

// ── opening ─────────────────────────────────────────────────────────────────

/// Is Claude Code here, and which version? Called when a delegation opens, so a
/// definition naming a harness this machine does not have is refused THEN —
/// before a record exists and before a receipt says work is under way.
///
/// Also where `runner_version` comes from, and on this arm that column is
/// OBSERVED PROVENANCE rather than a pin: later rounds run whatever `claude`
/// resolves to on PATH then (`record.Created`).
pub fn probe(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !union(enum) { ok: []const u8, failed: []const u8 } {
    const exe = executable(env);
    const said = proc.run(alloc, io, &.{ exe, "--version" }) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "could not run '{s} --version' ({s}). Claude Code must be installed and on PATH for a definition with `runner: claude`.",
            .{ exe, @errorName(err) },
        ) };
    };
    if (said.code != 0) {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "'{s} --version' failed: {s}",
            .{ exe, proc.detail(said) },
        ) };
    }
    return .{ .ok = proc.firstLine(said.stdout) };
}

/// Copy the rendered persona into the delegation, once, when it opens. The layout
/// is the record's; the sentence about the limit is this runner's.
pub fn freezePersona(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    delegation: []const u8,
    rendered: []const u8,
) !union(enum) { ok, failed: []const u8 } {
    return switch (try record.freezePersona(alloc, io, base, delegation, rendered, max_persona_bytes)) {
        .ok => .ok,
        .failed => |f| .{ .failed = f },
        .too_long => |n| .{ .failed = try std.fmt.allocPrint(
            alloc,
            "this persona is {d} bytes and the claude runner passes it on the command line, which holds {d}. Shorten it, or run this agent on the nulya runner, which freezes the whole of it into the session.",
            .{ n, max_persona_bytes },
        ) },
    };
}

/// A connection with a Claude session on the other end of it.
pub const Session = struct {
    child: std.process.Child,
    buf: []u8,
    reader: std.Io.File.Reader,
    write_buf: [4096]u8 = undefined,
    next_control: u32 = 1,
    /// Is there a ceiling to hold this process to — re-checked against the echo
    /// of every session start (`checkInit`)? A bool rather than the three words:
    /// `readonly` is the only one that is checked.
    readonly: bool = false,
    /// Has an `init` for this process been seen and accepted yet?
    confirmed: bool = false,

    pub fn close(self: *Session, io: std.Io) void {
        // Closing stdin is how a `-p` session in streaming input mode is told
        // there is nothing more coming; the kill makes sure a round leaves no
        // process behind when it does not take the hint.
        if (self.child.stdin) |stdin| {
            var f = stdin;
            f.close(io);
            self.child.stdin = null;
        }
        self.child.kill(io);
    }
};

pub const Attempt = union(enum) { ok: Session, failed: []const u8 };

/// Start the process that holds this delegation's conversation for one whole
/// background task.
///
/// Nothing is read here: `system/init` — the echo the read-only check reads —
/// arrives at the start of the first TURN, so the confirmation lives in
/// `driveRound`, ahead of the model's first word and of any tool.
pub fn attach(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    base: std.Io.Dir,
    delegation: []const u8,
    session_id: []const u8,
    permissions: record.Permissions,
    model: []const u8,
) !Attempt {
    if (delegation.len == 0) {
        return .{ .failed = "the claude runner drives a delegation: its persona and its message channel both live in `.nulya/delegations/<d>/`" };
    }
    const persona = base.readFileAlloc(
        io,
        try record.pathIn(alloc, delegation, record.persona_name),
        alloc,
        .limited(max_persona_bytes),
    ) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "delegation {s} has no frozen persona ({s})",
            .{ delegation, @errorName(err) },
        ) };
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{
        executable(env),
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
    });
    // Opened by name the first time, resumed by name after that. The fact
    // deciding which is on disk, so a round after a crash that opened nothing
    // still creates rather than resuming a session that is not there.
    const opened = blk: {
        base.access(io, try record.pathIn(alloc, delegation, started_name), .{}) catch break :blk false;
        break :blk true;
    };
    try argv.append(alloc, if (opened) "--resume" else "--session-id");
    try argv.append(alloc, session_id);
    try argv.appendSlice(alloc, &.{ "--append-system-prompt", persona });
    if (model.len != 0) try argv.appendSlice(alloc, &.{ "--model", model });
    try argv.appendSlice(alloc, &.{ "--permission-mode", modeWord(permissions) });
    if (permissions.isReadonly()) {
        // Availability, not approval: a tool that is not in the session cannot be
        // reached, and it is the half `system/init` reports back.
        try argv.appendSlice(alloc, &.{ "--tools", try std.mem.join(alloc, ",", &readonly_tools) });
        // No `--mcp-config`, so this leaves the session with no MCP servers at
        // all — a configured one could otherwise contribute a tool nobody here
        // has ever seen the name of.
        try argv.append(alloc, "--strict-mcp-config");
    }

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        // Dropped rather than captured: a pipe nobody drains is a process that
        // blocks once it fills.
        .stderr = .ignore,
    }) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "could not start '{s}' ({s})",
            .{ executable(env), @errorName(err) },
        ) };
    };
    errdefer child.kill(io);
    const buf = try alloc.alloc(u8, max_line_bytes);
    return .{ .ok = .{
        .child = child,
        .buf = buf,
        .reader = child.stdout.?.readerStreaming(io, buf),
        .readonly = permissions.isReadonly(),
    } };
}

// ── driving one round ───────────────────────────────────────────────────────

/// One turn, read to its end (or cut short by an interrupt).
pub const RoundResult = struct {
    /// The last thing the agent said this round — the report.
    text: []const u8 = "",
    /// The turn's own word for how it ended, for a report with nothing else.
    stopped: []const u8 = "",
    /// Why the round could not run at all. Non-empty means "stop looping".
    failure: []const u8 = "",
    interrupted: bool = false,
};

/// Answer the next message waiting for this delegation.
///
/// ONE MESSAGE, READ AND ANSWERED BEFORE IT IS DROPPED. It is read from
/// `<d>/inbox/` and stays there; only "the turn ended" acks it. So every other
/// way out of here — an error, an interrupt, a killed process — leaves it exactly
/// where it was. The cost is at-least-once: an ack that does not land means the
/// next round hands the same message over again.
///
/// MARKER CHECKED BEFORE MESSAGE, always. An interrupt delivers its message and
/// THEN writes the marker, so both are on disk at once; checking the marker first
/// keeps the message where it is rather than feeding it to a turn about to be
/// thrown away.
pub fn driveRound(
    alloc: std.mem.Allocator,
    io: std.Io,
    sess: *Session,
    base: std.Io.Dir,
    delegation: []const u8,
    interrupt_path: []const u8,
) !RoundResult {
    var out: RoundResult = .{};

    const entry = (try mailbox.peekOne(alloc, io, base, delegation)) orelse {
        // Not a failure and not a report: the caller's pending check decides
        // whether to come round again.
        out.stopped = "idle";
        return out;
    };
    const message = entry.msg;
    // Left in the inbox until the turn ends, and dropped only then. Every early
    // return goes through here having acked nothing, so a round that could not use
    // the message leaves it in its place, in order, and still there if this
    // process is killed.
    var answered = false;
    defer if (answered) mailbox.ack(alloc, io, base, delegation, entry.name);

    writeUserMessage(alloc, io, sess, message.text) catch |err| {
        out.failure = try std.fmt.allocPrint(
            alloc,
            "could not hand that turn to claude ({s})",
            .{@errorName(err)},
        );
        return out;
    };

    while (true) {
        // ① The interrupt marker, at the granularity the stream gives for free.
        if (mailbox.takeInterruptAt(io, base, interrupt_path)) {
            interrupt(alloc, io, sess) catch {};
            out.interrupted = true;
            // The turn this cut short consumed the message, and its answer is
            // thrown away on purpose — the interrupt IS the new direction, and
            // the message behind it is still in the inbox.
            answered = true;
            drainToEnd(alloc, sess);
            return out;
        }

        const msg = (try next(alloc, sess)) orelse {
            out.failure = if (sess.confirmed)
                "claude ended the session before the turn finished"
            else
                try std.fmt.allocPrint(
                    alloc,
                    "claude said nothing and exited; run the same delegation by hand to see why ('{s}' is what this runner spawns)",
                    .{"claude -p --input-format stream-json --output-format stream-json"},
                );
            return out;
        };
        const kind = stringOf(msg, "type") orelse continue;

        if (std.mem.eql(u8, kind, "system")) {
            const subtype = stringOf(msg, "subtype") orelse continue;
            if (!std.mem.eql(u8, subtype, "init")) continue;
            if (try checkInit(alloc, sess, msg)) |refusal| {
                out.failure = refusal;
                // Refused, not deferred: driving it again would refuse again, and
                // a message that comes back for ever is worse than one answered
                // with "this delegation cannot run here".
                answered = true;
                return out;
            }
            sess.confirmed = true;
            // This session now exists on Claude's side, so later rounds resume it.
            markStarted(alloc, io, base, delegation) catch {};
            continue;
        }

        // The echo comes FIRST or the ceiling is not a ceiling. `system/init`
        // opens every turn ahead of everything else, so anything meaning the
        // model has begun working, seen before it, is a session whose shape was
        // never confirmed. Refuse rather than check after the fact.
        if (sess.readonly and !sess.confirmed and workBegun(kind)) {
            out.failure = try std.fmt.allocPrint(
                alloc,
                "this agent is read-only, and claude started working ('{s}') without reporting the session's tools and permission mode first — so the ceiling cannot be confirmed. Refusing rather than running it wider than it asked for.",
                .{kind},
            );
            answered = true;
            return out;
        }

        if (std.mem.eql(u8, kind, "assistant")) {
            // A subagent's own words are not this conversation's answer.
            if (hasParentToolUse(msg)) continue;
            if (assistantText(alloc, msg)) |text| out.text = text;
            continue;
        }

        if (std.mem.eql(u8, kind, "result")) {
            answered = true;
            out.stopped = try alloc.dupe(u8, stringOf(msg, "subtype") orelse "");
            // The final response text, which the sub-agent was told its report
            // would be. The last assistant block is the fallback for a turn that
            // ended without one.
            if (stringOf(msg, "result")) |final| {
                const trimmed = std.mem.trim(u8, final, " \t\r\n");
                if (trimmed.len != 0) out.text = try alloc.dupe(u8, trimmed);
            }
            if (isError(msg) and out.text.len == 0) {
                out.failure = try std.fmt.allocPrint(
                    alloc,
                    "claude ended the turn with an error: {s}",
                    .{stringOf(msg, "error") orelse out.stopped},
                );
            }
            return out;
        }
    }
}

/// `{"type":"user", …}` — the one thing a client writes to start a turn.
/// `parent_tool_use_id` is required by the schema and null for anything that is
/// not a subagent's own message.
fn writeUserMessage(alloc: std.mem.Allocator, io: std.Io, sess: *Session, text: []const u8) !void {
    var line: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &line.writer };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("user");
    try jw.objectField("message");
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("user");
    try jw.objectField("content");
    try jw.write(text);
    try jw.endObject();
    try jw.objectField("parent_tool_use_id");
    try jw.write(null);
    try jw.endObject();
    try line.writer.writeByte('\n');
    try writeLine(io, sess, line.writer.buffered());
}

/// The stop, in this harness's dialect: the control channel the SDK's own
/// `interrupt()` uses. Fire and forget — the round's answer is already decided,
/// and what matters is that the turn stops, not that we hear it did.
fn interrupt(alloc: std.mem.Allocator, io: std.Io, sess: *Session) !void {
    const id = sess.next_control;
    sess.next_control += 1;
    const line = try std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"control_request\",\"request_id\":\"nulya-{d}\",\"request\":{{\"subtype\":\"interrupt\"}}}}\n",
        .{id},
    );
    try writeLine(io, sess, line);
}

/// Read until the turn ends, so the process is left with nothing half-said on it
/// and the next round starts from a quiet stream. Bounded by the stream itself.
fn drainToEnd(alloc: std.mem.Allocator, sess: *Session) void {
    while (next(alloc, sess) catch null) |msg| {
        const kind = stringOf(msg, "type") orelse continue;
        if (std.mem.eql(u8, kind, "result")) return;
    }
}

/// The fail-closed half: the `system/init` echo is the only thing Claude says
/// back about what it applied, so it is what the ceiling is checked against. Null
/// means "narrow enough".
fn checkInit(alloc: std.mem.Allocator, sess: *Session, msg: std.json.ObjectMap) !?[]const u8 {
    if (!sess.readonly) return null;

    const mode = stringOf(msg, "permissionMode") orelse return try std.fmt.allocPrint(
        alloc,
        "this agent is read-only, and claude did not say which permission mode it applied — so the ceiling cannot be confirmed. Refusing rather than running it wider than it asked for.",
        .{},
    );
    if (!std.mem.eql(u8, mode, readonly_mode)) {
        return try std.fmt.allocPrint(
            alloc,
            "this agent is read-only, but claude applied the '{s}' permission mode instead of '{s}'. Refusing rather than running it wider than it asked for.",
            .{ mode, readonly_mode },
        );
    }

    const tools = switch (msg.get("tools") orelse std.json.Value{ .null = {} }) {
        .array => |a| a,
        else => return try std.fmt.allocPrint(
            alloc,
            "this agent is read-only, and claude did not say which tools the session has — so the ceiling cannot be confirmed. Refusing rather than running it wider than it asked for.",
            .{},
        ),
    };
    for (tools.items) |item| {
        const name = switch (item) {
            .string => |s| s,
            else => continue,
        };
        for (readonly_tools) |allowed| {
            if (std.mem.eql(u8, name, allowed)) break;
        } else {
            return try std.fmt.allocPrint(
                alloc,
                "this agent is read-only, but claude opened the session with '{s}', which is not one of the tools that only read ({s}). Refusing rather than running it wider than it asked for.",
                .{ name, try std.mem.join(alloc, ", ", &readonly_tools) },
            );
        }
    }

    // An MCP server is a tool face this side has never seen a name from. Asked
    // for with `--strict-mcp-config` and checked here: the flag is a request, the
    // echo is the answer.
    switch (msg.get("mcp_servers") orelse std.json.Value{ .null = {} }) {
        .array => |a| if (a.items.len != 0) return try std.fmt.allocPrint(
            alloc,
            "this agent is read-only, but claude opened the session with {d} MCP server(s), whose tools this ceiling cannot vouch for. Refusing rather than running it wider than it asked for.",
            .{a.items.len},
        ),
        else => {},
    }
    return null;
}

fn markStarted(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, delegation: []const u8) !void {
    try base.writeFile(io, .{
        .sub_path = try record.pathIn(alloc, delegation, started_name),
        .data = "",
    });
}

/// The text blocks of one assistant message, joined. Null when it carried none.
fn assistantText(alloc: std.mem.Allocator, msg: std.json.ObjectMap) ?[]const u8 {
    const body = switch (msg.get("message") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => return null,
    };
    const content = switch (body.get("content") orelse std.json.Value{ .null = {} }) {
        .array => |a| a,
        .string => |s| {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            return if (trimmed.len == 0) null else trimmed;
        },
        else => return null,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (content.items) |block| {
        if (block != .object) continue;
        const kind = stringOf(block.object, "type") orelse continue;
        if (!std.mem.eql(u8, kind, "text")) continue;
        const text = stringOf(block.object, "text") orelse continue;
        out.writer.writeAll(text) catch return null;
    }
    const whole = std.mem.trim(u8, out.writer.buffered(), " \t\r\n");
    return if (whole.len == 0) null else whole;
}

/// Does this line mean the model has started working? Only the conversation's own
/// message kinds: startup noise (hook events, plugin installs, notices) may
/// legitimately precede `system/init`, and none of it can run a tool.
fn workBegun(kind: []const u8) bool {
    inline for (.{ "assistant", "user", "stream_event", "tool_progress", "result" }) |working| {
        if (std.mem.eql(u8, kind, working)) return true;
    }
    return false;
}

fn hasParentToolUse(msg: std.json.ObjectMap) bool {
    return switch (msg.get("parent_tool_use_id") orelse std.json.Value{ .null = {} }) {
        .string => |s| s.len != 0,
        else => false,
    };
}

fn isError(msg: std.json.ObjectMap) bool {
    return switch (msg.get("is_error") orelse std.json.Value{ .null = {} }) {
        .bool => |b| b,
        else => false,
    };
}

// ── the stream ──────────────────────────────────────────────────────────────

fn writeLine(io: std.Io, sess: *Session, line: []const u8) !void {
    const stdin = sess.child.stdin orelse return error.ConnectionClosed;
    var writer = stdin.writerStreaming(io, &sess.write_buf);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
}

/// One message off the stream, or null when it ended. Every line is one JSON
/// object; anything that is not is stepped over rather than believed.
fn next(alloc: std.mem.Allocator, sess: *Session) !?std.json.ObjectMap {
    while (true) {
        const line = sess.reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            // Longer than we will hold: step over it rather than stop reading.
            // Giving up would stop draining a pipe Claude is still writing into,
            // and then it blocks on stdout while we wait for a turn that has
            // already ended.
            error.StreamTooLong => {
                _ = sess.reader.interface.discardDelimiterInclusive('\n') catch return null;
                continue;
            },
            else => return null,
        } orelse return null;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch continue;
        switch (parsed.value) {
            .object => |o| return o,
            else => continue,
        }
    }
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
