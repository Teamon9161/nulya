//! The Codex runner: a delegation held by a Codex thread.
//!
//! Newline-delimited JSON-RPC over `codex app-server`'s stdio, verified against
//! `generate-json-schema` and a live handshake. The server OMITS the `jsonrpc`
//! member on its replies, so a reader must key on the members that ARE there:
//! `{"id":N,"method":…,"params":…}` is a request either direction,
//! `{"id":N,"result":…}` / `{"error":…,"id":N}` its reply, `{"method":…,
//! "params":…}` a notification. The verbs:
//!
//!   `initialize {clientInfo}`   once per connection, then the `initialized`
//!                               notification. Nothing else is answered before.
//!   `thread/start {…}`          opens a conversation → `result.thread.id`.
//!   `thread/resume {threadId}`  picks it up in a later process, which is what
//!                               lets a delegation survive between rounds.
//!   `turn/start {threadId, input:[{type:"text",text}]}` → `result.turn.id`,
//!                               then notifications ending in `turn/completed`.
//!   `turn/steer {threadId, expectedTurnId, input}`   another message INTO the
//!                               turn already running.
//!   `turn/interrupt {threadId, turnId}`              the stop.
//!
//! One connection per round. `readonly` is FAIL-CLOSED: both `thread/start` and
//! `thread/resume` echo the sandbox policy they actually applied, so a read-only
//! delegation asks for `read-only` and then CHECKS the answer.

const std = @import("std");
const record = @import("record.zig");
const mailbox = @import("mailbox.zig");

/// Which binary to talk to. `codex` on PATH is the answer on a real machine; the
/// variable lets a test point at one that answers the protocol without a network.
pub const exe_var = "NULYA_CODEX_EXE";

pub fn executable(env: *const std.process.Environ.Map) []const u8 {
    const named = env.get(exe_var) orelse return "codex";
    const trimmed = std.mem.trim(u8, named, " \t\r\n");
    return if (trimmed.len == 0) "codex" else trimmed;
}

/// How long one line of the protocol may be. A turn's items carry whole model
/// messages, and a `thread/resume` reply carries the thread's history.
const max_line_bytes: usize = 8 << 20;

/// What `thread/start` is asked for, and what a `turn/start` is given.
pub const OpenOptions = struct {
    /// The persona, verbatim. It rides as `developerInstructions`, never
    /// `baseInstructions`: the latter REPLACES Codex's own operating prompt —
    /// the part that tells it how its tools work — so a persona sent that way
    /// would silently cost the agent its harness.
    persona: []const u8,
    /// Whatever the definition or the call said to run on, in Codex's own
    /// vocabulary. Empty leaves Codex's configured default alone. Opaque here: a
    /// parser on this side could only be a staler copy of its catalogue.
    model: []const u8 = "",
    /// How much this delegation may do (`record.Permissions`). Codex has a word
    /// for each of the three, so the sandbox below is a straight translation.
    permissions: record.Permissions = record.default_permissions,
};

/// A connection with a thread on the other end of it. No `permissions` here: the
/// ceiling was settled by the exchange that opened this — `attach` refuses
/// rather than returns when the sandbox comes back wider.
pub const Session = struct {
    client: Client,
    thread_id: []const u8,

    pub fn close(self: *Session, io: std.Io) void {
        self.client.close(io);
    }
};

/// What a connection attempt came back with. A failure is a SENTENCE, not an
/// error code: it ends up in a refusal the model reads.
pub const Attempt = union(enum) { ok: Session, failed: []const u8 };

// ── opening and resuming ────────────────────────────────────────────────────

