//! The Codex runner: a delegation held by a Codex thread.
//!
//! **The protocol, as this machine reports it** (`codex app-server`, verified
//! against `codex app-server generate-json-schema` and a live handshake —
//! contract §6). Newline-delimited JSON-RPC over the child's stdio; the server
//! omits the `jsonrpc` member on its replies, so a reader must key on the
//! members that are there rather than on the version tag:
//!
//!   `{"id":N,"method":…,"params":…}`  a request (either direction)
//!   `{"id":N,"result":…}` / `{"error":…,"id":N}`   the reply to one
//!   `{"method":…,"params":…}`         a notification (no reply)
//!
//! The five verbs a runner needs are all there:
//!
//!   `initialize {clientInfo}`   once per connection, then the `initialized`
//!                               notification. Nothing else is answered before.
//!   `thread/start {…}`          opens a conversation → `result.thread.id`.
//!   `thread/resume {threadId}`  picks that conversation back up in a later
//!                               process — which is what makes a delegation
//!                               survive between rounds without a daemon.
//!   `turn/start {threadId, input:[{type:"text",text}]}` → `result.turn.id`,
//!                               then a stream of notifications ending in
//!                               `turn/completed`.
//!   `turn/steer {threadId, expectedTurnId, input}`      another message INTO
//!                               the turn already running (D3's send, at this
//!                               harness's own granularity).
//!   `turn/interrupt {threadId, turnId}`                 D6's stop.
//!
//! **Why a process per round rather than a daemon.** A delegation's rounds are
//! separate background tasks (`runner.zig`), so nothing survives between them
//! anyway; `thread/resume` is the harness's own answer to that, and a resident
//! app-server would be a second lifetime to manage on top of the lease that
//! already decides who is driving. One connection is opened when a round starts
//! and closed when it ends.
//!
//! **readonly is fail-closed (D10).** `thread/start` and `thread/resume` both
//! take `sandbox` and both ECHO the policy they actually applied. A read-only
//! delegation asks for `read-only` and then CHECKS the answer: anything else and
//! the delegation is refused rather than run wider than it said. A claim a
//! harness did not confirm is worth nothing, and the whole point of the flag is
//! that the sub-agent cannot exceed it.

const std = @import("std");
const record = @import("record.zig");
const mailbox = @import("mailbox.zig");

/// Which binary to talk to. `codex` on PATH is the answer on a real machine;
/// the variable exists so a test can point at one that answers the protocol
/// without a network (the same shape as `NULYA_EXE` — a harness names the exact
/// executable rather than trusting a search path).
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
    /// The persona, verbatim. It rides as `developerInstructions` rather than
    /// `baseInstructions`: the latter REPLACES Codex's own operating prompt —
    /// the part that tells it how its tools work — so a persona sent that way
    /// would silently cost the agent its harness. `developerInstructions` is the
    /// client's own instruction channel, which is exactly what a persona is.
    persona: []const u8,
    /// Whatever the definition or the call said to run on, in Codex's own
    /// vocabulary (D9). Empty leaves Codex's configured default alone. Opaque
    /// here on purpose: a model id is a fact about that harness, and a parser
    /// on this side could only ever be a second, staler copy of its catalogue.
    model: []const u8 = "",
    /// How much this delegation may do, in the one vocabulary every arm reads
    /// (`record.Permissions`). Codex has a word for each of the three, which is
    /// why the sandbox below is a straight translation rather than a choice.
    permissions: record.Permissions = record.default_permissions,
};

/// A connection with a thread on the other end of it. There is no `permissions`
/// here: the ceiling was settled by the exchange that opened this (`attach`
/// refuses rather than returns when the sandbox comes back wider), so carrying
/// the word on would be a second copy of an answer already given.
pub const Session = struct {
    client: Client,
    thread_id: []const u8,

    pub fn close(self: *Session, io: std.Io) void {
        self.client.close(io);
    }
};

/// What a connection attempt came back with. A failure is a SENTENCE, not an
/// error code: it ends up in a refusal the model reads, or in the report of a
/// round that could not run.
pub const Attempt = union(enum) { ok: Session, failed: []const u8 };

// ── opening and resuming ────────────────────────────────────────────────────

/// Open a new Codex thread for a delegation. On success the thread id is the
/// delegation's `remote` — the handle every later round resumes from.
///
/// The connection is closed before this returns: the thread lives on disk in
/// Codex's own session store, and the round that drives it will resume it.
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
    // is the workspace (DESIGN §7.6). Naming it here would be a second answer
    // to a question the spawn already answered.
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
    // Every way out of here but the last one leaves no session behind, and a
    // refusal below is an ordinary return rather than an error — so this is a
    // `defer` with a flag rather than an `errdefer`, or a delegation refused for
    // its sandbox would leave the app-server it refused still running.
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

