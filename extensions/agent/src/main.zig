//! `agent` — delegation, outside the kernel.
//!
//! **What it is.** Three tools in one binary, dispatched on `params.name`:
//!
//!   `agent {name, task}`   the model asking for one piece of work to be
//!                          delegated. Materialises the persona, creates the
//!                          child session, and starts a BACKGROUND TASK that
//!                          drives it. Returns a receipt naming the child.
//!   `materialize {name}`   a definition file → a frozen data extension version.
//!                          The single writer of that rendering; the front end
//!                          calls it too rather than keeping a second copy.
//!   `run {session, …}`     the background command itself (`runner.zig`).
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
    if (std.mem.eql(u8, request.name, "materialize")) return materialize(ctx, request.arguments);
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
        .message = try std.fmt.allocPrint(ctx.alloc, "agent has no tool named '{s}' (it has agent, materialize, list, run)", .{request.name}),
    } };
}

// ── materialize ─────────────────────────────────────────────────────────────

const Materialized = struct {
    def: defs.Def,
    id: []const u8,
    version: []const u8,
    warnings: []const []const u8,
};

/// Read a definition, render it, freeze it. The one implementation of that
/// rendering (see `defs.zig`): the version id is the hash of exactly these
/// bytes, so a second spelling anywhere would be a second version of one persona.
fn build(ctx: *const Ctx, name: []const u8) !union(enum) { ok: Materialized, failed: rpc.Fail } {
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

    const id = try defs.extensionId(alloc, def.name);
    const draft = try defs.draftPath(alloc, id);
    try defs.writeDraft(alloc, ctx.io, def, id, draft);

    // Built every time, and that is cheap and deliberate: the version is the
    // hash of the draft, so an unedited definition rebuilds to the version
    // already in the store, and an edit is picked up without anybody running a
    // command. A user definition lands in the user store — the layer it was
    // written in, so a checkout's personas do not accumulate on the machine.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ ctx.exe, "ext", "build", draft });
    if (defs.userStore(def.layer)) try argv.append(alloc, "--user");
    const built = try run(alloc, ctx.io, argv.items);
    if (built.code != 0) {
        return .{ .failed = try failed(alloc, rpc.code_refused, "could not build the persona for '{s}': {s}", .{ def.name, detail(built) }) };
    }
    const version = extractVersion(built.stdout) orelse {
        return .{ .failed = try failed(alloc, rpc.code_refused, "building '{s}' produced no version: {s}", .{ def.name, detail(built) }) };
    };
    // Before anybody composes with this: can the packages its pins name actually
    // be brought in? Checked here so BOTH callers get the same answer — the
    // model's `agent` tool and the front end's `/agent` both go through
    // `materialize`, and a second check on one side would be a second opinion.
    if (try membersAvailable(ctx, def.name, try pinMembers(alloc, def.pins))) |fail| {
        return .{ .failed = fail };
    }
    return .{ .ok = .{ .def = def, .id = id, .version = version, .warnings = entry.warnings } };
}

