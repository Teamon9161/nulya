//! The remote channel's frame protocol — what the host and a `nulya remote
//! serve` on the other machine say to each other (DESIGN §8.1,
//! `docs/goals/remote-env.md` §3.4).
//!
//! The contract is stated here, at the top of the module that implements it, so
//! `nulya src environment/remote/protocol.zig` prints the rules AND the code
//! that keeps them — the `extension/protocol.zig` precedent, and the reason
//! there is no second document to drift from.
//!
//! ── The frame ───────────────────────────────────────────────────────────────
//!
//!     <header-line>\n[<payload>]
//!
//! The header is ONE line of compact JSON with no embedded newline. When it
//! names a positive `bytes`, exactly that many raw octets follow it, and the
//! next frame begins immediately after them.
//!
//! The header is JSON because a captured channel should be readable by a human.
//! The payload is RAW because it carries arbitrary bytes — a command, a
//! command's stdout — and a JSON string cannot: `std.json.Stringify` writes
//! invalid UTF-8 as an array of numbers, which is exactly how a session file
//! once stopped being a session file (BUGS #22). Length-prefixed bytes are
//! exact for every byte sequence, and cost no encoding.
//!
//! ── The verbs ───────────────────────────────────────────────────────────────
//!
//! host → agent
//!     {"op":"hello","v":2,"nulya":"<build version>"}
//!     {"op":"run-shell","cwd":"<dir>","timeout_ms":N|null,"max_output_bytes":N,"bytes":L}
//!                                                       payload: the command
//!     {"op":"run-extension","id":…,"version":…,"tool":…,"cwd":…,"timeout_ms":…,
//!                          "max_output_bytes":N,"bytes":L}
//!                                                       payload: the arguments JSON
//!     {"op":"put-file","cwd":"<dir>","path":"<workspace-relative>","bytes":L}
//!                                                       payload: the file's bytes
//!     {"op":"list-dir","path":"<dir>"}
//!     {"op":"cancel"}
//!     {"op":"store-stat","id":"<ext id>","version":"v-<hash>"}
//!     {"op":"store-put","path":"<version-relative>","exec":B,"bytes":L}
//!                                                       payload: the file's bytes
//!     {"op":"store-commit"}
//!     {"op":"start-task","task":"<sid>/t<N>","cwd":…,"timeout_ms":N|null,"bytes":L}
//!                                                       payload: the command
//!     {"op":"task-poll","task":"<sid>/t<N>","cwd":…}
//!     {"op":"task-kill","task":"<sid>/t<N>","cwd":…}
//!
//! agent → host
//!     {"ok":true,"v":2,"nulya":…,"os":…,"arch":…,"home":…,"cwd":…,"dialect":…}
//!     {"ok":true,"exit_code":N,"timed_out":B,"canceled":B,"bytes":L,"out":M}
//!                                     payload: stdout ++ stderr, `out` long and
//!                                     `bytes - out` long respectively
//!     {"ok":true,"bytes":L,"message":"<note>"}
//!                                     payload: [{"name":"…","dir":B},…] — the
//!                                     directory listing, as JSON (`encodeEntries`)
//!     {"ok":true}                     put-file wrote it / the task was started
//!                                     / the kill marker is down
//!     {"ok":true,"held":B}            store-stat: whether that machine's user
//!                                     store already holds that version, sealed
//!     {"ok":true,"bytes":L}           task-poll: `TaskSnapshot`, as JSON
//!     {"ok":false,"message":"…"}
//!
//! ── A background task over there (goals/remote-env.md §4 Phase 4) ───────────
//!
//! `start-task` asks the agent to start `nulya task supervise` on ITS machine —
//! the same binary, the same role, the same `Tree` around the command — with the
//! log, the status and the lease all in the far workspace, beside that session's
//! spills. So a background command runs where the foreground ones do, and it
//! outlives this channel: closing the channel ends the agent, not the task.
//!
//! **A task's PATH never crosses.** The frame names `task` — `<sid>/t<N>`, the
//! full name the model already reads — and each side derives the directory from
//! it with the same function (`launch.sessionTasksDir`), against its own
//! workspace. That is why there are three task verbs rather than "write an empty
//! file at this path": a task is a name here, and the host does not spell
//! directories on another machine (goals/remote-env.md §3.3).
//!
//! **The report comes back by being FETCHED, not pushed.** There are no
//! unsolicited frames (rule 1), and the far supervisor could not deposit anyway:
//! the session file is on the host. So it leaves its report next to its log, and
//! whichever host verb next asks (`task list`, `task wait`, a `session step`)
//! turns it into the `task_finished` the session's inbox already understands.
//! The mechanism a driver sees is unchanged — an inbox event, not a second kind
//! of file to learn (CLAUDE.md's working rule).
//!
//! ── Running an extension over there (goals/remote-env.md §3.1) ──────────────
//!
//! `run-extension` names an IDENTITY — `(id, version, tool)` — and never a path.
//! The agent picks the entry variant for ITS OS, verifies that version against
//! its own seal, joins its own store root, and derives `NULYA_TOOL` /
//! `NULYA_ARG_<k>` from the very arguments JSON in the payload
//! (`extension/protocol.zig`). So there is no shell quoting anywhere on this
//! path and no argv length limit, and the host never models the far file system.
//!
//! A version that machine does not hold is `ok:false` with a sentence naming
//! `nulya ext push` — which the host turns into an ordinary FAILED CALL (exit 1
//! plus that stderr), so the model reads it and the usage journal records a
//! truthful `ok=false`, rather than the whole step failing.
//!
//! ── Pushing an extension version (`nulya ext push`, DESIGN §7.4) ────────────
//!
//! The three `store-*` verbs are one sequence, and they are three rather than
//! one because a version is a TREE and a frame carries one payload:
//!
//!     store-stat   → held:true  … nothing more to do; the hash IS the check
//!                  → held:false … the agent opens a staging directory for this
//!                                 version under `<id>/` and takes that id's
//!                                 writer lease (`Store.lease`), which it holds
//!                                 until commit or until the channel closes
//!     store-put ×N   one file each, version-relative and `/`-spelled
//!     store-commit   the agent validates the staging tree AS a version
//!                    (`.sealed`, its own bytes, its own machine) and only then
//!                    renames it into `<id>/versions/<v>`
//!
//! `store-put` and `store-commit` name no id: the agent is holding exactly one
//! open push (rule 1 — one request in flight, one channel) and inventing a
//! second place to say which one would be a second answer to drift from. What
//! makes this safe is the commit: a torn or tampered tree fails validation and
//! is deleted, so a half-copied version can never become visible under
//! `versions/`, whatever happened to the channel in the middle.
//!
//! `exec` on `store-put` says these bytes are meant to be executed — the host
//! sets it for the compiled entry under `bin/`. It exists because the bytes
//! travel as bytes: a file copy carries its mode, a payload does not, and a
//! pushed binary that arrives without the bit is a version that is there and
//! cannot run. Hosts that have no such bit ignore it.
//!
//! ── The rules ───────────────────────────────────────────────────────────────
//!
//!  1. **One request in flight.** The channel is strictly request → reply, and
//!     there is no request id because there is never a second answer to match.
//!     A concurrent channel would buy nothing: a tool batch runs serially
//!     (`loop.zig`), which is where every request comes from.
//!
//!  2. **`cancel` is the one thing the host may send while a request is in
//!     flight, and having sent it the host does not reuse the channel.** This
//!     is what lets the agent read control frames with the same single reader
//!     the main loop uses: when the agent cancels a control read because the
//!     command finished first, that read cannot have consumed a partial frame,
//!     because the host sends nothing else. A host that breaks this rule
//!     desynchronises only itself.
//!
//!  3. **Every request gets exactly one reply frame** — including a canceled
//!     one, which replies with whatever output it had captured and
//!     `canceled:true`. Answering costs nothing and a silent verb would make
//!     "the agent died" and "the agent decided not to answer" the same event.
//!
//!  4. **`hello` is the only negotiation.** It is the first frame on every
//!     channel; a `v` this build does not implement is refused with a sentence,
//!     never guessed at. There is no capability list: the verbs above are `v`.
//!
//!  5. **Nothing on this channel carries a credential.** There is no field for
//!     one, the host never forwards its environment map, and the agent builds
//!     its children's environment from ITS OWN host environment through the
//!     same `isSecretKey` denylist (physics #6, run on both machines by the
//!     same code). The remote side of a nulya session never needs an API key:
//!     the model connection stays on the host.
//!
//!  6. **Nothing that grows with what the far machine holds rides in a header.**
//!     A header is bounded (`max_header_bytes`) because the other side reads it
//!     with one delimited read into one buffer; a payload is not. So a listing,
//!     a command, a command's output and a file's bytes are all payload, and
//!     `encodeRequest` / `encodeReply` REFUSE a header over the bound rather
//!     than write a frame the peer cannot read. That refusal is the rule's
//!     enforcement, not a comment asking future verbs to remember it: a listing
//!     of a thousand 255-byte names is a quarter of a megabyte, and carrying it
//!     in the header once made a perfectly ordinary directory able to kill the
//!     channel.

