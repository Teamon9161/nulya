//! `compact` — compaction as a driver, outside the kernel.
//!
//! Nulya's ledger only appends, so compaction is not an edit but a FORK: ask
//! the session to summarise itself, open a new session file whose header
//! points back at the old one, and carry the summary over as its first turn.
//! The old file stays on disk, whole. The summary is produced INSIDE the old
//! session — compaction fires when the cached prefix is largest, so this is
//! one cache-hit request rather than a fresh sub-session re-sending the whole
//! transcript uncached. Nothing here is a kernel concept: `session append`,
//! `session step` and `session new --parent` already exist, and this is a
//! procedure over them — compiled Zig rather than a script, since this driver
//! parses `nulya session step`'s JSONL events, which neither `sh` nor
//! PowerShell can do without an external JSON tool neither platform
//! guarantees. The seven-step procedure and the two fork-only shortcuts are
//! documented at `compact` and its `briefFrom*` helpers below.

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

/// Appended to every carried brief, by code. The child session inherits no
/// history, but the parent file is still whole on disk and the child has a
/// shell — so naming the parent turns "the brief lost it" into "go and read it".
const parent_footer =
    "\n\n---\nParent session: {s} (forked at seq {d}). The full transcript is still on disk — read it with: nulya session events {s}\n";

/// Capture cap for a child's stdout/stderr. A step's output carries whole tool
/// results, so this is generous; it exists only so a runaway child cannot eat
/// the machine.
const max_child_output: usize = 4 << 20;

/// How much of a failing child's stderr is quoted back to the caller.
const max_detail_bytes: usize = 400;

/// The tool whose call carries a handover brief (`extensions/handoff`). A NAME,
/// because that is all a ledger event records about a call — there is no tool id
/// on the wire — and it is the name that package has always put on the model's
/// face.
const handoff_tool = "handoff";

/// Cap per rendered section. A brief this long is a transcript, not a handover.
/// The ledger keeps the call whole either way; this bounds only what is carried
/// into the next session.
const max_section_bytes: usize = 64 << 10;

const Done = struct {
    session: []const u8,
    parent_session: []const u8,
    parent_seq: u64,
    summary_bytes: usize,
};

/// What the tool answers with: the fork it made, or the reason it made none.
/// Host faults (out of memory, an unspawnable child) surface as Zig errors and
/// are folded into a refusal by `main`, so every path still ends in exactly one
/// answer.
const Outcome = union(enum) { done: Done, failed: []const u8 };

const Args = struct {
    session: []const u8,
    /// Empty means no extra emphasis.
    focus: []const u8 = "",
    /// Steps the summarising run may take, clamped to 1..3.
    max_steps: u32 = 1,
    /// A brief the caller already has, as a path (workspace-relative or
    /// absolute). Empty means "ask the old session for one" — the seven-step
    /// path. Non-empty means fork only: the old session is never touched.
    brief_file: []const u8 = "",
    /// Take the brief from a `handoff` call already in the old session's ledger.
    /// The only word this understands is `latest`; anything else is refused by
    /// name rather than guessed at.
    brief: []const u8 = "",
    /// Which `handoff` call, by the seq of the assistant event that made it.
    /// Selects instead of `brief=latest`; it does NOT move the fork point, which
    /// is the ledger's tail either way (a child inherits no history, so the seq
    /// in its lineage records where the conversation was left, not where it was
    /// cut).
    brief_seq: ?u64 = null,

    /// Where this call wants its brief from. The three are exclusive: a caller
    /// that names two sources has not decided, and picking one for it would be
    /// forking on something it did not ask for.
    const Source = enum { file, ledger, ask };
    fn source(self: Args) ?Source {
        const from_ledger = self.brief.len != 0 or self.brief_seq != null;
        if (self.brief_file.len != 0) return if (from_ledger) null else .file;
        return if (from_ledger) .ledger else .ask;
    }
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

    // The wire is `plain`: stdin is this call's arguments as one JSON object,
    // and this package has one tool, so `NULYA_TOOL` says nothing it does not
    // already know.
    var outcome: Outcome = .{ .failed = "compact expects this call's arguments as one JSON object on stdin" };

    if (std.json.parseFromSlice(std.json.Value, alloc, request, .{})) |parsed| {
        if (parsed.value == .object) {
            if (readArgs(parsed.value.object)) |args| {
                outcome = compact(alloc, io, init.environ_map, args) catch |err| Outcome{
                    .failed = try std.fmt.allocPrint(alloc, "compact could not run: {s}", .{@errorName(err)}),
                };
            } else {
                outcome = .{ .failed = "compact needs {\"session\":\"<id>\"} (optional: \"focus\", \"max_steps\", \"brief\", \"brief_seq\", \"brief_file\")" };
            }
        }
    } else |_| {}

    try answer(alloc, io, outcome);
}