/// `materialize {name}` → the frozen version, and the arguments a driver needs
/// to compose it. JSON rather than prose: its reader is a driver.
fn materialize(ctx: *const Ctx, args: std.json.ObjectMap) !rpc.Outcome {
    const name = rpc.trimmedField(args, "name");
    if (name.len == 0) return rpc.invalidParams(ctx.alloc, "materialize needs a name (which agent definition to freeze)", .{});
    const outcome = try build(ctx, name);
    switch (outcome) {
        .failed => |f| return .{ .failed = f },
        .ok => |m| {
            var out: std.Io.Writer.Allocating = .init(ctx.alloc);
            var jw: std.json.Stringify = .{ .writer = &out.writer };
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(m.def.name);
            try jw.objectField("id");
            try jw.write(m.id);
            try jw.objectField("version");
            try jw.write(m.version);
            try jw.objectField("ref");
            try jw.write(try std.fmt.allocPrint(ctx.alloc, "{s}@{s}", .{ m.id, m.version }));
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
            try jw.objectField("pins");
            try jw.beginArray();
            for (m.def.pins) |pin| try jw.write(pin);
            try jw.endArray();
            // The `--with` members those pins imply: a pin names a tool of an
            // extension, and an extension that is not a MEMBER of the session
            // cannot be pinned into it (`PinNamesUnknownExtension`, DESIGN §5.1).
            try jw.objectField("members");
            try jw.beginArray();
            for (try pinMembers(ctx.alloc, m.def.pins)) |id| try jw.write(id);
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


/// The distinct extension ids a definition's pins name.
///
/// A pin gives a tool a native slot; it does not make its package a member of
/// the session, and pinning a tool of a non-member is a hard refusal
/// (`PinNamesUnknownExtension`, DESIGN §5.1). So every delegation derives one
/// `--with <id>` per distinct id — without a version, so the store's `current`
/// is used and the persona follows whatever is installed.
///
/// Deduplicated because a command line saying the same thing three times is
/// noise, not because it would be wrong: the kernel documents (and this
/// repository's own check confirmed) that a repeated `--with` of one id simply
/// overrides the earlier one, as does naming an already-activated id.
fn pinMembers(alloc: std.mem.Allocator, pins: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (pins) |pin| {
        const rest = pin["ext:".len..];
        const id = rest[0..std.mem.indexOfScalar(u8, rest, '/').?];
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, id)) break;
        } else try out.append(alloc, id);
    }
    return out.items;
}


/// Check that every `--with` a persona's pins imply can actually be resolved,
/// and say how to fix it when one cannot. Null when all of them are fine.
///
/// Two reasons this is checked HERE rather than left to the kernel's own
/// refusal:
///
///  1. **The message.** The kernel says "--with names an extension with no such
///     built version", which is true and does not tell a person that their
///     `explore` persona wants `std` and that `nulya ext build extensions/std
///     --user` is the way out. This one names the persona, the packages, and the
///     command.
///  2. **A kernel bug this would otherwise hit.** `session new --with <a
///     resolvable one> --with <an unresolvable one>` panics in
///     `composition.unionWith`'s `errdefer freeResolved` (an invalid free)
///     rather than returning `WithVersionNotFound`; with the unresolvable one
///     FIRST it reports cleanly. A delegation always passes the persona's own
///     `--with` first, so it would always take the crashing order. Reported
///     alongside this change; nothing here depends on how it is fixed —
///     checking first is what a good message needs anyway.
///
/// "Resolvable" is `current`, because that is what a bare `--with <id>` takes:
/// a version built but never activated is not one the store will hand over.
fn membersAvailable(ctx: *const Ctx, agent_name: []const u8, members: []const []const u8) !?rpc.Fail {
    if (members.len == 0) return null;
    const alloc = ctx.alloc;
    const listed = try run(alloc, ctx.io, &.{ ctx.exe, "ext", "list" });
    if (listed.code != 0) return null; // no listing is no evidence; let the kernel answer

    var missing: std.ArrayList([]const u8) = .empty;
    var inactive: std.ArrayList([]const u8) = .empty;
    for (members) |id| {
        switch (activation(listed.stdout, id)) {
            .active => {},
            .built => try inactive.append(alloc, id),
            .absent => try missing.append(alloc, id),
        }
    }
    if (missing.items.len == 0 and inactive.items.len == 0) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.print("'{s}' asks for tools from packages this workspace cannot use yet", .{agent_name});
    if (inactive.items.len != 0) {
        try out.writer.print("; built but not active: {s} (`nulya ext activate --user <id> <version>`, see `nulya ext list`)", .{try std.mem.join(alloc, ", ", inactive.items)});
    }
    if (missing.items.len != 0) {
        try out.writer.print("; not built here: {s} (`nulya ext seed --user` then `nulya ext build <draft> --user`, e.g. `nulya ext build extensions/std --user`)", .{try std.mem.join(alloc, ", ", missing.items)});
    }
    try out.writer.writeAll(". Nothing was delegated — install them, or drop those pins from the definition.");
    return .{ .code = rpc.code_refused, .message = try out.toOwnedSlice() };
}

const Activation = enum { active, built, absent };

