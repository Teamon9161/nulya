//! `plan` — planning mode as a package (goals/tui-plugin.md U4, the first of the
//! two consumers that the declaration layer and the plugin host were built for).
//!
//! **What the package is.** A system prompt that says what this session is for,
//! a `policy` that narrows what it may do while it is worn, three tools, and a
//! front-end module (`tui/plan.ts`). `/plan` puts it on, and the manifest does
//! not have to say so: a driver derives that command from the shape of a
//! package whose contribution is a prompt (tui.md §11 T49). The
//! kernel enforces none of it (DESIGN §7.2.1): every part is a declaration that
//! a driver chooses to honour, and whether a session wears this package at all
//! is the person's own decision, said in config or on one `session new`.
//!
//! **The three tools.**
//!
//!   `propose {plan_md}`  the model recording the plan it arrived at. The plan
//!                        text IS the argument, so it lands in the ledger —
//!                        which is the whole point: the conversation is the
//!                        record, and a review panel is only a lens on it. The
//!                        tool writes nothing and answers "recorded, end your
//!                        turn" (goals/tui-plugin.md D7, `handoff`'s shape).
//!   `todo {items}`       the checklist the model is working through, declared
//!                        `render: "checklist"` + `panel: true` so a front end
//!                        with no plugin loaded still shows progress (D12).
//!                        Also writes nothing: the call is the record.
//!   `approve {…}`        `surface: "driver"`. The one tool here that touches
//!                        the disk: it renders an approved plan into
//!                        `.nulya/handoffs/<session>-<n>.md` — byte-shaped like
//!                        what `extensions/handoff` writes — and returns the
//!                        path, which the front end hands to `compact --arg
//!                        brief_file=…` to fork into a session that carries the
//!                        plan and NOT this persona.
//!
//! **Why `approve` writes a file rather than forking.** The same division
//! `handoff` keeps (DESIGN §11): `session new --parent` is called from exactly
//! one place in this repository, `extensions/compact`. A brief on disk is a
//! proposal that has not changed the conversation yet; forking is the driver's
//! act, and the driver here is a person pressing a key.
//!
//! **Why the review is not a blocking call.** A tool that waited for a person to
//! read a plan would put a step process on their reading speed under a 600 s
//! ceiling it cannot raise, and would hang any driver with nobody watching.
//! Instead the comments come back as an ordinary user turn — append-only, so a
//! revision round costs one cache-cheap increment — and a front end with no
//! plugin degrades to a person typing their comments, which is the same thing.
//!
//! **Why compiled Zig rather than a script.** Identical to `handoff` and
//! `agent`: a plan and a checklist to validate before either is on the record,
//! and a brief to write. `sh` has no JSON reader, Windows has neither `jq` nor a
//! guaranteed python, and one manifest carries one `interpreter`.

const std = @import("std");
const rpc = @import("rpc.zig");

/// Where an approved plan lands. The same directory `extensions/handoff` writes
/// to, and for the same reason: what is written there is a brief a new session
/// can start from, and `compact --arg brief_file=` is what starts it. One shape,
/// two producers — a driver that already watches this directory needs to learn
/// nothing new.
const handoff_dir = ".nulya/handoffs";

/// What `propose` answers with. The model has just been told the plan is on the
/// record; anything else it does this turn is work the review has not asked for.
const propose_message =
    "plan recorded — do not call any more tools; end this turn now. " ++
    "The review comes back as the next message: either comments to fold in — " ++
    "revise and call propose again with the WHOLE plan, not a diff — or approval, " ++
    "which continues the work in a fresh session carrying this plan.";

/// A plan this long is a document nobody will review.
const max_plan_bytes: usize = 128 << 10;

/// A checklist longer than this is not a checklist.
const max_items: usize = 100;
const max_item_bytes: usize = 512;

