//! `handoff` — the model's own end-of-phase signal, outside the kernel.
//!
//! **What it is.** One tool. The model calls it when a phase of work is really
//! finished and the rest of the job no longer needs this phase's process detail:
//! it hands over four sections (`done` / `next_task` / `keep` / `drop?`), this
//! extension checks them, writes them to `.nulya/handoffs/<session>-<n>.md`, and
//! answers "recorded — end this turn now". It does NOT fork. Forking is
//! `extensions/compact` (DESIGN §11), and `session new --parent` stays called
//! from exactly one place in this repository.
//!
//! **Why a tool and not a text convention.** A model "announcing" a handoff in
//! prose is a signal a driver can only guess at — forgotten, buried mid-answer,
//! wrapped in a code fence, and the driver is left doing regex archaeology. A
//! tool call is structured, is validated (a brief missing a section comes back
//! as an error the model can fix), and carries its own instructions: the tool
//! description is in front of the model for the whole session, so the rule
//! "call it once, at a phase boundary, then stop" needs no extra prompting.
//! Landing it here rather than as a third builtin is the same discipline: nulya
//! has no "std tool" layer, and a tool that is always in front of every model
//! costs a `max_tools` slot and prefix tokens in sessions that will never use it
//! (PLAN §3.4.1). It ships with the repo, DEFAULT-OFF, and a driver that wants
//! it says so — `session new --with handoff@<v> --pin ext:handoff/handoff`.
//!
//! **How a driver consumes it.** The file on disk IS the proposal. A driver
//! (`drivers/goal.sh` / `drivers/goal.ps1`, PLAN §3.6) steps the session, then
//! looks for a new `.nulya/handoffs/<id>-*.md`; if one appeared it calls
//! `compact --arg session=<id> --arg brief_file=<that file>` — the fork path
//! that leaves the old session byte-identical — and continues in the child. The
//! model proposes, the driver decides (physics #3): nothing here opens, steps or
//! forks a session.
//!
//! **Why compiled Zig rather than a script.** Identical to `extensions/compact`:
//! the tool receives a JSON-RPC request, must echo its `id` back, and has to
//! validate four sections. `sh` has no JSON reader (jq is not guaranteed),
//! Windows has neither jq nor a guaranteed python, and one manifest carries one
//! `interpreter` — so a repo-shipped script tool would mean a `.ps1` and a `.sh`
//! implementation of the same tool that could never share one version id. PLAN
//! §0.1 #3 keeps compiled Zig open for exactly this.

const std = @import("std");

/// Where the proposals land. Relative to the workspace, which is this process's
/// cwd (DESIGN §7.6), and the one path this extension's manifest asks to write.
const handoff_dir = ".nulya/handoffs";

/// The answer on the happy path. The model has just been told the phase is
/// recorded; anything else it does in this turn is work the NEXT session was
/// supposed to do with a clean context.
const end_turn_message = "handoff recorded — do not call any more tools; end this turn now.";

/// A brief this long is a transcript, not a handover.
const max_section_bytes: usize = 64 << 10;

/// Upper bound on `<session>-<n>.md` before giving up. A session that has handed
/// off a thousand times is not making progress.
const max_handoffs_per_session: usize = 1000;

const Fail = struct { code: i64, message: []const u8 };

const Done = struct { recorded: []const u8 };

/// What the tool answers with: a result, or a JSON-RPC error. Host faults (out
/// of memory, an unwritable workspace) surface as Zig errors and are folded into
/// a `-32000` by `main`, so every path still writes exactly one response.
const Outcome = union(enum) { done: Done, failed: Fail };

/// The brief, already trimmed. The three required sections are validated as a
/// group so a model that forgot two of them is told about both at once.
const Brief = struct {
    done: []const u8 = "",
    next_task: []const u8 = "",
    keep: []const u8 = "",
    drop: []const u8 = "",
};

/// `std.process.Init` rather than a bare `main()`: the io it hands over carries
/// the real process environment, which is where `NULYA_SESSION` lives.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: this process validates a brief, writes one
    // file and prints one line, so individual frees would be noise.
    const alloc = init.arena.allocator();

    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const request = try reader.interface.allocRemaining(alloc, .limited(1 << 20));

    // The host sends a string id and requires it back unchanged (DESIGN §7.3).
    var call_id: []const u8 = "call";
    var outcome: Outcome = .{ .failed = .{
        .code = -32600,
        .message = "handoff expects one JSON-RPC tool/call request on stdin",
    } };

    if (std.json.parseFromSlice(std.json.Value, alloc, request, .{})) |parsed| {
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (stringField(obj, "id")) |id| call_id = id;
            outcome = record(alloc, io, init.environ_map, readBrief(obj)) catch |err| Outcome{ .failed = .{
                .code = -32000,
                .message = try std.fmt.allocPrint(alloc, "handoff could not run: {s}", .{@errorName(err)}),
            } };
        }
    } else |_| {}

    try writeResponse(alloc, io, call_id, outcome);
}

