//! `nulya session …` — the one session driver surface. There is no setTools /
//! setModel / replaceHistory: changing composition means a new session.
//!
//! Each subcommand is a separate process over the durable session file, and
//! only `step` ever WRITES it: `append`, `note` and `cancel` deposit into the
//! session's siblings (`<id>.inbox/`, `<id>.cancel`) for `step` to consume at
//! its next step boundary, and `events` tails the file read-only.
//!
//! Output discipline: stdout carries data and success only (a new id, event
//! JSONL, a listing, a confirmation); every refusal goes to stderr. Under
//! `--stream` the diagnostic is itself a protocol line and stays on stdout.

const std = @import("std");
const environment = @import("../environment.zig");
const journal = @import("../journals/journal.zig");
const outcome = @import("../journals/outcome.zig");
const config = @import("../config.zig");
const ledger = @import("../ledger.zig");
const prompt = @import("../prompt.zig");
const session = @import("../session.zig");
const loop = @import("../loop.zig");
const provider = @import("../provider.zig");
const composition = @import("../composition.zig");
const launch = @import("../launch.zig");
const remote = @import("../environment/remote/mod.zig");
const common = @import("common.zig");
const cli_ext = @import("ext.zig");
/// Only for `sweepRemoteReports`: this file lends it the channel it already
/// has.
const task_cli = @import("task.zig");
const session_list = @import("session_list.zig");
const StepStream = @import("step_stream.zig").StepStream;
const StepGate = @import("step_stream.zig").StepGate;
const cwdRealPath = common.cwdRealPath;
const flagValue = common.flagValue;
const sliceHasFlag = common.sliceHasFlag;
const memberRef = common.memberRef;
const freeMemberRefs = common.freeMemberRefs;
const envSessionId = common.envSessionId;
const printOut = common.printOut;
const printErrFmt = common.printErrFmt;
const printRaw = common.printRaw;
const printErr = common.printErr;

/// Answers "which build target do this session's extension calls run on" by
/// asking that machine (`composition.ExecTargetProbe`). Opens a channel, reads
/// the handshake and closes it again: at most once per creation, and only when
/// a `compiled` member is actually composed.
///
/// The agent reports `@tagName(builtin.cpu.arch)` and `@tagName(builtin.os.tag)`,
/// exactly the spelling `extension/target.zig` puts into a version id, so this
/// is a comparison and never a translation.
const RemoteTargetProbe = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    spec: []const u8,
    ssh_password: ?[]const u8 = null,
    answer: ?[]u8 = null,

    fn ask(ptr: *anyopaque) anyerror![]const u8 {
        const self: *RemoteTargetProbe = @ptrCast(@alignCast(ptr));
        if (self.answer) |cached| return cached;
        var ch = try remote.Channel.connectPassword(self.alloc, self.io, try remote.parseSpec(self.spec), launch.version, .default, self.ssh_password);
        defer ch.deinit();
        const words = try std.fmt.allocPrint(self.alloc, "{s}-{s}", .{ ch.hello.arch, ch.hello.os });
        self.answer = words;
        return words;
    }

    fn handle(self: *RemoteTargetProbe) composition.ExecTargetProbe {
        return .{ .ptr = self, .askFn = ask };
    }

    fn deinit(self: *RemoteTargetProbe) void {
        if (self.answer) |cached| self.alloc.free(cached);
    }
};

pub fn dispatchSession(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return sessionUsage(io);
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "new")) return sessionNew(alloc, io, rest);
    if (std.mem.eql(u8, sub, "append")) return sessionAppend(alloc, io, rest);
    if (std.mem.eql(u8, sub, "note")) return sessionNote(alloc, io, rest);
    if (std.mem.eql(u8, sub, "step")) return sessionStep(alloc, io, rest);
    if (std.mem.eql(u8, sub, "events")) return sessionEvents(alloc, io, rest);
    if (std.mem.eql(u8, sub, "cancel")) return sessionCancel(alloc, io, rest);
    if (std.mem.eql(u8, sub, "prune")) return sessionPrune(alloc, io, rest);
    if (std.mem.eql(u8, sub, "outcome")) return sessionOutcome(alloc, io, rest);
    if (std.mem.eql(u8, sub, "list")) return session_list.sessionList(alloc, io, sliceHasFlag(rest, "--json"));
    try printErr(io, "unknown `session` subcommand; try new|append|note|step|events|cancel|prune|outcome|list\n");
    return 1;
}

/// `nulya session outcome <id> <verdict> [--note <text>] [--seq N]` — record
/// how a session turned out. Writes only the outcome journal: never the
/// session file, never its writer lease, which is what lets a session another
/// process is stepping be judged right now. `--seq` narrows a line to one
/// assistant turn; it is checked for being a positive integer and NOT
/// bounds-checked, since reading the ledger would give up that property.
fn sessionOutcome(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try printErr(io, "usage: nulya session outcome <id> <success|partial|failure> [--note <text>] [--seq N]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const verdict = outcome.Verdict.parse(args[1]) orelse {
        try printErrFmt(alloc, io, "invalid verdict '{s}' (want success|partial|failure)\n", .{args[1]});
        return 1;
    };
    const note = flagValue(args[2..], "--note");
    var seq: ?u64 = null;
    if (flagValue(args[2..], "--seq")) |v| {
        const n = std.fmt.parseInt(u64, v, 10) catch 0;
        if (n == 0) {
            try printErr(io, "--seq must be a positive integer\n");
            return 1;
        }
        seq = n;
    }

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printErrFmt(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    // Who is judging. This command reaches the model through `shell`, whose env
    // names the live session, so a session grading itself is recorded as such.
    const by = try envSessionId(alloc);
    defer if (by) |b| alloc.free(b);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const at = try journal.rfc3339Now(alloc, io);
    defer alloc.free(at);
    try outcome.append(alloc, io, cwd_path, .{
        .session = id,
        .verdict = verdict,
        .note = note,
        .at = at,
        .source = if (by != null) .agent else .human,
        .by = by,
        .seq = seq,
    });

    try printOut(alloc, io, "{s}: {s}\n", .{ id, @tagName(verdict) });
    return 0;
}

/// The session's member extensions: the config's `extensions.with` first, then
/// every `--with <id>[@<version>][:<tool>,…]` in argv order (repeatable). Config
/// first so a command line naming the same id overrides it —
/// `composition.unionWith` keeps the last mention of an id. Both sources take
/// the same spelling. Strings borrow `configured` and `args`; the caller owns
/// the array and each selection (`freeMemberRefs`).
fn withRefs(
    alloc: std.mem.Allocator,
    configured: []const []const u8,
    args: []const []const u8,
) ![]composition.WithRef {
    var out: std.ArrayList(composition.WithRef) = .empty;
    errdefer freeMemberRefs(alloc, out.items);
    // An entry with no version follows `current`, so `ext activate` still moves
    // it and a rollback stays one verb.
    for (configured) |spec| try out.append(alloc, try memberRef(alloc, spec));
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--with")) continue;
        try out.append(alloc, try memberRef(alloc, args[i + 1]));
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// `--bare`: compose from argv alone. The standing config list
/// (`[extensions] with`) reads as empty, so a delegated sub-agent cannot inherit
/// capabilities its definition never named. `max_tools` is still read: it is a
/// ceiling, not a selection. The flag reaches no header column — a resume reads
/// the frozen list either way.
fn bareComposition(args: []const []const u8) bool {
    return sliceHasFlag(args, "--bare");
}

/// Every `--prompt <file>` (repeatable), read HERE, at creation time, into the
/// bytes the header freezes — a path would make the session's identity text
/// depend on something outside the session file staying put.
///
/// Null means the request was refused and the reason is already on stderr,
/// before a session id exists, so nothing was created. The caller owns the
/// array and every string in it.
fn promptRefs(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !?[]ledger.InlinePrompt {
    var out: std.ArrayList(ledger.InlinePrompt) = .empty;
    // Covers a refusal and an allocation failure both; a successful
    // `toOwnedSlice` leaves the list empty, so this then frees nothing.
    defer {
        freePrompts(alloc, out.items);
        out.deinit(alloc);
    }
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--prompt")) continue;
        const path = args[i + 1];
        i += 1;
        // The same limit composition reads an extension's system prompt with,
        // so a file accepted here is one every session boundary can carry.
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(prompt.max_system_prompt_bytes)) catch |err| {
            const why = switch (err) {
                error.FileNotFound => "no such file",
                error.StreamTooLong => "larger than the 2 MiB system prompt limit",
                error.IsDir => "is a directory",
                error.AccessDenied => "cannot be read",
                else => @errorName(err),
            };
            try printErrFmt(alloc, io, "--prompt {s}: {s}\n", .{ path, why });
            return null;
        };
        if (bytes.len == 0) {
            alloc.free(bytes);
            try printErrFmt(alloc, io, "--prompt {s}: file is empty\n", .{path});
            return null;
        }
        // `std.json.Stringify` writes a non-UTF-8 `[]const u8` as an ARRAY OF
        // NUMBERS, in both places these bytes are serialized: the header stops
        // matching its schema, and the provider body carries `"text":[89,…]`,
        // which every real model API rejects.
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            alloc.free(bytes);
            try printErrFmt(alloc, io, "--prompt {s}: not valid UTF-8\n", .{path});
            return null;
        }
        // The kernel never reads this label, but it goes into the same header
        // JSON the text above does, so it needs the same UTF-8 guarantee: raw
        // POSIX filenames do not promise UTF-8.
        const source = std.fs.path.stem(path);
        if (!std.unicode.utf8ValidateSlice(source)) {
            alloc.free(bytes);
            try printErrFmt(alloc, io, "--prompt {s}: file name is not valid UTF-8\n", .{path});
            return null;
        }
        try out.append(alloc, .{ .source = try alloc.dupe(u8, source), .text = bytes });
    }
    return try out.toOwnedSlice(alloc);
}