const std = @import("std");

/// The protocol this build speaks. Bumped when a frame changes meaning — never
/// to add a verb, which rule 4 covers by answering `ok:false` for one it does
/// not implement.
///
/// v2: `list-dir` answers its entries as a payload instead of a header field
/// (rule 6), and `put-file` became a real verb instead of a refusal.
///
/// The three `store-*` verbs, and later the three task verbs, arrived WITHOUT a
/// bump — the rule working
/// rather than an exception to it: no existing frame changed meaning, and an
/// older agent asked for one answers the `unknown` sentence naming what it does
/// know. A push against such a machine therefore fails with a sentence about
/// that machine's build — the outcome a version number could only have produced
/// earlier and less precisely, at the cost of breaking every other verb too.
pub const version: u32 = 2;

/// The longest header line either side will read before refusing. Headers are
/// small by construction (paths and numbers; the command travels as payload),
/// so this is a guard against a peer that is not speaking this protocol at all
/// — a login banner, an ssh error page — rather than a real limit.
pub const max_header_bytes: usize = 64 * 1024;

/// The largest payload either side will accept a header's word for. A frame
/// claiming more is refused BEFORE any allocation: "the length is a lie" is the
/// one thing a hostile or broken peer can say cheaply that costs the reader
/// dearly.
pub const max_payload_bytes: usize = 64 * 1024 * 1024;