/// One `ext list` row: `<id>\t<version|(inactive)>\t<root>[\t…]` (DESIGN §7.2).
fn activation(listing: []const u8, id: []const u8) Activation {
    var found: Activation = .absent;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        var fields = std.mem.splitScalar(u8, line, '\t');
        const row_id = fields.next() orelse continue;
        if (!std.mem.eql(u8, row_id, id)) continue;
        const version = fields.next() orelse continue;
        // The first root that has it ACTIVE is the one that wins (§7.2); a later
        // inactive copy says nothing about the earlier answer.
        if (std.mem.startsWith(u8, version, "v-")) return .active;
        found = .built;
    }
    return found;
}

// ── list ────────────────────────────────────────────────────────────────────

/// `list` — every definition all three layers hold, in search order.
///
/// Driver-facing, and never pinned: the model does not need a catalogue (an
/// unknown name already comes back with the names that exist), while a driver
/// needs one to draw a picker and to decide what a checkout brought with it.
/// This is the ONE reader of the definition format, the way `materialize` is the
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

    if (target.len != 0) return followUp(ctx, parent, target, task, depth);
    return newDelegation(ctx, parent, name, task, depth);
}

/// A fresh delegation: materialise the persona, open a session wearing it, give
/// it the task, and start the background task that drives it.
fn newDelegation(ctx: *const Ctx, parent: []const u8, name: []const u8, task: []const u8, depth: u32) !rpc.Outcome {
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

    const outcome = try build(ctx, name);
    const m = switch (outcome) {
        .failed => |f| return .{ .failed = f },
        .ok => |ok| ok,
    };

    // The parent's model unless the definition names one: a persona that does
    // not care which model runs it should not silently move the work onto
    // whatever the config's default happens to be.
    const inherited = parentIdentity(alloc, ctx.io, parent);
    const profile = if (m.def.profile.len != 0) m.def.profile else inherited.profile;
    const model = if (m.def.profile.len != 0) m.def.model else inherited.model;

    const self_ref = try selfRef(alloc, ctx.io);

    var new_argv: std.ArrayList([]const u8) = .empty;
    try new_argv.appendSlice(alloc, &.{ ctx.exe, "session", "new", "--with", try std.fmt.allocPrint(alloc, "{s}@{s}", .{ m.id, m.version }) });
    if (profile.len != 0) try new_argv.appendSlice(alloc, &.{ "--profile", profile });
    if (model.len != 0) try new_argv.appendSlice(alloc, &.{ "--model", model });
    // A pin needs its package to be a MEMBER of the session (DESIGN §5.1), and
    // the child composes from scratch — whatever is activated in this workspace
    // is not automatically in it. So each distinct id its pins name comes along
    // as `--with <id>`, at the store's `current`.
    const members = try pinMembers(alloc, m.def.pins);
    for (members) |id| try new_argv.appendSlice(alloc, &.{ "--with", id });
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

    // Is it a delegation at all? A session wearing an `agent-*` member is one;
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
/// same string this tool composed.
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
    for (tasks.items) |item| {
        const row = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const command = rpc.stringField(row, "command") orelse continue;
        if (std.mem.indexOf(u8, command, needle) == null) continue;
        const state = rpc.stringField(row, "state") orelse continue;
        if (std.mem.eql(u8, state, "starting") or std.mem.eql(u8, state, "running")) return true;
    }
    return false;
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
    const path = std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent}) catch return .{};
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .{};
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);
    const line = (reader.interface.takeDelimiter('\n') catch return .{}) orelse return .{};
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return .{};
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{},
    };
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
    return said[said.len -| max_detail_bytes ..];
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const at = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    return trimmed[0..at];
}

fn failed(alloc: std.mem.Allocator, code: i64, comptime fmt: []const u8, args: anytype) !rpc.Fail {
    return .{ .code = code, .message = try std.fmt.allocPrint(alloc, fmt, args) };
}

fn extractVersion(text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, "v-") orelse return null;
    var end = at + 2;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]))) end += 1;
    return if (end > at + 2) text[at..end] else null;
}