fn freePrompts(alloc: std.mem.Allocator, prompts: []const ledger.InlinePrompt) void {
    for (prompts) |p| {
        alloc.free(p.source);
        alloc.free(p.text);
    }
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn sessionNew(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const id = (try createSession(alloc, io, args, .refuse)) orelse return 1;
    defer alloc.free(id);
    try printOut(alloc, io, "{s}\n", .{id});
    return 0;
}

/// What creation does when the named profile's credential resolves nowhere.
///
///   refuse    — `session new`. Identity is frozen for life, so a session
///               created without its credential would be answered by the
///               offline stand-in forever while naming the requested model.
///   stand_in  — `nulya demo`, which shows the durable path on a machine that
///               has nothing configured.
pub const KeylessPolicy = enum { refuse, stand_in };

/// Create a durable session file from `session new`'s own flags and return its
/// id (owned by the caller), or null when the request was refused and the
/// reason has already been printed. `session new` and `nulya demo` are both
/// thin printers over this, so the two cannot drift; `keyless` is the one thing
/// they differ on, and it is named at both call sites rather than inferred.
pub fn createSession(
    alloc: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    keyless: KeylessPolicy,
) !?[]u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();

    var password_buf: [4097]u8 = undefined;
    var password_stdin = std.Io.File.stdin().readerStreaming(io, &password_buf);
    const ssh_password = if (sliceHasFlag(args, "--ssh-password-stdin"))
        remote.readSshPassword(alloc, &password_stdin.interface) catch |err| {
            try printErrFmt(alloc, io, "--ssh-password-stdin: {s}\n", .{@errorName(err)});
            return null;
        }
    else
        null;
    defer if (ssh_password) |secret| {
        std.crypto.secureZero(u8, secret);
        alloc.free(secret);
    };

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    if (!try storeTrusted(alloc, io, &host, cwd_path)) {
        try printErr(io, "session new failed: the workspace extension store is not trusted (see the lines above)\n");
        return null;
    }

    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    // `--parent <id>:<seq>` names the lineage this session continues. The
    // parent must exist: a lineage pointer into nothing is not provenance. Its
    // header is also where an unnamed model comes from, below.
    var parent: ?ledger.ParentRef = null;
    var parent_header: ?ledger.OwnedHeader = null;
    defer if (parent_header) |*h| h.deinit();
    if (flagValue(args, "--parent")) |p| {
        const ref = parseParent(p) orelse {
            try printErr(io, "invalid --parent (want <session>:<seq>)\n");
            return null;
        };
        if (!launch.isValidSessionId(ref.session)) {
            try printErr(io, "invalid --parent session id\n");
            return null;
        }
        const ppath = try launch.sessionPath(alloc, ref.session);
        defer alloc.free(ppath);
        parent_header = ledger.readHeader(alloc, io, std.Io.Dir.cwd(), ppath) catch |err| {
            if (err == error.UnsupportedLedgerVersion) {
                try printErrFmt(alloc, io, "session '{s}' was written by a newer nulya; this binary reads ledger v{d}\n", .{ ref.session, ledger.format_version });
            } else {
                try printErrFmt(alloc, io, "cannot read parent session '{s}': {s}\n", .{ ref.session, @errorName(err) });
            }
            return null;
        };
        parent = ref;
    }

    // `--profile` names HOW to reach a provider, `--model` WHICH of its ids to
    // run (default: the profile's own).
    const named_profile = flagValue(args, "--profile");
    const model_id = flagValue(args, "--model");

    // A fork continues its parent's model unless told otherwise, so a
    // compaction cannot change who the conversation is with because
    // `active_profile` moved meanwhile. Composition does NOT come along: a fork
    // is a session boundary like any other, where today's member list and newly
    // activated versions take hold.
    //
    // `--profile` replaces the parent's; `--model` only picks another id WITHIN
    // a profile, so the parent's profile still carries. Naming either
    // re-resolves against today's config; naming neither takes the parent's
    // frozen descriptor verbatim, which is the compaction case.
    //
    // An empty profile is a legacy header that never recorded one: absent, not
    // a profile named "".
    const parent_profile: ?[]const u8 = if (parent_header) |h|
        (if (h.value.model.len != 0) h.value.model else null)
    else
        null;
    const inherited: ?ledger.ModelDescriptor = if (parent_header) |h| blk: {
        if (named_profile != null or model_id != null) break :blk null;
        break :blk if (h.value.model_identity.provider.len != 0) h.value.model_identity else null;
    } else null;

    const profile = named_profile orelse parent_profile orelse
        (if (cfg.provider.active_profile.len != 0) cfg.provider.active_profile else "scripted");

    // An inherited identity needs no resolution and no credential warning: it
    // never degrades to scripted. A missing credential is reported, loudly and
    // once, by the `step` that needs it.
    var identity: ledger.ModelDescriptor = undefined;
    if (inherited) |d| {
        identity = d;
    } else {
        const profile_cfg = cfg.provider.findProfile(profile) orelse {
            try printErrFmt(alloc, io, "no such profile '{s}' (see `nulya config show`)\n", .{profile});
            return null;
        };
        // No credential, no session: the creation-time twin of resume's
        // `MissingCredential`. `nulya demo` keeps the fallback and does not
        // come through here.
        if (!launch.credentialAvailable(alloc, io, profile_cfg, &host)) {
            var paths = try config.ConfigPaths.init(alloc, &host);
            defer paths.deinit(alloc);
            const msg = if (profile_cfg.kind == .codex)
                try std.fmt.allocPrint(alloc, "profile '{s}' has no credential: run `codex login` (see `nulya config show`)\n", .{profile})
            else
                try std.fmt.allocPrint(
                    alloc,
                    "profile '{s}' has no credential: set {s}, or put api_key in {s} (see `nulya config show`)\n",
                    .{ profile, profile_cfg.api_key_env, paths.user },
                );
            defer alloc.free(msg);
            if (keyless == .refuse) {
                try printErr(io, msg);
                return null;
            }
            // `stand_in`: say the same sentence, then say what happens instead.
            // The demo goes on — with the scripted provider, frozen as scripted,
            // which is exactly what `resolveDescriptor` returns below.
            try printErr(io, msg);
            try printErr(io, "running the offline stand-in instead (this is `nulya demo`)\n");
        }
        // Freeze the RESOLVED model identity now: config chooses the model at
        // creation, and a later config edit can never change it.
        identity = launch.resolveDescriptor(alloc, io, cfg.provider, &host, profile, model_id);
    }

    // Where this session's `shell` commands — and its compiled extension calls
    // — will run, for its whole life. Checked before a session id exists: a
    // session frozen onto a machine it cannot reach would fail identically on
    // every step it ever takes.
    //
    // Environment is a creation-time identity fact like model identity, not
    // composition a new session boundary re-resolves, so `--env` ABSENT with a
    // `--parent` inherits `environment` AND `remote_workspace` from the
    // parent's frozen header instead of falling back to local. Naming `--env`
    // at all (any value, including `local`, which normalizes to `""`) means
    // "this machine here", and the parent's two columns play no part.
    // `--workspace` on its own overrides only the directory column.
    const env_named = flagValue(args, "--env");
    const inherit_env = env_named == null and parent_header != null;
    const exec = if (env_named) |e|
        environment.normalizeExecSpec(e)
    else if (parent_header) |h|
        // Normalized like every other path into this variable, so the value
        // frozen into the child does not depend on which branch produced it.
        environment.normalizeExecSpec(h.value.environment)
    else
        environment.normalizeExecSpec("");
    if (ssh_password != null and !remote.isSshSpec(exec)) {
        try printErr(io, "--ssh-password-stdin applies only with --env remote:ssh:<destination>\n");
        return null;
    }
    if (launch.execTargetRefusal(exec)) |why| {
        if (inherit_env) {
            try printErrFmt(
                alloc,
                io,
                "--env: inherited from parent session '{s}', which runs in '{s}': {s} (name --env explicitly on this fork to pick a different machine)\n",
                .{ parent.?.session, exec, why },
            );
        } else {
            try printErrFmt(alloc, io, "--env {s}: {s}\n", .{ exec, why });
        }
        return null;
    }

    // Which directory ON THAT MACHINE this session works in. Only a remote
    // environment has the question: a local session works where nulya was
    // started, and a `wsl` exec target does not move the workspace at all. On
    // an inherited `--env`, an unnamed `--workspace` inherits the parent's
    // directory too.
    const remote_workspace = flagValue(args, "--workspace") orelse
        (if (inherit_env) parent_header.?.value.remote_workspace else "");
    if (remote_workspace.len != 0 and !launch.isRemoteSpec(exec)) {
        try printErrFmt(
            alloc,
            io,
            "--workspace names a directory on the machine a remote session runs on; it applies only with --env remote:… ({s})\n",
            .{launch.remote_spec_syntax},
        );
        return null;
    }

    // `--carry` is what makes changing model, tools or system prompt mid
    // conversation ONE primitive: the fork copies the parent's events 1..seq
    // into a file of its own, under whatever the flags above resolved to. The
    // parent is only read.
    //
    // Read before anything exists on disk, like `--prompt` below: a history
    // that cannot be carried must leave no session behind at all.
    var carried: ?ledger.Carried = null;
    defer if (carried) |*c| c.deinit();
    if (sliceHasFlag(args, "--carry")) {
        const ref = parent orelse {
            try printErr(io, "--carry names no history: it copies a parent's events, so it needs --parent <id>:<seq>\n");
            return null;
        };
        const ppath = try launch.sessionPath(alloc, ref.session);
        defer alloc.free(ppath);
        carried = ledger.readCarry(alloc, io, std.Io.Dir.cwd(), ppath, ref.seq) catch |err| switch (err) {
            error.CarrySeqBeyondTail => {
                try printErrFmt(alloc, io, "--carry: session '{s}' has fewer than {d} events (see `nulya session events {s}`)\n", .{ ref.session, ref.seq, ref.session });
                return null;
            },
            error.LegacyModelRebind => {
                try printErrFmt(alloc, io, "--carry: session '{s}' records a model_rebind, an event this binary no longer has; carry the part before it (`--parent {s}:<seq>`)\n", .{ ref.session, ref.session });
                return null;
            },
            else => {
                try printErrFmt(alloc, io, "--carry: cannot read the history of '{s}': {s}\n", .{ ref.session, @errorName(err) });
                return null;
            },
        };
        // The same catalog rule `session append --image` asks, once, here: the
        // pictures come along, so the model taking the conversation over has to
        // claim it can see them.
        if (carried.?.has_images and !try visionClaimed(alloc, io, &cfg, identity.model, "--carry")) return null;
    }

    // Read before anything exists on disk: a `--prompt` that cannot be read
    // must leave no session behind at all.
    const prompts = (try promptRefs(alloc, io, args)) orelse return null;
    defer {
        freePrompts(alloc, prompts);
        alloc.free(prompts);
    }

    const id = try launch.genSessionId(alloc, io);
    defer alloc.free(id);
    const created = try journal.rfc3339Now(alloc, io);
    defer alloc.free(created);
    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);

    try std.Io.Dir.cwd().createDirPath(io, launch.sessions_dir);

    // No session ref: `session new` composes and writes a header, it never runs
    // a tool, so nothing here can start a background task. `exec` was vetted
    // above, so the two target errors cannot land here.
    //
    // A REMOTE spec is deliberately not passed: building that environment means
    // opening a connection, and `session new` runs nothing. Freezing the spec
    // is the whole of its job; the first `step` is where that machine has to
    // answer.
    const ext_roots = try launch.extensionRoots(alloc, &host, &cfg);
    defer launch.freeExtensionRoots(alloc, ext_roots);

    const compose_exec = if (launch.isRemoteSpec(exec)) "" else exec;
    var lenv = launch.localEnvironment(alloc, io, &cfg, null, compose_exec, ext_roots) catch |err| switch (err) {
        error.UnsupportedEnvironmentBackend => {
            try printErrFmt(alloc, io, "environment backend '{s}' is not implemented; only local\n", .{@tagName(cfg.environment.backend)});
            return null;
        },
        else => return err,
    };
    defer lenv.deinit();

    // Which machine's binaries will serve this session's extension calls. Only
    // a REMOTE session has the question, and it is asked lazily — hence a probe
    // rather than an answer: composing nothing compiled never connects.
    var target_probe: RemoteTargetProbe = .{ .alloc = alloc, .io = io, .spec = exec, .ssh_password = ssh_password };
    defer target_probe.deinit();

    const bare = bareComposition(args);

    // The session's members, and the whole of them: config's standing
    // `[extensions] with`, then every `--with <id>[@<version>][:<tool>,…]` on
    // the command line. A package joins a session only by being on this list —
    // activating one never puts it here, and the usage journal never puts a
    // tool on the model's face by itself.
    const with = try withRefs(alloc, if (bare) &.{} else cfg.extensions.with, args);
    defer freeMemberRefs(alloc, with);

    // A placeholder handle is enough since `new` never steps.
    var holder: launch.ModelHolder = .{ .scripted = .{} };
    const scratch = try launch.sessionScratchDir(alloc, id);
    defer alloc.free(scratch);
    var sess = session.AgentSession.createDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd_path },
            .scratch_dir = scratch,
        },
        .extension_roots = ext_roots,
        .registry = .{
            .max_tools = cfg.registry.max_tools,
            .with = with,
            .prompts = prompts,
            .exec_target = if (launch.isRemoteSpec(exec)) target_probe.handle() else null,
        },
    }, .{
        .workspace = std.Io.Dir.cwd(),
        .session_path = spath,
        .session_id = id,
        .model_profile = profile,
        .model_identity = identity,
        .environment = exec,
        .remote_workspace = remote_workspace,
        .created = created,
        .nulya_version = launch.version,
        .parent = parent,
    }) catch |err| switch (err) {
        error.WithVersionNotFound => {
            try printWithFailure(alloc, io, with, "has no such built version (see `nulya ext list`); give it one with `--with <id>@<version>`, or `nulya ext activate <id> <version>`");
            return null;
        },
        // A member named without a version resolved through `current` to
        // something unusable. `composition.resolveCurrent` already named the
        // `id@version` and the two ways back on stderr.
        error.ActiveExtensionBroken => {
            try printErrFmt(alloc, io, "session new failed: an extension this session names has a broken current version (see the line above)\n", .{});
            return null;
        },
        // A package has no build for the machine this session's tools run on.
        // The line above already named it, the target and the fix.
        error.ExecVersionNotFound => {
            try printErrFmt(alloc, io, "session new failed: an extension this session composes has no build for the machine its tools run on (see the line above)\n", .{});
            return null;
        },
        // The machine has to answer before its target can be known, so an
        // unreachable one stops creation rather than freezing a session onto a
        // guess.
        error.RemoteChannelLost, error.RemoteChannelStalled, error.RemoteVersionMismatch, error.RemoteSpecUnsupportedOnHost => {
            try printErrFmt(alloc, io, "session new failed: '{s}' did not answer, and this session composes an extension whose build for that machine has to be identified now\n", .{exec});
            return null;
        },
        error.WithToolNotDeclared => {
            try printWithFailure(alloc, io, with, "selects a tool its version does not declare, or one whose surface is `internal` and reachable only through `nulya ext run` (see `nulya ext inspect <id>`)");
            return null;
        },
        error.ToolBudgetExceeded => {
            try printWithFailure(alloc, io, with, "puts more tools on the face than registry.max_tools allows (the builtin included)");
            return null;
        },
        else => {
            try printErrFmt(alloc, io, "session new failed: {s}\n", .{@errorName(err)});
            return null;
        },
    };
    defer sess.deinit();
    if (carried) |c| {
        for (c.events) |e| sess.l.append(e) catch |err| {
            try printErrFmt(alloc, io, "session new failed while carrying history: {s}\n", .{@errorName(err)});
            return null;
        };
    }

    return try alloc.dupe(u8, id);
}