/// Open a new Codex thread for a delegation. On success the thread id is the
/// delegation's `remote` — the handle every later round resumes from. The
/// connection is closed before this returns: the thread lives in Codex's own
/// session store, and the round that drives it resumes it.
pub fn open(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: OpenOptions,
) !union(enum) { ok: []const u8, failed: []const u8 } {
    var client = spawn(alloc, io, env) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "could not start '{s} app-server' ({s}). Codex must be installed and on PATH for a definition with `runner: codex`.",
            .{ executable(env), @errorName(err) },
        ) };
    };
    defer client.close(io);

    if (try handshake(alloc, io, &client)) |failure| return .{ .failed = failure };

    var params: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &params.writer };
    try jw.beginObject();
    // No `cwd`: the app-server inherits this process's working directory, which
    // is the workspace.
    try writeSandbox(&jw, opts.permissions);
    if (opts.persona.len != 0) {
        try jw.objectField("developerInstructions");
        try jw.write(opts.persona);
    }
    if (opts.model.len != 0) {
        try jw.objectField("model");
        try jw.write(opts.model);
    }
    try jw.endObject();

    const reply = try request(alloc, io, &client, "thread/start", params.writer.buffered());
    const result = switch (reply) {
        .failed => |f| return .{ .failed = try std.fmt.allocPrint(alloc, "codex refused to start a thread: {s}", .{f}) },
        .ok => |o| o,
    };
    if (try sandboxRefusal(alloc, result, opts.permissions)) |refusal| return .{ .failed = refusal };

    const thread = switch (result.get("thread") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => return .{ .failed = "codex started a thread but did not say which one (no `thread` in the reply)" },
    };
    const id = stringOf(thread, "id") orelse
        return .{ .failed = "codex started a thread but did not say which one (no `thread.id` in the reply)" };
    if (id.len == 0) return .{ .failed = "codex started a thread with an empty id" };
    return .{ .ok = try alloc.dupe(u8, id) };
}

/// Pick a delegation's thread back up for one round.
pub fn attach(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    thread_id: []const u8,
    permissions: record.Permissions,
) !Attempt {
    var client = spawn(alloc, io, env) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "could not start '{s} app-server' ({s})",
            .{ executable(env), @errorName(err) },
        ) };
    };
    // A refusal below is an ordinary return rather than an error, so this is a
    // `defer` with a flag rather than an `errdefer`: otherwise a delegation
    // refused for its sandbox would leave the app-server still running.
    var handed_over = false;
    defer if (!handed_over) client.close(io);

    if (try handshake(alloc, io, &client)) |failure| return .{ .failed = failure };

    var params: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &params.writer };
    try jw.beginObject();
    try jw.objectField("threadId");
    try jw.write(thread_id);
    // Asked for again on every round, and checked again: a resumed thread is a
    // fresh decision about what it may do, and a read-only delegation that came
    // back writable would be a ceiling that quietly stopped applying.
    try writeSandbox(&jw, permissions);
    try jw.endObject();

    const reply = try request(alloc, io, &client, "thread/resume", params.writer.buffered());
    const result = switch (reply) {
        .failed => |f| return .{ .failed = try std.fmt.allocPrint(alloc, "codex could not resume thread {s}: {s}", .{ thread_id, f }) },
        .ok => |o| o,
    };
    if (try sandboxRefusal(alloc, result, permissions)) |refusal| return .{ .failed = refusal };

    handed_over = true;
    return .{ .ok = .{ .client = client, .thread_id = thread_id } };
}

/// Codex's own word for each of the three: a straight translation, because the
/// harness already draws the line in the same three places. `danger-full-access`
/// is reached by writing `unsafe`, never by omission.
fn sandboxWord(permissions: record.Permissions) []const u8 {
    return switch (permissions) {
        .readonly => "read-only",
        .default => "workspace-write",
        .unsafe => "danger-full-access",
    };
}

fn writeSandbox(jw: *std.json.Stringify, permissions: record.Permissions) !void {
    try jw.objectField("sandbox");
    try jw.write(sandboxWord(permissions));
    // Nobody is at the keyboard: a background task cannot answer an approval
    // request, and a turn that blocks on one hangs until the task is killed.
    try jw.objectField("approvalPolicy");
    try jw.write("never");
}

