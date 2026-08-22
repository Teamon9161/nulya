//! `agent` — delegation, outside the kernel.
//!
//! **What it is.** Three tools in one binary, dispatched on `params.name`:
//!
//!   `agent {name, task}`   the model asking for one piece of work to be
//!                          delegated. Renders the persona, creates the child
//!                          session wearing it, and starts a BACKGROUND TASK
//!                          that drives it. Returns a receipt naming the child.
//!   `render {name}`        a definition file → the prompt file and the whole
//!                          set of `session new` arguments it asks for. The
//!                          single writer of that rendering; the front end calls
//!                          it too rather than keeping a second copy.
//!   `run {session, …}`     the background command itself (`runner.zig`).
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
//! **Leaf.** A delegated session does not carry this package (the driver brings
//! it in with `--with` only for top-level sessions), so a sub-agent cannot
//! delegate again. One level, until there is a reason and a bound for more —
//! agents-and-review §1's `SpawnPolicy`, in its minimal form.
//!
//! **Why compiled Zig.** Identical to `compact` and `handoff`: JSON-RPC in, an
//! `id` to echo, arguments to validate, and `run` parses the `session step`
//! JSONL protocol and answers a gate on a pipe. `sh` has no JSON reader, Windows
//! has neither `jq` nor a guaranteed python, and one manifest carries one
//! `interpreter` — a script version would be a `.sh` and a `.ps1` that could
//! never share a version id.

const std = @import("std");
const rpc = @import("rpc.zig");
const defs = @import("defs.zig");
const runner = @import("runner.zig");
const header_mod = @import("header.zig");

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

    const request = rpc.readRequest(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try rpc.writeResponse(alloc, io, rpc.fallback_id, .{ .failed = .{
                .code = -32600,
                .message = "agent expects one JSON-RPC tool/call request on stdin",
            } });
            return;
        },
    };

    const exe = init.environ_map.get("NULYA_EXE") orelse "";
    const ctx: Ctx = .{ .alloc = alloc, .io = io, .env = init.environ_map, .exe = exe };

    // Host faults surface as Zig errors and are folded into a `-32000` here, so
    // every path still writes exactly one response.
    const outcome = dispatch(&ctx, request) catch |err| rpc.Outcome{ .failed = .{
        .code = rpc.code_refused,
        .message = try std.fmt.allocPrint(alloc, "{s} could not run: {s}", .{ request.name, @errorName(err) }),
    } };
    try rpc.writeResponse(alloc, io, request.id, outcome);
}