/// The workspace-store gate, asked before a session composes anything.
/// `.nulya/extensions` is checkout content AND the first store root, so a store
/// that arrived with a clone would otherwise put its active versions into the
/// composition — system prompts into the system blocks, tools one `ext run`
/// away — with nothing in between. False means the session was refused and the
/// reason is already on stderr.
///
/// The refusal is HARD rather than "start without that root": a session missing
/// a capability it was composed with is not the session that was asked for.
fn storeTrusted(
    alloc: std.mem.Allocator,
    io: std.Io,
    host: *const std.process.Environ.Map,
    cwd_path: []const u8,
) !bool {
    launch.ensureWorkspaceStoreTrusted(alloc, io, host, cwd_path) catch |err| switch (err) {
        error.WorkspaceStoreUntrusted => {
            try cli_ext.printUntrustedStoreRefusal(alloc, io, cwd_path);
            return false;
        },
        else => return err,
    };
    return true;
}

/// One line for a refused member: what went wrong, plus every member this
/// session asked for, since either config or argv could have carried the bad
/// one (a Zig error names none of them).
fn printWithFailure(alloc: std.mem.Allocator, io: std.Io, with: []const composition.WithRef, reason: []const u8) !void {
    var listed: std.Io.Writer.Allocating = .init(alloc);
    defer listed.deinit();
    for (with, 0..) |ref, i| {
        if (i != 0) try listed.writer.writeByte(' ');
        try listed.writer.writeAll(ref.id);
        if (ref.version) |v| try listed.writer.print("@{s}", .{v});
        switch (ref.tools) {
            .default => {},
            .none => try listed.writer.writeAll(":none"),
            .named => |names| for (names, 0..) |n, j| try listed.writer.print("{s}{s}", .{ if (j == 0) ":" else ",", n }),
        }
    }
    try printErrFmt(alloc, io, "session new failed: a member {s}; composed: {s}\n", .{ reason, listed.written() });
}