/// The fail-closed half: `thread/start` and `thread/resume` both report the
/// policy they applied, so a read-only delegation is CONFIRMED rather than hoped
/// for. Only `readonly` is checked — the other two are not ceilings, and a
/// narrower sandbox than asked is a disappointment, not a breach.
fn sandboxRefusal(alloc: std.mem.Allocator, result: std.json.ObjectMap, permissions: record.Permissions) !?[]const u8 {
    if (!permissions.isReadonly()) return null;
    const applied: ?[]const u8 = switch (result.get("sandbox") orelse std.json.Value{ .null = {} }) {
        .object => |o| stringOf(o, "type"),
        .string => |s| s,
        else => null,
    };
    const word = applied orelse return try std.fmt.allocPrint(
        alloc,
        "this agent is read-only, and codex did not say which sandbox it applied — so the ceiling cannot be confirmed. Refusing rather than running it wider than it asked for.",
        .{},
    );
    if (std.mem.eql(u8, word, "readOnly")) return null;
    return try std.fmt.allocPrint(
        alloc,
        "this agent is read-only, but codex applied the '{s}' sandbox instead of a read-only one. Refusing rather than running it wider than it asked for.",
        .{word},
    );
}

// ── driving one round ───────────────────────────────────────────────────────

/// One turn, read to the end (or cut short by an interrupt).
pub const RoundResult = struct {
    /// The last thing the agent said this round — the report.
    text: []const u8 = "",
    /// The turn's own word for how it ended (`completed` / `interrupted` /
    /// `failed`), for a report with nothing else to say.
    stopped: []const u8 = "",
    /// Why the round could not run at all. Non-empty means "stop looping".
    failure: []const u8 = "",
    interrupted: bool = false,
};