/// The whole procedure. Every early return leaves the conversation exactly where
/// it was: the summary is obtained before anything moves, because a compaction
/// that half-happened is a conversation thrown away.
fn compact(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: Args) !Outcome {
    // 1. Where is the harness? Not `nulya` on PATH — the binary that matters is
    //    the one running this session, and it put its own path here for exactly
    //    this.
    const exe = env.get("NULYA_EXE") orelse
        return Outcome{ .failed = "compact needs NULYA_EXE (the nulya kernel sets it for its children)" };

    // 1b. A caller whose brief already exists (the `/goal` driver after the
    //     model handed off) skips straight to the fork: steps 2-4 exist only to
    //     OBTAIN a brief, and running them anyway would append two turns to a
    //     file those branches promise not to touch.
    const source = args.source() orelse return Outcome{
        .failed = "compact takes the brief from one place: `brief`/`brief_seq` (the ledger's own handoff call) or `brief_file` (a file you wrote), not both",
    };
    const brief = switch (source) {
        .file => try briefFromFile(alloc, io, exe, args),
        .ledger => try briefFromLedger(alloc, io, exe, args),
        .ask => try briefFromSession(alloc, io, exe, args),
    };
    const found = switch (brief) {
        .failed => |f| return .{ .failed = f },
        .harvested => |h| h,
    };

    // 4b. Assemble what will be carried, and CHECK it — before anything moves.
    //     `session append` refuses bytes that are not valid UTF-8, and
    //     everything below is irreversible: checking after the fork would
    //     leave a child that can never receive its summary, holding the
    //     parent's tasks, with nobody reading either. So the order is render
    //     → validate → fork, and it stays that way for whatever bad bytes a
    //     future brief source brings (`brief_file` reads a file this package
    //     did not write).
    //
    //     The parent pointer is written by code (see `parent_footer`).
    const footer = try std.fmt.allocPrint(alloc, parent_footer, .{ args.session, found.seq, args.session });
    const carried = try std.fmt.allocPrint(alloc, "{s}\n{s}{s}", .{ summary_marker, found.summary, footer });
    if (!std.unicode.utf8ValidateSlice(carried)) {
        return .{ .failed = try fail(
            alloc,
            "the brief for {s} is not valid UTF-8, which `session append` refuses; nothing moved",
            .{args.session},
        ) };
    }

    // 5. The fork. The kernel checks the parent exists and carries its frozen
    //    model identity over (a compaction must not change who the conversation
    //    is with); composition is resolved fresh, because a new session is
    //    exactly where new pins and newly activated versions take hold — so
    //    no `--with` / `--pin` here.
    const parent_ref = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ args.session, found.seq });
    const forked = try runNulya(alloc, io, exe, &.{ "session", "new", "--parent", parent_ref });
    const new_id = std.mem.trim(u8, forked.stdout, " \t\r\n");
    if (forked.code != 0 or !std.mem.startsWith(u8, new_id, "s-")) {
        return .{ .failed = try fail(alloc, "cannot open the continuing session: {s}", .{detail(forked)}) };
    }

    // 5b. Background tasks the parent still has running are handed over too.
    //     A fork does NOT inherit them by itself and should not — a sub-session
    //     must not take a parent's work — but a compaction is not a branch: it
    //     is the same conversation in a new file, and a result delivered into a
    //     session nobody is reading any more is a result lost. Failing to hand
    //     one over never fails the fork; the result simply stays with the parent.
    const tasks_footer = try handOverTasks(alloc, io, exe, args.session, new_id);

    // 6. Carry the brief over. It is deposited, not stepped: it waits in the new
    //    session's inbox exactly like a turn typed before a step runs.
    //
    //    The task note is the one part assembled AFTER the fork, so it is the
    //    one part that cannot be refused on the brief's behalf: it is generated
    //    from task names and their commands and is valid by construction, and if
    //    it somehow is not, it costs a sentence rather than the summary. The
    //    retargeting has already happened either way — the note only describes it.
    const note_ok = std.unicode.utf8ValidateSlice(tasks_footer);
    if (!note_ok) try warn(alloc, io, "compact: the background-task note was not valid UTF-8 and was left out of {s}'s brief\n", .{new_id});
    const full_text = if (note_ok) try std.fmt.allocPrint(alloc, "{s}{s}", .{ carried, tasks_footer }) else carried;

    // The brief travels as a FILE, not an argv word. It is not small by
    // construction: a handoff section alone can be 64 KiB, `brief_file` reads
    // up to 4 MiB, and `tasks_footer` grows with however many tasks this
    // session had running. All of that landing on a command line risks the
    // OPERATING SYSTEM's argv length limit, not `session append`'s own, and
    // Windows's is well within reach of a legitimate brief — and hitting it
    // here would mean the child session already exists and its tasks are
    // already retargeted, but with nothing carried over. `session append
    // --file` already exists for exactly this (up to 8 MiB), so this writes
    // the brief to a scratch file this compaction owns (named after the
    // child session id, which is unique) and hands over the path instead.
    const scratch_dir = ".nulya/scratch/compact";
    try std.Io.Dir.cwd().createDirPath(io, scratch_dir);
    const brief_path = try std.fmt.allocPrint(alloc, "{s}/{s}.md", .{ scratch_dir, new_id });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = brief_path, .data = full_text });
    // The file did its one job once this scope ends, including when spawning
    // `session append` itself fails before it can return a `Run`.
    defer std.Io.Dir.cwd().deleteFile(io, brief_path) catch {};
    const handed = try runNulya(alloc, io, exe, &.{ "session", "append", new_id, "--file", brief_path });
    if (handed.code != 0) {
        return .{ .failed = try fail(alloc, "{s} was created but the summary could not be carried into it: {s}", .{ new_id, detail(handed) }) };
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

/// Retarget every task that reports into the parent to the child, and describe
/// the live ones for the carried brief. Empty when there are none — a session
/// with no background work says nothing about background work.
///
/// EVERY row, not just the running ones. The question this has to answer is
/// "which results should follow me", and a task that finished a moment ago —
/// after the fork point, before this line — has a result sitting undrained in
/// the parent's inbox: exactly the window `task retarget`'s `moveDeposit` half
/// exists for. Asking `--running` filtered that window out and lost the result
/// there, which is the same loss the whole procedure is meant to prevent. On a
/// `.done` row whose result a step already drained, `moveDeposit` finds
/// nothing to move and `task retarget` leaves the notify pointer untouched —
/// a real no-op, not merely a harmless one: writing that pointer anyway would
/// make a long-finished, already-read task follow every future compaction
/// down the fork chain forever (`cli/task.zig`'s `taskRetarget`).
///
/// The footer is still only the live ones: it promises "their results will
/// arrive here", and a task whose result has already been read is not part of
/// that promise. `state` is the kernel's own projection, so what counts as live
/// is not re-derived here.
///
/// Every failure is a warning on stderr and nothing more: the fork has already
/// happened, and a task whose delivery could not be moved still reports into the
/// parent's inbox, where it is findable — losing the whole compaction over it
/// would be the worse trade.
fn handOverTasks(alloc: std.mem.Allocator, io: std.Io, exe: []const u8, parent: []const u8, child: []const u8) ![]const u8 {
    const listed = runNulya(alloc, io, exe, &.{ "task", "list", "--session", parent, "--json" }) catch |err| {
        warn(alloc, io, "compact: could not list {s}'s background tasks: {s}\n", .{ parent, @errorName(err) }) catch {};
        return "";
    };
    if (listed.code != 0) {
        warn(alloc, io, "compact: could not list {s}'s background tasks: {s}\n", .{ parent, detail(listed) }) catch {};
        return "";
    }
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, listed.stdout, .{}) catch return "";
    if (parsed.value != .object) return "";
    const tasks = switch (parsed.value.object.get("tasks") orelse return "") {
        .array => |a| a,
        else => return "",
    };

    var moved: std.ArrayList([]const u8) = .empty;
    var first: []const u8 = "";
    var unknown: std.ArrayList([]const u8) = .empty;
    var first_unknown: []const u8 = "";
    for (tasks.items) |entry| {
        if (entry != .object) continue;
        const name = stringField(entry.object, "task") orelse continue;
        const done = runNulya(alloc, io, exe, &.{ "task", "retarget", name, "--to", child }) catch |err| {
            warn(alloc, io, "compact: {s} keeps reporting into {s}: {s}\n", .{ name, parent, @errorName(err) }) catch {};
            continue;
        };
        if (done.code != 0) {
            warn(alloc, io, "compact: {s} keeps reporting into {s}: {s}\n", .{ name, parent, detail(done) }) catch {};
            continue;
        }
        const command = stringField(entry.object, "command") orelse "";
        if (isUnreachable(entry.object)) {
            // Retargeted the same as any other row (the race this exists to
            // close does not know or care whether the far machine will ever
            // answer again), but NOT folded into the same sentence as `moved`:
            // that sentence says "still running", a claim about a machine this
            // host cannot currently reach. Saying nothing instead would drop
            // the fact that a result may still arrive.
            if (first_unknown.len == 0) first_unknown = name;
            try unknown.append(alloc, try std.fmt.allocPrint(alloc, "{s} ({s})", .{ name, command }));
            continue;
        }
        if (!isLive(entry.object)) continue;
        if (first.len == 0) first = name;
        const elapsed: ?i64 = switch (entry.object.get("elapsed_s") orelse std.json.Value{ .null = {} }) {
            .integer => |n| n,
            else => null,
        };
        try moved.append(alloc, if (elapsed) |s|
            try std.fmt.allocPrint(alloc, "{s} ({s}, {d}s so far)", .{ name, command, s })
        else
            try std.fmt.allocPrint(alloc, "{s} ({s})", .{ name, command }));
    }
    if (moved.items.len == 0 and unknown.items.len == 0) return "";

    var out: std.ArrayList(u8) = .empty;
    if (moved.items.len != 0) {
        try out.print(
            alloc,
            "\nBackground tasks still running when this session was forked: {s} — nulya task status {s}; their results will arrive here when they finish.\n",
            .{ try std.mem.join(alloc, ", ", moved.items), first },
        );
    }
    if (unknown.items.len != 0) {
        try out.print(
            alloc,
            "\nBackground tasks with unknown remote state at fork: {s} — nulya task status {s}; their machine could not be reached when this session was forked, so whether they are still running is not known, but they were retargeted here and may still report.\n",
            .{ try std.mem.join(alloc, ", ", unknown.items), first_unknown },
        );
    }
    return out.toOwnedSlice(alloc);
}