/// Upper bound on `<session>-<n>.md` before giving up, matching `handoff`.
const max_briefs_per_session: usize = 1000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: this process validates arguments, may write
    // one file and prints one line, so individual frees would be noise.
    const alloc = init.arena.allocator();

    const name = init.environ_map.get("NULYA_TOOL") orelse "";
    const arguments = rpc.readArguments(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try rpc.answer(io, .{ .failed = "plan expects this call's arguments as one JSON object on stdin" }),
    };

    // Host faults surface as Zig errors and are folded into a refusal here, so
    // every path still ends in exactly one answer.
    const outcome = dispatch(alloc, io, name, arguments) catch |err| rpc.Outcome{
        .failed = try std.fmt.allocPrint(alloc, "{s} could not run: {s}", .{ name, @errorName(err) }),
    };
    try rpc.answer(io, outcome);
}

fn dispatch(alloc: std.mem.Allocator, io: std.Io, name: []const u8, arguments: std.json.ObjectMap) !rpc.Outcome {
    if (std.mem.eql(u8, name, "propose")) return propose(alloc, arguments);
    if (std.mem.eql(u8, name, "todo")) return todo(alloc, arguments);
    if (std.mem.eql(u8, name, "approve")) return approve(alloc, io, arguments);
    return .{ .failed = "plan has three tools: propose, todo, approve" };
}

// ── propose ────────────────────────────────────────────────────────────────

/// Check the plan and hand it back to the conversation. Nothing is written: the
/// call is already in the ledger with the plan in its arguments, which is the
/// only copy that should exist (physics #3 — what the model must see lives in
/// the ledger, everything else is a view).
fn propose(alloc: std.mem.Allocator, args: std.json.ObjectMap) !rpc.Outcome {
    const plan = rpc.trimmedField(args, "plan_md");
    if (plan.len == 0) {
        return rpc.refuse(
            alloc,
            "propose needs a non-empty plan_md; nothing was recorded. " ++
                "plan_md is the WHOLE plan in markdown: the phases in order, and for each one the files and " ++
                "symbols it changes, what it makes true, and how it is verified.",
            .{},
        );
    }
    if (plan.len > max_plan_bytes) {
        return rpc.refuse(
            alloc,
            "that plan is {d} bytes, past the {d} this tool takes; a plan nobody can read in one sitting " ++
                "is a phase list plus a transcript — send the phase list.",
            .{ plan.len, max_plan_bytes },
        );
    }
    return .{ .text = propose_message };
}

// ── todo ───────────────────────────────────────────────────────────────────

/// Check the checklist and say what it now shows. Like `propose`, the call is
/// the record; this exists so the shape is validated once, out loud, rather than
/// silently drawn wrong by whoever is rendering it.
fn todo(alloc: std.mem.Allocator, args: std.json.ObjectMap) !rpc.Outcome {
    const items = switch (args.get("items") orelse std.json.Value{ .null = {} }) {
        .array => |a| a,
        else => return rpc.refuse(
            alloc,
            "todo needs items: [{{\"text\": \"…\", \"state\": \"todo\"|\"doing\"|\"done\"}}]. " ++
                "Send the WHOLE list every time — each call replaces what is shown.",
            .{},
        ),
    };
    if (items.items.len == 0) {
        return rpc.refuse(alloc, "todo needs at least one item; an empty list says nothing.", .{});
    }
    if (items.items.len > max_items) {
        return rpc.refuse(
            alloc,
            "{d} items is not a checklist anybody reads; keep it to the {d} steps that matter.",
            .{ items.items.len, max_items },
        );
    }

    var done: usize = 0;
    for (items.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return rpc.refuse(
                alloc,
                "every entry of items must be an object {{text, state}}.",
                .{},
            ),
        };
        const text = rpc.trimmedField(obj, "text");
        if (text.len == 0 or text.len > max_item_bytes) {
            return rpc.refuse(
                alloc,
                "every item needs a short non-empty text; nothing was recorded.",
                .{},
            );
        }
        const state = rpc.trimmedField(obj, "state");
        if (state.len == 0) continue;
        if (std.mem.eql(u8, state, "done")) {
            done += 1;
        } else if (!std.mem.eql(u8, state, "todo") and !std.mem.eql(u8, state, "doing")) {
            return rpc.refuse(
                alloc,
                "'{s}' is not a state; each item is \"todo\", \"doing\" or \"done\" (leaving it out means todo).",
                .{state},
            );
        }
    }

    return .{ .text = try std.fmt.allocPrint(
        alloc,
        "checklist recorded — {d} of {d} done. Keep working; call todo again whenever something moves.",
        .{ done, items.items.len },
    ) };
}