/// Take everything waiting for this delegation and answer it. Codex has no inbox
/// of its own, so `<d>/inbox/` is drained here, between notification lines.
///
/// AN INTERRUPT IS NEVER STEERED, whichever way it is noticed — steering a
/// message and then cutting the turn down delivers it into an answer about to be
/// thrown away, so it must stay where it is until a round that will answer it.
///
/// Checked TWICE, because the fact arrives by two routes: the marker before the
/// drain (①), and the message's own envelope (②). ② is the load-bearing one here
/// — the marker is a separate file written just after the message, so a drain
/// landing in that gap sees a message that looks ordinary, and only the envelope
/// is atomic with the text.
pub fn driveRound(
    alloc: std.mem.Allocator,
    io: std.Io,
    sess: *Session,
    base: std.Io.Dir,
    delegation: []const u8,
    interrupt_path: []const u8,
) !RoundResult {
    var out: RoundResult = .{};

    // How far into the inbox this round has already offered. Peeking does not
    // consume and this arm peeks on every pass of the read loop, so without a
    // cursor the same message would be steered into the same turn over and over.
    //
    // A number rather than a set of names, which is what the mailbox's publish
    // order buys: a message arriving during this round has a number past
    // everything already seen.
    var cursor: usize = 0;
    // The ones the harness confirmed, dropped when the round is over and NOT
    // before:
    //
    //   * an ack is a delivery receipt, and a round that ends badly should not
    //     have been handing them out as it went;
    //   * a name freed mid-round can be HANDED OUT AGAIN — `scanForPut` takes one
    //     past the highest present, so acking the message that started the turn
    //     empties the directory and the next message lands on that same number,
    //     behind the cursor and therefore never offered at all.
    var confirmed: std.ArrayList([]const u8) = .empty;
    defer for (confirmed.items) |name| mailbox.ack(alloc, io, base, delegation, name);

    const first = try mailbox.peekAfter(alloc, io, base, delegation, cursor);
    if (first.len == 0) {
        // Not a failure and not a report: the caller's pending check decides
        // whether to go round again.
        out.stopped = "idle";
        return out;
    }

    var params: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &params.writer };
    try jw.beginObject();
    try jw.objectField("threadId");
    try jw.write(sess.thread_id);
    try jw.objectField("input");
    try jw.beginArray();
    // The envelope says nothing here: a message that asked to interrupt has
    // nothing to interrupt when it is the one STARTING the turn.
    for (first) |entry| {
        try writeTextInput(&jw, entry.msg.text);
        cursor = entry.seq;
    }
    try jw.endArray();
    try jw.endObject();

    const reply = try request(alloc, io, &sess.client, "turn/start", params.writer.buffered());
    const result = switch (reply) {
        .failed => |f| {
            // Nothing acked: a turn that never started did not take them, so
            // they wait for the next round.
            out.failure = try std.fmt.allocPrint(alloc, "codex refused the turn: {s}", .{f});
            return out;
        },
        .ok => |o| o,
    };
    // The turn has them: delivered, and dropped when this round is done.
    for (first) |entry| try confirmed.append(alloc, entry.name);
    const turn_id = blk: {
        const turn = switch (result.get("turn") orelse std.json.Value{ .null = {} }) {
            .object => |o| o,
            else => break :blk "",
        };
        break :blk stringOf(turn, "id") orelse "";
    };
    if (turn_id.len == 0) {
        out.failure = "codex started a turn but did not say which one (no `turn.id` in the reply)";
        return out;
    }
    const turn = try alloc.dupe(u8, turn_id);

    // Steers whose reply has not come back yet. A steered message is still in the
    // inbox — nothing is taken there — so the reply only decides whether it is
    // ever ACKED: confirmed goes on the list above, refused (the turn ended under
    // it) is left untouched for the next round. Each is tracked until its reply
    // lands, because that reply is the only thing that tells the two apart.
    var steered: std.ArrayList(Steered) = .empty;

    while (true) {
        // ① The interrupt marker, before anything else could do with a message.
        if (mailbox.takeInterruptAt(io, base, interrupt_path)) {
            try interrupt(alloc, io, &sess.client, sess.thread_id, turn);
            out.interrupted = true;
            // Read on until the turn actually ends, so the connection closes with
            // nothing half-said on it and any steer in flight is settled.
            try drainToEnd(alloc, io, &sess.client, &steered, &confirmed);
            return out;
        }
        // ② Anything that arrived while this turn has been running goes INTO it —
        // that is what `turn/steer` is for. Unless it was sent AS an interrupt:
        // the same decision as ①, here as well because the two facts arrive by
        // two routes. Whichever gets here first, leave it untouched and stop.
        const batch = try mailbox.peekAfter(alloc, io, base, delegation, cursor);
        for (batch) |entry| {
            if (entry.msg.interrupt) {
                // It and everything queued behind it stay exactly where they
                // are — nothing was taken, so the next round finds them in the
                // order they were sent.
                try interrupt(alloc, io, &sess.client, sess.thread_id, turn);
                out.interrupted = true;
                try drainToEnd(alloc, io, &sess.client, &steered, &confirmed);
                return out;
            }
            const sid = try steer(alloc, io, &sess.client, sess.thread_id, turn, entry.msg.text);
            try steered.append(alloc, .{ .id = sid, .name = entry.name });
            cursor = entry.seq;
        }

        const msg = (try next(alloc, &sess.client)) orelse {
            out.failure = "codex closed the connection before the turn finished";
            return out;
        };
        switch (msg) {
            // A reply to `turn/steer`. Confirmed means the message may be acked
            // when the round ends; refused means the turn ended under it, so it
            // is left in the inbox for the next round.
            .response => |r| {
                try settleSteer(alloc, &steered, &confirmed, r);
                continue;
            },
            .server_request => |req| {
                // Codex is asking US something — an approval, an elicitation.
                // With `approvalPolicy: "never"` this should not happen, but an
                // unanswered request stalls the turn for ever, so every one gets
                // an answer and the answer is no.
                try declineRequest(alloc, io, &sess.client, req.id);
                continue;
            },
            .notification => |note| {
                const note_params = note.params orelse continue;
                if (std.mem.eql(u8, note.method, "item/completed")) {
                    if (agentMessage(note_params)) |text| out.text = try alloc.dupe(u8, text);
                    continue;
                }
                if (std.mem.eql(u8, note.method, "turn/completed")) {
                    out.stopped = try alloc.dupe(u8, turnStatus(note_params));
                    // Steers still unanswered are messages in limbo: returning
                    // now would let a refusal after this line lose one unheard.
                    try settleOutstanding(alloc, io, &sess.client, &steered, &confirmed);
                    return out;
                }
                if (std.mem.eql(u8, note.method, "error")) {
                    // A turn-level error Codex will not retry ends the round; one
                    // it will retry is noise on the way.
                    if (willRetry(note_params)) continue;
                    out.failure = try std.fmt.allocPrint(alloc, "codex reported an error: {s}", .{errorMessage(note_params)});
                    return out;
                }
                continue;
            },
        }
    }
}

