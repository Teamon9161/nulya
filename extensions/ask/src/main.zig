//! `ask` — the model's way of putting a question to the person, outside the
//! kernel (goals/tui-plugin.md D13, the second U4 consumer).
//!
//! **What it is.** One tool. The model calls it with a question and, when the
//! answer is a choice, the options; this extension checks them and answers
//! "recorded — end this turn now". It does NOT wait. Nothing here blocks, polls
//! or reads an answer back: the question is in the ledger the moment the call is
//! recorded, and the answer is an ordinary user turn that arrives later.
//!
//! **Why it does not block** (goals/tui-plugin.md D7, the same shape
//! `extensions/handoff` has). A tool that waited would put a step process — and
//! the model's whole turn — on a person's reading speed, under a 600 s ceiling
//! it cannot raise (`tool.Timeouts.extension_max_ms`). It would also make a
//! headless driver hang on a question nobody is there to see. Returning at once
//! costs nothing instead: the conversation is append-only, so an answer arriving
//! as the next turn is one cache-cheap increment, and a front end that wants to
//! offer a keystroke for it can (`tui/ask.ts`), while one that does not leaves
//! the question sitting in the transcript where a person can simply type back.
//!
//! **Why it is a tool and not a sentence.** The same reason `handoff` is: a
//! model "asking" in prose is a signal a driver can only guess at, and a front
//! end cannot tell it apart from thinking aloud. A tool call is structured — a
//! panel can list the options, a headless reader can still read the question —
//! and it carries its own instructions, because the description is in front of
//! the model for the whole session.
//!
//! **Where it wants to be composed**, unlike its sibling `extensions/plan`.
//! That is not something a manifest can say — reach is the person's decision
//! (config's `[extensions] with`, or one `session new --with`, DESIGN §5.1) —
//! but the two packages want opposite answers, and the reason is worth writing
//! down. `plan` is a MODE: wearing it says what THIS session is, a persona and
//! a read-only stance, and a person decides that before the work starts.
//! Nobody can decide in advance that a question will come up: the model finds
//! that out in the middle of a task, so a package that only lived in sessions
//! somebody had already earmarked for questions would be a package that never
//! fires. So this one belongs in the standing lists — `[extensions] with` plus
//! a pin for its single tool, since whether it costs a `max_tools` slot is the
//! OTHER axis's question (DESIGN §7.5), per-machine and reversible with one
//! key. For one session only, `--with ask --pin ext:ask/ask` still does what it
//! always did; the `/ask` command this manifest declares is that route.
//!
//! **Why compiled Zig rather than a script.** Identical to `handoff`: a question
//! and a list of options to validate as a group, so one retry is informed. `sh`
//! has no JSON reader, Windows has neither `jq` nor a guaranteed python, and one
//! manifest carries one `interpreter` — so a repo-shipped script tool would be a
//! `.ps1` and a `.sh` that could never share a version id.

const std = @import("std");

/// The answer on the happy path. The model has just been told the question is
/// recorded; anything else it does in this turn is work that depends on an
/// answer it does not have yet.
const end_turn_message =
    "question recorded — do not call any more tools; end this turn now. " ++
    "The answer arrives as the next message; if none comes, take the most reasonable reading and say which one you took.";

/// A question this long is a document, not a question.
const max_question_bytes: usize = 8 << 10;

/// A short phrase each, and few enough to read at a glance. A model that needs
/// more than this is not offering a choice, it is offering a search.
const max_option_bytes: usize = 512;
const max_options: usize = 20;

/// What the tool answers with: a sentence for the model, or the teaching
/// message that says why nothing was recorded. Host faults (out of memory)
/// surface as Zig errors and are folded into a refusal by `main`, so every path
/// still ends in exactly one answer.
const Outcome = union(enum) { text: []const u8, failed: []const u8 };

/// `std.process.Init` rather than a bare `main()`: the io it hands over carries
/// the real process environment, which is the shape every bundled extension in
/// this repository uses.
///
/// The wire is `plain` (DESIGN §7.3, contract at the top of
/// `src/extension/protocol.zig`): stdin is this call's arguments as one JSON
/// object, and this package has one tool, so `NULYA_TOOL` says nothing it does
/// not already know.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: this process validates a few strings and
    // prints one line, so individual frees would be noise.
    const alloc = init.arena.allocator();

    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const request = try reader.interface.allocRemaining(alloc, .limited(1 << 20));

    var outcome: Outcome = .{ .failed = "ask expects this call's arguments as one JSON object on stdin" };

    if (std.json.parseFromSlice(std.json.Value, alloc, request, .{})) |parsed| {
        if (parsed.value == .object) {
            outcome = record(alloc, parsed.value.object) catch |err| Outcome{
                .failed = try std.fmt.allocPrint(alloc, "ask could not run: {s}", .{@errorName(err)}),
            };
        }
    } else |_| {}

    try answer(io, outcome);
}

/// Validate and answer. Nothing is written anywhere: the call itself — with the
/// question in its arguments — is the record, and the kernel put it in the
/// ledger before this process was even spawned.
fn record(alloc: std.mem.Allocator, args: std.json.ObjectMap) !Outcome {
    const question = trimmed(args, "question");
    if (question.len == 0) {
        return .{ .failed = "ask needs a non-empty question; nothing was recorded. " ++
            "Ask the whole thing in one message — the person sees this and nothing else of your reasoning — " ++
            "and add options: [...] when the answer is a choice between a few phrasings." };
    }
    if (question.len > max_question_bytes) {
        return .{ .failed = "that question is too long to be a question; say the decision that needs making in a few sentences." };
    }

    // The options are checked as a group so a model that sent one bad entry is
    // told what is wrong with the list, not asked to guess by retrying.
    switch (args.get("options") orelse std.json.Value{ .null = {} }) {
        .null => {},
        .array => |items| {
            if (items.items.len > max_options) {
                return .{ .failed = "too many options to choose between; offer the few that are really different, " ++
                    "and let the rest be an answer in their own words." };
            }
            for (items.items) |item| {
                const text = switch (item) {
                    .string => |s| std.mem.trim(u8, s, " \t\r\n"),
                    else => return .{ .failed = "every entry of options must be a string — one short phrase a person can pick." },
                };
                if (text.len == 0 or text.len > max_option_bytes) {
                    return .{ .failed = "every option must be a short non-empty phrase; nothing was recorded." };
                }
            }
        },
        else => return .{ .failed = "options must be an array of short phrases, or left out entirely for an open question." },
    }

    _ = alloc;
    return .{ .text = end_turn_message };
}

/// One argument, trimmed. Whitespace-only is empty: a model that sent `"  "`
/// did not ask anything.
fn trimmed(args: std.json.ObjectMap, key: []const u8) []const u8 {
    const raw = stringField(args, key) orelse return "";
    return std.mem.trim(u8, raw, " \t\r\n");
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The answer, then exit — the whole runtime contract. stdout reaches the model
/// verbatim (DESIGN §7.3), which is what this tool wants: its answer is a
/// sentence, not data. A refusal goes to stderr, and the non-zero exit is what
/// makes it a failed call.
fn answer(io: std.Io, outcome: Outcome) !noreturn {
    switch (outcome) {
        .text => |text| {
            try std.Io.File.stdout().writeStreamingAll(io, text);
            std.process.exit(0);
        },
        .failed => |message| {
            try std.Io.File.stderr().writeStreamingAll(io, message);
            try std.Io.File.stderr().writeStreamingAll(io, "\n");
            std.process.exit(1);
        },
    }
}
