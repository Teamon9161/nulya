//! `agent` — delegation, outside the kernel.
//!
//! **What it is.** Four tools in one binary, dispatched on `NULYA_TOOL`:
//!
//!   `agent {name, task}`   the model asking for one piece of work to be
//!                          delegated. Renders the persona, opens a
//!                          conversation wearing it, and starts a BACKGROUND
//!                          TASK that drives it. Returns a receipt naming the
//!                          DELEGATION (`d-…`, `record.zig`).
//!   `agent {session, task}` another turn into one that is already going —
//!                          including while it is working (`interrupt: true`
//!                          says take it NOW rather than at its next natural
//!                          boundary).
//!   `render {name}`        a definition file → the prompt file and the whole
//!                          set of `session new` arguments it asks for. The
//!                          single writer of that rendering; the front end calls
//!                          it too rather than keeping a second copy.
//!   `run {delegation, …}`  the background command itself (`runner.zig`).
//!
//! **One world view, many runners.** The model names a DELEGATION, never the
//! session that happens to be behind it: `d-…` is the conversation, and which
//! harness holds it — this nulya today — is the definition's `runner:`, frozen
//! into the delegation's record when it opens (`runners.zig`, contract D1/D7).
//! The record is readable and the report still points at the remote transcript:
//! the abstraction gives the facts one name, it does not hide them (D2).
//!
//! **Why the persona is not an extension.** It used to be: every delegation
//! froze the body into an `agent-<name>` data extension and composed it in with
//! `--with`. That made a piece of per-session text into an installed artifact —
//! it showed up in `ext list`, and `ext prune` could break the resume of a
//! session frozen on an older version of it. `session new --prompt <file>`
//! freezes the BYTES into the session header instead (DESIGN §3, §5), which is
//! where text with one session's lifetime belongs.
//!
//! **Why the report comes back through a background task.** A delegation is a
//! mechanism that owes an answer later, and the kernel already has exactly one
//! of those: a background task's `task_finished` event, deposited into the
//! parent's inbox and drained at its next step boundary (DESIGN §6.1 / §3.1).
//! Using it means every driver already knows how to collect the answer —
//! `drivers/goal.*` needed no change, the TUI needed no new watcher, and the
//! next driver will need nothing either. The alternative considered first was a
//! request file for drivers to poll (`extensions/handoff`'s shape); that is a
//! second protocol every driver would have to learn, in two implementations on
//! two platforms, for a loop the kernel already runs.
//!
//! **A definition is the WHOLE composition.** Every child session is created
//! `--bare` (DESIGN §14): the workspace's standing `[extensions] with` and
//! `registry.pinned_native_tools` are read as empty for it. Those two lists are
//! how a PERSON says "every session I open here carries this"; a session opened
//! by the model to do one piece of work is not one of those, and inheriting
//! them would give a sub-agent capabilities its author never wrote down — and
//! would make the same definition behave differently in two workspaces. So a
//! definition with no `pins` gets `shell` and nothing else, which is a real
//! answer (`explore` deliberately narrows itself that way) rather than an
//! oversight to be topped up from config.
//!
//! **Leaf by default.** A delegated session carries this package only when its
//! own definition names somebody to pass work to (`agents:` non-empty), so a
//! sub-agent that was not given that field cannot delegate again — the tool is
//! simply not there. One field, read in one place, and no refusal to write.
//!
//! **Why compiled Zig.** `run` reads the `session step` JSONL protocol line by
//! line and answers a gate on a pipe while it does, and the other three parse
//! markdown front matter and validate it. `sh` has no JSON reader, Windows has
//! neither `jq` nor a guaranteed python, and one manifest carries one
//! `interpreter` — a script version would be a `.sh` and a `.ps1` that could
//! never share a version id.

const std = @import("std");
const rpc = @import("rpc.zig");
const defs = @import("defs.zig");
const runner = @import("runner.zig");
const runners = @import("runners.zig");
const record = @import("record.zig");
const mailbox = @import("mailbox.zig");
const proc = @import("proc.zig");
const header_mod = @import("header.zig");

const Run = proc.Run;
const run = proc.run;
const detail = proc.detail;
const firstLine = proc.firstLine;

/// The largest task text this tool will pass on to a child session.
const max_task_bytes: usize = 64 << 10;

const Ctx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// Absolute path of the nulya that spawned this process (DESIGN §7.6): the
    /// binary every child call must use, rather than whichever copy is on PATH.
    exe: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: this process makes a handful of child calls
    // and prints one response, so individual frees would be noise.
    const alloc = init.arena.allocator();

    const name = init.environ_map.get("NULYA_TOOL") orelse "";
    const arguments = rpc.readArguments(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try rpc.answer(io, .{ .failed = "agent expects this call's arguments as one JSON object on stdin" }),
    };

    const exe = init.environ_map.get("NULYA_EXE") orelse "";
    const ctx: Ctx = .{ .alloc = alloc, .io = io, .env = init.environ_map, .exe = exe };

    // Host faults surface as Zig errors and are folded into a refusal here, so
    // every path still ends in exactly one answer.
    const outcome = dispatch(&ctx, name, arguments) catch |err| rpc.Outcome{
        .failed = try std.fmt.allocPrint(alloc, "{s} could not run: {s}", .{ name, @errorName(err) }),
    };
    try rpc.answer(io, outcome);
}