const append_usage = "usage: nulya session append <id> [<text> | --file <path>] [--image <path>]…\n";

fn sessionAppend(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, append_usage);
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }

    // One pass over the tail: `--file` / `--image` (repeatable) take the next
    // argument, and the first thing left over is the turn's text.
    var text_arg: ?[]const u8 = null;
    var file_arg: ?[]const u8 = null;
    var image_args: std.ArrayList([]const u8) = .empty;
    defer image_args.deinit(alloc);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const is_file = std.mem.eql(u8, arg, "--file");
        if (is_file or std.mem.eql(u8, arg, "--image")) {
            if (i + 1 >= args.len) {
                try printErrFmt(alloc, io, "{s} takes a path\n", .{arg});
                return 1;
            }
            if (is_file) file_arg = args[i + 1] else try image_args.append(alloc, args[i + 1]);
            i += 1;
            continue;
        }
        if (text_arg != null) {
            try printErr(io, append_usage);
            return 1;
        }
        text_arg = arg;
    }

    const text = if (file_arg) |path|
        std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20)) catch {
            try printErrFmt(alloc, io, "cannot read --file '{s}'\n", .{path});
            return 1;
        }
    else if (text_arg) |t|
        try alloc.dupe(u8, t)
    else if (image_args.items.len != 0)
        // An image with nothing said about it is a turn ("look at this").
        try alloc.dupe(u8, "")
    else {
        try printErr(io, append_usage);
        return 1;
    };
    defer alloc.free(text);
    // The same UTF-8 boundary `--prompt` draws above. A user turn is the
    // person's own words, so it is refused rather than repaired the way a
    // tool's output is.
    if (!std.unicode.utf8ValidateSlice(text)) {
        try printErr(io, "message is not valid UTF-8\n");
        return 1;
    }

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printErrFmt(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    // Held from here to the deposit. Two things need it: the delivery id is
    // minted from what is already waiting, so two racing appends could
    // otherwise take the same queue position; and `session prune` may not take
    // the session away between the check below and the deposit.
    var lease = ledger.acquireDepositLease(alloc, io, std.Io.Dir.cwd(), spath, .block) catch {
        try printErr(io, "session append failed: cannot open this session's inbox\n");
        return 1;
    };
    defer lease.close(io);
    // Under the lease, because waiting for it is a moment in which the session
    // can have been pruned.
    if (!sessionExists(io, spath)) {
        try printErrFmt(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    // Three gates: can this session's model see an image at all, is this file
    // even an image, is it small enough. Every one refuses BEFORE anything is
    // deposited, so a refused append leaves the session exactly as it was.
    var images: std.ArrayList(ledger.Image) = .empty;
    defer {
        for (images.items) |img| alloc.free(img.data);
        images.deinit(alloc);
    }
    if (image_args.items.len != 0) {
        if (!try visionAccepted(alloc, io, spath)) return 1;
        for (image_args.items) |path| {
            const img = loadImage(alloc, io, path) catch |err| {
                try printImageRefusal(alloc, io, path, err);
                return 1;
            };
            try images.append(alloc, img);
        }
    }

    // `append` never writes the session file (its one writer is `step`): the
    // user turn is deposited into the session inbox under a fresh name and
    // appended at the next step boundary — including mid-run, if a step
    // process is going right now.
    const name = try ledger.freshDeliveryName(alloc, io, std.Io.Dir.cwd(), spath, "msg");
    defer alloc.free(name);
    ledger.depositEventLeased(alloc, io, std.Io.Dir.cwd(), spath, name, .{
        .user_text = .{ .text = text, .images = images.items },
    }) catch |err| switch (err) {
        // From the inbox itself rather than a gate: a turn this large would be
        // accepted and then unreadable at every step boundary.
        error.InboxEventTooLarge => {
            try printErrFmt(
                alloc,
                io,
                "session append refused: this turn encodes to more than {d} bytes, which no step could read back; send less text or fewer images\n",
                .{ledger.max_inbox_event_bytes},
            );
            return 1;
        },
        else => return err,
    };
    return 0;
}

const note_usage = "usage: nulya session note <id> --source <label> [--meta <json>] (<text> | --file <path>)\n";

/// `nulya session note <id> --source <label> [--meta <json>] (<text>|--file)` —
/// deposit one machine fact into a session.
///
/// The counterpart of `append` for everything a PERSON did not say: a driver's
/// or a plugin's observation, a watcher's report. Same deposit path, same step
/// boundary, different event — so the ledger never has to claim a person typed
/// what a package assembled.
///
/// `--source` is the depositor's own short label and is carried, not
/// interpreted. `--meta` must be one valid JSON value: the kernel stores its
/// bytes verbatim and never parses them, so a reader that trusts the column
/// would otherwise be handed whatever the caller typed.
///
/// The delivery name is fresh every time: two identical notes are two facts.
fn sessionNote(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, note_usage);
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }

    var text_arg: ?[]const u8 = null;
    var file_arg: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var meta: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "--source") or std.mem.eql(u8, arg, "--meta")) {
            if (i + 1 >= args.len) {
                try printErrFmt(alloc, io, "{s} takes a value\n", .{arg});
                return 1;
            }
            const value = args[i + 1];
            if (std.mem.eql(u8, arg, "--file")) file_arg = value;
            if (std.mem.eql(u8, arg, "--source")) source = value;
            if (std.mem.eql(u8, arg, "--meta")) meta = value;
            i += 1;
            continue;
        }
        if (text_arg != null) {
            try printErr(io, note_usage);
            return 1;
        }
        text_arg = arg;
    }

    const label = source orelse {
        try printErr(io, note_usage);
        return 1;
    };
    if (label.len == 0) {
        try printErr(io, "--source takes a non-empty label naming who deposited this\n");
        return 1;
    }
    if (meta.len != 0 and !try std.json.validate(alloc, meta)) {
        try printErr(io, "--meta takes one JSON value; readers of that column never parse text\n");
        return 1;
    }

    const text = if (file_arg) |path|
        std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20)) catch {
            try printErrFmt(alloc, io, "cannot read --file '{s}'\n", .{path});
            return 1;
        }
    else if (text_arg) |t|
        try alloc.dupe(u8, t)
    else {
        try printErr(io, note_usage);
        return 1;
    };
    defer alloc.free(text);
    if (!std.unicode.utf8ValidateSlice(text)) {
        try printErr(io, "note text is not valid UTF-8\n");
        return 1;
    }

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printErrFmt(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }
    // Held across "does this session still exist" and the deposit, and across
    // minting the delivery name from what is already queued.
    var lease = ledger.acquireDepositLease(alloc, io, std.Io.Dir.cwd(), spath, .block) catch {
        try printErr(io, "session note failed: cannot open this session's inbox\n");
        return 1;
    };
    defer lease.close(io);
    if (!sessionExists(io, spath)) {
        try printErrFmt(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    const name = try ledger.freshDeliveryName(alloc, io, std.Io.Dir.cwd(), spath, "note");
    defer alloc.free(name);
    ledger.depositEventLeased(alloc, io, std.Io.Dir.cwd(), spath, name, .{
        .note = .{ .source = label, .text = text, .meta = meta },
    }) catch |err| switch (err) {
        error.InboxEventTooLarge => {
            try printErrFmt(
                alloc,
                io,
                "session note refused: this note encodes to more than {d} bytes, which no step could read back\n",
                .{ledger.max_inbox_event_bytes},
            );
            return 1;
        },
        else => return err,
    };
    return 0;
}

/// `nulya session prune <id> [--force]` — remove a session and everything that
/// is only about it.
///
/// Without `--force` it removes only a session that holds nothing: a header
/// and no events is a name, not a ledger. `--force` takes one with history too;
/// it accepts one id and never a pattern.
///
/// `--force` does not lift the refusals that are not judgments: a step writing
/// this session, a deposit in flight, a task of it still running, a finished
/// task whose result is still sitting on another machine. The first three are
/// answered under LOCKS, and a lock can only be answered by TAKING it — probing
/// guesses wrong exactly when it matters, while another process sits between
/// its own check and its write. So this command takes BOTH of the session's
/// leases itself, asks the task question under them, and hands them to
/// `ledger.pruneSessionLeased`, which holds them across the counting and the
/// removal.
///
/// Exit 0 means one thing only: it is gone because this command removed it.
fn sessionPrune(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const force = sliceHasFlag(args, "--force");
    var id: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--")) {
            if (std.mem.eql(u8, a, "--force")) continue;
            try printErr(io, "usage: nulya session prune <id> [--force]\n");
            return 1;
        }
        if (id != null) {
            try printErr(io, "usage: nulya session prune <id> [--force]\n");
            return 1;
        }
        id = a;
    }
    const session_id = id orelse {
        try printErr(io, "usage: nulya session prune <id> [--force]\n");
        return 1;
    };
    if (!launch.isValidSessionId(session_id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const spath = try launch.sessionPath(alloc, session_id);
    defer alloc.free(spath);

    if (!sessionExists(io, spath)) {
        try printErrFmt(alloc, io, "no such session '{s}'\n", .{session_id});
        return 1;
    }

    // Both leases, taken HERE rather than inside `pruneSession`, because the
    // question below has to be settled under them: they are what freezes the
    // session's lifetime, and a task can start down either of the two paths
    // they cover (`task run` takes the deposit lease across its spawn; an
    // in-step `shell {background:true}` is covered by its step's writer lease).
    // Asking first and locking after leaves exactly the window where both
    // commands report success and the session is gone from under a running
    // supervisor.
    var leases = ledger.acquireSessionLeases(alloc, io, std.Io.Dir.cwd(), spath) catch |err| switch (err) {
        error.DepositInFlight => {
            try printErrFmt(alloc, io, "session prune refused: something is writing into '{s}' right now\n", .{session_id});
            return 1;
        },
        error.SessionBusy => {
            try printErrFmt(alloc, io, "session prune refused: a step is running '{s}'\n", .{session_id});
            return 1;
        },
        else => return err,
    };
    defer leases.close(io);

    // Under both leases, and it deposits nothing on the way past
    // (`heldTaskFor`) — a reading verb collects a far machine's finished
    // reports as it goes, and doing that here would wait for a lease this
    // process is holding. Which is why the second answer exists: a report
    // waiting on another machine is a fact this session's directory is holding
    // for somebody, and `--force` does not lift it either — collecting it
    // (`nulya task status`) turns it into a deposit, and THAT is a judgment
    // `--force` may then make.
    if (try task_cli.heldTaskFor(alloc, io, session_id)) |held| {
        defer held.deinit(alloc);
        switch (held.why) {
            .alive => try printErrFmt(
                alloc,
                io,
                "session prune refused: background task {s} is still running; `nulya task kill {s}` first\n",
                .{ held.full, held.full },
            ),
            .undelivered => try printErrFmt(
                alloc,
                io,
                "session prune refused: background task {s} finished on another machine and its result has not been collected; `nulya task status {s}` first\n",
                .{ held.full, held.full },
            ),
        }
        return 1;
    }

    const report = ledger.pruneSessionLeased(alloc, io, std.Io.Dir.cwd(), spath, .{ .force = force }, &leases) catch |err| switch (err) {
        error.NoSuchSession => {
            try printErrFmt(alloc, io, "no such session '{s}'\n", .{session_id});
            return 1;
        },
        error.HasEvents => {
            try printErrFmt(
                alloc,
                io,
                "session prune refused: '{s}' has recorded events; `nulya session prune {s} --force` removes it and them\n",
                .{ session_id, session_id },
            );
            return 1;
        },
        error.HoldsDeposits => {
            try printErrFmt(
                alloc,
                io,
                "session prune refused: a turn is queued for '{s}' and no step has drained it; `nulya session prune {s} --force` removes it too\n",
                .{ session_id, session_id },
            );
            return 1;
        },
        else => return err,
    };

    // Removed only after the session itself. Safe to take whole, because a
    // task still writing under it was refused above.
    const scratch = try launch.sessionScratchDir(alloc, session_id);
    defer alloc.free(scratch);
    // Said, but not an exit code: the session IS gone, so the answer stays 0.
    std.Io.Dir.cwd().deleteTree(io, scratch) catch |err| {
        try printErrFmt(alloc, io, "note: could not remove {s}: {s}\n", .{ scratch, @errorName(err) });
    };

    try printOut(alloc, io, "pruned {s}\n", .{session_id});
    // The same rule as the scratch tree above, for the same reason: past the
    // commit point the session IS gone, so what would not go is a note here and
    // not a verdict.
    if (report.leftovers) {
        try printErrFmt(alloc, io, "note: some files of '{s}' could not be removed\n", .{session_id});
    }
    if (force and (report.events != 0 or report.deposits != 0)) {
        // The journals are deliberately not in this count: an outcome or usage
        // row is evidence about something that happened, and it stays.
        try printErrFmt(
            alloc,
            io,
            "removed {d} recorded events, {d} queued deposits; journal rows stay\n",
            .{ report.events, report.deposits },
        );
    }
    return 0;
}

/// The largest image one turn may carry, raw bytes before base64: the tightest
/// per-image limit among the providers we speak. Over it is a refusal — nulya
/// does not silently rescale a user's picture.
const max_image_bytes: u64 = 5 << 20;

const ImageError = error{ UnreadableImage, UnsupportedImageType, ImageTooLarge };

/// Read one image file and inline it as base64. The type comes from the file's
/// MAGIC, never its extension: a provider that rejects a mislabeled `.png`
/// would do it mid-run, one step later.
fn loadImage(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !ledger.Image {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return ImageError.UnreadableImage;
    defer file.close(io);
    const size = (file.stat(io) catch return ImageError.UnreadableImage).size;
    if (size > max_image_bytes) return ImageError.ImageTooLarge;

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_image_bytes)) catch
        return ImageError.UnreadableImage;
    defer alloc.free(raw);
    const media_type = sniffMediaType(raw) orelse return ImageError.UnsupportedImageType;

    const encoder = std.base64.standard.Encoder;
    const data = try alloc.alloc(u8, encoder.calcSize(raw.len));
    errdefer alloc.free(data);
    return .{ .media_type = media_type, .data = encoder.encode(data, raw) };
}

