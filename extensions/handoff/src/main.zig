//! `handoff` — the model's own end-of-phase signal, outside the kernel.
//!
//! **What it is.** One tool. The model calls it when a phase of work is really
//! finished and the rest of the job no longer needs this phase's process detail:
//! it hands over four sections (`done` / `next_task` / `keep` / `drop?`), this
//! extension checks them, and answers "recorded — end this turn now". It does
//! NOT fork. Forking is `extensions/compact` (DESIGN §11), and
//! `session new --parent` stays called from exactly one place in this
//! repository.
//!
//! **Where the proposal lives: in the ledger.** This tool writes nothing. The
//! four sections ARE the arguments of this call, and the kernel froze that call
//! into the session's ledger before this process ever started — so a second copy
//! on disk would be a second truth (physics #3). It used to write
//! `.nulya/handoffs/<session>-<n>.md` and let drivers watch that directory;
//! that shape made every driver learn a disk convention nobody enforced, meant
//! two implementations on two platforms, and died outright once a workspace
//! could live on another machine (the package runs there, the driver does not —
//! goals/remote-env.md §3.2). What replaced it needs no convention at all:
//! `compact --arg brief=latest` reads the last accepted `handoff` call out of
//! the session's own ledger and renders the brief from its arguments.
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
//! (PLAN §3.4.1). It ships with the repo, DEFAULT-OFF; a driver that wants it
//! composes the package explicitly: `session new --with handoff@<v>`. Its
//! manifest declares `surface: "auto"`, so that membership is the whole of
//! putting the tool on the model face — no second flag.
//!
//! **How a driver consumes it.** A driver (`drivers/goal.sh` / `drivers/goal.ps1`,
//! PLAN §3.6) steps the session and watches the step's own `--stream` lines for
//! a `handoff` call; when one appears it runs
//! `compact --arg session=<id> --arg brief=latest` — the fork path that leaves
//! the old session byte-identical — and continues in the child. The model
//! proposes, the driver decides (physics #3): nothing here opens, steps or forks
//! a session.
//!
//! **Why compiled Zig rather than a script.** Identical to `extensions/compact`:
//! four sections to validate as a group. `sh` has no JSON reader (jq is not
//! guaranteed), Windows has neither jq nor a guaranteed python, and one manifest
//! carries one `interpreter` — so a repo-shipped script tool would mean a `.ps1`
//! and a `.sh` implementation of the same tool that could never share one
//! version id. PLAN §0.1 #3 keeps compiled Zig open for exactly this.

const std = @import("std");

/// The answer on the happy path. The model has just been told the phase is
/// recorded; anything else it does in this turn is work the NEXT session was
/// supposed to do with a clean context.
const end_turn_message = "handoff recorded — do not call any more tools; end this turn now.";

/// What the tool answers with: the acceptance, or a teaching message. Host
/// faults surface as Zig errors and are folded into a refusal by `main`, so
/// every path still ends in exactly one answer.
const Outcome = union(enum) { done: []const u8, failed: []const u8 };

/// The brief, already trimmed. The three required sections are validated as a
/// group so a model that forgot two of them is told about both at once.
///
/// Nothing here is capped: this process does not carry these bytes anywhere —
/// the ledger already has the call verbatim — and whoever renders the brief
/// (`extensions/compact`) bounds what it carries at the point it carries it.
const Brief = struct {
    done: []const u8 = "",
    next_task: []const u8 = "",
    keep: []const u8 = "",
};

/// `std.process.Init` rather than a bare `main()` for the io it hands over.
///
/// The wire is `plain` (DESIGN §7.3, contract at the top of
/// `src/extension/protocol.zig`): stdin is this call's arguments as one JSON
/// object, and this package has one tool, so `NULYA_TOOL` says nothing it does
/// not already know.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: this process validates a brief and prints
    // one line, so individual frees would be noise.
    const alloc = init.arena.allocator();

    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const request = try reader.interface.allocRemaining(alloc, .limited(1 << 20));

    var outcome: Outcome = .{ .failed = "handoff expects this call's arguments as one JSON object on stdin" };

    if (std.json.parseFromSlice(std.json.Value, alloc, request, .{})) |parsed| {
        if (parsed.value == .object) {
            outcome = record(alloc, readBrief(parsed.value.object)) catch |err| Outcome{
                .failed = try std.fmt.allocPrint(alloc, "handoff could not run: {s}", .{@errorName(err)}),
            };
        }
    } else |_| {}

    try answer(io, outcome);
}

/// Check the brief. That is the whole of this tool's work now: the proposal is
/// the call, and the call is already in the ledger — so "accepted" means the
/// model answered all three questions, and a refusal is an ordinary failed call
/// the model can read and redo.
fn record(alloc: std.mem.Allocator, brief: Brief) !Outcome {
    if (try missingSections(alloc, brief)) |message| return .{ .failed = message };
    return .{ .done = end_turn_message };
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

/// This call's arguments. An empty object yields an empty brief, which
/// `missingSections` then reports section by section — the same message a
/// half-filled brief gets, because to the model it is the same mistake.
///
/// `drop` is not read here: it is optional, so there is nothing to check about
/// it, and the renderer reads it from the ledger like every other section.
fn readBrief(arguments: std.json.ObjectMap) Brief {
    return .{
        .done = section(arguments, "done"),
        .next_task = section(arguments, "next_task"),
        .keep = section(arguments, "keep"),
    };
}

/// One section, trimmed. Whitespace-only is empty: a model that sent
/// `"done": "  "` did not answer the question.
fn section(arguments: std.json.ObjectMap, key: []const u8) []const u8 {
    const raw = stringField(arguments, key) orelse return "";
    return std.mem.trim(u8, raw, " \t\r\n");
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The answer, then exit — the whole runtime contract. A success is the sentence
/// itself on stdout (a string result reaches the model verbatim, DESIGN §7.3);
/// a failure is the teaching message on stderr, and the non-zero exit is what
/// makes it a failed call.
fn answer(io: std.Io, outcome: Outcome) !noreturn {
    switch (outcome) {
        .done => |message| {
            try std.Io.File.stdout().writeStreamingAll(io, message);
            std.process.exit(0);
        },
        .failed => |message| {
            try std.Io.File.stderr().writeStreamingAll(io, message);
            try std.Io.File.stderr().writeStreamingAll(io, "\n");
            std.process.exit(1);
        },
    }
}