fn dispatch(ctx: *const Ctx, name: []const u8, arguments: std.json.ObjectMap) !rpc.Outcome {
    if (ctx.exe.len == 0) {
        return rpc.refuse(ctx.alloc, "agent cannot find the nulya that spawned it (NULYA_EXE is not set)", .{});
    }
    if (std.mem.eql(u8, name, "agent")) return delegate(ctx, arguments);
    if (std.mem.eql(u8, name, "render")) return renderTool(ctx, arguments);
    if (std.mem.eql(u8, name, "list")) return list(ctx);
    if (std.mem.eql(u8, name, "run")) {
        return runner.run(ctx.alloc, ctx.io, ctx.exe, .{
            .delegation = rpc.trimmedField(arguments, "delegation"),
            .depth = rpc.intField(arguments, "depth") orelse 1,
            .env = ctx.env,
        });
    }
    return rpc.refuse(ctx.alloc, "agent has no tool named '{s}' (it has agent, render, list, run)", .{name});
}

// ── render ──────────────────────────────────────────────────────────────────

const Rendered = struct {
    def: defs.Def,
    /// The block label this persona's system prompt carries (`agent-<name>`).
    label: []const u8,
    /// The file `session new --prompt` reads the body from.
    path: []const u8,
    warnings: []const []const u8,
};

/// Read a definition and write its body where `session new --prompt` can read
/// it. The one implementation of that rendering (see `defs.zig`), so the front
/// end and the model's own `agent` tool cannot disagree about what a persona is.
fn render(ctx: *const Ctx, name: []const u8) !union(enum) { ok: Rendered, failed: []const u8 } {
    const alloc = ctx.alloc;
    if (!defs.isPlainName(name)) {
        return .{ .failed = try std.fmt.allocPrint(alloc, "'{s}' is not an agent name; a name is letters, digits, '.', '_' or '-' and names one definition file", .{name}) };
    }
    const entry = (try defs.find(alloc, ctx.io, ctx.env, name)) orelse {
        const known = try availableAgentsSummary(alloc, ctx.io, ctx.env);
        return .{ .failed = if (known.len == 0)
            try std.fmt.allocPrint(
                alloc,
                "no agent '{s}': this workspace defines no agents at all. Definitions are markdown files in {s}/ or in this machine's agents directory; without one there is nobody to delegate to, so do the work yourself.",
                .{ name, defs.project_dir },
            )
        else
            try std.fmt.allocPrint(alloc, "no agent '{s}'. Available: {s}. For the full catalogue, run `nulya ext run agent list` with shell.", .{ name, known }) };
    };

    const def = entry.def;

    // Written every time, and that is cheap and deliberate: the contents are
    // decided by the definition, so an unedited one rewrites the same bytes and
    // an edit is picked up without anybody running a command. Two delegations
    // racing here write the same file.
    const label = try defs.promptLabel(alloc, def.name);
    const path = try defs.promptPath(alloc, label);
    defs.writePrompt(alloc, ctx.io, def, path) catch |err| {
        return .{ .failed = try failed(alloc, "could not write the prompt for '{s}' to {s}: {s}", .{ def.name, path, @errorName(err) }) };
    };

    return .{ .ok = .{ .def = def, .label = label, .path = path, .warnings = entry.warnings } };
}

fn availableAgentsSummary(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var shown: usize = 0;
    var total: usize = 0;
    for (try defs.discover(alloc, io, env)) |entry| {
        if (entry.shadowed) continue;
        total += 1;
        if (shown >= 8) continue;
        if (shown > 0) try out.writer.writeAll("; ");
        if (entry.def.description.len == 0) {
            try out.writer.writeAll(entry.def.name);
        } else {
            try out.writer.print("{s} — {s}", .{ entry.def.name, entry.def.description });
        }
        shown += 1;
    }
    if (total > shown) try out.writer.print("; … and {d} more", .{total - shown});
    return try out.toOwnedSlice();
}