fn writeTextInput(jw: *std.json.Stringify, text: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("text");
    try jw.objectField("text");
    try jw.write(text);
    try jw.endObject();
}

fn steer(
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *Client,
    thread_id: []const u8,
    turn_id: []const u8,
    text: []const u8,
) !i64 {
    var params: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &params.writer };
    try jw.beginObject();
    try jw.objectField("threadId");
    try jw.write(thread_id);
    // The precondition Codex requires: a steer is for THIS turn, and one aimed at
    // a turn that has already ended is refused rather than silently becoming a
    // new one. The reply is not waited for here — the read loop settles it.
    try jw.objectField("expectedTurnId");
    try jw.write(turn_id);
    try jw.objectField("input");
    try jw.beginArray();
    try writeTextInput(&jw, text);
    try jw.endArray();
    try jw.endObject();
    return try send(alloc, io, client, "turn/steer", params.writer.buffered());
}

/// A steer whose reply has not come back yet, and the inbox name it is for.
const Steered = struct { id: i64, name: []const u8 };

/// Match a reply to an outstanding steer. Confirmed means the turn took it, so it
/// is acked; a refusal — the turn ended under it — leaves it in `<d>/inbox/` in
/// its original place, where the next round finds it.
fn settleSteer(
    alloc: std.mem.Allocator,
    steered: *std.ArrayList(Steered),
    confirmed: *std.ArrayList([]const u8),
    r: anytype,
) !void {
    for (steered.items, 0..) |s, i| {
        if (s.id != r.id) continue;
        if (r.failure == null) try confirmed.append(alloc, s.name);
        _ = steered.swapRemove(i);
        return;
    }
}

fn interrupt(alloc: std.mem.Allocator, io: std.Io, client: *Client, thread_id: []const u8, turn_id: []const u8) !void {
    var params: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &params.writer };
    try jw.beginObject();
    try jw.objectField("threadId");
    try jw.write(thread_id);
    try jw.objectField("turnId");
    try jw.write(turn_id);
    try jw.endObject();
    _ = try send(alloc, io, client, "turn/interrupt", params.writer.buffered());
}

/// Read until the turn ends, answering anything that would otherwise stall it.
/// Called after an interrupt: the round's answer is already decided, and this
/// only leaves the connection in a state nobody is waiting on.
///
/// Steer replies are settled here rather than discarded: an unsettled steer costs
/// a message delivered twice, and the reply is what tells "confirmed" from
/// "refused".
fn drainToEnd(
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *Client,
    steered: *std.ArrayList(Steered),
    confirmed: *std.ArrayList([]const u8),
) !void {
    while (try next(alloc, client)) |msg| {
        switch (msg) {
            .server_request => |req| try declineRequest(alloc, io, client, req.id),
            .notification => |note| {
                if (std.mem.eql(u8, note.method, "turn/completed")) break;
            },
            .response => |r| try settleSteer(alloc, steered, confirmed, r),
        }
    }
    try settleOutstanding(alloc, io, client, steered, confirmed);
}

