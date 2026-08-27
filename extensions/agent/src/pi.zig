//! The Pi runner: a delegation held by a `pi` session.
//!
//! **The protocol, as this machine reports it** (`pi --help` and the RPC
//! reference shipped inside the package itself — contract §6). `pi --mode rpc`
//! is newline-delimited JSON over the child's stdio, and unlike the other two
//! external harnesses it is DOCUMENTED as a protocol rather than reconstructed
//! from a schema: commands in, responses and events out.
//!
//! What goes IN, one object per line:
//!
//!   `{"id":"…","type":"prompt","message":"…"}`   a turn.
//!   `{"type":"abort"}`                           D6's stop.
//!
//! What comes OUT:
//!
//!   `{"type":"response","command":"prompt","success":true|false,"error":"…"}`
//!                              the command was accepted, or was not.
//!   `{"type":"message_end","message":{…}}`       one message finished; the
//!                              assistant ones carry the text this reports.
//!   `{"type":"tool_execution_start","toolName":"…"}`   a tool is beginning.
//!   `{"type":"agent_settled"}`  the run is fully settled — no retry, no
//!                              compaction retry, no queued continuation left.
//!                              That is the end of a round, and `agent_end` is
//!                              not: it fires once per low-level run and can be
//!                              followed by more.
//!
//! **One flag opens or resumes.** `pi --session-id <id>` opens the project
//! session with that id, or creates one under that id when there is none (its own
//! `createSessionManager` does exactly that, and says so on stderr). So unlike the
//! Claude arm there is no fact on disk deciding between two flags: a delegation's
//! id IS the whole of how its conversation is found again.
//!
//! **One process per task, one turn per round** — the same shape as the Claude
//! arm, for the same reason (`claude.zig`): a message is READ from `<d>/inbox/`
//! and left there, and anything that goes wrong before its turn settles simply
//! never acks it. Pi has `steer` and `follow_up` commands for a message that
//! arrives mid-run, and this uses neither: both would hand the message to a queue
//! inside a process that could die with it, where our inbox is a file. What they
//! buy — delivery after the current turn — is what waiting in the inbox already
//! does (D3), and the way to cut a turn short is `abort`, which is implemented.
//!
//! **readonly is fail-closed (D10), with no echo to check.** `--tools` is an
//! allowlist over every tool source pi has (built-in, extension, custom), and it
//! is pi that enforces it — but nothing in the protocol reports back what the
//! session ended up with: `get_state` answers with the model, the queue modes and
//! the session file, and no tool list at all. So the mechanism is the flag, and
//! the check is the EVENT STREAM: `tool_execution_start` names every tool as it
//! begins, and one outside the read-only set aborts the run and refuses the round.
//! That is weaker than the Codex sandbox echo or Claude's `system/init` — it
//! catches a breach at the first tool rather than before the first word — and it
//! is the strongest thing this protocol offers. Recorded as such rather than
//! dressed up: contract §6.
//!
//! **And there is no `unsafe` here to reach for.** Pi's other two levels are
//! one level: it has no bypass mode, nothing to switch off, no grant above the
//! set it already takes. So a delegation asking for `unsafe` runs exactly as a
//! `default` one does on this arm, and the record still freezes the word that
//! was asked for — what a definition wanted and what a harness could give are
//! two facts, and collapsing them would lose the one a later sandbox reads.

const std = @import("std");
const proc = @import("proc.zig");
const record = @import("record.zig");
const mailbox = @import("mailbox.zig");

/// Which binary to talk to. `pi` on PATH is the answer on a real machine; the
/// variable exists so a test can point at one that answers the protocol without a
/// network (`codex.exe_var`'s shape, for its reason).
pub const exe_var = "NULYA_PI_EXE";

pub fn executable(env: *const std.process.Environ.Map) []const u8 {
    const named = env.get(exe_var) orelse return "pi";
    const trimmed = std.mem.trim(u8, named, " \t\r\n");
    return if (trimmed.len == 0) "pi" else trimmed;
}

/// How long one line of the stream may be. A `message_end` carries a whole
/// message, and `agent_end` carries every message of a run.
const max_line_bytes: usize = 8 << 20;

/// A persona longer than this is refused rather than truncated. Generous, because
/// unlike the Claude arm this one hands over a PATH — `--append-system-prompt`
/// reads the file when its argument is one — so the only bound is what is
/// reasonable to freeze.
const max_persona_bytes: usize = 1 << 20;

/// What a read-only delegation may call. Pi's whole built-in set is `read`,
/// `bash`, `edit`, `write`, `grep`, `find`, `ls`; these are the four that only
/// look. Named rather than "not the writing ones": a tool this list has never
/// heard of might do anything.
const readonly_tools = [_][]const u8{ "read", "grep", "find", "ls" };

// ── opening ─────────────────────────────────────────────────────────────────

