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
//! **Why its activation is the default one** (`always`, DESIGN §7.2.1), unlike
//! its sibling `extensions/plan`. `activation` is a package answering "am I a
//! capability or a mode", and the two answers are for two different questions.
//! `plan` is a mode: wearing it says what THIS session is — a persona, a
//! read-only stance — and a person decides that before the work starts.
//! Nobody can decide in advance that a question will come up: the model finds
//! that out in the middle of a task, so a package that only worked in sessions
//! somebody had already earmarked for questions would be a package that never
//! fires. So activation composes this into every session, and whether its one
//! tool costs a `max_tools` slot is the OTHER axis's question — a pin (DESIGN
//! §7.5), which is per-machine and reversible with one key. For one session
//! only, without a standing pin, `--with ask --pin ext:ask/ask` still does what
//! it always did; the `/ask` command this manifest declares is that route.
//!
//! **Why compiled Zig rather than a script.** Identical to `handoff`: the tool
//! receives a JSON-RPC request, must echo its `id` back, and validates its
//! arguments. `sh` has no JSON reader, Windows has neither `jq` nor a guaranteed
//! python, and one manifest carries one `interpreter` — so a repo-shipped script
//! tool would be a `.ps1` and a `.sh` that could never share a version id.

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

const Fail = struct { code: i64, message: []const u8 };

/// What the tool answers with: a sentence for the model, or a JSON-RPC error.
/// Host faults (out of memory) surface as Zig errors and are folded into a
/// `-32000` by `main`, so every path still writes exactly one response.
const Outcome = union(enum) { text: []const u8, failed: Fail };

/// `std.process.Init` rather than a bare `main()`: the io it hands over carries
/// the real process environment, which is the shape every bundled extension in
/// this repository uses.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: this process validates a few strings and
    // prints one line, so individual frees would be noise.
    const alloc = init.arena.allocator();

    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const request = try reader.interface.allocRemaining(alloc, .limited(1 << 20));

    // The host sends a string id and requires it back unchanged (DESIGN §7.3).
    var call_id: []const u8 = "call";
    var outcome: Outcome = .{ .failed = .{
        .code = -32600,
        .message = "ask expects one JSON-RPC tool/call request on stdin",
    } };

    if (std.json.parseFromSlice(std.json.Value, alloc, request, .{})) |parsed| {
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (stringField(obj, "id")) |id| call_id = id;
            outcome = record(alloc, arguments(obj)) catch |err| Outcome{ .failed = .{
                .code = -32000,
                .message = try std.fmt.allocPrint(alloc, "ask could not run: {s}", .{@errorName(err)}),
            } };
        }
    } else |_| {}

    try writeResponse(alloc, io, call_id, outcome);
}

/// Validate and answer. Nothing is written anywhere: the call itself — with the
/// question in its arguments — is the record, and the kernel put it in the
/// ledger before this process was even spawned.
fn record(alloc: std.mem.Allocator, args: std.json.ObjectMap) !Outcome {
    const question = trimmed(args, "question");
    if (question.len == 0) {
        return .{ .failed = .{
            .code = -32602,
            .message = "ask needs a non-empty question; nothing was recorded. " ++
                "Ask the whole thing in one message — the person sees this and nothing else of your reasoning — " ++
                "and add options: [...] when the answer is a choice between a few phrasings.",
        } };
    }
    if (question.len > max_question_bytes) {
        return .{ .failed = .{
            .code = -32602,
            .message = "that question is too long to be a question; say the decision that needs making in a few sentences.",
        } };
    }

    // The options are checked as a group so a model that sent one bad entry is
    // told what is wrong with the list, not asked to guess by retrying.
    switch (args.get("options") orelse std.json.Value{ .null = {} }) {
        .null => {},
        .array => |items| {
            if (items.items.len > max_options) {
                return .{ .failed = .{
                    .code = -32602,
                    .message = "too many options to choose between; offer the few that are really different, " ++
                        "and let the rest be an answer in their own words.",
                } };
            }
            for (items.items) |item| {
                const text = switch (item) {
                    .string => |s| std.mem.trim(u8, s, " \t\r\n"),
                    else => return .{ .failed = .{
                        .code = -32602,
                        .message = "every entry of options must be a string — one short phrase a person can pick.",
                    } },
                };
                if (text.len == 0 or text.len > max_option_bytes) {
                    return .{ .failed = .{
                        .code = -32602,
                        .message = "every option must be a short non-empty phrase; nothing was recorded.",
                    } };
                }
            }
        },
        else => return .{ .failed = .{
            .code = -32602,
            .message = "options must be an array of short phrases, or left out entirely for an open question.",
        } },
    }

    _ = alloc;
    return .{ .text = end_turn_message };
}

/// `params.arguments` of a `tool/call`. A request without them yields an empty
/// map, which `record` then reports as a missing question — to the model that is
/// the same mistake.
fn arguments(request: std.json.ObjectMap) std.json.ObjectMap {
    const params = switch (request.get("params") orelse return .empty) {
        .object => |o| o,
        else => return .empty,
    };
    return switch (params.get("arguments") orelse return .empty) {
        .object => |o| o,
        else => .empty,
    };
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

/// One JSON-RPC response on stdout, then exit — the whole runtime contract. A
/// STRING result reaches the model verbatim (DESIGN §7.3), which is what this
/// tool wants: its answer is a sentence, not data.
fn writeResponse(alloc: std.mem.Allocator, io: std.Io, call_id: []const u8, outcome: Outcome) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try jw.write(call_id);
    switch (outcome) {
        .text => |text| {
            try jw.objectField("result");
            try jw.write(text);
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