/// `render {name}` → the prompt file, and the arguments a driver needs to open a
/// session wearing it. JSON rather than prose: its reader is a driver.
fn renderTool(ctx: *const Ctx, args: std.json.ObjectMap) !rpc.Outcome {
    const name = rpc.trimmedField(args, "name");
    if (name.len == 0) return rpc.refuse(ctx.alloc, "render needs a name (which agent definition to render)", .{});
    const outcome = try render(ctx, name);
    switch (outcome) {
        .failed => |f| return .{ .failed = f },
        .ok => |m| {
            var out: std.Io.Writer.Allocating = .init(ctx.alloc);
            var jw: std.json.Stringify = .{ .writer = &out.writer };
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(m.def.name);
            // `session new --prompt <this>`: the whole of how a persona reaches
            // a session now. Nothing is installed, so there is no version and no
            // id to name.
            try jw.objectField("prompt");
            try jw.write(m.path);
            // Always true, and named rather than assumed, because a driver that
            // opened this session WITHOUT it would compose something else
            // entirely (`session new --bare`, DESIGN §14). A definition's
            // `pins` are its whole tool face; a workspace's standing
            // `[extensions] with` / `pinned_native_tools` are what a PERSON
            // asked every session of theirs to carry, and a delegated session
            // is not one of those. Inheriting them would hand a sub-agent
            // capabilities its author never wrote down.
            try jw.objectField("bare");
            try jw.write(true);
            try jw.objectField("label");
            try jw.write(m.label);
            try jw.objectField("description");
            try jw.write(m.def.description);
            // Two columns, one answer. `permissions` is the field a definition
            // writes and the record freezes; `readonly` is that same answer as
            // the one bit every existing reader asks for, kept so a driver that
            // only ever wanted "may this touch anything" is not made to learn
            // three words to ask one question.
            try jw.objectField("permissions");
            try jw.write(m.def.permissions.label());
            try jw.objectField("readonly");
            try jw.write(m.def.permissions.isReadonly());
            // Which harness will hold the conversation (D1). A driver rendering
            // a persona to open a session itself only ever sees `nulya`; the
            // column is here because "what runs this" is part of what a
            // definition asks for, and the answer must not be inferred from the
            // absence of the field.
            try jw.objectField("runner");
            try jw.write(m.def.runner.label());
            try jw.objectField("layer");
            try jw.write(@tagName(m.def.layer));
            try jw.objectField("profile");
            try jw.write(m.def.profile);
            try jw.objectField("model");
            try jw.write(m.def.model);
            // An external runner's opaque model string (D9). Beside the other
            // two rather than folded into them: a driver reading this must not
            // have to guess which vocabulary the value is in.
            try jw.objectField("runner_model");
            try jw.write(m.def.runner_model);
            try jw.objectField("max_steps");
            try jw.write(m.def.max_steps);
            try jw.objectField("max_exchanges");
            try jw.write(m.def.max_exchanges);
            // The names it may pass work to. Non-empty is what makes a delegated
            // session carry this package at all (`newDelegation`), so a driver
            // composing one needs the same answer.
            try jw.objectField("agents");
            try jw.beginArray();
            for (m.def.agents) |one| try jw.write(one);
            try jw.endArray();
            // Pins only. The `--with` a pin implies is the KERNEL's implication
            // now (DESIGN §5.1): `session new --pin ext:<id>/<tool>` brings the
            // package in at `current` by itself, so a driver that derived the
            // membership list here was saying the same thing a second time — and
            // three drivers said it three slightly different ways.
            try jw.objectField("pins");
            try jw.beginArray();
            for (m.def.pins) |pin| try jw.write(pin);
            try jw.endArray();
            try jw.objectField("warnings");
            try jw.beginArray();
            for (m.warnings) |w| try jw.write(w);
            try jw.endArray();
            try jw.endObject();
            return .{ .text = try out.toOwnedSlice() };
        },
    }
}

// ── list ────────────────────────────────────────────────────────────────────

/// `list` — every definition all three layers hold, in search order.
///
/// Driver-facing, and never pinned: the model does not need a catalogue (an
/// unknown name already comes back with the names that exist), while a driver
/// needs one to draw a picker and to decide what a checkout brought with it.
/// This is the ONE reader of the definition format, the way `render` is the
/// one writer of the rendering — the front end used to parse front matter as
/// well, and two parsers of one file is two answers to "is this agent read-only".
fn list(ctx: *const Ctx) !rpc.Outcome {
    const alloc = ctx.alloc;
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginArray();
    for (try defs.discover(alloc, ctx.io, ctx.env)) |entry| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(entry.def.name);
        try jw.objectField("description");
        try jw.write(entry.def.description);
        try jw.objectField("permissions");
        try jw.write(entry.def.permissions.label());
        // The derived bit, beside the word it comes from (see `render`).
        try jw.objectField("readonly");
        try jw.write(entry.def.permissions.isReadonly());
        try jw.objectField("runner");
        try jw.write(entry.def.runner.label());
        try jw.objectField("layer");
        try jw.write(@tagName(entry.def.layer));
        // Listed, not dropped: a definition that never runs because an earlier
        // layer has the name is exactly the thing somebody needs to be told
        // about (DESIGN §7.2's rule for store roots, for its reason).
        try jw.objectField("shadowed");
        try jw.write(entry.shadowed);
        try jw.objectField("source");
        try jw.write(entry.def.source);
        try jw.objectField("profile");
        try jw.write(entry.def.profile);
        try jw.objectField("model");
        try jw.write(entry.def.model);
        try jw.objectField("runner_model");
        try jw.write(entry.def.runner_model);
        try jw.objectField("max_steps");
        try jw.write(entry.def.max_steps);
        try jw.objectField("max_exchanges");
        try jw.write(entry.def.max_exchanges);
        try jw.objectField("agents");
        try jw.beginArray();
        for (entry.def.agents) |one| try jw.write(one);
        try jw.endArray();
        try jw.objectField("pins");
        try jw.beginArray();
        for (entry.def.pins) |pin| try jw.write(pin);
        try jw.endArray();
        try jw.objectField("warnings");
        try jw.beginArray();
        for (entry.warnings) |w| try jw.write(w);
        try jw.endArray();
        try jw.endObject();
    }
    try jw.endArray();
    return .{ .text = try out.toOwnedSlice() };
}

// ── agent ───────────────────────────────────────────────────────────────────

/// How deep a chain of delegations may go before this refuses outright.
///
/// A backstop against an INDIRECT cycle (`a` may delegate to `b`, `b` to `a`),
/// which no whitelist catches — not a security boundary: `NULYA_AGENT_DEPTH` is
/// an ordinary variable, it is absent when a person drives a delegated session
/// from a front end, and the whitelist above it is a policy in exactly the way
/// the approval tables are (DESIGN §9).
const max_depth: u32 = 3;

