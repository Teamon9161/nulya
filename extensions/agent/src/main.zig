//! `agent` — delegation, outside the kernel. Four tools in one binary,
//! dispatched on `NULYA_TOOL`:
//!
//!   `agent {name, task}`    a new delegation: render the persona, open a
//!                           conversation wearing it, start a BACKGROUND TASK
//!                           driving it. Returns a receipt naming the DELEGATION.
//!   `agent {session, task}` another turn into one already going, including
//!                           while it works (`interrupt: true` = take it NOW).
//!   `render {name}`         a definition file → the prompt file and the whole
//!                           set of `session new` arguments it asks for. The
//!                           single WRITER of that rendering.
//!   `run {delegation, …}`   the background command itself (`runner.zig`).
//!
//! The model names a DELEGATION, never the session behind it; which harness holds
//! it is the definition's `runner:`, frozen into the record when it opens. The
//! persona reaches a session as `session new --prompt <file>` — bytes frozen into
//! the header, nothing installed. Every child session is `--bare`, so a
//! definition's `with` is its whole composition and it behaves the same in every
//! workspace. A delegated session carries this package only when its definition
//! names somebody to pass work to (`agents:` non-empty).

const std = @import("std");
const rpc = @import("rpc.zig");
const defs = @import("defs.zig");
const fleet = @import("fleet.zig");
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
    /// Absolute path of the nulya that spawned this process: the binary every
    /// child call must use, rather than whichever copy is on PATH.
    exe: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: a handful of child calls and one response.
    const alloc = init.arena.allocator();

    const name = init.environ_map.get("NULYA_TOOL") orelse "";
    const arguments = rpc.readArguments(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try rpc.answer(io, .{ .failed = "agent expects this call's arguments as one JSON object on stdin" }),
    };

    const exe = init.environ_map.get("NULYA_EXE") orelse "";
    const ctx: Ctx = .{ .alloc = alloc, .io = io, .env = init.environ_map, .exe = exe };

    // Host faults are folded into a refusal, so every path ends in one answer.
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

