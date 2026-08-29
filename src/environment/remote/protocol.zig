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
//!     {"op":"hello","v":1,"nulya":"<build version>"}
//!     {"op":"run-shell","cwd":"<dir>","timeout_ms":N|null,"max_output_bytes":N,"bytes":L}
//!                                                       payload: the command
//!     {"op":"list-dir","path":"<dir>"}
//!     {"op":"cancel"}
//!
//! agent → host
//!     {"ok":true,"v":1,"nulya":…,"os":…,"arch":…,"home":…,"cwd":…,"dialect":…}
//!     {"ok":true,"exit_code":N,"timed_out":B,"canceled":B,"bytes":L,"out":M}
//!                                     payload: stdout ++ stderr, `out` long and
//!                                     `bytes - out` long respectively
//!     {"ok":true,"entries":[{"name":"…","dir":B},…]}
//!     {"ok":false,"message":"…"}
//!
//! `run-extension`, `put-file` and `start-task` are named in `Op` and answered
//! `ok:false` with a sentence saying which phase implements them. They are in
//! the vocabulary and not in this build on purpose: a host talking to a newer
//! agent, or the reverse, gets a sentence rather than "unknown op".
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

const std = @import("std");

/// The protocol this build speaks. Bumped when a frame changes meaning — never
/// to add a verb, which rule 4 covers by answering `ok:false` for one it does
/// not implement.
pub const version: u32 = 1;

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
    /// `run-shell`: the directory to run in, as the AGENT's machine spells it.
    /// `"."` means that machine's workspace, which is where the agent was
    /// started — the host never translates a path (goals/remote-env.md §3.3).
    cwd: []const u8 = "",
    /// `list-dir`.
    path: []const u8 = "",
    /// `run-shell`: the agent's own wall-clock budget for the command.
    timeout_ms: ?u32 = null,
    /// `run-shell`: the runner-level capture cap, applied on the agent side so
    /// an enormous output never crosses the channel at all.
    max_output_bytes: usize = 0,
    /// Payload length, in octets, following this header's newline.
    bytes: usize = 0,
};

/// One directory entry, as `list-dir` answers it. Exact rather than parsed out
/// of an `ls`: a file name may contain a newline, and a directory browser needs
/// the kind anyway.
pub const Entry = struct {
    name: []const u8,
    dir: bool = false,
};

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
    /// Payload length: stdout followed by stderr.
    bytes: usize = 0,
    /// How many of `bytes` are stdout; the remainder is stderr.
    out: usize = 0,
    /// `list-dir`.
    entries: []const Entry = &.{},
};

const json_opts: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = true };

/// Encode a header line, newline included. The caller writes the payload (if
/// any) straight after it.
///
/// Framing safety is not a convention here, it is a property of the encoder:
/// `std.json` escapes a newline inside any string, so no field value — a
/// command's text, a path, a diagnostic — can end the header line early. The
/// unit test below pins that rather than trusting it.
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

test "unknown verbs stay in the vocabulary instead of becoming errors" {
    // Every named verb parses back to itself…
    for ([_]Op{ .hello, .run_shell, .list_dir, .cancel, .run_extension, .put_file, .start_task }) |op| {
        try std.testing.expectEqual(op, Op.parse(op.wire()));
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