/// `agent{name, task}` — a new delegation — or `agent{session, task}` — another
/// turn in one that is already going.
///
/// The two are one tool because they are one act with one answer: the caller
/// wants work done by somebody else and gets a report back. The second form is
/// the cheaper one and the model should reach for it — another turn lands in a
/// conversation that still holds everything it learned (append-only, so it hits
/// its OWN prefix cache, DESIGN §1), where a fresh delegation pays for the
/// reconnaissance again.
///
/// The `session` argument names a DELEGATION (`d-…`), not the session that
/// happens to be behind it. A delegation is the conversation; which harness
/// holds it — this nulya, another one later — is the runner's business, and a
/// model that had to name a session id could only ever address the one runner
/// that has such things (D1/D11).
fn delegate(ctx: *const Ctx, args: std.json.ObjectMap) !rpc.Outcome {
    const alloc = ctx.alloc;
    const name = rpc.trimmedField(args, "name");
    const target = rpc.trimmedField(args, "session");
    const raw_task = rpc.trimmedField(args, "task");
    const task = raw_task[0..@min(raw_task.len, max_task_bytes)];
    const asked_model = rpc.trimmedField(args, "model");
    const asked_permissions = rpc.trimmedField(args, "permissions");
    const interrupt = rpc.boolField(args, "interrupt");

    if (task.len == 0) {
        return rpc.refuse(
            alloc,
            "agent needs a non-empty task — the whole job in its own words: what to do, what to look at, what counts as finished, because the sub-agent sees nothing of this conversation.",
            .{},
        );
    }
    if ((name.len == 0) == (target.len == 0)) {
        return rpc.refuse(
            alloc,
            "agent takes EITHER name (start a new delegation) OR session (send another turn into one that already reported), not {s}. A follow-up is the cheaper one: that session still holds everything it found.",
            .{if (name.len == 0) "neither" else "both"},
        );
    }

    // Which session is this? `session step` puts the live session's file path in
    // the environment of everything it runs (DESIGN §5.3). Without it there is
    // nobody to report BACK to: the background task's `task_finished` is
    // deposited into a session's inbox, and there would be no session.
    const session_path = ctx.env.get("NULYA_SESSION") orelse
        return rpc.refuse(alloc, "agent must be called from inside a session (NULYA_SESSION is not set)", .{});
    const parent = std.fs.path.stem(session_path);
    if (parent.len == 0) return rpc.refuse(alloc, "agent must be called from inside a session (NULYA_SESSION names no session file)", .{});

    const depth = currentDepth(ctx.env);
    if (depth >= max_depth) {
        return rpc.refuse(
            alloc,
            "delegation is already {d} levels deep; do this one yourself. (A chain this long is usually two agents handing the same work back and forth.)",
            .{depth},
        );
    }

    // A model reference is a choice made when a session is CREATED and frozen
    // there (physics #2, DESIGN §3.4). A follow-up creates nothing — it appends
    // a turn to a session whose identity was frozen rounds ago — so a `model`
    // on that form cannot be honoured, and quietly ignoring it would be the
    // worst of the three answers.
    if (target.len != 0 and asked_model.len != 0) {
        return rpc.refuse(
            alloc,
            "model applies to a NEW delegation only: {s} froze what it runs on when it was created and append-only is what makes another turn cheap. Drop model to follow up, or start a fresh delegation with name + model.",
            .{target},
        );
    }
    // The ceiling is frozen into the delegation's record when it opens, for the
    // same reason a model is frozen into a session header: everything about
    // what a conversation may do was settled before it said its first word, and
    // a follow-up that could widen it would make the ceiling a suggestion. So
    // this argument only means anything on the form that CREATES something.
    if (target.len != 0 and asked_permissions.len != 0) {
        return rpc.refuse(
            alloc,
            "permissions applies to a NEW delegation only: {s} froze what it may do when it was opened, and a follow-up that could widen that would make it no ceiling at all. Drop permissions to follow up, or start a fresh delegation with name + permissions.",
            .{target},
        );
    }
    // `interrupt` is how a message is delivered, not a kind of message (D3), so
    // it only means anything where there is something in flight to interrupt.
    if (name.len != 0 and interrupt) {
        return rpc.refuse(
            alloc,
            "interrupt applies to a delegation that is already going: there is nothing yet to interrupt in a new one. Drop interrupt to start '{s}'.",
            .{name},
        );
    }
    if (target.len != 0) return sendTurn(ctx, parent, target, task, interrupt, depth);
    // `model` is NOT parsed here: what grammar it is written in depends on the
    // runner the definition names, and the definition is not read until
    // `newDelegation` renders it (D9). One string, two vocabularies, and the
    // one place that knows which is the one that has the definition in hand.
    // Nearest first, and only two answers: what THIS call asked for, then what
    // the definition says. Nothing is inherited — not from the parent session,
    // not from a front end's mode, not from the environment. `unsafe` is only
    // ever reached because somebody wrote the word in one of those two places,
    // and this call is itself a tool call the parent's own gate rules on, so a
    // person watching an `ask`-mode conversation sees it before it runs.
    const permissions: ?record.Permissions = if (asked_permissions.len == 0) null else record.Permissions.parse(asked_permissions) orelse {
        return rpc.refuse(
            alloc,
            "permissions must be one of {s} — got '{s}'. readonly holds the sub-agent to tools that only read; default is ordinary work in this checkout; unsafe takes the harness's guard rails off and is worth a sentence in your task saying why it is needed.",
            .{ record.permission_words, asked_permissions },
        );
    };
    return newDelegation(ctx, parent, name, task, asked_model, permissions, depth);
}