/// Is this row still expected to produce a result? The same two states
/// `task list --running` keeps (`cli/task.zig`'s `isLive`), read off the row
/// rather than re-derived: this package does not get to disagree with the kernel
/// about what a task is doing. `unreachable` is handled separately
/// (`isUnreachable`, above) rather than folded in here or dropped: nobody here
/// knows whether that machine's task is running, so it earns its own sentence
/// that says so, instead of either promise this function's two other outcomes
/// would otherwise make on its behalf.
fn isLive(row: std.json.ObjectMap) bool {
    const state = stringField(row, "state") orelse return false;
    return std.mem.eql(u8, state, "running") or std.mem.eql(u8, state, "starting");
}

fn isUnreachable(row: std.json.ObjectMap) bool {
    const state = stringField(row, "state") orelse return false;
    return std.mem.eql(u8, state, "unreachable");
}

fn warn(alloc: std.mem.Allocator, io: std.Io, comptime fmt: []const u8, fmt_args: anytype) !void {
    const line = try std.fmt.allocPrint(alloc, fmt, fmt_args);
    defer alloc.free(line);
    try std.Io.File.stderr().writeStreamingAll(io, line);
}

/// A brief, or the reason there is none. Every way of NOT getting one leaves the
/// conversation exactly where it was, so both branches answer in this shape and
/// the fork happens in one place.
const Brief = union(enum) { harvested: Harvest, failed: []const u8 };