pub const Error = error{
    /// The header line is not JSON, or not an object of this shape.
    BadFrame,
    /// The header's `bytes` exceeds `max_payload_bytes`.
    PayloadTooLarge,
    /// Encoding produced a header line over `max_header_bytes` — a frame the
    /// peer could not read back (rule 6). Refused at the writer, so the bug
    /// belongs to whoever put a growing field in a header.
    HeaderTooLarge,
    /// The peer speaks a different `v` (rule 4).
    VersionMismatch,
    /// The stream ended where a frame was expected.
    ChannelClosed,
};

/// The verbs, as a closed vocabulary. `unknown` is what an unrecognised `op`
/// string becomes — kept as a value rather than an error so the agent can
/// answer it with a sentence naming what it does know.
pub const Op = enum {
    hello,
    run_shell,
    list_dir,
    cancel,
    run_extension,
    put_file,
    start_task,
    task_poll,
    task_kill,
    store_stat,
    store_put,
    store_commit,
    unknown,

    /// The wire spelling: kebab-case, because that is what a reader of a
    /// captured channel expects and Zig identifiers cannot hold a hyphen.
    pub fn wire(self: Op) []const u8 {
        return switch (self) {
            .hello => "hello",
            .run_shell => "run-shell",
            .list_dir => "list-dir",
            .cancel => "cancel",
            .run_extension => "run-extension",
            .put_file => "put-file",
            .start_task => "start-task",
            .task_poll => "task-poll",
            .task_kill => "task-kill",
            .store_stat => "store-stat",
            .store_put => "store-put",
            .store_commit => "store-commit",
            .unknown => "unknown",
        };
    }

    pub fn parse(s: []const u8) Op {
        inline for (@typeInfo(Op).@"enum".fields) |f| {
            const op: Op = @enumFromInt(f.value);
            if (op != .unknown and std.mem.eql(u8, s, op.wire())) return op;
        }
        return .unknown;
    }
};

