//! `compact` — compaction as a driver, outside the kernel.
//!
//! Nulya has no "replace the history" verb and will not grow one: a ledger only
//! appends, and nothing may rewrite what the model has already seen. So
//! compaction is not an edit but a **fork** — ask the session to summarise
//! itself, open a new session file whose header points back at the old one, and
//! carry the summary over as its first turn. The old file stays on disk, whole
//! (DESIGN §11, PLAN §3.4).
//!
//! Two things follow, and they shape the whole procedure:
//!
//!  1. **The summary is produced INSIDE the old session.** Compaction fires
//!     exactly when the cached prefix is at its largest, so asking the old
//!     session to summarise itself is one nearly-free cache-hit request. A
//!     fresh sub-session would re-send the entire transcript as uncached input
//!     — paying full price for the very thing being compacted. The cost is that
//!     the request and its summary become two real events in the old ledger,
//!     which is honest: that file now records why it ended.
//!
//!  2. **Nothing here is a kernel concept.** `session append`, `session step`
//!     and `session new --parent` already exist; this is a procedure over them
//!     (PLAN §3.6), and the kernel neither knows nor cares that a compaction
//!     happened. When to compact is policy, what to keep is the model's
//!     judgement — neither belongs in the kernel (physics #8).
//!
//! **Why compiled Zig rather than a shell script.** A driver has to PARSE what
//! `nulya session step` prints: JSONL ledger events. `sh` has no JSON reader
//! (jq is not guaranteed), Windows has neither jq nor a guaranteed python, and
//! PowerShell/sh would mean two implementations of the same procedure. Zig with
//! `std.json` is the zero-dependency choice that runs identically on every host
//! nulya builds for — precisely the case PLAN §0.1 #3 keeps open for compiled
//! extensions ("Zig is the optimisation for when measurement calls for it").
//! Scripts remain the default for extensions that only wrap a command.
//!
//! The procedure, in seven steps (see `compact`):
//!   1. find the harness (`NULYA_EXE`, set by the kernel for its children);
//!   2. `session append` the compaction request into the OLD session;
//!   3. `session step` it, and read the ledger lines it prints;
//!   4. no summary → nothing moves, the old session is still the live one;
//!   5. `session new --parent <old>:<seq>` — the fork;
//!   6. `session append` the summary into the new session;
//!   7. report `{session, parent, summary_bytes}`.
//!
//! Wall clock: the host kills an extension call at `tool.Timeouts.extension_ms`
//! (30s, DESIGN §7.3), and steps 2-3 wait for a real model. A slow provider will
//! therefore hit that ceiling; when it does, nothing has moved except the two
//! appended turns in the old ledger, and the compaction can simply be asked for
//! again.

const std = @import("std");

/// The two marker lines. They are a convention between drivers and front ends —
/// the kernel stores both turns as ordinary `user_text` — so that a transcript
/// can fold the machinery and a summary nobody typed does not look typed.
/// `tui/src/compact.ts` mirrors these two strings; THIS file is their source.
pub const request_marker = "<nulya:compact-request>";
pub const summary_marker = "<nulya:context-summary>";

/// The continuation brief, frozen with the version (`src/**` rides into the
/// package, so the prompt and the code that sends it are one artifact).
const prompt_body = @embedFile("compact_prompt.md");

/// A focus supplements the required sections and never replaces them, or
/// "focus on the API design" would quietly drop the file list.
const focus_intro = "\nAdditional focus the user asked for (this supplements, and never replaces, the sections above):\n";
const prompt_closing = "\nAnswer with the summary text and nothing else — do not call any tool.";

/// Capture cap for a child's stdout/stderr. A step's output carries whole tool
/// results, so this is generous; it exists only so a runaway child cannot eat
/// the machine.
const max_child_output: usize = 4 << 20;

/// How much of a failing child's stderr is quoted back to the caller.
const max_detail_bytes: usize = 400;

const Fail = struct { code: i64, message: []const u8 };

const Done = struct {
    session: []const u8,
    parent_session: []const u8,
    parent_seq: u64,
    summary_bytes: usize,
};

/// What the tool answers with: a result, or a JSON-RPC error. Host faults (out
/// of memory, an unspawnable child) surface as Zig errors and are folded into a
/// `-32000` by `main`, so every path still writes exactly one response.
const Outcome = union(enum) { done: Done, failed: Fail };

const Args = struct {
    session: []const u8,
    /// Empty means no extra emphasis.
    focus: []const u8 = "",
    /// Steps the summarising run may take, clamped to 1..3.
    max_steps: u32 = 1,
};