/// Is pi here, and which version? Called when a delegation opens, so a definition
/// naming a harness this machine does not have is refused THEN — before a record
/// exists and before a receipt says work is under way. It is also where
/// `runner_version` comes from — and, as on the claude arm, that column is
/// OBSERVED PROVENANCE rather than a pin: later rounds run whatever `pi`
/// resolves to on PATH then, because a PATH binary offers nothing to pin
/// (`record.Created`, D7).
pub fn probe(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !union(enum) { ok: []const u8, failed: []const u8 } {
    const exe = executable(env);
    const said = proc.run(alloc, io, &.{ exe, "--version" }) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "could not run '{s} --version' ({s}). pi must be installed and on PATH for a definition with `runner: pi`.",
            .{ exe, @errorName(err) },
        ) };
    };
    if (said.code != 0) {
        return .{ .failed = try std.fmt.allocPrint(alloc, "'{s} --version' failed: {s}", .{ exe, proc.detail(said) }) };
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
            "this persona is {d} bytes, and a frozen persona is held to {d}.",
            .{ n, max_persona_bytes },
        ) },
    };
}

/// A connection with a pi session on the other end of it.
pub const Session = struct {
    child: std.process.Child,
    buf: []u8,
    reader: std.Io.File.Reader,
    write_buf: [4096]u8 = undefined,
    next_id: u32 = 1,
    readonly: bool = false,

    pub fn close(self: *Session, io: std.Io) void {
        if (self.child.stdin) |stdin| {
            var f = stdin;
            f.close(io);
            self.child.stdin = null;
        }
        self.child.kill(io);
    }
};

pub const Attempt = union(enum) { ok: Session, failed: []const u8 };

/// Start the process that will hold this delegation's conversation for the whole
/// of one background task.
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
        return .{ .failed = "the pi runner drives a delegation: its persona and its message channel both live in `.nulya/delegations/<d>/`" };
    }
    // A PATH, not the bytes: `--append-system-prompt` reads the file when its
    // argument is one (`resolvePromptInput`), so nothing has to fit on a command
    // line here.
    const persona = try record.pathIn(alloc, delegation, record.persona_name);
    base.access(io, persona, .{}) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "delegation {s} has no frozen persona ({s})",
            .{ delegation, @errorName(err) },
        ) };
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ executable(env), "--mode", "rpc" });
    // Opens it or creates it under that name — one flag for both, which is why
    // this arm needs no on-disk fact about whether the session exists yet.
    try argv.appendSlice(alloc, &.{ "--session-id", session_id });
    try argv.appendSlice(alloc, &.{ "--append-system-prompt", persona });
    // Opaque, in pi's own vocabulary (D9): `--model` takes a pattern, an id, or
    // `provider/id`, and this side owns none of that catalogue.
    if (model.len != 0) try argv.appendSlice(alloc, &.{ "--model", model });
    // The allowlist covers built-in, extension and custom tools alike, which is
    // what makes it the ceiling rather than a preference.
    //
    // Only `readonly` narrows anything here. Pi has NO level above its own
    // default — no bypass, no way to hand it more than it already takes — so
    // `unsafe` runs exactly as `default` does on this arm. The record still
    // says `unsafe`, because what was asked for is a different fact from what
    // this harness was able to grant (`runners.zig`, contract ar-h).
    if (permissions.isReadonly()) try argv.appendSlice(alloc, &.{ "--tools", try std.mem.join(alloc, ",", &readonly_tools) });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        // Dropped rather than captured: pi's diagnostics are its own, and a pipe
        // nobody drains is a process that blocks once it fills.
        .stderr = .ignore,
    }) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(alloc, "could not start '{s} --mode rpc' ({s})", .{ executable(env), @errorName(err) }) };
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

/// One turn, read to the point where the run has fully settled (or cut short by
/// an interrupt). The same facts `runner.zig` collects from a nulya round.
pub const RoundResult = struct {
    text: []const u8 = "",
    stopped: []const u8 = "",
    failure: []const u8 = "",
    interrupted: bool = false,
};