/// The `brief_file` branch: read the brief the caller already has, and fork at
/// the old ledger's current tail. Nothing is written to the old session.
fn briefFromFile(alloc: std.mem.Allocator, io: std.Io, exe: []const u8, args: Args) !Brief {
    const raw = readFileMaybe(alloc, io, args.brief_file) catch |err| return Brief{
        .failed = try fail(alloc, "cannot read brief_file '{s}': {s}", .{ args.brief_file, @errorName(err) }),
    };
    const summary = std.mem.trim(u8, raw orelse "", " \t\r\n");
    if (summary.len == 0) {
        return .{ .failed = try fail(alloc, "brief_file '{s}' is missing or empty; nothing moved", .{args.brief_file}) };
    }

    // The fork point is where the old ledger stands right now. `session events`
    // is a read-only tail, so asking costs the old file nothing — but it is
    // the WHOLE tail, so this reads with `runNulyaScan`'s bigger cap.
    const listed = try runNulyaScan(alloc, io, exe, &.{ "session", "events", args.session });
    if (listed.code != 0) {
        return .{ .failed = try fail(alloc, "cannot read the events of {s}: {s}", .{ args.session, detail(listed) }) };
    }
    const seq = lastSeq(alloc, listed.stdout) orelse return Brief{
        .failed = try fail(alloc, "{s} has no events yet; there is nothing to fork from", .{args.session}),
    };
    return .{ .harvested = .{ .summary = summary, .seq = seq } };
}