/// One request header. A single struct rather than a union of per-verb shapes:
/// the JSON encoding IS this type (the `ledger.Header` discipline — field names
/// are wire names), and a fixed shape means neither side has to branch before
/// it can parse. Fields not meaningful for a verb are simply at their defaults.
pub const Request = struct {
    op: []const u8 = "",
    /// `hello` only.
    v: u32 = 0,
    /// `hello` only: the build version, for the diagnostic, never for a gate.
    nulya: []const u8 = "",
    /// `run-shell` and `put-file`: the session's workspace, as the AGENT's
    /// machine spells it. `"."` means that machine's workspace, which is where
    /// the agent was started — the host never translates a path
    /// (goals/remote-env.md §3.3).
    cwd: []const u8 = "",
    /// `list-dir`: the directory to list. `put-file`: the destination, relative
    /// to `cwd` and spelled with `/` — it is the very string the model reads in
    /// a spill footer, which is what makes "where it was written" and "where the
    /// model is told to look" one fact rather than two.
    path: []const u8 = "",
    /// `run-shell`: the agent's own wall-clock budget for the command.
    timeout_ms: ?u32 = null,
    /// `run-shell`: the runner-level capture cap, applied on the agent side so
    /// an enormous output never crosses the channel at all.
    max_output_bytes: usize = 0,
    /// `store-stat` and `run-extension`: which extension, and which immutable
    /// version of it. The two later verbs of a push name neither — the agent has
    /// exactly one open push, and a second spelling of "which one" is a second
    /// thing to drift.
    id: []const u8 = "",
    version: []const u8 = "",
    /// `run-extension`: the tool name that version's frozen manifest declares.
    /// It becomes `NULYA_TOOL` on the far side, derived there together with the
    /// argument variables — one implementation of that rule, two machines.
    tool: []const u8 = "",
    /// The session these commands belong to, by IDENTITY (`NULYA_SESSION_ID`,
    /// DESIGN §5.3). Never the session FILE's path: that names a file on the
    /// host, and a package over there handed one would be told a lie. The id is
    /// true on any machine, which is exactly why the two were split.
    session: []const u8 = "",
    /// The three task verbs: which background task, by its FULL name
    /// `<sid>/t<N>` — the one the model reads in its receipt. Not a directory:
    /// each side turns the name into a path with the same rule against its own
    /// workspace, so no layout of one machine is ever spelled by the other.
    task: []const u8 = "",
    /// `store-put`: these bytes are meant to be executed (the compiled entry
    /// under `bin/`). A file copy carries its mode; a payload does not.
    exec: bool = false,
    /// Payload length, in octets, following this header's newline.
    bytes: usize = 0,
};

/// One directory entry, as `list-dir` answers it. Exact rather than parsed out
/// of an `ls`: a file name may contain a newline, and a directory browser needs
/// the kind anyway.
///
/// A listing travels as PAYLOAD (rule 6). It is JSON rather than raw bytes
/// because unlike a command's output it is not arbitrary: a name that is not
/// valid UTF-8 is dropped by the writer, with a note, so what crosses is always
/// encodable — see `cli/remote.zig`.
pub const Entry = struct {
    name: []const u8,
    dir: bool = false,
};