/// Answer the next message waiting for this delegation.
///
/// **Marker before message, always.** An interrupt delivers its message and THEN
/// writes the marker (D6), so both are on disk at once; checking the marker first
/// is what keeps the message where it is.
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
        out.stopped = "idle";
        return out;
    };
    const message = entry.msg;
    // Left in the inbox until the run settles, and dropped only then — every
    // early return goes through here having acked nothing (`mailbox.peekAfter`).
    var answered = false;
    defer if (answered) mailbox.ack(alloc, io, base, delegation, entry.name);

    prompt(alloc, io, sess, message.text) catch |err| {
        out.failure = try std.fmt.allocPrint(alloc, "could not hand that turn to pi ({s})", .{@errorName(err)});
        return out;
    };

    while (true) {
        if (mailbox.takeInterruptAt(io, base, interrupt_path)) {
            abort(alloc, io, sess) catch {};
            out.interrupted = true;
            // The run this cut short consumed the message, and its answer is
            // being thrown away on purpose — the interrupt IS the new direction,
            // and the message behind it is still in the inbox.
            answered = true;
            drainToSettled(alloc, sess);
            return out;
        }

        const msg = (try next(alloc, sess)) orelse {
            out.failure = "pi ended the session before the run settled";
            return out;
        };
        const kind = stringOf(msg, "type") orelse continue;

        if (std.mem.eql(u8, kind, "response")) {
            // Only the command this round sent matters; every other response is
            // to something nothing here asked for.
            const command = stringOf(msg, "command") orelse continue;
            if (!std.mem.eql(u8, command, "prompt")) continue;
            if (accepted(msg)) continue;
            out.failure = try std.fmt.allocPrint(
                alloc,
                "pi refused the turn: {s}",
                .{stringOf(msg, "error") orelse "no detail"},
            );
            return out;
        }

        if (std.mem.eql(u8, kind, "tool_execution_start")) {
            // The one check this protocol allows (see the note at the top of this
            // file). A tool outside the ceiling means the allowlist did not take,
            // and the run stops now rather than after it has finished.
            if (try breached(alloc, sess, msg)) |refusal| {
                abort(alloc, io, sess) catch {};
                out.failure = refusal;
                // Refused, not deferred: driving it again would refuse again.
                answered = true;
                drainToSettled(alloc, sess);
                return out;
            }
            continue;
        }

        if (std.mem.eql(u8, kind, "message_end")) {
            if (assistantText(alloc, msg)) |text| out.text = text;
            continue;
        }

        if (std.mem.eql(u8, kind, "agent_settled")) {
            answered = true;
            out.stopped = "settled";
            return out;
        }
    }
}

fn prompt(alloc: std.mem.Allocator, io: std.Io, sess: *Session, text: []const u8) !void {
    const id = sess.next_id;
    sess.next_id += 1;
    var line: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &line.writer };
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(try std.fmt.allocPrint(alloc, "nulya-{d}", .{id}));
    try jw.objectField("type");
    try jw.write("prompt");
    try jw.objectField("message");
    try jw.write(text);
    try jw.endObject();
    try line.writer.writeByte('\n');
    try writeLine(io, sess, line.writer.buffered());
}

/// D6's stop, in this harness's dialect. Fire and forget — the round's answer is
/// already decided, and what matters is that the run stops, not that we hear it.
fn abort(alloc: std.mem.Allocator, io: std.Io, sess: *Session) !void {
    _ = alloc;
    try writeLine(io, sess, "{\"type\":\"abort\"}\n");
}

/// Read until the run settles, so the process is left with nothing half-said on
/// it and the next round starts from a quiet stream.
fn drainToSettled(alloc: std.mem.Allocator, sess: *Session) void {
    while (next(alloc, sess) catch null) |msg| {
        const kind = stringOf(msg, "type") orelse continue;
        if (std.mem.eql(u8, kind, "agent_settled")) return;
    }
}

fn accepted(msg: std.json.ObjectMap) bool {
    return switch (msg.get("success") orelse std.json.Value{ .null = {} }) {
        .bool => |b| b,
        else => false,
    };
}

/// Is this tool outside a read-only delegation's ceiling? Null means "fine", or
/// "this is not a read-only delegation and there is no ceiling to breach".
fn breached(alloc: std.mem.Allocator, sess: *Session, msg: std.json.ObjectMap) !?[]const u8 {
    if (!sess.readonly) return null;
    const name = stringOf(msg, "toolName") orelse return null;
    for (readonly_tools) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return null;
    }
    return try std.fmt.allocPrint(
        alloc,
        "this agent is read-only, but pi began calling '{s}', which is not one of the tools that only read ({s}) — so the allow-list it was started with did not hold. Stopping the run rather than letting it go wider than it asked for.",
        .{ name, try std.mem.join(alloc, ", ", &readonly_tools) },
    );
}

/// The text of a finished assistant message, or null when it carried none (a
/// message of tool calls, or a user or tool-result message).
fn assistantText(alloc: std.mem.Allocator, msg: std.json.ObjectMap) ?[]const u8 {
    const body = switch (msg.get("message") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => return null,
    };
    const role = stringOf(body, "role") orelse return null;
    if (!std.mem.eql(u8, role, "assistant")) return null;
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

// ── the stream ──────────────────────────────────────────────────────────────

fn writeLine(io: std.Io, sess: *Session, line: []const u8) !void {
    const stdin = sess.child.stdin orelse return error.ConnectionClosed;
    var writer = stdin.writerStreaming(io, &sess.write_buf);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
}

/// One message off the stream, or null when it ended.
///
/// Split on `\n` only, and a trailing `\r` stripped — pi's own reference is
/// explicit that its framing is strict JSONL and that a reader which also breaks
/// on the Unicode separators will corrupt records that legitimately contain them.
fn next(alloc: std.mem.Allocator, sess: *Session) !?std.json.ObjectMap {
    while (true) {
        const line = sess.reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            // Longer than we will hold: step over it rather than stop reading.
            // Giving up here would stop draining a pipe pi is still writing into,
            // and then it blocks on stdout while we wait for a run that has
            // already settled.
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