/// png / jpeg, by magic — the whole list.
fn sniffMediaType(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xFF\xD8\xFF")) return "image/jpeg";
    return null;
}

fn printImageRefusal(alloc: std.mem.Allocator, io: std.Io, path: []const u8, err: anyerror) !void {
    switch (err) {
        ImageError.UnreadableImage => try printErrFmt(alloc, io, "cannot read --image '{s}'\n", .{path}),
        ImageError.UnsupportedImageType => try printErrFmt(
            alloc,
            io,
            "--image '{s}': not a PNG or JPEG (nulya reads the file's magic, not its extension); supported: image/png, image/jpeg\n",
            .{path},
        ),
        ImageError.ImageTooLarge => {
            const size = imageSize(io, path) orelse 0;
            try printErrFmt(
                alloc,
                io,
                "--image '{s}': {d} bytes exceeds the {d} byte per-image limit; send a smaller image\n",
                .{ path, size, max_image_bytes },
            );
        },
        else => return err,
    }
}

fn imageSize(io: std.Io, path: []const u8) ?u64 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    return (file.stat(io) catch return null).size;
}

/// Does anything claim this model accepts images?
///
/// The `[[models]]` catalog is descriptive and trusted-layer only, and no entry
/// — like an entry without `vision = true` — is a NO: nothing here guesses on a
/// model's behalf. Both places pictures and a model meet ask this one question:
/// `session append --image` about the session's frozen identity, and
/// `session new --carry` about the model a fork hands the pictures to. `what`
/// names the refusing command; a false answer prints its own refusal (stderr)
/// and how to state the claim, and the kernel never learns any of it exists.
fn visionClaimed(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    model_id: []const u8,
    what: []const u8,
) !bool {
    const named = if (model_id.len != 0) model_id else "(unnamed model)";
    for (cfg.models) |m| {
        if (!std.mem.eql(u8, m.id, model_id)) continue;
        if (m.vision) return true;
        try printErrFmt(alloc, io, "{s} refused: model '{s}' is not marked as accepting images\n", .{ what, named });
        break;
    } else {
        try printErrFmt(alloc, io, "{s} refused: no [[models]] entry for '{s}', so nothing claims it accepts images\n", .{ what, named });
    }
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var paths = try config.ConfigPaths.init(alloc, &host);
    defer paths.deinit(alloc);
    try printVisionHint(alloc, io, model_id, paths.user);
    return false;
}

/// The vision gate for `session append --image`: may THIS session be handed an
/// image? It asks the identity the session's header froze — the one every step
/// of it runs on — never today's active profile.
fn visionAccepted(alloc: std.mem.Allocator, io: std.Io, spath: []const u8) !bool {
    var header = ledger.readHeader(alloc, io, std.Io.Dir.cwd(), spath) catch {
        try printErr(io, "session append failed: cannot read this session's header\n");
        return false;
    };
    defer header.deinit();

    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    return visionClaimed(alloc, io, &cfg, header.value.model_identity.model, "session append");
}

fn printVisionHint(alloc: std.mem.Allocator, io: std.Io, model_id: []const u8, user_config: []const u8) !void {
    try printErrFmt(
        alloc,
        io,
        "  add to your user config ({s}):\n    [[models]]\n    id = \"{s}\"\n    vision = true\n  then check it with `nulya config show`\n",
        .{ user_config, model_id },
    );
}

/// Why the run stopped, from facts the kernel already reports: a canceled step
/// short-circuits `run`; a reply cut by `max_tokens` is not a finished turn
/// (whether it stopped the run alone or as the second in a row); an assistant
/// turn with no calls ends the turn; anything else means the step budget ran out.
pub fn stoppedReason(last_status: loop.StepStatus, last_stop: provider.StopReason, turn_done: bool) []const u8 {
    if (last_status == .canceled) return "canceled";
    if (last_stop == .max_tokens) return "max_tokens";
    return if (turn_done) "end_turn" else "budget";
}