/// One `handoff` call as the old ledger recorded it.
const HandoffCall = struct { seq: u64, call_id: []const u8, args_json: []const u8 };

/// The ledger branch: the model already handed off, so the brief is the
/// arguments of that call. Nothing is written to the old session.
///
/// **Only a call the kernel ACCEPTED counts.** A `handoff` whose result came
/// back `ok=false` was refused — an incomplete brief the model was told to redo,
/// or a call a gate denied — and forking on it would carry over the very brief
/// somebody said no to. That check is the matching `tool_results` entry, not a
/// re-validation of the sections here: the package that owns the rule already
/// answered, and its answer is in the ledger.
fn briefFromLedger(alloc: std.mem.Allocator, io: std.Io, exe: []const u8, args: Args) !Brief {
    if (args.brief.len != 0 and !std.mem.eql(u8, args.brief, "latest")) {
        return .{ .failed = try fail(alloc, "brief '{s}' is not a word compact knows; the only one is `latest` (or name one call with brief_seq)", .{args.brief}) };
    }

    // `session events` is a read-only tail, so asking costs the old file
    // nothing — but it is the WHOLE tail, so this reads with `runNulyaScan`'s
    // bigger cap.
    const listed = try runNulyaScan(alloc, io, exe, &.{ "session", "events", args.session });
    if (listed.code != 0) {
        return .{ .failed = try fail(alloc, "cannot read the events of {s}: {s}", .{ args.session, detail(listed) }) };
    }

    var calls: std.ArrayList(HandoffCall) = .empty;
    var accepted: std.ArrayList([]const u8) = .empty;
    var tail: u64 = 0;

    // Read the same forgiving way `harvest` does: these are the kernel's own
    // lines, and a shape this build does not know is not a reason to lose a
    // conversation.
    var lines = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const seq: u64 = switch (obj.get("seq") orelse std.json.Value{ .null = {} }) {
            .integer => |n| if (n > 0) @intCast(n) else 0,
            else => 0,
        };
        if (seq > tail) tail = seq;
        const kind = stringField(obj, "kind") orelse continue;

        if (std.mem.eql(u8, kind, "assistant")) {
            const list = switch (obj.get("calls") orelse continue) {
                .array => |a| a,
                else => continue,
            };
            for (list.items) |entry| {
                if (entry != .object) continue;
                const tool = stringField(entry.object, "tool") orelse continue;
                if (!std.mem.eql(u8, tool, handoff_tool)) continue;
                try calls.append(alloc, .{
                    .seq = seq,
                    .call_id = stringField(entry.object, "id") orelse "",
                    .args_json = stringField(entry.object, "args") orelse "",
                });
            }
            continue;
        }
        if (!std.mem.eql(u8, kind, "tool_results")) continue;
        const results = switch (obj.get("results") orelse continue) {
            .array => |a| a,
            else => continue,
        };
        for (results.items) |entry| {
            if (entry != .object) continue;
            const ok = switch (entry.object.get("ok") orelse std.json.Value{ .null = {} }) {
                .bool => |b| b,
                else => false,
            };
            if (!ok) continue;
            try accepted.append(alloc, stringField(entry.object, "call_id") orelse continue);
        }
    }

    if (tail == 0) {
        return .{ .failed = try fail(alloc, "{s} has no events yet; there is nothing to fork from", .{args.session}) };
    }

    var chosen: ?HandoffCall = null;
    var seen_at_seq = false;
    for (calls.items) |call| {
        if (args.brief_seq) |want| {
            if (call.seq != want) continue;
            seen_at_seq = true;
        }
        if (!contains(accepted.items, call.call_id)) continue;
        chosen = call; // the last one wins: `latest` means the most recent
    }
    const call = chosen orelse {
        if (args.brief_seq) |want| return Brief{ .failed = if (seen_at_seq)
            try fail(alloc, "the {s} call at seq {d} of {s} was not accepted — the brief was incomplete or the call was denied; nothing moved", .{ handoff_tool, want, args.session })
        else
            try fail(alloc, "seq {d} of {s} is not an accepted {s} call; nothing moved", .{ want, args.session, handoff_tool }) };
        return Brief{ .failed = try fail(
            alloc,
            "{s} has no accepted {s} call to fork on; nothing moved. The brief is the call's own arguments, so there is one only after the model has handed off — compose the package with `session new --with handoff@<v>`, or pass brief_file if you wrote a brief yourself",
            .{ args.session, handoff_tool },
        ) };
    };

    const rendered = renderHandoff(alloc, args.session, call.args_json) catch |err| return Brief{
        .failed = try fail(alloc, "the {s} call at seq {d} of {s} could not be read back: {s}; nothing moved", .{ handoff_tool, call.seq, args.session, @errorName(err) }),
    };
    const summary = rendered orelse return Brief{
        .failed = try fail(alloc, "the {s} call at seq {d} of {s} carries no readable brief; nothing moved", .{ handoff_tool, call.seq, args.session }),
    };
    return .{ .harvested = .{ .summary = summary, .seq = tail } };
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    for (haystack) |one| if (std.mem.eql(u8, one, needle)) return true;
    return false;
}