/// A fresh delegation: render the persona, open a session wearing it, give it
/// the task, and start the background task that drives it.
fn newDelegation(
    ctx: *const Ctx,
    parent: []const u8,
    name: []const u8,
    task: []const u8,
    asked_model: []const u8,
    asked_permissions: ?record.Permissions,
    depth: u32,
) !rpc.Outcome {
    const alloc = ctx.alloc;

    // What may THIS session delegate to? A session wearing a persona may only
    // reach the names that persona's `agents` list allows; a top-level
    // conversation is unrestricted.
    if (try allowedHere(ctx, parent)) |allowed| {
        for (allowed) |one| {
            if (std.mem.eql(u8, one, name)) break;
        } else {
            return if (allowed.len == 0)
                rpc.refuse(alloc, "this agent cannot delegate — do the work yourself and report it.", .{})
            else
                rpc.refuse(alloc, "this agent may only delegate to: {s}. '{s}' is not one of them.", .{ try std.mem.join(alloc, ", ", allowed), name });
        }
    }

    const outcome = try render(ctx, name);
    const m = switch (outcome) {
        .failed => |f| return .{ .failed = f },
        .ok => |ok| ok,
    };

    // Three answers to "what runs this", nearest first: what THIS call asked
    // for, then what the definition says, then what the parent is running on. A
    // persona that does not care which model runs it should not silently move
    // the work onto whatever the config's default happens to be — and the caller
    // knows something neither of the other two do, which is what this piece of
    // work is worth.
    //
    // A pair, never a mix: `--model` is an id WITHIN a profile (DESIGN §9.5), so
    // taking the profile from one source and the id from another would name a
    // model that profile does not serve.
    // An EXTERNAL runner has its own catalogue, so the same argument means a
    // different thing (D9): an opaque string, in that harness's vocabulary,
    // passed through untouched and with its errors coming back untouched.
    // Nothing is inherited from the parent either — this nulya's profile is not
    // a name Codex has ever heard.
    var profile: []const u8 = "";
    var model: []const u8 = "";
    var runner_model: []const u8 = "";
    var chosen = false;
    if (m.def.runner.usesNulyaModels()) {
        const ref: ?defs.ModelRef = if (asked_model.len == 0) null else defs.parseModelRef(asked_model) orelse {
            return rpc.refuse(
                alloc,
                "model must be <profile> or <profile>/<model-id> (the same form a definition's `model:` takes) — got '{s}'. `nulya config show` lists the profiles and the model ids each one serves.",
                .{asked_model},
            );
        };
        chosen = ref != null;
        // A pair, never a mix (see above).
        const identity: Identity = if (ref) |r|
            .{ .profile = r.profile, .model = r.model }
        else if (m.def.profile.len != 0)
            .{ .profile = m.def.profile, .model = m.def.model }
        else
            parentIdentity(alloc, ctx.io, parent);
        profile = identity.profile;
        model = identity.model;
    } else {
        chosen = asked_model.len != 0;
        runner_model = if (asked_model.len != 0) asked_model else m.def.runner_model;
    }

    // The ceiling, nearest answer first and nothing behind the two: the call, or
    // the definition. There is no third source on purpose (contract ar-h) — an
    // escalation that could be inherited from the parent, the front end's mode
    // or the environment would be an escalation nobody wrote down.
    const permissions = asked_permissions orelse m.def.permissions;

    const self_ref = try proc.selfRef(alloc, ctx.io);

    // The delegation's own identity, minted BEFORE the conversation is opened:
    // a runner may need somewhere of its own to put what it freezes (the claude
    // arm copies the persona into `<d>/`), and nothing about the id depends on
    // what the runner answers. Nothing is written yet — the record's opening row
    // is below, once there is a remote conversation for it to name.
    const d = try record.mint(alloc, ctx.io);

    // …and this package itself, but ONLY for a persona that names somebody to
    // pass work to. That one field is what makes a session a leaf or not, and it
    // is read in one place: a delegated session that cannot delegate simply does
    // not carry the tool, so there is nothing to refuse later.
    //
    // Membership is the whole of it: the `agent` tool is `surface: "auto"`, so
    // naming the package IS putting it on that session's tool face (DESIGN
    // §5.1) — and a pin at it would now be refused outright
    // (`PinToolNotPinnable`). The other three tools are `internal`; they stay
    // where they are, reached through `ext run`.
    const created = try runners.start(m.def.runner, alloc, ctx.io, .{
        .exe = ctx.exe,
        .prompt = m.path,
        .env = ctx.env,
        .profile = profile,
        .model = model,
        .runner_model = runner_model,
        // The ceiling reaches the runner HERE, not only when a round is driven:
        // a runner that cannot enforce the read-only one refuses the whole
        // delegation rather than opening one that would run wider than it said
        // (D10). For the nulya arm the gate does it at every call; for Codex the
        // sandbox is asked for and its answer checked.
        .permissions = permissions,
        .pins = m.def.pins,
        .with_self = if (m.def.agents.len != 0) self_ref else "",
        .delegation = d,
    });
    if (created.run.code != 0) {
        // Straight through, including the credential refusal (DESIGN §9.5): the
        // kernel already says the whole way out, and a second sentence composed
        // here would be a second place that has an opinion about credentials.
        // The one thing added is where the model reference came from, and only
        // when it came from the CALL — the caller can retry without it, which is
        // not obvious from a message about a profile it did not know it named.
        if (chosen) {
            return rpc.refuse(
                alloc,
                "could not open a conversation for '{s}' on the model you asked for: {s}\n(That was the `model` argument of this call. Dropping it runs '{s}' on its own default.)",
                .{ m.def.name, detail(created.run), m.def.name },
            );
        }
        return rpc.refuse(alloc, "could not open a conversation for '{s}': {s}", .{ m.def.name, detail(created.run) });
    }
    const remote = std.mem.trim(u8, created.run.stdout, " \t\r\n");
    if (remote.len == 0) return rpc.refuse(alloc, "the {s} runner opened no conversation for '{s}'", .{ m.def.runner.label(), m.def.name });

    // The journal that holds everything decided once about this delegation —
    // which runner, at what version, over which remote conversation (D2/D7).
    // Written BEFORE the first message, so a runner started by that message
    // always finds a record describing what it drives.
    try record.appendCreated(alloc, ctx.io, std.Io.Dir.cwd(), d, .{
        .agent = m.def.name,
        .runner = m.def.runner.label(),
        .runner_version = created.version,
        .remote = remote,
        .parent = parent,
        .permissions = permissions,
        .profile = profile,
        .model = model,
        .runner_model = runner_model,
        // The policy this delegation lives under for the rest of its life. Read
        // from the definition HERE and never again: this is the moment the
        // definition has a say, and everything after it reads the record.
        .max_exchanges = m.def.max_exchanges,
        .max_steps = m.def.max_steps,
        .agents = m.def.agents,
    });

    const spec: Spec = .{
        .delegation = d,
        .remote = remote,
        .runner = m.def.runner,
    };

    switch (try deliver(ctx, spec, task, false)) {
        .failed => |f| return .{ .failed = f },
        .ok => {},
    }
    const started = switch (try wake(ctx, parent, spec, depth)) {
        .failed => |f| return rpc.refuse(alloc, "'{s}' has delegation {s} but its run could not be started: {s}", .{ m.def.name, d, f }),
        // Nobody can hold the lease of a delegation that did not exist a moment
        // ago, so this is unreachable in practice; saying the honest thing
        // rather than asserting keeps one shape for both callers.
        .busy => "(already running)",
        .task => |t| t,
    };

    return .{ .text = try std.fmt.allocPrint(
        alloc,
        "delegated to '{s}' — delegation {s}, {s}, running as background task {s}{s}.\n" ++
            "Do not call any more tools about this; end your turn. Its report will arrive here as a message when it finishes, and only its final answer comes back — nothing else from that conversation enters this one.\n" ++
            "To press it for specifics, send a correction, or change its direction mid-run, call agent again with session={s} instead of starting a new one — it keeps everything it already found. {s}",
        .{
            m.def.name,
            d,
            try runners.remoteLabel(m.def.runner, alloc, remote),
            started,
            switch (permissions) {
                .readonly => " (read-only)",
                .default => "",
                .unsafe => " (unsafe: its harness's guard rails are off)",
            },
            d,
            try runners.transcriptHint(m.def.runner, alloc, remote),
        },
    ) };
}