/// Read on until no steer is still waiting for its reply. Every JSON-RPC request
/// gets exactly one reply, so waiting for it is the only way to know whether the
/// message was taken.
fn settleOutstanding(
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *Client,
    steered: *std.ArrayList(Steered),
    confirmed: *std.ArrayList([]const u8),
) !void {
    while (steered.items.len != 0) {
        const more = (try next(alloc, client)) orelse break;
        switch (more) {
            .response => |r| try settleSteer(alloc, steered, confirmed, r),
            .server_request => |req| try declineRequest(alloc, io, client, req.id),
            .notification => {},
        }
    }
}

fn declineRequest(alloc: std.mem.Allocator, io: std.Io, client: *Client, id: i64) !void {
    // A JSON-RPC error is the one reply valid for every request there is: this
    // client answers no question Codex could ask, and saying so beats guessing at
    // a result shape per method.
    var line: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &line.writer };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(-32601);
    try jw.objectField("message");
    try jw.write("this codex thread is driven by a background task with nobody to ask");
    try jw.endObject();
    try jw.endObject();
    try line.writer.writeByte('\n');
    try writeLine(io, client, line.writer.buffered());
}

fn agentMessage(params: std.json.ObjectMap) ?[]const u8 {
    const item = switch (params.get("item") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => return null,
    };
    const kind = stringOf(item, "type") orelse return null;
    if (!std.mem.eql(u8, kind, "agentMessage")) return null;
    const text = stringOf(item, "text") orelse return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn turnStatus(params: std.json.ObjectMap) []const u8 {
    const turn = switch (params.get("turn") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => return "",
    };
    return stringOf(turn, "status") orelse "";
}

fn willRetry(params: std.json.ObjectMap) bool {
    return switch (params.get("willRetry") orelse std.json.Value{ .null = {} }) {
        .bool => |b| b,
        else => false,
    };
}

fn errorMessage(params: std.json.ObjectMap) []const u8 {
    const err = switch (params.get("error") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => return "no detail",
    };
    return stringOf(err, "message") orelse "no detail";
}

// ── the connection ──────────────────────────────────────────────────────────

pub const Client = struct {
    child: std.process.Child,
    buf: []u8,
    reader: std.Io.File.Reader,
    write_buf: [4096]u8 = undefined,
    next_id: i64 = 1,

    pub fn close(self: *Client, io: std.Io) void {
        // Closing stdin is how a well-behaved app-server is told to stop; the
        // kill makes sure a round leaves no process behind when it is not.
        if (self.child.stdin) |stdin| {
            var f = stdin;
            f.close(io);
            self.child.stdin = null;
        }
        self.child.kill(io);
    }
};

fn spawn(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Client {
    var child = try std.process.spawn(io, .{
        .argv = &.{ executable(env), "app-server" },
        .stdin = .pipe,
        .stdout = .pipe,
        // Dropped rather than captured: a pipe nobody drains is a process that
        // blocks once it fills.
        .stderr = .ignore,
    });
    errdefer child.kill(io);
    const buf = try alloc.alloc(u8, max_line_bytes);
    return .{
        .child = child,
        .buf = buf,
        .reader = child.stdout.?.readerStreaming(io, buf),
    };
}

/// `initialize` and the `initialized` notification that follows it. Codex
/// answers nothing else until both have happened.
fn handshake(alloc: std.mem.Allocator, io: std.Io, client: *Client) !?[]const u8 {
    var params: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &params.writer };
    try jw.beginObject();
    try jw.objectField("clientInfo");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write("nulya");
    try jw.objectField("version");
    try jw.write("1");
    try jw.endObject();
    try jw.endObject();

    const reply = try request(alloc, io, client, "initialize", params.writer.buffered());
    switch (reply) {
        .failed => |f| return try std.fmt.allocPrint(alloc, "codex refused the handshake: {s}", .{f}),
        .ok => {},
    }
    try writeLine(io, client, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}\n");
    return null;
}

pub const Reply = union(enum) { ok: std.json.ObjectMap, failed: []const u8 };

/// Send a request and read until its reply, answering anything that would stall
/// the connection. Notifications are dropped: the three callers all happen
/// before any turn.
fn request(alloc: std.mem.Allocator, io: std.Io, client: *Client, method: []const u8, params: []const u8) !Reply {
    const id = try send(alloc, io, client, method, params);
    while (try next(alloc, client)) |msg| {
        switch (msg) {
            .response => |r| {
                if (r.id != id) continue;
                if (r.failure) |f| return .{ .failed = f };
                return .{ .ok = r.result orelse return .{ .failed = try std.fmt.allocPrint(
                    alloc,
                    "codex answered {s} with something that is not an object",
                    .{method},
                ) } };
            },
            .server_request => |req| try declineRequest(alloc, io, client, req.id),
            .notification => {},
        }
    }
    return .{ .failed = try std.fmt.allocPrint(alloc, "codex closed the connection without answering {s}", .{method}) };
}

/// Every method name here is a literal from this file, and every `params` was
/// built by `std.json.Stringify`, so the line is assembled rather than encoded.
fn send(alloc: std.mem.Allocator, io: std.Io, client: *Client, method: []const u8, params: []const u8) !i64 {
    const id = client.next_id;
    client.next_id += 1;
    const line = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n",
        .{ id, method, params },
    );
    try writeLine(io, client, line);
    return id;
}

