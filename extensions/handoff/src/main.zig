//! `handoff` — the model's own end-of-phase signal, outside the kernel.
//!
//! One tool. The model calls it when a phase of work is finished: it hands
//! over four sections (`done` / `next_task` / `keep` / `drop?`), this
//! extension validates them, and answers "recorded — end this turn now". It
//! writes nothing and does NOT fork — the four sections ARE the call's
//! arguments, already frozen into the session's ledger, and forking is
//! `extensions/compact`'s job (`compact --arg brief=latest` reads the last
//! accepted `handoff` call out of the ledger and renders the brief from it).
//!
//! Ships DEFAULT-OFF; a driver composes it with `session new --with
//! handoff@<v>` and watches `--stream` for the call to trigger the
//! compact/fork itself — the model proposes, the driver decides.

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
/// The wire is `plain` (contract at the top of `src/extension/protocol.zig`):
/// stdin is this call's arguments as one JSON object, and this package has
/// one tool, so `NULYA_TOOL` says nothing it does not already know.
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

/// The answer, then exit — the whole runtime contract. A success is the
/// sentence itself on stdout (a string result reaches the model verbatim);
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