/// Everything about a delegation the sending and waking paths need. Read from
/// the RECORD for a delegation that already exists, and from the definition for
/// one being opened — the two are the same facts, so they are one struct.
///
/// It is this short because the background command is: what a round is driven
/// WITH is read from the record by the process that drives it
/// (`proc.startDelegationTask`), so nothing here has to be carried there — and
/// what is left is exactly what DELIVERING a message needs. The ceiling and the
/// persona name used to be here too; both were read from the record by then and
/// nothing on this side looked at the copies.
const Spec = struct {
    delegation: []const u8,
    remote: []const u8,
    runner: runners.Runner,
};

/// Another turn into a delegation that is already going.
///
/// Append-only, so the sub-agent resumes with everything it learned still in
/// front of it and hits its OWN prefix cache (DESIGN §1) — a correction costs
/// one turn where a fresh delegation would pay for the reconnaissance again.
/// Nothing new is created: same conversation, same frozen composition, same
/// read-only ceiling (the runner recomputes it from that session's own header,
/// so it cannot drift).
///
/// **It is never refused for being busy.** It used to be: a turn appended while
/// the sub-agent was working would be drained mid-run by the very step producing
/// the report, and that was called a race. It is not one — it is exactly what
/// the main conversation does when a person types while the model is answering
/// (D3), and the kernel drains a session's inbox at every step boundary whether
/// or not anybody is watching. What was missing was not a refusal but a
/// guarantee that somebody eventually drives what was accepted, and that is the
/// wake invariant below.
fn sendTurn(
    ctx: *const Ctx,
    parent: []const u8,
    target: []const u8,
    task: []const u8,
    interrupt: bool,
    depth: u32,
) !rpc.Outcome {
    const alloc = ctx.alloc;

    // ① The shape. A session id here is the OLD vocabulary, and a delegation
    // opened under it has no record, so there is nothing to resume — say which
    // word replaced it rather than reporting a missing directory (D11).
    if (!record.isPlainId(target)) {
        if (defs.isPlainSessionId(target)) {
            return rpc.refuse(
                alloc,
                "'{s}' is a session id; this takes a delegation id (they look like d-…), which is what the receipt of a delegation names. A session is where one runner happens to keep the conversation — delegate again and use the id you get back.",
                .{target},
            );
        }
        return rpc.refuse(alloc, "'{s}' is not a delegation id (they look like d-…)", .{target});
    }

    // ② Is it one of ours? The record is this package's own truth about the
    // delegation — it says which persona is wearing it, which runner drives it
    // and what that runner opened — where the session header could only ever
    // answer for a nulya session.
    const state = (record.read(alloc, ctx.io, std.Io.Dir.cwd(), target) catch |err| switch (err) {
        // A record that is there but cannot be believed is not a delegation to
        // send another turn into: what it may do and how much of it is left are
        // both in that file (`record.read`). Named rather than folded into "no
        // delegation" — the two have different repairs, and only one of them is
        // "start a fresh one".
        record.Corrupt.CorruptDelegationRecord => return rpc.refuse(
            alloc,
            "delegation {s} has a damaged record ({s}/{s}/{s}), so what it was allowed to do can no longer be read. Nothing was sent. Start a fresh delegation for this work.",
            .{ target, record.root, target, record.record_name },
        ),
        else => return err,
    }) orelse {
        return rpc.refuse(
            alloc,
            "there is no delegation {s} here, so there is nothing to send a turn into. Call agent with a name to start one.",
            .{target},
        );
    };
    const worn = state.created.agent;
    const runner_kind = runners.Runner.parse(state.created.runner) orelse {
        return rpc.refuse(
            alloc,
            "delegation {s} was opened by a runner this build does not have ('{s}'), so it cannot be driven from here.",
            .{ target, state.created.runner },
        );
    };

    // ③ Is it OURS? A delegation belongs to the conversation that opened it, and
    // that is what the frozen `parent` says. It used to be provenance only: the
    // check was missing and `wake` starts the background task under whichever
    // session is calling, so a second session that learned the id could take a
    // delegation over and have its next report land somewhere else. Then
    // "a sub-agent reports back to its parent" would mean "to whoever spoke to
    // it last", and the record's own column would be describing something that
    // was no longer true.
    //
    // A fork is a different conversation by this rule, and that is consistent
    // rather than incidental: `session new --parent` inherits no composition, no
    // prompts and no images either (DESIGN §11) — everything in this system
    // treats a fork as a boundary, and a delegation is not the one exception.
    if (!std.mem.eql(u8, parent, state.created.parent)) {
        return rpc.refuse(
            alloc,
            "delegation {s} belongs to another conversation (it was opened by session {s}), and a sub-agent reports back to the one that opened it. Start a fresh delegation for this work.",
            .{ target, state.created.parent },
        );
    }

    // ④ How many turns has it had, and how many was it opened with? Both come
    // from the record. The count, because it is the only one an external runner
    // can answer too — counting a child session's user turns is a fact about
    // nulya sessions and nothing else. The budget, because the definition is
    // consulted when a delegation is CREATED and never again: one edited since
    // must not change what a conversation already under way is allowed, and one
    // DELETED since must not strand a conversation whose persona, remote and
    // ceiling are all still right here.
    const allowed_exchanges = state.created.max_exchanges;
    // `>` rather than `>= allowed + 1`, which is the same thing without an
    // addition that overflows on a definition asking for the largest budget
    // there is: `turns` counts the opening task too, so "has had them all" is
    // exactly "more turns than follow-ups allowed".
    if (allowed_exchanges != 0 and state.turns > allowed_exchanges) {
        return rpc.refuse(
            alloc,
            "'{s}' allows {d} follow-up turn(s) per delegation and {s} has had them all. Start a fresh delegation with what you now know, or do the rest yourself.",
            .{ worn, allowed_exchanges, target },
        );
    }

    const spec: Spec = .{
        .delegation = target,
        .remote = state.created.remote,
        .runner = runner_kind,
    };

    switch (try deliver(ctx, spec, task, interrupt)) {
        .failed => |f| return .{ .failed = f },
        .ok => {},
    }

    const started = switch (try wake(ctx, parent, spec, depth)) {
        .failed => |f| return rpc.refuse(alloc, "the turn is queued in delegation {s} but a run could not be started for it: {s}", .{ target, f }),
        .busy => return .{ .text = try std.fmt.allocPrint(
            alloc,
            "{s} for delegation {s} ('{s}') — it is working right now and will take this at its next turn.\n" ++
                "Do not call any more tools about this; end your turn. Its next report will arrive here as a message.",
            .{ if (interrupt) "interrupt queued" else "queued", target, worn },
        ) },
        .task => |t| t,
    };

    return .{ .text = try std.fmt.allocPrint(
        alloc,
        "sent to delegation {s} ('{s}'), running as background task {s}.\n" ++
            "Do not call any more tools about this; end your turn. Its next report will arrive here as a message.",
        .{ target, worn, started },
    ) };
}