/// A `session step` diagnostic. Plain text on stderr without `--stream`, so
/// stdout stays the event JSONL and nothing else; with `--stream` it is a
/// `run error` line, which is part of the protocol and therefore on stdout.
fn stepFail(
    alloc: std.mem.Allocator,
    io: std.Io,
    stream: ?*StepStream,
    comptime fmt: []const u8,
    args: anytype,
) !u8 {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);
    if (stream) |s| {
        try s.runError(msg);
    } else {
        try printErrFmt(alloc, io, "{s}\n", .{msg});
    }
    return 1;
}

/// Say once, on resume, that this binary's kernel prompt / builtin definitions
/// are not the ones frozen into the session. Those constants enter the
/// session's model-visible state but live in the BINARY, so an upgrade moves
/// them under an existing session.
///
/// Provenance, not a gate: nothing is refused, and a header with no stamp warns
/// about nothing. The line goes to stderr, keeping `--stream` stdout pure.
fn warnKernelDrift(alloc: std.mem.Allocator, io: std.Io, id: []const u8, stamp: ledger.Stamp) !void {
    if (stamp.kernel_hash.len == 0) return;
    const mine = try composition.kernelHash(alloc);
    defer alloc.free(mine);
    if (std.mem.eql(u8, mine, stamp.kernel_hash)) return;
    const by = if (stamp.version.len != 0) stamp.version else "unknown";
    const msg = try std.fmt.allocPrint(
        alloc,
        "warning: session {s} was created by nulya {s} whose kernel prompt/builtins differ from this binary's; its frozen system prompt has changed\n",
        .{ id, by },
    );
    defer alloc.free(msg);
    try printErr(io, msg);
}

fn sessionStep(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session step <id> [--max-steps N] [--effort E] [--stream] [--gate]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const streaming = sliceHasFlag(args[1..], "--stream");
    // `--gate` asks the caller before every tool call on the same wire the
    // stream uses: a request line on stdout, a verdict line on stdin. Without
    // `--stream` there is no such wire, so the combination is refused rather
    // than silently running ungated.
    const gating = sliceHasFlag(args[1..], "--gate");
    if (gating and !streaming) {
        try printErr(io, "--gate requires --stream: the approval request is a line of that protocol\n");
        return 1;
    }
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var stream_state: StepStream = .{ .alloc = alloc, .out = &stdout.interface };
    const stream: ?*StepStream = if (streaming) &stream_state else null;
    // One buffer for the whole run: a verdict line is short, and `deny <note>`
    // longer than this is a note nobody typed.
    var in_buf: [4097]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const ssh_password = if (sliceHasFlag(args[1..], "--ssh-password-stdin"))
        remote.readSshPassword(alloc, &stdin.interface) catch |err|
            return stepFail(alloc, io, stream, "--ssh-password-stdin: {s}", .{@errorName(err)})
    else
        null;
    defer if (ssh_password) |secret| {
        std.crypto.secureZero(u8, secret);
        alloc.free(secret);
    };
    var gate_state: StepGate = .{ .io = io, .out = &stdout.interface, .in = &stdin.interface };
    const gate: ?*StepGate = if (gating) &gate_state else null;
    // The kernel clamps this to `session.max_steps_ceiling`: a driver can lower
    // the budget, never raise it.
    var max_steps: usize = session.max_steps_ceiling;
    if (flagValue(args[1..], "--max-steps")) |v| {
        max_steps = std.fmt.parseInt(usize, v, 10) catch 0;
        if (max_steps == 0) {
            try printErr(io, "--max-steps must be a positive integer\n");
            return 1;
        }
    }

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);

    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    // Gated on every step, not only at creation: composition is frozen in the
    // header, but the extension BYTES are read from the store on each resume,
    // so a store that arrived between two steps must not be executed either.
    if (!try storeTrusted(alloc, io, &host, cwd_path)) {
        return stepFail(alloc, io, stream, "the workspace extension store is not trusted (see the lines above); run `nulya ext trust` after reviewing it", .{});
    }

    var hdr = ledger.readHeader(alloc, io, std.Io.Dir.cwd(), spath) catch |err| {
        // A file this binary is too old to read is not a missing session: say
        // which format it reads, so upgrading is the obvious answer.
        if (err == error.UnsupportedLedgerVersion) {
            return stepFail(alloc, io, stream, "session '{s}' was written by a newer nulya; this binary reads ledger v{d}", .{ id, ledger.format_version });
        }
        return stepFail(alloc, io, stream, "no such session '{s}': {s}", .{ id, @errorName(err) });
    };
    defer hdr.deinit();
    try warnKernelDrift(alloc, io, id, hdr.value.nulya);
    if (ssh_password != null and !remote.isSshSpec(hdr.value.environment))
        return stepFail(alloc, io, stream, "--ssh-password-stdin applies only to a remote:ssh: session", .{});

    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    // The session this step's background tasks belong to: their supervisor
    // deposits its report note into this file's inbox, and their directories
    // live beside this session's spills.
    const tasks_dir = try launch.sessionTasksDir(alloc, id);
    defer alloc.free(tasks_dir);
    // Where this session's commands run comes from the HEADER, never from a
    // flag or today's config: it was decided once, at creation. A target this
    // host cannot reach fails loudly — running the commands here instead would
    // be a silent substitution.
    const ext_roots = try launch.extensionRoots(alloc, &host, &cfg);
    defer launch.freeExtensionRoots(alloc, ext_roots);
    var lenv = launch.sessionEnvironment(alloc, io, &cfg, .{
        .session_path = spath,
        .tasks_dir = tasks_dir,
    }, hdr.value.environment, hdr.value.remote_workspace, ext_roots, ssh_password) catch |err| switch (err) {
        error.UnsupportedEnvironmentBackend => {
            return stepFail(alloc, io, stream, "environment backend '{s}' is not implemented; only local", .{@tagName(cfg.environment.backend)});
        },
        error.InvalidExecTarget, error.ExecTargetUnsupportedOnHost, error.InvalidRemoteSpec, error.RemoteSpecUnsupportedOnHost => {
            // A header frozen with the retired `ssh:` exec target gets the
            // same specific pointer a fresh `--env ssh:…` does — never a silent
            // re-interpretation as `remote:ssh:`.
            if (launch.legacySshHint(environment.normalizeExecSpec(hdr.value.environment))) |hint| {
                return stepFail(alloc, io, stream, "session '{s}' runs its commands in '{s}', which this binary on this host cannot reach; refusing to run them here instead ({s})", .{ id, hdr.value.environment, hint });
            }
            return stepFail(alloc, io, stream, "session '{s}' runs its commands in '{s}', which this binary on this host cannot reach; refusing to run them here instead", .{ id, hdr.value.environment });
        },
        // Named and reachable in principle, but it did not answer — a
        // different fix from "this host has no way to get there" above. The
        // transport's own diagnostic already went to stderr unmodified; this
        // only says which session it stopped.
        error.RemoteChannelLost, error.RemoteChannelStalled => {
            return stepFail(alloc, io, stream, "session '{s}' runs its commands on '{s}', which did not answer; nothing was run here instead", .{ id, hdr.value.environment });
        },
        error.RemoteVersionMismatch => {
            return stepFail(alloc, io, stream, "session '{s}' reached '{s}', but the nulya there speaks a different remote protocol; install a matching build on that machine", .{ id, hdr.value.environment });
        },
        else => return err,
    };
    defer lenv.deinit();
    // Let this session's children name it: the FILE path, so `nulya ext
    // activate` can deposit a capability note into its inbox, and the ID, which
    // is true on whichever machine the child runs.
    try lenv.publishSession(spath, id);
    // A background task on another machine cannot deposit its own report — the
    // session file is here. So before stepping, ask that machine about the
    // tasks reporting into this session (its own and any retargeted here) and
    // turn a finished report into the note the inbox already
    // understands, which `prepareStep` drains at the step boundary exactly as
    // it drains one a local supervisor deposited.
    //
    // The open channel is LENT rather than re-opened, so a bare `session step`
    // loop with no driver around it still receives its results for a few frames
    // instead of a second connection.
    if (lenv == .remote) {
        var renv = &lenv.remote;
        task_cli.sweepRemoteReports(alloc, io, &renv.ch, id);
    }

    // Reconstruct the model frozen at creation, re-resolving only the
    // credential — the profile's own `api_key` (found by the header's profile
    // name), else the env var the header names, else the Codex auth file. No
    // silent fallback: a real session whose key is gone fails loudly rather
    // than quietly becoming a scripted session. The session id is also the
    // prompt-cache scope, so a provider that keys its cache explicitly keeps
    // hitting it across separate `step` processes.
    const inline_key = if (cfg.provider.findProfile(hdr.value.model)) |p| p.api_key else null;
    var holder = launch.buildFromDescriptor(alloc, io, hdr.value.model_identity, &host, .{ .cache_key = id, .inline_key = inline_key }) catch |err| switch (err) {
        error.MissingCredential => {
            const credential = if (hdr.value.model_identity.api_key_env.len != 0) hdr.value.model_identity.api_key_env else "codex login";
            return stepFail(alloc, io, stream, "session '{s}' is a '{s}' session but its credential (profile '{s}' api_key, or {s}) is not available; refusing to run (no silent fallback)", .{ id, hdr.value.model_identity.provider, hdr.value.model, credential });
        },
        error.ProviderUnavailable => {
            return stepFail(alloc, io, stream, "session '{s}' was created with provider '{s}', which this build cannot construct", .{ id, hdr.value.model_identity.provider });
        },
        else => return err,
    };
    defer holder.deinit();

    // Effort is a generation option, not identity: the driver may set it per
    // step; otherwise the profile / catalog default applies. Which profile's
    // default is settled below, once the ledger has said which model this
    // session is actually on.
    const effort_flag = flagValue(args[1..], "--effort");

    // Workspace-relative, deliberately: a spill is written through the
    // environment's `putWorkspaceFile`, so this one string is the path on
    // whichever machine this session's workspace lives on.
    const scratch = try launch.sessionScratchDir(alloc, id);
    defer alloc.free(scratch);
    var sess = session.AgentSession.openDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.handle(), .cwd = cwd_path },
            .scratch_dir = scratch,
            .retry = cfg.provider.retry,
            .observer = if (stream) |s| s.observer() else null,
            .gate = if (gate) |g| g.gate() else null,
        },
        .extension_roots = ext_roots,
    }, .{ .workspace = std.Io.Dir.cwd(), .session_path = spath }) catch |err| switch (err) {
        error.LegacyModelRebind => return stepFail(alloc, io, stream, legacy_rebind_refusal, .{ id, id }),
        else => return stepFail(alloc, io, stream, "session open failed: {s}", .{@errorName(err)}),
    };
    defer sess.deinit();

    sess.model_options = .{ .effort = effort_flag orelse cfg.defaultEffort(hdr.value.model, hdr.value.model_identity.model) };

    const before = sess.l.len();
    if (stream) |s| {
        s.printed = before;
        // Read-only, and only so a drained inbox turn reaches the reader when
        // it lands rather than at the end of the step it opened.
        s.ledger_view = &sess.l;
    }
    const steps = sess.run(max_steps) catch |err| {
        // Whatever this run did append before it faulted is still fact; report
        // those lines, then the error.
        if (stream) |s| s.flushEvents(sess.l.view()) catch {};
        // Not a fault but a state: the last reply was cut off, and stepping it
        // again would send it back as a prefill.
        if (err == error.LegacyModelRebind) {
            return stepFail(alloc, io, stream, legacy_rebind_refusal, .{ id, id });
        }
        if (err == error.TruncatedTurnNeedsInput) {
            return stepFail(alloc, io, stream, "the last reply was cut off at its output cap; append a message before stepping again", .{});
        }
        return stepFail(alloc, io, stream, "session step failed: {s}", .{@errorName(err)});
    };

    if (stream) |s| {
        // Every event was already flushed at its step boundary; only the run
        // verdict is left.
        try s.runDone(steps, stoppedReason(s.last_status, sess.lastStopReason(), sess.lastAssistantDone()));
        // A dropped observation is not a broken step, but the reader's picture
        // is incomplete: say so on stderr (stdout stays pure JSON) and exit
        // non-zero.
        if (s.err) |e| {
            try printErr(io, "stream write failed: ");
            try printErr(io, @errorName(e));
            try printErr(io, "\n");
            return 1;
        }
        // Same for a broken approval channel: the step is legal (everything it
        // could not ask about was denied), the caller's picture is not.
        // Reaching the end of stdin is not a failure and sets nothing.
        if (gate) |g| {
            if (g.err) |e| {
                try printErr(io, "gate channel failed: ");
                try printErr(io, @errorName(e));
                try printErr(io, "\n");
                return 1;
            }
        }
        return 0;
    }

    // stdout is the events this invocation appended, as one JSONL line each.
    for (sess.l.view()[before..], before..) |ev, i| {
        const line = try ledger.encodeEventLine(alloc, ev, i + 1);
        defer alloc.free(line);
        try printRaw(io, line);
    }
    return 0;
}