/// Validate, then write. Every refusal happens BEFORE anything is written: a
/// rejected brief must leave no file, or a driver watching the directory would
/// fork on a handoff the model was told to redo.
fn record(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, brief: Brief) !Outcome {
    if (try missingSections(alloc, brief)) |message| {
        return .{ .failed = .{ .code = -32602, .message = message } };
    }

    // Which session is this? `session step` puts the live session's file path in
    // the environment of everything it runs (DESIGN §5.3), and the stem is the
    // id. Without it there is nobody to hand off FROM: the driver would have no
    // way to tell whose proposal this file is, and the model would have been
    // told "recorded" for a phase boundary that does not exist.
    const session_path = env.get("NULYA_SESSION") orelse return Outcome{ .failed = .{
        .code = -32000,
        .message = "handoff must be called from inside a session (NULYA_SESSION is not set)",
    } };
    const session_id = std.fs.path.stem(session_path);
    if (session_id.len == 0) return Outcome{ .failed = .{
        .code = -32000,
        .message = "handoff must be called from inside a session (NULYA_SESSION names no session file)",
    } };

    const body = try render(alloc, session_id, brief);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, handoff_dir);

    // `<session>-<n>.md`, taking the first free n. Exclusive creation is the
    // check: it is monotonic within a session, never overwrites an earlier
    // proposal, and two processes racing cannot land on the same name.
    var n: usize = 1;
    while (n <= max_handoffs_per_session) : (n += 1) {
        const rel = try std.fmt.allocPrint(alloc, "{s}/{s}-{d}.md", .{ handoff_dir, session_id, n });
        const file = cwd.createFile(io, rel, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        defer file.close(io);
        try file.writeStreamingAll(io, body);
        return .{ .done = .{ .recorded = rel } };
    }
    return .{ .failed = .{
        .code = -32000,
        .message = "this session has already recorded too many handoffs",
    } };
}

/// The message naming every required section that is missing, or null when the
/// brief is complete. Naming all of them at once means one retry, not three.
fn missingSections(alloc: std.mem.Allocator, brief: Brief) !?[]const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    if (brief.done.len == 0) try missing.append(alloc, "done");
    if (brief.next_task.len == 0) try missing.append(alloc, "next_task");
    if (brief.keep.len == 0) try missing.append(alloc, "keep");
    if (missing.items.len == 0) return null;

    const names = try std.mem.join(alloc, ", ", missing.items);
    return try std.fmt.allocPrint(
        alloc,
        "handoff needs a non-empty {s}; nothing was recorded. " ++
            "done = what this phase concluded (what was built, which files changed, what was decided); " ++
            "next_task = what the next phase must do and what counts as finished; " ++
            "keep = the facts it must carry over verbatim (paths, symbols, commands, ids, test results). " ++
            "drop is optional.",
        .{names},
    );
}

/// The proposal as a human-readable file. It is the driver's signal AND the
/// brief the next session will start from, so it is markdown, not JSON.
fn render(alloc: std.mem.Allocator, session_id: []const u8, brief: Brief) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.print("# Handoff\n\nsession: {s}\n\n", .{session_id});
    try w.print("## Done\n\n{s}\n\n", .{brief.done});
    try w.print("## Next task\n\n{s}\n\n", .{brief.next_task});
    try w.print("## Keep\n\n{s}\n", .{brief.keep});
    if (brief.drop.len != 0) try w.print("\n## Dropped\n\n{s}\n", .{brief.drop});
    return out.toOwnedSlice();
}

/// `params.arguments` of a `tool/call`. A request without them yields an empty
/// brief, which `missingSections` then reports section by section — the same
/// message a half-filled brief gets, because to the model it is the same mistake.
fn readBrief(request: std.json.ObjectMap) Brief {
    const params = switch (request.get("params") orelse return .{}) {
        .object => |o| o,
        else => return .{},
    };
    const arguments = switch (params.get("arguments") orelse return .{}) {
        .object => |o| o,
        else => return .{},
    };
    return .{
        .done = section(arguments, "done"),
        .next_task = section(arguments, "next_task"),
        .keep = section(arguments, "keep"),
        .drop = section(arguments, "drop"),
    };
}

/// One section, trimmed and capped. Whitespace-only is empty: a model that sent
/// `"done": "  "` did not answer the question.
fn section(arguments: std.json.ObjectMap, key: []const u8) []const u8 {
    const raw = stringField(arguments, key) orelse return "";
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return trimmed[0..@min(trimmed.len, max_section_bytes)];
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
            try jw.objectField("recorded");
            try jw.write(done.recorded);
            try jw.objectField("message");
            try jw.write(end_turn_message);
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