/// Record one message, then deliver it.
///
/// **The turn is written down FIRST, and that order is the fail-closed one.**
/// The two writes can only be made atomic by a transaction neither of them is
/// worth, so one of them can land alone, and the question is which way that
/// leans. Sending first leaned the wrong way: a delivered message whose row
/// failed to append is one the sub-agent will actually answer, uncounted, with
/// the caller told it failed — three things wrong at once, and `max_exchanges`
/// quietly widened by one, which is the number this row exists to enforce.
/// Recording first can only ever spend an exchange on a message that did not
/// go, and the caller is told exactly that.
///
/// An interrupt is the same message, sent saying so (D6). On the arms with an
/// inbox that word travels IN the message, atomically, because two writes is a
/// race in either order (`mailbox.Message`); the `<d>/interrupt` marker is
/// written as well, and is what stops a turn on the nulya arm — which has no
/// inbox of its own — and on the arms that do not drain mid-turn. Both orders
/// are correct now, so the marker goes after the message, where a runner that
/// sees it always finds something behind it.
fn deliver(
    ctx: *const Ctx,
    spec: Spec,
    task: []const u8,
    interrupt: bool,
) !union(enum) { ok, failed: []const u8 } {
    const alloc = ctx.alloc;
    try record.appendTurn(alloc, ctx.io, std.Io.Dir.cwd(), spec.delegation, interrupt);
    const sent = try runners.send(
        spec.runner,
        alloc,
        ctx.io,
        std.Io.Dir.cwd(),
        ctx.exe,
        spec.remote,
        spec.delegation,
        .{ .text = task, .interrupt = interrupt },
    );
    if (sent.code != 0) {
        return .{ .failed = try failed(alloc, "could not send that turn to delegation {s}: {s}", .{ spec.delegation, detail(sent) }) };
    }
    if (interrupt) try mailbox.markInterrupt(alloc, ctx.io, std.Io.Dir.cwd(), spec.delegation);
    return .ok;
}