/// The four sections of a `handoff` call as the markdown brief the next session
/// opens with. Null when nothing readable is left after trimming — a brief that
/// says nothing is not a brief, and forking on it would throw the conversation
/// away for no continuation.
///
/// `args_json` is the ledger's copy of what the model sent, so it can be torn
/// (a reply cut by `max_tokens` records the fragment verbatim): a parse
/// failure here is a refusal, never a crash.
fn renderHandoff(alloc: std.mem.Allocator, session_id: []const u8, args_json: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const done = handoffSection(obj, "done");
    const next_task = handoffSection(obj, "next_task");
    const keep = handoffSection(obj, "keep");
    const drop = handoffSection(obj, "drop");
    if (done.len == 0 and next_task.len == 0 and keep.len == 0) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.print("# Handoff\n\nsession: {s}\n\n", .{session_id});
    try w.print("## Done\n\n{s}\n\n", .{done});
    try w.print("## Next task\n\n{s}\n\n", .{next_task});
    try w.print("## Keep\n\n{s}\n", .{keep});
    if (drop.len != 0) try w.print("\n## Dropped\n\n{s}\n", .{drop});
    return try out.toOwnedSlice();
}

/// One section, trimmed and capped. Whitespace-only is empty, and the cut lands
/// on a CHARACTER boundary, never inside one: the rendered brief goes through
/// `session append`, which refuses bytes that are not valid UTF-8, so a cap
/// that fell mid-character would turn a perfectly good handoff into a refused
/// one — and it would do it only for the briefs long enough to be cut, which
/// is the worst kind of rarely.
///
/// Same rule `emit.validUtf8PrefixLen` follows in the kernel. The two cannot
/// share code: an extension is compiled from its own frozen snapshot and
/// reaches nothing under `src/`.
fn handoffSection(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const raw = stringField(obj, key) orelse return "";
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return trimmed[0..utf8PrefixLen(trimmed, max_section_bytes)];
}

/// The longest prefix of `s` no longer than `max_len` that does not end inside a
/// multi-byte character. Nothing here validates `s` itself — a cut cannot repair
/// bytes that were already bad, and the one gate that must not be passed is the
/// check on the assembled text in `compact`.
fn utf8PrefixLen(s: []const u8, max_len: usize) usize {
    var end = @min(s.len, max_len);
    while (end > 0 and end < s.len and (s[end] & 0b1100_0000) == 0b1000_0000) end -= 1;
    return end;
}

/// The seven-step path: ask the OLD session to summarise itself (steps 2-4).
fn briefFromSession(alloc: std.mem.Allocator, io: std.Io, exe: []const u8, args: Args) !Brief {
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
        return .{ .failed = try fail(alloc, "cannot append the compaction request to {s}: {s}", .{ args.session, detail(asked) }) };
    }

    // 3. Step the OLD session, on its own cached prefix, and read what it wrote.
    const budget = try std.fmt.allocPrint(alloc, "{d}", .{args.max_steps});
    const stepped = try runNulya(alloc, io, exe, &.{ "session", "step", args.session, "--max-steps", budget });
    if (stepped.code != 0) {
        return .{ .failed = try fail(alloc, "the summarising step failed: {s}", .{detail(stepped)}) };
    }

    // 4. No brief is a legitimate outcome, not an accident to paper over: a
    //    cancelled step, or a model that answered with tool calls, leaves the
    //    window exactly as full as it was. The two turns from steps 2-3 stay in
    //    the old ledger — that file records why the attempt happened.
    const found = (try harvest(alloc, stepped.stdout)) orelse return Brief{
        .failed = "no summary came back; nothing moved — the old session is still the live one",
    };
    return .{ .harvested = found };
}