/// `std.process.Init` rather than a bare `main()`, and that is load-bearing:
/// the io it hands over carries the REAL process environment, so the children
/// spawned below inherit it. A hand-rolled `std.Io.Threaded.init(gpa, .{})`
/// defaults its environ to empty and would silently spawn `nulya session step`
/// with no environment at all — no API key, no HOME, no PATH. That failure mode
/// is invisible until a real provider refuses to run.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: this process exists to make a handful of
    // child calls and print one line, so individual frees would be noise.
    const alloc = init.arena.allocator();

    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const request = try reader.interface.allocRemaining(alloc, .limited(1 << 20));

    // The host sends a string id and requires it back unchanged (DESIGN §7.3).
    var call_id: []const u8 = "call";
    var outcome: Outcome = .{ .failed = .{
        .code = -32600,
        .message = "compact expects one JSON-RPC tool/call request on stdin",
    } };

    if (std.json.parseFromSlice(std.json.Value, alloc, request, .{})) |parsed| {
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (stringField(obj, "id")) |id| call_id = id;
            if (readArgs(obj)) |args| {
                outcome = compact(alloc, io, init.environ_map, args) catch |err| Outcome{ .failed = .{
                    .code = -32000,
                    .message = try std.fmt.allocPrint(alloc, "compact could not run: {s}", .{@errorName(err)}),
                } };
            } else {
                outcome = .{ .failed = .{
                    .code = -32602,
                    .message = "compact needs {\"session\":\"<id>\"} (optional: \"focus\", \"max_steps\")",
                } };
            }
        }
    } else |_| {}

    try writeResponse(alloc, io, call_id, outcome);
}

/// The whole procedure. Every early return leaves the conversation exactly where
/// it was: the summary is obtained before anything moves, because a compaction
/// that half-happened is a conversation thrown away.
fn compact(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: Args) !Outcome {
    // 1. Where is the harness? Not `nulya` on PATH — the binary that matters is
    //    the one running this session, and it put its own path here for exactly
    //    this.
    const exe = env.get("NULYA_EXE") orelse return Outcome{ .failed = .{
        .code = -32000,
        .message = "compact needs NULYA_EXE (the nulya kernel sets it for its children)",
    } };

    // 2. Ask the old session for the brief. It goes in as a plain user turn,
    //    marked so a front end can fold it — the kernel sees nothing special.
    const focus_block = if (args.focus.len == 0)
        ""
    else
        try std.fmt.allocPrint(alloc, "{s}{s}\n", .{ focus_intro, args.focus });
    const request_text = try std.fmt.allocPrint(
        alloc,
        "{s}\n{s}{s}{s}",
        .{ request_marker, prompt_body, focus_block, prompt_closing },
    );
    const asked = try runNulya(alloc, io, exe, &.{ "session", "append", args.session, request_text });
    if (asked.code != 0) {
        return failf(alloc, -32000, "cannot append the compaction request to {s}: {s}", .{ args.session, detail(asked) });
    }

    // 3. Step the OLD session, on its own cached prefix, and read what it wrote.
    const budget = try std.fmt.allocPrint(alloc, "{d}", .{args.max_steps});
    const stepped = try runNulya(alloc, io, exe, &.{ "session", "step", args.session, "--max-steps", budget });
    if (stepped.code != 0) {
        return failf(alloc, -32000, "the summarising step failed: {s}", .{detail(stepped)});
    }

    // 4. No brief is a legitimate outcome, not an accident to paper over: a
    //    cancelled step, or a model that answered with tool calls, leaves the
    //    window exactly as full as it was. The two turns from steps 2-3 stay in
    //    the old ledger — that file records why the attempt happened.
    const found = (try harvest(alloc, stepped.stdout)) orelse return Outcome{ .failed = .{
        .code = -32001,
        .message = "no summary came back; nothing moved — the old session is still the live one",
    } };

    // 5. The fork. The kernel checks the parent exists and carries its frozen
    //    model identity over (a compaction must not change who the conversation
    //    is with); composition is resolved fresh, because a new session is
    //    exactly where new pins and newly activated versions take hold
    //    (DESIGN §11) — so no `--with` / `--pin` here.
    const parent_ref = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ args.session, found.seq });
    const forked = try runNulya(alloc, io, exe, &.{ "session", "new", "--parent", parent_ref });
    const new_id = std.mem.trim(u8, forked.stdout, " \t\r\n");
    if (forked.code != 0 or !std.mem.startsWith(u8, new_id, "s-")) {
        return failf(alloc, -32000, "cannot open the continuing session: {s}", .{detail(forked)});
    }

    // 6. Carry the brief over. It is deposited, not stepped: it waits in the new
    //    session's inbox exactly like a turn typed before a step runs.
    const carried = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ summary_marker, found.summary });
    const handed = try runNulya(alloc, io, exe, &.{ "session", "append", new_id, carried });
    if (handed.code != 0) {
        return failf(alloc, -32000, "{s} was created but the summary could not be carried into it: {s}", .{ new_id, detail(handed) });
    }

    // 7. The caller decides what to do with the new session; this tool only
    //    reports what it did.
    return .{ .done = .{
        .session = new_id,
        .parent_session = args.session,
        .parent_seq = found.seq,
        .summary_bytes = found.summary.len,
    } };
}

const Harvest = struct { summary: []const u8, seq: u64 };