/// The sender's half of the wake invariant (D4): after delivering, probe the
/// runner's lease and start one only when nobody holds it.
///
/// Probing rather than "was a task running a moment ago" is the whole point.
/// The runner's half is the mirror of this — it re-checks for messages AFTER
/// letting the lease go — and between the two, a message delivered in any
/// window is seen by somebody: either the holder finds it before it lets go, or
/// it lets go and finds it, or it has already let go and this probe starts a
/// fresh runner.
fn wake(
    ctx: *const Ctx,
    parent: []const u8,
    spec: Spec,
    depth: u32,
) !union(enum) { task: []const u8, busy, failed: []const u8 } {
    if (record.leaseHeld(ctx.alloc, ctx.io, std.Io.Dir.cwd(), spec.delegation)) return .busy;
    const started = try proc.startDelegationTask(
        ctx.alloc,
        ctx.io,
        ctx.exe,
        try proc.selfRef(ctx.alloc, ctx.io),
        parent,
        spec.delegation,
        depth + 1,
    );
    if (started.code != 0) return .{ .failed = detail(started) };
    return .{ .task = firstLine(started.stdout) };
}

/// The names this session may delegate to, or null when it is not a delegation
/// and nothing is restricted.
///
/// Two questions, and the frozen answer to each. IS this a delegation: the
/// persona in the session's own header says so, and a header cannot have changed
/// since. WHICH names: the delegation's record, frozen when it opened — not the
/// definition as it reads today, which would let an edit widen (or empty) the
/// whitelist of a conversation already under way.
///
/// The runner tells the step it drives which delegation it is
/// (`record.delegation_var`), for the same reason it tells it the depth: it is a
/// fact about this chain, it is not secret-shaped, and it survives the
/// environment sanitising every child gets (DESIGN §7.6).
///
/// Without it, the definition answers — and that is not the leak this function
/// was changed to close. A session wearing a persona with no delegation behind
/// it is a person driving one by hand from a front end (`/agent` opens exactly
/// that): nothing was ever frozen for it, so there is no frozen answer to
/// contradict, and holding it to `leaf` would take a coordinator's whole reason
/// for existing away from the one caller who can watch what it does.
///
/// **The delegation is asked FIRST, and the header is not asked at all on that
/// path.** A delegated session's authority is its record; the header could only
/// ever corroborate it. Asking the header first meant an unreadable one answered
/// `null` — "not a delegation, nothing is restricted" — for a session that
/// plainly IS one, which is the widest possible answer taken from the least
/// authoritative source.
fn allowedHere(ctx: *const Ctx, parent: []const u8) !?[]const []const u8 {
    const d = std.mem.trim(u8, ctx.env.get(record.delegation_var) orelse "", " \t\r\n");
    if (record.isPlainId(d)) {
        const found = record.read(ctx.alloc, ctx.io, std.Io.Dir.cwd(), d) catch null;
        if (found) |state| return state.created.agents;
        // A delegation was named and its record is missing or damaged: that is
        // not a hand-driven session, it is a delegated one whose frozen answer
        // cannot be read, and `leaf` is the only honest answer. No refusal is
        // needed here because this IS the refusal — the caller turns an empty
        // list into "this agent cannot delegate".
        return &.{};
    }
    // No delegation, so this is a person driving a persona by hand — or an
    // ordinary conversation, which nothing restricts.
    const worn = (try defs.wornPersona(ctx.alloc, ctx.io, parent)) orelse return null;
    const entry = (try defs.find(ctx.alloc, ctx.io, ctx.env, worn)) orelse return &.{};
    return entry.def.agents;
}

/// The delegation depth this session is running at (`NULYA_AGENT_DEPTH`, set by
/// the runner for the step it drives).
///
/// Two absences, two answers, as everywhere else here. ABSENT is zero: a
/// top-level conversation, or a person driving a delegated session from a front
/// end, and neither of those is deep in anything. Present and UNREADABLE is the
/// ceiling: somebody set it, this build cannot tell what to, and the one thing
/// the variable exists to stop is a chain that does not know how long it is.
/// Reading it as zero says "top level" about a session that certainly is not.
fn currentDepth(env: *const std.process.Environ.Map) u32 {
    const raw = env.get("NULYA_AGENT_DEPTH") orelse return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch max_depth;
}

const Identity = struct { profile: []const u8 = "", model: []const u8 = "" };

/// What the parent session runs on, from its frozen header (DESIGN §3.4). Best
/// effort: an unreadable header simply means "no inheritance", and then the
/// kernel's own default decides — which is what would have happened anyway.
fn parentIdentity(alloc: std.mem.Allocator, io: std.Io, parent: []const u8) Identity {
    const obj = header_mod.object(alloc, io, parent) orelse return .{};
    var out: Identity = .{};
    if (rpc.stringField(obj, "model")) |profile| out.profile = alloc.dupe(u8, profile) catch "";
    if (obj.get("model_identity")) |ident| {
        if (ident == .object) {
            if (rpc.stringField(ident.object, "model")) |id| out.model = alloc.dupe(u8, id) catch "";
        }
    }
    return out;
}

fn failed(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(alloc, fmt, args);
}