const Harvest = struct { summary: []const u8, seq: u64 };

/// Read a `session step` stdout (one ledger event per line) and pull out the
/// brief plus the sequence number to fork at.
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

/// The highest `seq` in a `session events` dump — the fork point when the caller
/// brought its own brief. Null means the parent has no events at all. Read the
/// same forgiving way `harvest` does: a shape this build does not know is
/// skipped rather than fatal.
fn lastSeq(alloc: std.mem.Allocator, stdout: []const u8) ?u64 {
    var seq: u64 = 0;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        if (parsed.value != .object) continue;
        switch (parsed.value.object.get("seq") orelse continue) {
            .integer => |n| if (n > 0 and @as(u64, @intCast(n)) > seq) {
                seq = @intCast(n);
            },
            else => {},
        }
    }
    return if (seq == 0) null else seq;
}

/// Read a file named by the caller, workspace-relative or absolute (this
/// process's cwd IS the workspace). Null means it is not there; anything
/// else is the real I/O error, because "cannot read the brief" and "there is
/// no brief" deserve different messages.
fn readFileMaybe(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        }
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return try reader.interface.allocRemaining(alloc, .limited(max_child_output));
}

const Run = struct { code: u8, stdout: []u8, stderr: []u8 };

/// The largest ledger tail the two fork-only branches will read in one gulp —
/// `briefFromFile` and `briefFromLedger` both ask `session events <old>` with
/// no `--since`, which is the WHOLE ledger (a read-only tail, but an
/// unbounded one). `max_child_output` (4 MiB) is sized for a bounded child's
/// output; a long-lived session is exactly what compaction exists to
/// shorten, so the longer it ran before someone compacted it, the bigger
/// this read gets — hitting the ordinary cap here would mean the session
/// most in need of compacting is the one these two branches refuse to look
/// at (`briefFromSession`'s default path never hits this: it reads one
/// `session step`'s new events, not the ledger's history). Still a cap, not
/// `.unlimited`: a size no real ledger will reach, not a budget tuned to the
/// common case.
const max_ledger_scan_bytes: usize = 64 << 20;

/// One `nulya <args…>` invocation, in this process's working directory — which
/// is the workspace, because that is where the host spawns an extension.
/// Output is captured, never inherited: stdout here is data.
fn runNulya(alloc: std.mem.Allocator, io: std.Io, exe: []const u8, tail: []const []const u8) !Run {
    return runNulyaLimited(alloc, io, exe, tail, max_child_output);
}

/// Like `runNulya`, for a read that may legitimately be an entire session's
/// ledger rather than one bounded child's output.
fn runNulyaScan(alloc: std.mem.Allocator, io: std.Io, exe: []const u8, tail: []const []const u8) !Run {
    return runNulyaLimited(alloc, io, exe, tail, max_ledger_scan_bytes);
}