/// Read a `session step` stdout (one ledger event per line, DESIGN §14) and pull
/// out the brief plus the sequence number to fork at.
///
/// The brief is every assistant text that came after the request line, joined.
/// An assistant turn carrying tool calls means the model did NOT answer with the
/// summary it was asked for, and a partial brief is worse than none — so that is
/// reported as absence. Anything unparseable is ignored rather than fatal: the
/// stream is the kernel's, and a line shape this build does not know is not a
/// reason to lose a conversation.
fn harvest(alloc: std.mem.Allocator, stdout: []const u8) !?Harvest {
    var parts: std.ArrayList([]const u8) = .empty;
    var seq: u64 = 0;
    var seen_request = false;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        if (obj.get("seq")) |s| switch (s) {
            .integer => |n| if (n > 0 and @as(u64, @intCast(n)) > seq) {
                seq = @intCast(n);
            },
            else => {},
        };
        const kind = stringField(obj, "kind") orelse continue;

        if (std.mem.eql(u8, kind, "user_text")) {
            const text = stringField(obj, "text") orelse continue;
            if (std.mem.startsWith(u8, text, request_marker)) seen_request = true;
            continue;
        }
        if (!seen_request or !std.mem.eql(u8, kind, "assistant")) continue;
        if (obj.get("calls")) |calls| switch (calls) {
            .array => |a| if (a.items.len != 0) return null,
            else => {},
        };
        const text = std.mem.trim(u8, stringField(obj, "text") orelse "", " \t\r\n");
        if (text.len != 0) try parts.append(alloc, text);
    }

    if (!seen_request or parts.items.len == 0) return null;
    const summary = std.mem.trim(u8, try std.mem.join(alloc, "\n", parts.items), " \t\r\n");
    if (summary.len == 0) return null;
    return .{ .summary = summary, .seq = seq };
}

const Run = struct { code: u8, stdout: []u8, stderr: []u8 };

/// One `nulya <args…>` invocation, in this process's working directory — which
/// is the workspace, because that is where the host spawns an extension
/// (DESIGN §7.6). Output is captured, never inherited: stdout here is data.
fn runNulya(alloc: std.mem.Allocator, io: std.Io, exe: []const u8, tail: []const []const u8) !Run {
    const argv = try alloc.alloc([]const u8, tail.len + 1);
    argv[0] = exe;
    @memcpy(argv[1..], tail);

    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_child_output),
        .stderr_limit = .limited(max_child_output),
    });
    return .{
        .code = switch (result.term) {
            .exited => |c| c,
            else => 1,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// What a failed child said, trimmed to something quotable. stderr first (that
/// is where the CLI writes diagnostics), stdout as the fallback.
fn detail(run: Run) []const u8 {
    const err = std.mem.trim(u8, run.stderr, " \t\r\n");
    const said = if (err.len != 0) err else std.mem.trim(u8, run.stdout, " \t\r\n");
    if (said.len == 0) return "no output";
    return said[said.len -| max_detail_bytes..];
}

fn failf(alloc: std.mem.Allocator, code: i64, comptime fmt: []const u8, fmt_args: anytype) !Outcome {
    return .{ .failed = .{ .code = code, .message = try std.fmt.allocPrint(alloc, fmt, fmt_args) } };
}

/// `params.arguments` of a `tool/call`, or null when it does not name a session.
fn readArgs(request: std.json.ObjectMap) ?Args {
    const params = switch (request.get("params") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const arguments = switch (params.get("arguments") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const session = stringField(arguments, "session") orelse return null;
    if (session.len == 0) return null;

    var args: Args = .{ .session = session };
    if (stringField(arguments, "focus")) |focus| args.focus = std.mem.trim(u8, focus, " \t\r\n");
    // A budget the caller cannot blow up with: the request says "answer, do not
    // call tools", so more than a few steps means the model is doing something
    // else entirely.
    if (arguments.get("max_steps")) |value| switch (value) {
        .integer => |n| args.max_steps = @intCast(std.math.clamp(n, 1, 3)),
        else => {},
    };
    return args;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// One JSON-RPC response on stdout, then exit — the whole runtime contract.
fn writeResponse(alloc: std.mem.Allocator, io: std.Io, call_id: []const u8, outcome: Outcome) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try jw.write(call_id);
    switch (outcome) {
        .done => |done| {
            try jw.objectField("result");
            try jw.beginObject();
            try jw.objectField("session");
            try jw.write(done.session);
            try jw.objectField("parent");
            try jw.beginObject();
            try jw.objectField("session");
            try jw.write(done.parent_session);
            try jw.objectField("seq");
            try jw.write(done.parent_seq);
            try jw.endObject();
            try jw.objectField("summary_bytes");
            try jw.write(done.summary_bytes);
            try jw.endObject();
        },
        .failed => |failed| {
            try jw.objectField("error");
            try jw.beginObject();
            try jw.objectField("code");
            try jw.write(failed.code);
            try jw.objectField("message");
            try jw.write(failed.message);
            try jw.endObject();
        },
    }
    try jw.endObject();

    try std.Io.File.stdout().writeStreamingAll(io, out.writer.buffered());
}