/// Encode a listing as one payload. Caller owns the result.
pub fn encodeEntries(alloc: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(entries, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Decode one. Borrows `arena`, like every other parsed frame. An empty payload
/// is an empty listing, not a malformed one: a directory can be empty.
pub fn parseEntries(arena: std.mem.Allocator, payload: []const u8) Error![]const Entry {
    if (payload.len == 0) return &.{};
    return std.json.parseFromSliceLeaky([]const Entry, arena, payload, json_opts) catch return error.BadFrame;
}

/// What one `task-poll` answers about one background task over there: the two
/// files that machine's supervisor writes, verbatim. The host owns the meaning
/// of both — `status.json` is `cli/task.zig`'s own declaration, and the report
/// is what becomes a `task_finished` — so nothing is re-parsed on the far side
/// and there is no second definition of either.
///
/// It travels as PAYLOAD (rule 6): a report grows with the command's output.
pub const TaskSnapshot = struct {
    /// `status.json` as that supervisor wrote it, or empty when it has not
    /// written one yet — which is exactly the `starting` projection, reported
    /// rather than guessed at.
    status: []const u8 = "",
    /// The report that supervisor left when the command ended, or empty until
    /// then. Its presence is what tells the host there is something to deliver.
    report: []const u8 = "",
    /// Is a supervisor still holding this task's lease, over there? Filled by
    /// that machine's own `leaseHeldIn` (`cli/task.zig`), in the same round as
    /// `status` — the only way `lost` (a supervisor that died) is knowable
    /// without a second question per poll. Null when the peer predates this
    /// column (`ignore_unknown_fields` + a default make that safe): "unknown"
    /// is not "false", so a reader that gets null must not claim the task died.
    lease_held: ?bool = null,
};

/// Encode one. Caller owns the result.
pub fn encodeTaskSnapshot(alloc: std.mem.Allocator, snap: TaskSnapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(snap, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Decode one. Borrows `arena`, like every other parsed frame. An empty payload
/// is a task nothing is known about yet, not a malformed one.
pub fn parseTaskSnapshot(arena: std.mem.Allocator, payload: []const u8) Error!TaskSnapshot {
    if (payload.len == 0) return .{};
    return std.json.parseFromSliceLeaky(TaskSnapshot, arena, payload, json_opts) catch return error.BadFrame;
}

/// One reply header. Same discipline as `Request`.
pub const Reply = struct {
    ok: bool = false,
    /// Set exactly when `ok` is false: the sentence the host shows.
    message: []const u8 = "",
    /// `hello`.
    v: u32 = 0,
    nulya: []const u8 = "",
    os: []const u8 = "",
    arch: []const u8 = "",
    home: []const u8 = "",
    /// `hello`: the absolute directory the agent is running in — the workspace
    /// this session's commands will start from, resolved by the machine that
    /// owns it.
    cwd: []const u8 = "",
    dialect: []const u8 = "",
    /// `run-shell`.
    exit_code: u8 = 0,
    timed_out: bool = false,
    /// The command was killed because the host asked (rule 3), so the output
    /// below is partial and the exit code means nothing.
    canceled: bool = false,
    /// `store-stat`: that machine's user store already holds this exact version
    /// and it still validates against its seal. A version is content-addressed,
    /// so this is the whole of "do I need to send it" — no manifest, no
    /// timestamps, no negotiation.
    held: bool = false,
    /// Payload length: `run-shell`'s stdout followed by its stderr, or
    /// `list-dir`'s encoded entries.
    bytes: usize = 0,
    /// How many of `bytes` are stdout; the remainder is stderr.
    out: usize = 0,
};

const json_opts: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = true };

/// Encode a header line, newline included. The caller writes the payload (if
/// any) straight after it.
///
/// Framing safety is not a convention here, it is a property of the encoder:
/// `std.json` escapes a newline inside any string, so no field value — a
/// command's text, a path, a diagnostic — can end the header line early. The
/// unit test below pins that rather than trusting it.
///
/// The encoder also enforces rule 6: a line over `max_header_bytes` is refused
/// instead of written, because the reader on the other side takes a header with
/// one delimited read into a buffer exactly that big. Refusing HERE is the only
/// place the fault can still be attributed to the frame that caused it.
pub fn encodeRequest(alloc: std.mem.Allocator, req: Request) ![]u8 {
    return encodeLine(alloc, req);
}

pub fn encodeReply(alloc: std.mem.Allocator, rep: Reply) ![]u8 {
    return encodeLine(alloc, rep);
}

fn encodeLine(alloc: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeByte('\n');
    if (out.written().len > max_header_bytes) return error.HeaderTooLarge;
    return out.toOwnedSlice();
}

/// Parse a header line (without its newline). The result borrows the arena the
/// caller passes, which is how both sides already handle a parsed frame: one
/// request, one arena, reset between frames.
pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) Error!Request {
    return parseLine(Request, arena, line);
}

pub fn parseReply(arena: std.mem.Allocator, line: []const u8) Error!Reply {
    return parseLine(Reply, arena, line);
}

fn parseLine(comptime T: type, arena: std.mem.Allocator, line: []const u8) Error!T {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.BadFrame;
    const parsed = std.json.parseFromSliceLeaky(T, arena, trimmed, json_opts) catch return error.BadFrame;
    if (parsed.bytes > max_payload_bytes) return error.PayloadTooLarge;
    return parsed;
}

/// Check a `hello` answer before anything else is sent. Version first, because
/// a mismatched peer's other fields describe a protocol this build does not
/// have — and a guess there is worse than a refusal (rule 4).
pub fn checkHello(rep: Reply) Error!void {
    if (!rep.ok) return error.BadFrame;
    if (rep.v != version) return error.VersionMismatch;
}

// ── tests ───────────────────────────────────────────────────────────────────

test "a header line round-trips and never ends early, whatever a field contains" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A cwd holding the two bytes that would break framing if they went through
    // unescaped. The command itself travels as payload, but a path does not.
    const line = try encodeRequest(alloc, .{
        .op = Op.run_shell.wire(),
        .cwd = "a\nb\"c",
        .bytes = 7,
        .max_output_bytes = 1024,
    });
    defer alloc.free(line);

    // Exactly one newline, and it is the terminator: the invariant the whole
    // framing rests on.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);

    const back = try parseRequest(arena, line[0 .. line.len - 1]);
    try std.testing.expectEqual(Op.run_shell, Op.parse(back.op));
    try std.testing.expectEqualStrings("a\nb\"c", back.cwd);
    try std.testing.expectEqual(@as(usize, 7), back.bytes);
}

test "a reply round-trips its payload split and its refusal" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = try encodeReply(alloc, .{ .ok = true, .exit_code = 3, .bytes = 10, .out = 4 });
    defer alloc.free(line);
    const back = try parseReply(arena, line[0 .. line.len - 1]);
    try std.testing.expect(back.ok);
    try std.testing.expectEqual(@as(u8, 3), back.exit_code);
    // stdout is the first `out` bytes, stderr the rest — the whole split.
    try std.testing.expectEqual(@as(usize, 4), back.out);
    try std.testing.expectEqual(@as(usize, 6), back.bytes - back.out);

    const refusal = try encodeReply(alloc, .{ .ok = false, .message = "no such thing" });
    defer alloc.free(refusal);
    const bad = try parseReply(arena, refusal[0 .. refusal.len - 1]);
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings("no such thing", bad.message);
}