fn writeLine(io: std.Io, client: *Client, line: []const u8) !void {
    const stdin = client.child.stdin orelse return error.ConnectionClosed;
    var writer = stdin.writerStreaming(io, &client.write_buf);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
}

pub const Message = union(enum) {
    /// `result` is null for a reply that carried an error, and for one whose
    /// result was not an object — nothing here reads a scalar result.
    response: struct { id: i64, result: ?std.json.ObjectMap, failure: ?[]const u8 },
    notification: struct { method: []const u8, params: ?std.json.ObjectMap },
    server_request: struct { id: i64, method: []const u8 },
};

/// One message off the wire, or null when the connection ended.
///
/// The server omits `jsonrpc` on its replies, so the shape is read from what is
/// present: `method` with `id` is a request TO us, `method` alone is a
/// notification, and anything else with an `id` is a reply.
fn next(alloc: std.mem.Allocator, client: *Client) !?Message {
    while (true) {
        const line = client.reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            // Longer than we will hold: step over it rather than stop reading.
            // Giving up would stop draining a pipe Codex is still writing into,
            // and then it blocks on stdout while we wait for a turn that has
            // already ended.
            error.StreamTooLong => {
                _ = client.reader.interface.discardDelimiterInclusive('\n') catch return null;
                continue;
            },
            else => return null,
        } orelse return null;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch continue;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const id: ?i64 = switch (obj.get("id") orelse std.json.Value{ .null = {} }) {
            .integer => |i| i,
            else => null,
        };
        if (stringOf(obj, "method")) |method| {
            if (id) |n| return .{ .server_request = .{ .id = n, .method = try alloc.dupe(u8, method) } };
            const params: ?std.json.ObjectMap = switch (obj.get("params") orelse std.json.Value{ .null = {} }) {
                .object => |o| o,
                else => null,
            };
            return .{ .notification = .{ .method = try alloc.dupe(u8, method), .params = params } };
        }
        const n = id orelse continue;
        if (obj.get("error")) |e| {
            if (e == .object) {
                return .{ .response = .{
                    .id = n,
                    .result = null,
                    .failure = try alloc.dupe(u8, stringOf(e.object, "message") orelse "no detail"),
                } };
            }
        }
        const result: ?std.json.ObjectMap = switch (obj.get("result") orelse std.json.Value{ .null = {} }) {
            .object => |o| o,
            else => null,
        };
        return .{ .response = .{ .id = n, .result = result, .failure = null } };
    }
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