// ── approve ────────────────────────────────────────────────────────────────

/// Freeze an approved plan into a brief on disk and report where it went.
///
/// The session id arrives as an ARGUMENT rather than from `NULYA_SESSION`,
/// because this tool is called by a driver (`nulya ext run`, `surface:
/// "driver"`) and not from inside a step — the front end that just watched a
/// person approve the plan is the one that knows which session it belongs to.
fn approve(alloc: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) !rpc.Outcome {
    const session = rpc.trimmedField(args, "session");
    if (session.len == 0) {
        return rpc.refuse(alloc, "approve needs {{\"session\": \"<id>\", \"plan_md\": \"…\"}}.", .{});
    }
    // The id becomes part of a file name, so it has to be one component. Not a
    // security boundary (this tool has the caller's authority either way,
    // DESIGN §9) — it is the difference between a clear refusal and a file
    // written somewhere nobody will look for it.
    if (std.mem.indexOfAny(u8, session, "/\\:") != null or std.mem.eql(u8, session, "..")) {
        return rpc.refuse(alloc, "'{s}' is not a session id; pass the id, not a path.", .{session});
    }
    const plan = rpc.trimmedField(args, "plan_md");
    if (plan.len == 0) {
        return rpc.refuse(alloc, "approve needs the approved plan_md; nothing was written.", .{});
    }
    if (plan.len > max_plan_bytes) {
        return rpc.refuse(
            alloc,
            "that plan is {d} bytes, past the {d} this tool takes.",
            .{ plan.len, max_plan_bytes },
        );
    }

    const body = try render(alloc, session, plan);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, handoff_dir);

    // `<session>-<n>.md`, taking the first free n — the same naming and the same
    // exclusive-creation rule `extensions/handoff` uses, so the two producers
    // cannot collide and a driver watching the directory sees one convention.
    var n: usize = 1;
    while (n <= max_briefs_per_session) : (n += 1) {
        const rel = try std.fmt.allocPrint(alloc, "{s}/{s}-{d}.md", .{ handoff_dir, session, n });
        const file = cwd.createFile(io, rel, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        defer file.close(io);
        try file.writeStreamingAll(io, body);
        return .{ .text = try std.fmt.allocPrint(alloc, "{{\"recorded\":{f}}}", .{std.json.fmt(rel, .{})}) };
    }
    return rpc.refuse(alloc, "{s} has already recorded too many briefs", .{session});
}

/// The brief, as the next session will read it. `extensions/compact` carries
/// this file's bytes over verbatim as the child's first turn, so it is written
/// for the model that wakes up there — which has none of the planning
/// conversation and must not start planning again.
fn render(alloc: std.mem.Allocator, session: []const u8, plan: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.print("# Approved plan\n\nsession: {s}\n\n", .{session});
    try w.writeAll(
        "The plan below was drafted in the session named above and approved there. " ++
            "It is the work to do now: carry it out phase by phase. " ++
            "Do not re-plan it and do not propose it again — if something in it turns out to be wrong, " ++
            "say so and say what you did instead.\n\n## Plan\n\n",
    );
    try w.writeAll(plan);
    try w.writeAll("\n");
    return out.toOwnedSlice();
}