test "a frame that is not this protocol is refused, and a claimed length is not believed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The shapes a wrong peer actually produces: a login banner, a half-written
    // line, nothing at all.
    for ([_][]const u8{ "Welcome to Ubuntu 24.04", "{\"op\":\"run-sh", "", "   ", "[1,2,3]" }) |bad| {
        try std.testing.expectError(error.BadFrame, parseRequest(arena, bad));
    }

    // A length nobody can honour is refused before a single byte is allocated
    // for it. This is the cheapest lie a broken peer can tell.
    const huge = "{\"op\":\"run-shell\",\"bytes\":99999999999}";
    try std.testing.expectError(error.PayloadTooLarge, parseRequest(arena, huge));
}

test "a big listing travels as payload, and the header it rides behind stays readable" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The shape that broke this before entries were payload: an ordinary
    // directory, at the listing cap, with names near what a file system allows.
    // A quarter of a megabyte of names — many times the header bound.
    var entries: std.ArrayList(Entry) = .empty;
    for (0..1000) |i| {
        const name = try std.fmt.allocPrint(arena, "{d}-{s}", .{ i, "n" ** 250 });
        try entries.append(arena, .{ .name = name, .dir = i % 2 == 0 });
    }

    const payload = try encodeEntries(alloc, entries.items);
    defer alloc.free(payload);
    try std.testing.expect(payload.len > max_header_bytes);

    const line = try encodeReply(alloc, .{ .ok = true, .bytes = payload.len });
    defer alloc.free(line);
    try std.testing.expect(line.len < max_header_bytes);

    const back = try parseEntries(arena, payload);
    try std.testing.expectEqual(entries.items.len, back.len);
    try std.testing.expectEqualStrings(entries.items[0].name, back[0].name);
    try std.testing.expectEqualStrings(entries.items[999].name, back[999].name);
    try std.testing.expect(back[0].dir and !back[1].dir);

    // An empty directory is an empty listing, not a broken frame.
    try std.testing.expectEqual(@as(usize, 0), (try parseEntries(arena, "")).len);
}