/// Codex's own word for each of the three (contract ar-h). A straight
/// translation, and the reason this arm needs no judgement of its own: the
/// harness already draws the line in the same three places.
///
/// `workspace-write` is Codex's posture for a non-interactive run and the
/// honest reading of "an agent working in this checkout"; `danger-full-access`
/// is what a definition asks for by writing `unsafe` and never by omission.
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
    // request, and a turn that blocks on one would hang until the task is
    // killed. Refusing is the answer a person would not be there to give.
    try jw.objectField("approvalPolicy");
    try jw.write("never");
}

/// The fail-closed half of D10: `thread/start` and `thread/resume` both report
/// the policy they applied, so a read-only delegation can be CONFIRMED rather
/// than hoped for.
///
/// Only `readonly` is checked. The other two are not ceilings — a Codex that
/// applied something NARROWER than asked has made the delegation less capable,
/// which is a disappointment and not a breach, and refusing it would turn a
/// harness's own caution into a failure.
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

/// One turn, read to the end (or cut short by an interrupt). The same five facts
/// `runner.zig` collects from a nulya round, in this harness's words.
pub const RoundResult = struct {
    /// The last thing the agent said this round — the report.
    text: []const u8 = "",
    /// The turn's own word for how it ended (`completed` / `interrupted` /
    /// `failed`), for a report that has nothing else to say.
    stopped: []const u8 = "",
    /// Why the round could not run at all. Non-empty means "stop looping".
    failure: []const u8 = "",
    interrupted: bool = false,
};