fn sessionEvents(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session events <id> [--since N] [--follow]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    var since: u64 = 0;
    if (flagValue(args[1..], "--since")) |v| since = std.fmt.parseInt(u64, v, 10) catch 0;
    const follow = sliceHasFlag(args[1..], "--follow");

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printErrFmt(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var tail: EventTail = .{ .since = since };
    try tail.dump(alloc, io, std.Io.Dir.cwd(), spath, &stdout.interface);
    try stdout.interface.flush();
    if (!follow) return 0;

    // Polling is enough: the file only grows.
    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
        try tail.dump(alloc, io, std.Io.Dir.cwd(), spath, &stdout.interface);
        try stdout.interface.flush();
    }
}

/// A read-only tail over a session file's raw lines. `events` never opens the
/// file for writing, and every line it prints is the file's own bytes — the file
/// IS the wire format, and its writer already validated that event line k
/// carries seq k, so selecting by seq is counting complete lines past the
/// header.
///
/// ONE line shape is not passed through verbatim: a `user_text` carrying
/// images is re-encoded with each image's base64 replaced by
/// `[image <media_type>, N base64 bytes]`. It is presentation on top of the
/// stored fact — `seq`, `origin` and every other column survive it, and a line
/// that will not parse is printed raw rather than dropped. `session step
/// --stream` prints ledger lines unredacted, so a driver sees the file's
/// shape.
const EventTail = struct {
    since: u64,
    /// Byte offset of the first unread line.
    offset: usize = 0,
    /// Event lines consumed so far (== the seq of the last one).
    seq: u64 = 0,
    header_seen: bool = false,

    /// Write every complete, not-yet-seen event line with seq > `since` to `out`.
    fn dump(self: *EventTail, alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, spath: []const u8, out: *std.Io.Writer) !void {
        const bytes = try dir.readFileAlloc(io, spath, alloc, .unlimited);
        defer alloc.free(bytes);
        const clean_end: usize = @intCast(ledger.lastCompleteLineEnd(bytes));
        if (clean_end < self.offset) return error.SessionFileShrank;
        var pos = self.offset;
        while (pos < clean_end) {
            // `clean_end` sits just past a newline, so one exists at or after `pos`.
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n').?;
            const line = bytes[pos .. nl + 1];
            pos = nl + 1;
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            if (!self.header_seen) {
                self.header_seen = true;
                continue;
            }
            self.seq += 1;
            if (self.seq <= self.since) continue;
            if (try redactImages(alloc, line, self.seq)) |redacted| {
                defer alloc.free(redacted);
                try out.writeAll(redacted);
            } else try out.writeAll(line);
        }
        self.offset = pos;
    }
};

/// The one re-encoding `events` does: a `user_text` line carrying images, with
/// every image's base64 swapped for a placeholder. Returns null for every other
/// line — including one that does not parse — so the caller prints the file's
/// own bytes. Caller owns the result.
fn redactImages(alloc: std.mem.Allocator, line: []const u8, seq: u64) !?[]u8 {
    // Cheap reject first: the overwhelming majority of lines carry no images,
    // and they must not pay a JSON parse for it.
    if (std.mem.indexOf(u8, line, "\"images\"") == null) return null;
    var parsed = ledger.parseEventLine(alloc, line) catch return null;
    defer parsed.deinit();
    const images = parsed.value.images orelse return null;
    if (images.len == 0) return null;
    const event = ledger.toEvent(parsed.arena.allocator(), parsed.value) catch return null;
    if (event != .user_text) return null;

    const placeholders = try parsed.arena.allocator().alloc(ledger.Image, images.len);
    for (images, placeholders) |img, *out| out.* = .{
        .media_type = img.media_type,
        .data = try std.fmt.allocPrint(parsed.arena.allocator(), "[image {s}, {d} base64 bytes]", .{ img.media_type, img.data.len }),
    };
    if (parsed.value.origins) |origins| return try ledger.encodeEventLineOrigins(
        alloc,
        .{ .user_text = .{ .text = event.user_text.text, .images = placeholders } },
        seq,
        origins,
    );
    if (parsed.value.origin) |origin| return try ledger.encodeEventLineOrigins(
        alloc,
        .{ .user_text = .{ .text = event.user_text.text, .images = placeholders } },
        seq,
        &.{origin},
    );
    return try ledger.encodeEventLine(
        alloc,
        .{ .user_text = .{ .text = event.user_text.text, .images = placeholders } },
        seq,
    );
}

fn sessionCancel(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session cancel <id>\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printErrFmt(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }
    // The kernel consumes the marker at the session's next step boundary —
    // between steps of a run already going, or at the start of the next `step`.
    try session.requestCancel(alloc, io, std.Io.Dir.cwd(), spath);
    try printOut(alloc, io, "cancel requested for {s}\n", .{id});
    return 0;
}

fn sessionExists(io: std.Io, spath: []const u8) bool {
    std.Io.Dir.cwd().access(io, spath, .{}) catch return false;
    return true;
}