test "a task snapshot carries both of that supervisor's files, and an empty one is a task nothing is known about" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The report is a multi-line text with the very characters that would end a
    // header line early; it travels as payload, and JSON escaping is what keeps
    // it whole either way.
    const snap: TaskSnapshot = .{
        .status = "{\"v\":1,\"state\":\"done\",\"exit_code\":0}",
        .report = "[background task s-1/t3 finished] echo hi · exit 0 · 0.1s\n--- output ---\nhi\n",
    };
    const payload = try encodeTaskSnapshot(alloc, snap);
    defer alloc.free(payload);
    const back = try parseTaskSnapshot(arena, payload);
    try std.testing.expectEqualStrings(snap.status, back.status);
    try std.testing.expectEqualStrings(snap.report, back.report);

    // A supervisor that has not written anything yet is not a broken frame: both
    // halves absent is the `starting` projection.
    const empty = try parseTaskSnapshot(arena, "");
    try std.testing.expectEqual(@as(usize, 0), empty.status.len);
    try std.testing.expectEqual(@as(usize, 0), empty.report.len);
}

test "a header that would outgrow the reader's buffer is refused instead of written" {
    const alloc = std.testing.allocator;
    const huge = try alloc.alloc(u8, max_header_bytes + 1);
    defer alloc.free(huge);
    @memset(huge, 'm');
    // Whoever puts a growing value in a header learns it here, at the frame that
    // caused it, rather than on the far side as a channel that went quiet.
    try std.testing.expectError(error.HeaderTooLarge, encodeReply(alloc, .{ .ok = false, .message = huge }));
    try std.testing.expectError(error.HeaderTooLarge, encodeRequest(alloc, .{ .op = Op.list_dir.wire(), .path = huge }));
}

test "unknown verbs stay in the vocabulary instead of becoming errors" {
    // Every named verb parses back to itself…
    inline for (@typeInfo(Op).@"enum".fields) |f| {
        const op: Op = @enumFromInt(f.value);
        if (op != .unknown) try std.testing.expectEqual(op, Op.parse(op.wire()));
    }
    // …and anything else is a value the agent can answer with a sentence,
    // which is what makes a newer host talking to an older agent legible.
    try std.testing.expectEqual(Op.unknown, Op.parse("teleport"));
}

test "the handshake refuses a peer speaking another version rather than guessing" {
    try checkHello(.{ .ok = true, .v = version });
    try std.testing.expectError(error.VersionMismatch, checkHello(.{ .ok = true, .v = version + 1 }));
    try std.testing.expectError(error.VersionMismatch, checkHello(.{ .ok = true, .v = 0 }));
    // A peer that refused the handshake is not a version problem.
    try std.testing.expectError(error.BadFrame, checkHello(.{ .ok = false, .message = "busy" }));
}