/// Read a definition and write its body where `session new --prompt` can read it.
/// The one implementation of that rendering.
fn render(ctx: *const Ctx, name: []const u8) !union(enum) { ok: Rendered, failed: []const u8 } {
    const alloc = ctx.alloc;
    if (!defs.isPlainName(name)) {
        return .{ .failed = try std.fmt.allocPrint(alloc, "'{s}' is not an agent name; a name is letters, digits, '.', '_' or '-' and names one definition file", .{name}) };
    }
    const entry = (try defs.find(alloc, ctx.io, ctx.env, name)) orelse {
        const known = try availableAgentsSummary(alloc, ctx.io, ctx.env);
        // Name the directories that were read. A definition written moments ago
        // and still not found is nearly always sitting in a `.nulya/agents`
        // under some OTHER directory — the shell that wrote it chose its own
        // cwd, and this delegation's workspace is the one below.
        const where = try defs.searchedDirs(alloc, ctx.io, ctx.env);
        return .{ .failed = if (known.len == 0)
            try std.fmt.allocPrint(
                alloc,
                "no agent '{s}': no definitions in {s}. Definitions are markdown files there; without one there is nobody to delegate to, so do the work yourself.",
                .{ name, where },
            )
        else
            try std.fmt.allocPrint(alloc, "no agent '{s}'. Available: {s}. Looked in {s}. For the full catalogue, run `nulya ext run agent list` with shell — from that same workspace, or it reads a different directory.", .{ name, known, where }) };
    };

    const def = entry.def;

    // Content-determined, so two delegations racing here write the same bytes
    // and an edit is picked up without anybody running a command.
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
            // The whole of how a persona reaches a session. Nothing is
            // installed, so there is no version and no id to name.
            try jw.objectField("prompt");
            try jw.write(m.path);
            // Always true, and named rather than assumed: without `--bare` the
            // session inherits the workspace's standing membership,
            // which its author never wrote down.
            try jw.objectField("bare");
            try jw.write(true);
            try jw.objectField("label");
            try jw.write(m.label);
            try jw.objectField("description");
            try jw.write(m.def.description);
            // Two columns, one answer: `permissions` is the word a definition
            // writes and the record freezes, `readonly` the single bit most
            // readers ask for.
            try jw.objectField("permissions");
            try jw.write(m.def.permissions.label());
            try jw.objectField("readonly");
            try jw.write(m.def.permissions.isReadonly());
            // Which harness holds the conversation, named so it is never
            // inferred from the absence of the field.
            try jw.objectField("runner");
            try jw.write(m.def.runner.label());
            try jw.objectField("layer");
            try jw.write(@tagName(m.def.layer));
            try jw.objectField("profile");
            try jw.write(m.def.profile);
            try jw.objectField("model");
            try jw.write(m.def.model);
            // An external runner's opaque model string. Its own column so a
            // reader never has to guess which vocabulary the value is in.
            try jw.objectField("runner_model");
            try jw.write(m.def.runner_model);
            try jw.objectField("max_steps");
            try jw.write(m.def.max_steps);
            try jw.objectField("max_exchanges");
            try jw.write(m.def.max_exchanges);
            // The names it may pass work to. Non-empty is what makes a delegated
            // session carry this package at all (`newDelegation`).
            try jw.objectField("agents");
            try jw.beginArray();
            for (m.def.agents) |one| try jw.write(one);
            try jw.endArray();
            try jw.objectField("with");
            try jw.beginArray();
            for (m.def.with) |member| try jw.write(member);
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
/// The ONE reader of the definition format, as `render` is the one writer of the
/// rendering: two parsers of one file would be two answers to "is this agent
/// read-only".
fn list(ctx: *const Ctx) !rpc.Outcome {
    const alloc = ctx.alloc;
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    const found = try defs.discover(alloc, ctx.io, ctx.env);

    // Where a rung would land if a delegation opened right now: this session's
    // profile, else the one the config chain opens on. Asked ONCE for the whole
    // list, and only when some definition names a rung — a picker's data is not
    // worth a subprocess nobody asked a question with.
    var payload: []const u8 = "";
    var here: []const u8 = "";
    for (found) |entry| {
        if (defs.rungOf(entry.def).len == 0) continue;
        const shown = proc.run(alloc, ctx.io, &.{ ctx.exe, "config", "show", "--json" }) catch break;
        if (shown.code != 0) break;
        payload = shown.stdout;
        here = hereProfile(alloc, ctx, payload);
        break;
    }

    try jw.beginArray();
    for (found) |entry| {
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
        // layer holds the name is exactly the thing somebody needs told.
        try jw.objectField("shadowed");
        try jw.write(entry.shadowed);
        try jw.objectField("source");
        try jw.write(entry.def.source);
        try jw.objectField("profile");
        try jw.write(entry.def.profile);
        try jw.objectField("model");
        try jw.write(entry.def.model);
        // The rung this persona RIDES — the one it named, or its own name when
        // it named no model at all, so every persona is something a profile can
        // staff. Empty only on one that already answered with a model of its
        // own (or a runner with no nulya profiles).
        try jw.objectField("rung");
        try jw.write(defs.rungOf(entry.def));
        // Where that rung lands on the profile a delegation would inherit right
        // now. Empty when this profile staffs no such rung, which is the case
        // somebody has to see: a rung with no landing runs on the model it
        // inherits, and a misspelled `@rung` looks exactly like that.
        try jw.objectField("rung_model");
        try jw.write(landing(alloc, payload, here, defs.rungOf(entry.def)));
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
        try jw.objectField("with");
        try jw.beginArray();
        for (entry.def.with) |member| try jw.write(member);
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
/// an ordinary variable and is absent when a person drives a delegated session
/// from a front end.
const max_depth: u32 = 3;

/// `agent{name, task}` — a new delegation — or `agent{session, task}` — another
/// turn in one that is already going.
///
/// The follow-up form is the cheaper one: another turn lands in a conversation
/// that still holds everything it learned and hits its OWN prefix cache, where a
/// fresh delegation pays for the reconnaissance again.
///
/// The `session` argument names a DELEGATION (`d-…`), not the session behind it:
/// a model naming a session id could only address a runner that has such things.
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

    // Which session is this? Without it there is nobody to report BACK to —
    // the report is deposited as a `note` into a session's inbox.
    //
    // The ID and not the file's path: everything below uses it as a name (the
    // task's owner, the record's `parent`, the header to read), and the path is
    // published only on the machine the file is on.
    const parent = ctx.env.get("NULYA_SESSION_ID") orelse
        return rpc.refuse(alloc, "agent must be called from inside a session (NULYA_SESSION_ID is not set)", .{});
    if (parent.len == 0) return rpc.refuse(alloc, "agent must be called from inside a session (NULYA_SESSION_ID is empty)", .{});

    const depth = currentDepth(ctx.env);
    if (depth >= max_depth) {
        return rpc.refuse(
            alloc,
            "delegation is already {d} levels deep; do this one yourself. (A chain this long is usually two agents handing the same work back and forth.)",
            .{depth},
        );
    }

    // A model reference is chosen when a session is CREATED and frozen there, so
    // a follow-up cannot honour one; ignoring it quietly would be worse.
    if (target.len != 0 and asked_model.len != 0) {
        return rpc.refuse(
            alloc,
            "model applies to a NEW delegation only: {s} froze what it runs on when it was created and append-only is what makes another turn cheap. Drop model to follow up, or start a fresh delegation with name + model.",
            .{target},
        );
    }
    // The ceiling is frozen into the record when the delegation opens: a
    // follow-up that could widen it would make the ceiling a suggestion. So this
    // argument only means anything on the form that CREATES something.
    if (target.len != 0 and asked_permissions.len != 0) {
        return rpc.refuse(
            alloc,
            "permissions applies to a NEW delegation only: {s} froze what it may do when it was opened, and a follow-up that could widen that would make it no ceiling at all. Drop permissions to follow up, or start a fresh delegation with name + permissions.",
            .{target},
        );
    }
    // `interrupt` is how a message is delivered, not a kind of message, so it
    // only means anything where there is something in flight to interrupt.
    if (name.len != 0 and interrupt) {
        return rpc.refuse(
            alloc,
            "interrupt applies to a delegation that is already going: there is nothing yet to interrupt in a new one. Drop interrupt to start '{s}'.",
            .{name},
        );
    }
    if (target.len != 0) return sendTurn(ctx, parent, target, task, interrupt, depth);
    // `model` is NOT parsed here: which vocabulary it is in depends on the
    // runner the definition names, and the definition is not read until
    // `newDelegation` renders it.
    //
    // Permissions: the call, then the definition, and nothing else — never the
    // parent session, a front end's mode, or the environment. This call is itself
    // gated by the parent, so `unsafe` is visible before it runs.
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

    // What runs this, nearest first: the call, the definition, then the parent.
    //
    // A PAIR, NEVER A MIX: `--model` is an id WITHIN a profile, so taking the
    // profile from one source and the id from another names a model that profile
    // does not serve.
    //
    // An EXTERNAL runner has its own catalogue, so the same argument is an
    // opaque string passed through untouched and never inherited from the parent.
    var profile: []const u8 = "";
    var model: []const u8 = "";
    var runner_model: []const u8 = "";
    var effort: []const u8 = "";
    var where: Where = .{};
    var chosen = false;
    if (m.def.runner.usesNulyaModels()) {
        // `@rung` is the third shape of this argument, and the only one whose
        // answer depends on the profile the levels below settle on — so it is
        // recognised here and spent after them.
        const asked_rung: []const u8 = if (asked_model.len == 0) "" else blk: {
            const shaped = defs.parseRole(asked_model) orelse break :blk "";
            if (shaped.len == 0) return rpc.refuse(alloc, "model '{s}' names no rung after the @ — a rung is named the way a sub-agent is (letters, digits, `-`, `_`, and `.` after the first character).", .{asked_model});
            break :blk shaped;
        };
        const ref: ?defs.ModelRef = if (asked_model.len == 0 or asked_rung.len != 0) null else defs.parseModelRef(asked_model) orelse {
            return rpc.refuse(
                alloc,
                "model must be <profile>, <profile>/<model-id> or @<rung> (the same forms a definition's `model:` takes) — got '{s}'. `nulya config show` lists the profiles, the model ids each one serves and the rungs each one staffs.",
                .{asked_model},
            );
        };
        chosen = asked_model.len != 0;
        // One read of a header that can be megabytes, two answers out of it:
        // what to inherit running ON, and where to run.
        const header = header_mod.object(alloc, ctx.io, parent);
        // A pair, never a mix (see above).
        const identity: Identity = if (ref) |r|
            .{ .profile = r.profile, .model = r.model }
        else if (m.def.profile.len != 0)
            .{ .profile = m.def.profile, .model = m.def.model }
        else
            parentIdentity(alloc, header);
        profile = identity.profile;
        model = identity.model;
        // Never a decision, always inherited: a sub-agent works over the same
        // checkout as the conversation that delegated to it.
        where = parentWhere(alloc, header);

        // A rung is asked of whatever profile the levels above just settled, so
        // `model: @explore` on a definition that also names a profile means
        // "that profile's explore". The call's rung beats the definition's, like
        // every other level; a profile that staffs neither leaves this alone,
        // which is plain inheritance.
        const rung = if (asked_rung.len != 0) asked_rung else if (ref != null) "" else defs.rungOf(m.def);
        if (rungOn(alloc, ctx, profile, rung)) |staffed| {
            if (staffed.profile.len != 0) profile = staffed.profile;
            model = staffed.model;
            effort = staffed.effort;
        }
    } else {
        // A rung names a nulya profile's table, so passing it through would send
        // the word `@explore` to somebody else's harness as a model name.
        if (defs.parseRole(asked_model) != null) {
            return rpc.refuse(
                alloc,
                "'{s}' names a rung of a nulya profile, and '{s}' runs on the {s} harness, which has no such table. Give a model name in that harness's own vocabulary, or drop `model` to run on what it is configured for.",
                .{ asked_model, m.def.name, m.def.runner.label() },
            );
        }
        chosen = asked_model.len != 0;
        runner_model = if (asked_model.len != 0) asked_model else m.def.runner_model;
    }

    // The ceiling: the call, or the definition, and nothing behind those two —
    // an inheritable escalation would be one nobody wrote down.
    const permissions = asked_permissions orelse m.def.permissions;

    const self_ref = try proc.selfRef(alloc, ctx.io);

    // Minted BEFORE the conversation is opened: a runner may need somewhere of
    // its own to put what it freezes. Nothing is written yet — the record's
    // opening row is below, once there is a remote conversation to name.
    const d = try record.mint(alloc, ctx.io);

    // …and this package itself, but ONLY for a persona that names somebody to
    // pass work to: a session that cannot delegate does not carry the tool, so
    // there is nothing to refuse later. Membership is the whole of it — the
    // `agent` tool is `surface: "auto"`, so naming the package puts it on that
    // session's tool face. The other three are `internal`.
    const created = try runners.start(m.def.runner, alloc, ctx.io, .{
        .exe = ctx.exe,
        .prompt = m.path,
        .env = ctx.env,
        .profile = profile,
        .model = model,
        .runner_model = runner_model,
        // The ceiling reaches the runner HERE, not only when a round is driven:
        // a runner that cannot enforce the read-only one refuses the whole
        // delegation rather than opening one that would run wider than it said.
        .permissions = permissions,
        .with = m.def.with,
        .with_self = if (m.def.agents.len != 0) self_ref else "",
        .delegation = d,
        .environment = where.environment,
        .workspace = where.workspace,
    });
    if (created.run.code != 0) {
        // Straight through, including the credential refusal: the kernel already
        // says the whole way out. The one thing added is where the model
        // reference came from, and only when it came from the CALL, so the caller
        // knows it can retry without it.
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

    // Everything decided once about this delegation. Written BEFORE the first
    // message, so a runner started by that message always finds a record
    // describing what it drives.
    try record.appendCreated(alloc, ctx.io, std.Io.Dir.cwd(), d, .{
        .agent = m.def.name,
        .runner = m.def.runner.label(),
        .runner_version = created.version,
        .remote = remote,
        .parent = parent,
        .permissions = permissions,
        .profile = profile,
        .model = model,
        .effort = effort,
        .runner_model = runner_model,
        // Read from the definition HERE and never again — everything after this
        // reads the record.
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
        // Unreachable in practice, but saying so rather than asserting keeps one
        // shape for both callers.
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

/// Everything the sending and waking paths need — from the RECORD for a
/// delegation that exists, from the definition for one being opened.
///
/// Short because what a round is driven WITH is read from the record by the
/// process that drives it, so what is left is what DELIVERING a message needs.
const Spec = struct {
    delegation: []const u8,
    remote: []const u8,
    runner: runners.Runner,
};

/// Another turn into a delegation that is already going.
///
/// Append-only, so the sub-agent resumes with everything it learned in front of
/// it and hits its OWN prefix cache. Nothing new is created: same conversation,
/// same frozen composition, same ceiling.
///
/// NEVER REFUSED FOR BEING BUSY: a turn arriving mid-run is what the main
/// conversation does when a person types while the model is answering, and the
/// kernel drains a session's inbox at every step boundary. What that needs is not
/// a refusal but the wake invariant below.
fn sendTurn(
    ctx: *const Ctx,
    parent: []const u8,
    target: []const u8,
    task: []const u8,
    interrupt: bool,
    depth: u32,
) !rpc.Outcome {
    const alloc = ctx.alloc;

    // ① The shape. A session id here is the OLD vocabulary and has no record, so
    // name the word that replaced it rather than report a missing directory.
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

    // ② Is it one of ours? The record says which persona wears it, which runner
    // drives it and what that runner opened; a session header could only answer
    // for a nulya session.
    const state = (record.read(alloc, ctx.io, std.Io.Dir.cwd(), target) catch |err| switch (err) {
        // A record that is there but cannot be believed is not one to send into:
        // what it may do and how much is left are both in that file. Named
        // rather than folded into "no delegation" — different repairs.
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
    // the frozen `parent` says which. Without this, `wake` would start the task
    // under whichever session is calling, so a second session that learned the id
    // could take the delegation over and have its next report land elsewhere.
    //
    // A fork is a different conversation by this rule, as it is everywhere:
    // `session new --parent` inherits no composition, prompts or images either.
    if (!std.mem.eql(u8, parent, state.created.parent)) {
        return rpc.refuse(
            alloc,
            "delegation {s} belongs to another conversation (it was opened by session {s}), and a sub-agent reports back to the one that opened it. Start a fresh delegation for this work.",
            .{ target, state.created.parent },
        );
    }

    // ④ How many turns has it had, and how many was it opened with? Both from
    // the record: the count because it is the only one an external runner can
    // answer too, the budget because an edit must not change what a conversation
    // already under way is allowed and a deletion must not strand one.
    const allowed_exchanges = state.created.max_exchanges;
    // `>` rather than `>= allowed + 1`: same thing without an addition that
    // overflows on the largest budget there is. `turns` counts the opening task
    // too, so "has had them all" is exactly "more turns than follow-ups
    // allowed".
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

/// Record one message, THEN deliver it. That order is the fail-closed one: the
/// two writes cannot be made atomic, and recording first can only spend an
/// exchange on a message that did not go — which the caller is told. Sending
/// first would leave a message the sub-agent answers, uncounted, with the caller
/// told it failed, quietly widening `max_exchanges` by one.
///
/// An interrupt is the same message, sent saying so. On the arms with an inbox
/// that word travels IN the message, atomically, because two writes is a race in
/// either order (`mailbox.Message`); the `<d>/interrupt` marker is written as
/// well and is what stops a turn on the nulya arm — which has no inbox — and on
/// the arms that do not drain mid-turn. The marker goes AFTER the message, so a
/// runner that sees it always finds something behind it.
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

/// The sender's half of the wake invariant: after DELIVERING, probe the runner's
/// lease and start one only when nobody holds it.
///
/// The runner's half mirrors this — it re-checks for messages AFTER letting the
/// lease go — and between the two, a message delivered in any window is seen by
/// somebody: either the holder finds it before letting go, or it lets go and
/// finds it, or it has already let go and this probe starts a fresh runner.
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
/// The DELEGATION is asked FIRST and the header not at all on that path: a
/// delegated session's authority is its record, frozen when it opened — not the
/// definition as it reads today, which would let an edit widen (or empty) the
/// whitelist of a conversation already under way. Asking the header first would
/// let an unreadable one answer "nothing is restricted" for a session that
/// plainly IS a delegation.
///
/// With no delegation named (`record.delegation_var`), the definition answers:
/// that is a person driving a persona by hand from a front end, where nothing was
/// ever frozen.
fn allowedHere(ctx: *const Ctx, parent: []const u8) !?[]const []const u8 {
    const d = std.mem.trim(u8, ctx.env.get(record.delegation_var) orelse "", " \t\r\n");
    if (record.isPlainId(d)) {
        const found = record.read(ctx.alloc, ctx.io, std.Io.Dir.cwd(), d) catch null;
        if (found) |state| return state.created.agents;
        // A delegation was named and its record is missing or damaged: a
        // delegated session whose frozen answer cannot be read, so `leaf`. The
        // caller turns an empty list into "this agent cannot delegate".
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
/// ABSENT is zero: a top-level conversation, or a person driving a delegated
/// session from a front end. Present and UNREADABLE is the ceiling: somebody set
/// it, this build cannot tell to what, and reading that as zero would say "top
/// level" about a session that certainly is not.
fn currentDepth(env: *const std.process.Environ.Map) u32 {
    const raw = env.get("NULYA_AGENT_DEPTH") orelse return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch max_depth;
}

const Identity = struct { profile: []const u8 = "", model: []const u8 = "" };

/// Where the parent's commands run: the `--env` spec verbatim, `""` being this
/// machine, and the remote workspace that spec needs. A delegated session is
/// opened with the same pair, so parent and child work over ONE workspace while
/// both ledgers stay on the machine driving them.
const Where = struct { environment: []const u8 = "", workspace: []const u8 = "" };

/// What the parent session runs on, from its frozen header. Best effort: an
/// unreadable header means "no inheritance", and the kernel's own default
/// decides.
fn parentIdentity(alloc: std.mem.Allocator, obj: ?std.json.ObjectMap) Identity {
    const o = obj orelse return .{};
    var out: Identity = .{};
    if (rpc.stringField(o, "model")) |profile| out.profile = alloc.dupe(u8, profile) catch "";
    if (o.get("model_identity")) |ident| {
        if (ident == .object) {
            if (rpc.stringField(ident.object, "model")) |id| out.model = alloc.dupe(u8, id) catch "";
        }
    }
    return out;
}

/// The profile a delegation opened from here would inherit: this session's, else
/// the one the config chain opens on. Empty when neither can be read.
fn hereProfile(alloc: std.mem.Allocator, ctx: *const Ctx, payload: []const u8) []const u8 {
    if (ctx.env.get("NULYA_SESSION_ID")) |id| {
        if (id.len != 0) {
            const ident = parentIdentity(alloc, header_mod.object(alloc, ctx.io, id));
            if (ident.profile.len != 0) return ident.profile;
        }
    }
    return fleet.activeProfile(alloc, payload) orelse "";
}

/// One rung's landing point as one string: `<model-id>`, or `<profile>/<model-id>`
/// when it crosses. Empty when that profile staffs no such rung.
fn landing(alloc: std.mem.Allocator, payload: []const u8, profile: []const u8, rung: []const u8) []const u8 {
    const staffed = fleet.find(alloc, payload, profile, rung) orelse return "";
    if (staffed.profile.len == 0) return staffed.model;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ staffed.profile, staffed.model }) catch staffed.model;
}

/// Which model `rung` lands on for `profile`, asked of the kernel's own
/// projection of the config chain. Null for every way of not having an answer —
/// no rung asked for, no profile inherited, the command failing, that profile
/// staffing no such rung — because the caller reads all of them as "inherit".
fn rungOn(alloc: std.mem.Allocator, ctx: *const Ctx, profile: []const u8, rung: []const u8) ?fleet.Rung {
    if (profile.len == 0 or rung.len == 0) return null;
    const shown = proc.run(alloc, ctx.io, &.{ ctx.exe, "config", "show", "--json" }) catch return null;
    if (shown.code != 0) return null;
    return fleet.find(alloc, shown.stdout, profile, rung);
}

/// Same header, same best-effort reading: unreadable means "this machine", and
/// `session new` refuses a spec it cannot reach anyway.
fn parentWhere(alloc: std.mem.Allocator, obj: ?std.json.ObjectMap) Where {
    const o = obj orelse return .{};
    var out: Where = .{};
    if (rpc.stringField(o, "environment")) |spec| out.environment = alloc.dupe(u8, spec) catch "";
    if (rpc.stringField(o, "remote_workspace")) |dir| out.workspace = alloc.dupe(u8, dir) catch "";
    return out;
}

fn failed(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(alloc, fmt, args);
}