/// A session written when moving a running conversation onto another model was
/// an event. Both takes on `{s}` are the session id: the refusal and the way on
/// from it name the same session.
const legacy_rebind_refusal =
    "session '{s}' records a model_rebind, an event this binary no longer has; continue it with `nulya session new --parent {s}:<seq> --carry --profile <P>`";

fn parseParent(s: []const u8) ?ledger.ParentRef {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const session_id = s[0..colon];
    if (session_id.len == 0) return null;
    const seq = std.fmt.parseInt(u64, s[colon + 1 ..], 10) catch return null;
    return .{ .session = session_id, .seq = seq };
}

/// Bare `nulya session` prints this family's block from the one CLI map.
fn sessionUsage(io: std.Io) !u8 {
    return common.usageSection(io, common.session_usage);
}

test "EventTail prints raw event lines past --since, skips the header and a torn tail, and resumes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = try ledger.encodeHeaderLine(alloc, .{ .session = "s" });
    defer alloc.free(header);
    const e1 = try ledger.encodeEventLine(alloc, .{ .user_text = .{ .text = "one" } }, 1);
    defer alloc.free(e1);
    const e2 = try ledger.encodeEventLine(alloc, .{ .user_text = .{ .text = "two" } }, 2);
    defer alloc.free(e2);
    const e3 = try ledger.encodeEventLine(alloc, .{ .user_text = .{ .text = "three" } }, 3);
    defer alloc.free(e3);

    // Header, two complete events, and a torn third being written right now.
    const first = try std.mem.concat(alloc, u8, &.{ header, e1, e2, e3[0 .. e3.len / 2] });
    defer alloc.free(first);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = first });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var tail: EventTail = .{ .since = 1 };
    try tail.dump(alloc, io, tmp.dir, "s.jsonl", &out.writer);
    try std.testing.expectEqualStrings(e2, out.written()); // seq 1 filtered, torn 3 withheld

    // The writer finishes the line; a follow-up dump prints only what is new,
    // and the file was never modified by the reader.
    const whole = try std.mem.concat(alloc, u8, &.{ header, e1, e2, e3 });
    defer alloc.free(whole);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = whole });
    out.clearRetainingCapacity();
    try tail.dump(alloc, io, tmp.dir, "s.jsonl", &out.writer);
    try std.testing.expectEqualStrings(e3, out.written());
    const on_disk = try tmp.dir.readFileAlloc(io, "s.jsonl", alloc, .unlimited);
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings(whole, on_disk);
}

test "events prints an image turn with the base64 replaced, and every other line raw" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = try ledger.encodeHeaderLine(alloc, .{ .session = "s" });
    defer alloc.free(header);
    const shot = try ledger.encodeEventLine(alloc, .{ .user_text = .{
        .text = "what is this",
        .images = &.{.{ .media_type = "image/png", .data = "iVBORw0KGgoAAAA=" }},
    } }, 1);
    defer alloc.free(shot);
    const plain = try ledger.encodeEventLine(alloc, .{ .assistant = .{ .text = "a screenshot", .calls = &.{} } }, 2);
    defer alloc.free(plain);

    const file = try std.mem.concat(alloc, u8, &.{ header, shot, plain });
    defer alloc.free(file);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = file });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var tail: EventTail = .{ .since = 0 };
    try tail.dump(alloc, io, tmp.dir, "s.jsonl", &out.writer);

    // The image line keeps its seq, kind and text; only the payload is gone.
    const expected = try std.mem.concat(alloc, u8, &.{
        "{\"seq\":1,\"kind\":\"user_text\",\"text\":\"what is this\"," ++
            "\"images\":[{\"media_type\":\"image/png\",\"data\":\"[image image/png, 16 base64 bytes]\"}]}\n",
        plain,
    });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());
    // Presentation only: the file still holds the base64 it always did.
    const on_disk = try tmp.dir.readFileAlloc(io, "s.jsonl", alloc, .unlimited);
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings(file, on_disk);

    // A line that merely mentions the word survives the cheap reject unharmed.
    const decoy = try ledger.encodeEventLine(alloc, .{ .user_text = .{ .text = "no \"images\" here" } }, 1);
    defer alloc.free(decoy);
    try std.testing.expect(try redactImages(alloc, decoy, 1) == null);
}

test "--with unions with the configured members, config first, and splits <id>[@<version>]" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{
        "--profile",      "scripted",
        "--with",         "evolution",
        "--with",         "web.search@v-0123456789abcdef01234567",
        "--parent",       "s-1:4",
        "--with-nothing", "ignored",
        "--with",
    }; // a trailing --with with no value is not a ref
    const refs = try withRefs(alloc, &.{}, &args);
    defer freeMemberRefs(alloc, refs);

    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("evolution", refs[0].id);
    try std.testing.expect(refs[0].version == null); // no @version = its current
    try std.testing.expectEqualStrings("web.search", refs[1].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", refs[1].version.?);

    const none = try withRefs(alloc, &.{}, &.{ "--profile", "scripted" });
    defer freeMemberRefs(alloc, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // Config's standing members come FIRST and carry no version — they follow
    // `current`. A command line naming the same id lands after, which is what
    // lets it override (`unionWith` keeps the last mention of an id).
    const configured = [_][]const u8{ "guide", "std" };
    const both = try withRefs(alloc, &configured, &.{ "--with", "std@v-0123456789abcdef01234567" });
    defer freeMemberRefs(alloc, both);
    try std.testing.expectEqual(@as(usize, 3), both.len);
    try std.testing.expectEqualStrings("guide", both[0].id);
    try std.testing.expect(both[0].version == null);
    try std.testing.expectEqualStrings("std", both[1].id);
    try std.testing.expect(both[1].version == null);
    try std.testing.expectEqualStrings("std", both[2].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", both[2].version.?);

    // `--bare` is the shell reading the standing list as empty; the argv half
    // is untouched.
    try std.testing.expect(bareComposition(&.{ "--profile", "scripted", "--bare" }));
    try std.testing.expect(!bareComposition(&args));
}

test "a member spec carries its own tool selection, in either source" {
    const alloc = std.testing.allocator;
    const configured = [_][]const u8{"std:read,grep"};
    const args = [_][]const u8{
        "--profile", "scripted",
        "--with",    "ask:none",
        "--with",    "web.search@v-0123456789abcdef01234567:web_search",
        "--with",    "plain",
    };
    const refs = try withRefs(alloc, &configured, &args);
    defer freeMemberRefs(alloc, refs);
    try std.testing.expectEqual(@as(usize, 4), refs.len);

    try std.testing.expectEqualStrings("std", refs[0].id);
    try std.testing.expectEqualStrings("read", refs[0].tools.named[0]);
    try std.testing.expectEqualStrings("grep", refs[0].tools.named[1]);

    // `:none` is a member with nothing on the model's face.
    try std.testing.expectEqualStrings("ask", refs[1].id);
    try std.testing.expectEqual(composition.ToolSelection.none, refs[1].tools);

    // A version and a selection on one spec: the `:` splits first, the `@`
    // inside the head second.
    try std.testing.expectEqualStrings("web.search", refs[2].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", refs[2].version.?);
    try std.testing.expectEqualStrings("web_search", refs[2].tools.named[0]);

    // No `:` at all is the package's own default.
    try std.testing.expectEqualStrings("plain", refs[3].id);
    try std.testing.expectEqual(composition.ToolSelection.default, refs[3].tools);
}

test "parseParent parses <session>:<seq> and rejects malformed input" {
    const p = parseParent("s-123:41").?;
    try std.testing.expectEqualStrings("s-123", p.session);
    try std.testing.expectEqual(@as(u64, 41), p.seq);
    try std.testing.expect(parseParent("no-seq") == null);
    try std.testing.expect(parseParent(":41") == null);
    try std.testing.expect(parseParent("s:notnum") == null);
}

test "a run stopped by the step budget reports stopped=budget, a canceled step reports canceled, a truncated reply reports max_tokens" {
    try std.testing.expectEqualStrings("end_turn", stoppedReason(.completed, .end_turn, true));
    try std.testing.expectEqualStrings("budget", stoppedReason(.completed, .tool_use, false));
    try std.testing.expectEqualStrings("canceled", stoppedReason(.canceled, .tool_use, false));
    // A cancel at the boundary wins even when the last assistant turn was clean.
    try std.testing.expectEqualStrings("canceled", stoppedReason(.canceled, .end_turn, true));
    // A cut-off reply is not a finished turn, with or without calls in it.
    try std.testing.expectEqualStrings("max_tokens", stoppedReason(.completed, .max_tokens, true));
    try std.testing.expectEqualStrings("max_tokens", stoppedReason(.completed, .max_tokens, false));
}

test "under --stream a diagnostic is a run error line, never a bare text line" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var stream: StepStream = .{ .alloc = alloc, .out = &out.writer };

    const code = try stepFail(alloc, io, &stream, "session open failed: {s}", .{"SessionBusy"});
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings(
        "{\"stream\":\"run\",\"event\":\"error\",\"message\":\"session open failed: SessionBusy\"}\n",
        out.written(),
    );
}