fn dispatch(ctx: *const Ctx, request: rpc.Request) !rpc.Outcome {
    if (ctx.exe.len == 0) {
        return rpc.refuse(ctx.alloc, "agent cannot find the nulya that spawned it (NULYA_EXE is not set)", .{});
    }
    if (std.mem.eql(u8, request.name, "agent")) return delegate(ctx, request.arguments);
    if (std.mem.eql(u8, request.name, "render")) return renderTool(ctx, request.arguments);
    if (std.mem.eql(u8, request.name, "list")) return list(ctx);
    if (std.mem.eql(u8, request.name, "run")) {
        return runner.run(ctx.alloc, ctx.io, ctx.exe, .{
            .session = rpc.trimmedField(request.arguments, "session"),
            .agent = rpc.trimmedField(request.arguments, "agent"),
            .readonly = rpc.boolField(request.arguments, "readonly"),
            .max_steps = rpc.intField(request.arguments, "max_steps") orelse 0,
            .depth = rpc.intField(request.arguments, "depth") orelse 1,
            .env = ctx.env,
        });
    }
    return .{ .failed = .{
        .code = rpc.code_unknown_tool,
        .message = try std.fmt.allocPrint(ctx.alloc, "agent has no tool named '{s}' (it has agent, render, list, run)", .{request.name}),
    } };
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
fn render(ctx: *const Ctx, name: []const u8) !union(enum) { ok: Rendered, failed: rpc.Fail } {
    const alloc = ctx.alloc;
    if (!defs.isPlainName(name)) {
        return .{ .failed = .{
            .code = rpc.code_invalid_params,
            .message = try std.fmt.allocPrint(alloc, "'{s}' is not an agent name; a name is letters, digits, '.', '_' or '-' and names one definition file", .{name}),
        } };
    }
    const entry = (try defs.find(alloc, ctx.io, ctx.env, name)) orelse {
        const known = try defs.names(alloc, ctx.io, ctx.env);
        return .{ .failed = .{ .code = rpc.code_invalid_params, .message = if (known.len == 0)
            try std.fmt.allocPrint(
                alloc,
                "no agent '{s}': this workspace defines no agents at all. Definitions are markdown files in {s}/ or in this machine's agents directory; without one there is nobody to delegate to, so do the work yourself.",
                .{ name, defs.project_dir },
            )
        else
            try std.fmt.allocPrint(alloc, "no agent '{s}'. Available: {s}.", .{ name, try std.mem.join(alloc, ", ", known) }) } };
    };

    const def = entry.def;

    // Written every time, and that is cheap and deliberate: the contents are
    // decided by the definition, so an unedited one rewrites the same bytes and
    // an edit is picked up without anybody running a command. Two delegations
    // racing here write the same file.
    const label = try defs.promptLabel(alloc, def.name);
    const path = try defs.promptPath(alloc, label);
    defs.writePrompt(alloc, ctx.io, def, path) catch |err| {
        return .{ .failed = try failed(alloc, rpc.code_refused, "could not write the prompt for '{s}' to {s}: {s}", .{ def.name, path, @errorName(err) }) };
    };

    return .{ .ok = .{ .def = def, .label = label, .path = path, .warnings = entry.warnings } };
}

/// `render {name}` → the prompt file, and the arguments a driver needs to open a
/// session wearing it. JSON rather than prose: its reader is a driver.
fn renderTool(ctx: *const Ctx, args: std.json.ObjectMap) !rpc.Outcome {
    const name = rpc.trimmedField(args, "name");
    if (name.len == 0) return rpc.invalidParams(ctx.alloc, "render needs a name (which agent definition to render)", .{});
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
            try jw.objectField("label");
            try jw.write(m.label);
            try jw.objectField("description");
            try jw.write(m.def.description);
            try jw.objectField("readonly");
            try jw.write(m.def.readonly);
            try jw.objectField("layer");
            try jw.write(@tagName(m.def.layer));
            try jw.objectField("profile");
            try jw.write(m.def.profile);
            try jw.objectField("model");
            try jw.write(m.def.model);
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
            return .{ .json = try out.toOwnedSlice() };
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
        try jw.objectField("readonly");
        try jw.write(entry.def.readonly);
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
    return .{ .json = try out.toOwnedSlice() };
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
/// turn in one that already reported.
///
/// The two are one tool because they are one act with one answer: the caller
/// wants work done by somebody else and gets a report back. The second form is
/// the cheaper one and the model should reach for it — a follow-up lands in a
/// session that still holds everything it learned (append-only, so it hits its
/// OWN prefix cache, DESIGN §1), where a fresh delegation pays for the
/// reconnaissance again.
fn delegate(ctx: *const Ctx, args: std.json.ObjectMap) !rpc.Outcome {
    const alloc = ctx.alloc;
    const name = rpc.trimmedField(args, "name");
    const target = rpc.trimmedField(args, "session");
    const raw_task = rpc.trimmedField(args, "task");
    const task = raw_task[0..@min(raw_task.len, max_task_bytes)];
    const asked_model = rpc.trimmedField(args, "model");

    if (task.len == 0) {
        return rpc.invalidParams(
            alloc,
            "agent needs a non-empty task — the whole job in its own words: what to do, what to look at, what counts as finished, because the sub-agent sees nothing of this conversation.",
            .{},
        );
    }
    if ((name.len == 0) == (target.len == 0)) {
        return rpc.invalidParams(
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
        return rpc.invalidParams(
            alloc,
            "model applies to a NEW delegation only: session {s} froze what it runs on when it was created and append-only is what makes a follow-up cheap. Drop model to follow up, or start a fresh delegation with name + model.",
            .{target},
        );
    }
    const chosen: ?defs.ModelRef = if (asked_model.len == 0) null else defs.parseModelRef(asked_model) orelse {
        return rpc.invalidParams(
            alloc,
            "model must be <profile> or <profile>/<model-id> (the same form a definition's `model:` takes) — got '{s}'. `nulya config show` lists the profiles and the model ids each one serves.",
            .{asked_model},
        );
    };

    if (target.len != 0) return followUp(ctx, parent, target, task, depth);
    return newDelegation(ctx, parent, name, task, chosen, depth);
}

/// A fresh delegation: render the persona, open a session wearing it, give it
/// the task, and start the background task that drives it.
fn newDelegation(
    ctx: *const Ctx,
    parent: []const u8,
    name: []const u8,
    task: []const u8,
    chosen: ?defs.ModelRef,
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
    const inherited = parentIdentity(alloc, ctx.io, parent);
    const identity: Identity = if (chosen) |ref|
        .{ .profile = ref.profile, .model = ref.model }
    else if (m.def.profile.len != 0)
        .{ .profile = m.def.profile, .model = m.def.model }
    else
        inherited;
    const profile = identity.profile;
    const model = identity.model;

    const self_ref = try selfRef(alloc, ctx.io);

    var new_argv: std.ArrayList([]const u8) = .empty;
    // The persona rides as BYTES the header freezes (DESIGN §3): nothing is
    // installed, so this session's identity text cannot be pruned out from
    // under its own resume.
    try new_argv.appendSlice(alloc, &.{ ctx.exe, "session", "new", "--prompt", m.path });
    if (profile.len != 0) try new_argv.appendSlice(alloc, &.{ "--profile", profile });
    if (model.len != 0) try new_argv.appendSlice(alloc, &.{ "--model", model });
    // Just the pins. A pin brings its own package into the session at `current`
    // (DESIGN §5.1) — the child composes from scratch, and the kernel is the one
    // place that implication is made, so a `--with` derived here would only be a
    // second, slightly different copy of it.
    for (m.def.pins) |pin| try new_argv.appendSlice(alloc, &.{ "--pin", pin });
    // …and this package itself, but ONLY for a persona that names somebody to
    // pass work to. That one field is what makes a session a leaf or not, and it
    // is read in one place: a delegated session that cannot delegate simply does
    // not carry the tool, so there is nothing to refuse later.
    if (m.def.agents.len != 0) {
        try new_argv.appendSlice(alloc, &.{ "--with", self_ref, "--pin", "ext:agent/agent" });
    }

    const created = try run(alloc, ctx.io, new_argv.items);
    if (created.code != 0) {
        // Straight through, including the credential refusal (DESIGN §9.5): the
        // kernel already says the whole way out, and a second sentence composed
        // here would be a second place that has an opinion about credentials.
        // The one thing added is where the model reference came from, and only
        // when it came from the CALL — the caller can retry without it, which is
        // not obvious from a message about a profile it did not know it named.
        if (chosen != null) {
            return rpc.refuse(
                alloc,
                "could not open a session for '{s}' on the model you asked for: {s}\n(That was the `model` argument of this call. `nulya config show` lists the profiles that can run; dropping the argument runs '{s}' on its own default.)",
                .{ m.def.name, detail(created), m.def.name },
            );
        }
        return rpc.refuse(alloc, "could not open a session for '{s}': {s}", .{ m.def.name, detail(created) });
    }
    const child = std.mem.trim(u8, created.stdout, " \t\r\n");
    if (child.len == 0) return rpc.refuse(alloc, "session new printed no id for '{s}'", .{m.def.name});

    const appended = try run(alloc, ctx.io, &.{ ctx.exe, "session", "append", child, task });
    if (appended.code != 0) {
        return rpc.refuse(alloc, "could not give '{s}' its task: {s}", .{ m.def.name, detail(appended) });
    }

    const started = try startRunner(ctx, parent, child, m.def, self_ref, depth);
    if (started.code != 0) {
        return rpc.refuse(alloc, "'{s}' has session {s} but its run could not be started: {s}", .{ m.def.name, child, detail(started) });
    }

    return .{ .text = try std.fmt.allocPrint(
        alloc,
        "delegated to '{s}' — session {s}, running as background task {s}{s}.\n" ++
            "Do not call any more tools about this; end your turn. Its report will arrive here as a message when it finishes, and only its final answer comes back — nothing else from that session enters this conversation.\n" ++
            "To press it for specifics or send a correction afterwards, call agent again with session={s} instead of starting a new one — it keeps everything it already found. Full transcript: nulya session events {s}",
        .{ m.def.name, child, firstLine(started.stdout), if (m.def.readonly) " (read-only)" else "", child, child },
    ) };
}

/// Another turn into a delegation that already reported.
///
/// Append-only, so the sub-agent resumes with everything it learned still in
/// front of it and hits its OWN prefix cache (DESIGN §1) — a correction costs
/// one turn where a fresh delegation would pay for the reconnaissance again.
/// Nothing new is created: same session, same frozen composition, same read-only
/// ceiling (the runner recomputes it from that session's own header, so it
/// cannot drift).
fn followUp(ctx: *const Ctx, parent: []const u8, child: []const u8, task: []const u8, depth: u32) !rpc.Outcome {
    const alloc = ctx.alloc;
    if (!defs.isPlainSessionId(child)) {
        return rpc.invalidParams(alloc, "'{s}' is not a session id (they look like s-…)", .{child});
    }

    // Is it a delegation at all? A session whose header froze an `agent-*`
    // system prompt is one;
    // anything else is somebody's conversation, and appending a task to it
    // through this tool would be a delegation nobody asked for.
    const worn = (try defs.wornPersona(alloc, ctx.io, child)) orelse {
        return rpc.refuse(
            alloc,
            "session {s} is not a delegated agent session (its frozen composition wears no agent persona), so there is nothing here to follow up. Use agent with a name to start one.",
            .{child},
        );
    };

    // Still working? Its report has not arrived, and a turn appended now would
    // be drained mid-run by the very step that is producing that report. Asked
    // of the kernel's own projection of the background task driving it, not
    // guessed: `task list` is the answer to "is it still going" (DESIGN §6.1).
    if (try runnerRunning(ctx, parent, child)) {
        return rpc.refuse(
            alloc,
            "'{s}' is still working on session {s}; wait for its report and then follow up.",
            .{ worn, child },
        );
    }

    const entry = (try defs.find(alloc, ctx.io, ctx.env, worn)) orelse {
        return rpc.refuse(alloc, "session {s} wears the persona '{s}', which is no longer defined here.", .{ child, worn });
    };
    if (entry.def.max_exchanges != 0) {
        // Every turn a caller has sent, which is what the limit is about — the
        // sub-agent's own steps are `max_steps`, one bound per round.
        const sent = try turnsSent(ctx, child);
        if (sent >= entry.def.max_exchanges + 1) {
            return rpc.refuse(
                alloc,
                "'{s}' allows {d} follow-up turn(s) per delegation and session {s} has had them all. Start a fresh delegation with what you now know, or do the rest yourself.",
                .{ worn, entry.def.max_exchanges, child },
            );
        }
    }

    const appended = try run(alloc, ctx.io, &.{ ctx.exe, "session", "append", child, task });
    if (appended.code != 0) {
        return rpc.refuse(alloc, "could not send that turn to session {s}: {s}", .{ child, detail(appended) });
    }

    const self_ref = try selfRef(alloc, ctx.io);
    const started = try startRunner(ctx, parent, child, entry.def, self_ref, depth);
    if (started.code != 0) {
        return rpc.refuse(alloc, "the turn is queued in session {s} but its run could not be started: {s}", .{ child, detail(started) });
    }

    return .{ .text = try std.fmt.allocPrint(
        alloc,
        "follow-up sent to agent session {s} ('{s}'), running as background task {s}.\n" ++
            "Do not call any more tools about this; end your turn. Its next report will arrive here as a message.",
        .{ child, worn, firstLine(started.stdout) },
    ) };
}

/// Start (or restart) the background task that drives one delegated session.
///
/// It belongs to the PARENT, so its `task_finished` is deposited into the
/// parent's inbox when it ends (DESIGN §6.1) — the loop every driver already
/// runs. A follow-up simply gets a new `t<N>`: nothing is reused, nothing is
/// resumed, and the two reports are two events in the parent's ledger.
fn startRunner(
    ctx: *const Ctx,
    parent: []const u8,
    child: []const u8,
    def: defs.Def,
    self_ref: []const u8,
    depth: u32,
) !Run {
    const alloc = ctx.alloc;
    var cmd: std.Io.Writer.Allocating = .init(alloc);
    // Quoted: the executable path may contain spaces, and the command is handed
    // to a shell by the supervisor (`environment.shellArgv`).
    try cmd.writer.print("\"{s}\" ext run {s} run --arg session={s} --arg agent={s} --arg depth={d}", .{ ctx.exe, self_ref, child, def.name, depth + 1 });
    if (def.readonly) try cmd.writer.writeAll(" --arg readonly=true");
    if (def.max_steps != 0) try cmd.writer.print(" --arg max_steps={d}", .{def.max_steps});

    var task_argv: std.ArrayList([]const u8) = .empty;
    try task_argv.appendSlice(alloc, &.{ ctx.exe, "task", "run", "--session", parent, "--" });
    try task_argv.append(alloc, cmd.writer.buffered());
    return run(alloc, ctx.io, task_argv.items);
}

/// Whether a background task of `parent` is currently driving `child`.
///
/// The kernel's own projection answers it (`task list --json`, DESIGN §6.1):
/// `starting` and `running` mean a runner is in flight, `done` and `lost` mean
/// nobody is. Matched on the command, which names the session it drives — the
/// same string this tool composed. One honest gap: a `starting` row has no
/// `status.json` yet, so its command is still empty and it cannot say WHICH
/// session it drives. It might be our runner in its first milliseconds, and
/// letting the follow-up through would drop it into the very run that is
/// producing the report — so an unattributable starting row counts as
/// in-flight. Refusing is the safe direction: the caller is told to wait, and
/// a moment later the row has a command and the answer is exact.
fn runnerRunning(ctx: *const Ctx, parent: []const u8, child: []const u8) !bool {
    const alloc = ctx.alloc;
    const listed = try run(alloc, ctx.io, &.{ ctx.exe, "task", "list", "--session", parent, "--json" });
    if (listed.code != 0) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, listed.stdout, " \r\n"), .{}) catch return false;
    const tasks = switch (parsed.value) {
        .object => |o| switch (o.get("tasks") orelse return false) {
            .array => |a| a,
            else => return false,
        },
        else => return false,
    };
    const needle = try std.fmt.allocPrint(alloc, "session={s}", .{child});
    var unattributable_start = false;
    for (tasks.items) |item| {
        const row = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const command = rpc.stringField(row, "command") orelse continue;
        const state = rpc.stringField(row, "state") orelse continue;
        if (std.mem.indexOf(u8, command, needle) == null) {
            if (command.len == 0 and std.mem.eql(u8, state, "starting")) unattributable_start = true;
            continue;
        }
        if (std.mem.eql(u8, state, "starting") or std.mem.eql(u8, state, "running")) return true;
    }
    return unattributable_start;
}

/// How many turns a caller has sent into `child` — its `user_text` events.
fn turnsSent(ctx: *const Ctx, child: []const u8) !u32 {
    const listed = try run(ctx.alloc, ctx.io, &.{ ctx.exe, "session", "events", child });
    if (listed.code != 0) return 0;
    return @intCast(std.mem.count(u8, listed.stdout, "\"kind\":\"user_text\""));
}

/// The names this session may delegate to, or null when it is not a delegation
/// and nothing is restricted.
///
/// Read from the persona this session is WEARING (its frozen header), not from
/// an argument: what a session may do is a property of what it was composed as,
/// and the header is the only thing that cannot have changed since.
fn allowedHere(ctx: *const Ctx, parent: []const u8) !?[]const []const u8 {
    const worn = (try defs.wornPersona(ctx.alloc, ctx.io, parent)) orelse return null;
    const entry = (try defs.find(ctx.alloc, ctx.io, ctx.env, worn)) orelse return &.{};
    return entry.def.agents;
}

/// The delegation depth this session is running at (`NULYA_AGENT_DEPTH`, set by
/// the runner for the step it drives). Absent — a top-level conversation, or a
/// person driving a delegated session from a front end — is zero.
fn currentDepth(env: *const std.process.Environ.Map) u32 {
    const raw = env.get("NULYA_AGENT_DEPTH") orelse return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch 0;
}

/// `agent@<version>` for the version running right now.
///
/// A frozen extension binary lives at `<root>/<id>/versions/<v>/bin/<id>`, so
/// the version is two directories up from this executable. Named rather than
/// left to `current`: this package is deliberately never activated (it is
/// brought into a session with `--with`), so there is no `current` to fall back
/// on — the same reason `/compact` names its version.
fn selfRef(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    const exe = std.process.executablePathAlloc(io, alloc) catch return "agent";
    const bin_dir = std.fs.path.dirname(exe) orelse return "agent";
    const version_dir = std.fs.path.dirname(bin_dir) orelse return "agent";
    const version = std.fs.path.basename(version_dir);
    if (!std.mem.startsWith(u8, version, "v-")) return "agent";
    return std.fmt.allocPrint(alloc, "agent@{s}", .{version});
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

// ── child processes ─────────────────────────────────────────────────────────

const max_child_output: usize = 4 << 20;

const Run = struct { code: u8, stdout: []u8, stderr: []u8 };

/// One `nulya <args…>` invocation, in this process's working directory — which
/// is the workspace, because that is where the host spawns an extension
/// (DESIGN §7.6). Output is captured, never inherited: stdout here is data.
fn run(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Run {
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

const max_detail_bytes: usize = 400;

/// What a failed child said, trimmed to something quotable. stderr first (that
/// is where the CLI writes diagnostics), stdout as the fallback.
fn detail(r: Run) []const u8 {
    const err = std.mem.trim(u8, r.stderr, " \t\r\n");
    const said = if (err.len != 0) err else std.mem.trim(u8, r.stdout, " \t\r\n");
    if (said.len == 0) return "no output";
    return said[said.len -| max_detail_bytes..];
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const at = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    return trimmed[0..at];
}

fn failed(alloc: std.mem.Allocator, code: i64, comptime fmt: []const u8, args: anytype) !rpc.Fail {
    return .{ .code = code, .message = try std.fmt.allocPrint(alloc, fmt, args) };
}