/// Take everything waiting for this delegation and answer it.
///
/// The message channel is `<d>/inbox/` (D5): Codex has no inbox of its own, so
/// the drain happens here, at the granularity this protocol gives — between
/// notification lines, which a turn produces constantly.
///
/// **An interrupt is never steered, whichever way it is noticed.** Steering with
/// a message and then cutting the turn down delivers it into an answer that is
/// about to be thrown away, so the message must stay where it is until a round
/// that will actually answer it.
///
/// This is checked TWICE because the fact arrives by two routes. The marker is
/// checked before the drain (①), and the message itself says how it was sent
/// (②) — and the second one is not belt and braces, it is the load-bearing one
/// on this arm. The marker is a separate file written just after the message, so
/// a drain landing in that gap sees a message that looks ordinary; only the
/// envelope is atomic with the text (`mailbox.Message`). Every other arm takes
/// its one message at the start of a round and never drains a running turn, so
/// the marker alone is enough there.
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
    // consume (`mailbox.peekAfter`) and this arm peeks again on every pass of
    // the read loop, so without a cursor the same message would be steered into
    // the same turn over and over — and every pass would re-read and re-parse
    // every file still waiting, once per streamed notification.
    //
    // A number rather than a set of names, and that is what rule 1 of the
    // mailbox buys: senders publish under a lock, so a message that arrives
    // during this round has a number past everything already seen.
    var cursor: usize = 0;
    // The ones the harness confirmed, dropped when the round is over and NOT
    // before. Two reasons, and the second one is not optional:
    //
    //   * an ack is a delivery receipt, and a round that ends badly should not
    //     have been handing them out as it went;
    //   * a name that is freed mid-round can be HANDED OUT AGAIN. `nextFree`
    //     takes one past the highest number present, so acking the message that
    //     started the turn empties the directory and the next message sent lands
    //     on that same number — behind the cursor, and therefore never offered
    //     at all. That is a message silently held back until the next round, and
    //     it is exactly what it looked like: a mid-turn message arriving as a
    //     fresh `turn/start` instead of a `turn/steer`.
    var confirmed: std.ArrayList([]const u8) = .empty;
    defer for (confirmed.items) |name| mailbox.ack(alloc, io, base, delegation, name);

    const first = try mailbox.peekAfter(alloc, io, base, delegation, cursor);
    if (first.len == 0) {
        // Nothing to answer. Not a failure and not a report: the caller's
        // pending check decides whether to go round again.
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
    // nothing to interrupt when it is the one STARTING the turn. (`driveOnce`
    // clears a stale marker before each round for the same reason.)
    for (first) |entry| {
        try writeTextInput(&jw, entry.msg.text);
        cursor = entry.seq;
    }
    try jw.endArray();
    try jw.endObject();

    const reply = try request(alloc, io, &sess.client, "turn/start", params.writer.buffered());
    const result = switch (reply) {
        .failed => |f| {
            // Nothing acked: a turn that never started did not take them, and
            // they wait for the next round rather than disappearing with this
            // one.
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

    // Steers whose reply has not come back yet. A steered message was TAKEN
    // from the inbox, and a steer aimed at a turn that has just ended is
    // refused — the one way a delivered message could vanish. So every steer
    // is tracked until its reply lands, and a refusal puts the message back
    // in the inbox for the next round (the wake invariant, D4, held on this
    // side too).
    var steered: std.ArrayList(Steered) = .empty;

    while (true) {
        // ① The interrupt marker, before anything else this round could do with
        // a message. See the note on this function.
        if (mailbox.takeInterruptAt(io, base, interrupt_path)) {
            try interrupt(alloc, io, &sess.client, sess.thread_id, turn);
            out.interrupted = true;
            // Read on until the turn actually ends, so the connection is closed
            // with nothing half-said on it — and so that any steer still in
            // flight is settled rather than abandoned.
            try drainToEnd(alloc, io, &sess.client, &steered, &confirmed);
            return out;
        }
        // ② Anything that arrived while this turn has been running goes INTO
        // it. That is what `turn/steer` is for, and it is the same act as
        // typing while the main conversation is answering (D3).
        //
        // Unless it was sent AS an interrupt. This is the same decision as ①
        // and it is here as well because the two facts arrive by two routes:
        // the marker is a separate file written just after the message, so this
        // arm — the only one that drains a running turn — can reach the message
        // first and steer it into a turn that is about to be cut down. Whoever
        // gets here first, the answer is the same: put it back untouched and
        // stop the turn (`mailbox.Message`).
        const batch = try mailbox.peekAfter(alloc, io, base, delegation, cursor);
        for (batch) |entry| {
            if (entry.msg.interrupt) {
                // It and everything queued behind it stay exactly where they
                // are — nothing was taken, so there is nothing to give back, and
                // the next round finds them in the order they were sent (D4).
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
            // A reply to `turn/steer`. Confirmed is done with; refused means
            // the turn ended under the message, and it goes BACK to the inbox
            // so the next round answers it rather than nobody.
            .response => |r| {
                try settleSteer(alloc, &steered, &confirmed, r);
                continue;
            },
            .server_request => |req| {
                // Codex is asking US something — an approval, an elicitation.
                // With `approvalPolicy: "never"` this should not happen, but an
                // unanswered request stalls the turn for ever, so every one gets
                // an answer, and the answer is no. A background task has nobody
                // to ask.
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
                    // now would let a refusal after this line lose the message
                    // unheard.
                    try settleOutstanding(alloc, io, &sess.client, &steered, &confirmed);
                    return out;
                }
                if (std.mem.eql(u8, note.method, "error")) {
                    // A turn-level error that Codex will not retry ends the
                    // round; one it will retry is just noise on the way.
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
    // The precondition Codex requires: a steer is for THIS turn, and one aimed
    // at a turn that has already ended is refused rather than silently becoming
    // a new one. The reply is not waited for here — the read loop settles it
    // (`settleSteer`), and a refusal re-queues the message for the next round.
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

/// Match a reply to an outstanding steer. Confirmed means the turn took it, so
/// it is acked; a refusal — the turn ended under it — leaves it in `<d>/inbox/`,
/// where the pending check and the next round find it, in its original place.
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
/// only makes sure the connection is left in a state nobody is waiting on.
///
/// **And that every steer is settled.** This used to discard replies (`.response
/// => {}`), which quietly lost a message: back when a steered message had been
/// TAKEN from the inbox, a refusal was the only thing that put it back. Peeking
/// makes that failure impossible rather than handled — an unsettled steer now
/// costs a message being delivered twice, never a message gone. Reading the
/// replies is still what tells the two apart, so it stays.
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

/// Read on until no steer is still waiting for its reply. A message in limbo is
/// a message that is neither in the inbox nor certainly delivered, and every
/// JSON-RPC request gets exactly one reply — so the only way to know which it
/// was is to wait for it.
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
    // A JSON-RPC error is the one reply that is valid for every request there
    // is: this client answers no question Codex could ask, and saying so is
    // better than guessing at a result shape per method.
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
        // kill is what makes sure a round does not leave a process behind when
        // it does not.
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
        // Dropped rather than captured: Codex's diagnostics are its own, and a
        // pipe nobody drains is a process that blocks once it fills.
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
/// the connection on the way. Notifications passed on the way are dropped: the
/// three calls that use this (`initialize`, `thread/start`, `thread/resume`)
/// happen before any turn, so nothing interesting can arrive during them.
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
/// built by `std.json.Stringify` — so the line is assembled directly rather than
/// re-encoded.
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
    /// result was not an object — nothing here reads a scalar result, and
    /// "there was no object" is the honest way to say so.
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
            // Giving up here would stop draining a pipe Codex is still writing
            // into, and then it blocks on stdout while we wait for a turn that
            // has already ended.
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