fn runNulyaLimited(alloc: std.mem.Allocator, io: std.Io, exe: []const u8, tail: []const []const u8, stdout_limit: usize) !Run {
    const argv = try alloc.alloc([]const u8, tail.len + 1);
    defer alloc.free(argv);
    argv[0] = exe;
    @memcpy(argv[1..], tail);

    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(stdout_limit),
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

/// A refusal message. Both `Outcome` and `Brief` carry one, so the reason is
/// built here and the caller says which shape it is returning.
fn fail(alloc: std.mem.Allocator, comptime fmt: []const u8, fmt_args: anytype) ![]const u8 {
    return std.fmt.allocPrint(alloc, fmt, fmt_args);
}

/// This call's arguments, or null when they do not name a session.
fn readArgs(arguments: std.json.ObjectMap) ?Args {
    const session = stringField(arguments, "session") orelse return null;
    if (session.len == 0) return null;

    var args: Args = .{ .session = session };
    if (stringField(arguments, "focus")) |focus| args.focus = std.mem.trim(u8, focus, " \t\r\n");
    if (stringField(arguments, "brief_file")) |path| args.brief_file = std.mem.trim(u8, path, " \t\r\n");
    if (stringField(arguments, "brief")) |word| args.brief = std.mem.trim(u8, word, " \t\r\n");
    if (arguments.get("brief_seq")) |value| switch (value) {
        .integer => |n| if (n > 0) {
            args.brief_seq = @intCast(n);
        },
        else => {},
    };
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

/// The answer, then exit — the whole runtime contract. A success is JSON on
/// stdout because a driver reads the new session id out of it; a refusal is
/// the message on stderr, and the non-zero exit is what makes it a failed
/// call.
fn answer(alloc: std.mem.Allocator, io: std.Io, outcome: Outcome) !noreturn {
    switch (outcome) {
        .done => |done| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            var jw: std.json.Stringify = .{ .writer = &out.writer };
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
            try std.Io.File.stdout().writeStreamingAll(io, out.writer.buffered());
            std.process.exit(0);
        },
        .failed => |message| {
            try std.Io.File.stderr().writeStreamingAll(io, message);
            try std.Io.File.stderr().writeStreamingAll(io, "\n");
            std.process.exit(1);
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// The one shape these tests need from the ledger: a call's arguments as the
/// object `renderHandoff` parses out of them.
fn testArgs(arena: std.mem.Allocator, pairs: []const [2][]const u8) !std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;
    for (pairs) |pair| try obj.put(arena, pair[0], .{ .string = pair[1] });
    return obj;
}

test "a capped section is cut between characters, never inside one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The boundary case that used to render a brief `session append` refuses:
    // the cap falls one byte into a multi-byte character, so a plain byte slice
    // ends on half of it.
    var straddling: std.ArrayList(u8) = .empty;
    try straddling.appendNTimes(arena, 'a', max_section_bytes - 1);
    try straddling.appendSlice(arena, "字"); // three bytes, across the cap

    const obj = try testArgs(arena, &.{
        .{ "done", straddling.items },
        .{ "keep", "  你好，世界  " },
    });

    const section = handoffSection(obj, "done");
    try std.testing.expect(std.unicode.utf8ValidateSlice(section));
    try std.testing.expect(section.len <= max_section_bytes);
    // The whole character goes rather than half of it staying: what survives is
    // the run that came before it.
    try std.testing.expectEqual(max_section_bytes - 1, section.len);

    // A section that fits is untouched, multi-byte characters and all.
    try std.testing.expectEqualStrings("你好，世界", handoffSection(obj, "keep"));
    try std.testing.expectEqualStrings("", handoffSection(obj, "missing"));
}

test "a brief long enough to be cut still renders as valid UTF-8" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every section over the cap and every one of them ending mid-character:
    // this is the shape that forked a child and then could carry nothing into it.
    var section: std.ArrayList(u8) = .empty;
    try section.appendNTimes(arena, 'x', max_section_bytes - 1);
    try section.appendSlice(arena, "汉");

    var args: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &args.writer };
    try jw.beginObject();
    for ([_][]const u8{ "done", "next_task", "keep", "drop" }) |key| {
        try jw.objectField(key);
        try jw.write(section.items);
    }
    try jw.endObject();

    const rendered = (try renderHandoff(arena, "s-1", args.written())).?;
    try std.testing.expect(std.unicode.utf8ValidateSlice(rendered));
}

test "the footer describes the live tasks, and only those" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Whether a row is retargeted and whether it is DESCRIBED are two different
    // questions: a finished row still has to move (its result may be undrained),
    // but it is not something whose result "will arrive here".
    for ([_][]const u8{ "running", "starting" }) |live| {
        const row = try testArgs(arena, &.{.{ "state", live }});
        try std.testing.expect(isLive(row));
    }
    for ([_][]const u8{ "done", "lost", "unreachable" }) |finished| {
        const row = try testArgs(arena, &.{.{ "state", finished }});
        try std.testing.expect(!isLive(row));
    }
    // A row whose state this build cannot read is not claimed to be live.
    var unknown: std.json.ObjectMap = .empty;
    try std.testing.expect(!isLive(unknown));
    try unknown.put(arena, "state", .{ .integer = 3 });
    try std.testing.expect(!isLive(unknown));
}

test "task handoff treats a subprocess launch failure as best-effort" {
    const footer = try handOverTasks(
        std.testing.allocator,
        std.testing.io,
        "nulya-compact-test-executable-that-does-not-exist",
        "s-parent",
        "s-child",
    );
    try std.testing.expectEqualStrings("", footer);
}
