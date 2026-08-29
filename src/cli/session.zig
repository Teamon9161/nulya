//! `nulya session …` (DESIGN §14, PLAN §3.2): the one session driver surface.
//! There is deliberately no setTools / setModel / replaceHistory — changing
//! composition means a new session. Only `step` ever writes the session file;
//! everything else deposits into its siblings or reads it back.
//!
//! Two pieces sit beside this file rather than in it, because neither drives a
//! session: `session_list.zig` reads every session at once, and
//! `step_stream.zig` is the `--stream` wire format a front end parses.
//!
//! Output discipline: stdout carries data and success only (a new id, event
//! JSONL, a listing, a confirmation); every refusal goes to stderr, so a driver
//! parsing stdout gets what it asked for or nothing. Under `--stream` the
//! diagnostic is itself a protocol line and therefore stays on stdout.

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
const session_list = @import("session_list.zig");
const StepStream = @import("step_stream.zig").StepStream;
const StepGate = @import("step_stream.zig").StepGate;
const cwdRealPath = common.cwdRealPath;
const flagValue = common.flagValue;
const sliceHasFlag = common.sliceHasFlag;
const withRef = common.withRef;
const envSessionId = common.envSessionId;
const printOut = common.printOut;
const printErrFmt = common.printErrFmt;
const printRaw = common.printRaw;
const printErr = common.printErr;

/// Answers "which build target do this session's extension calls run on" by
/// asking that machine — the one thing only it can say (`composition.ExecTargetProbe`).
///
/// It opens a channel, reads the handshake and closes it again: `session new`
/// runs nothing over there, it only needs the machine's own name for itself. The
/// connection therefore happens at most once per creation, and only when a
/// `compiled` member is actually composed — a remote session made of data and
/// script packages never touches the network here.
///
/// The agent reports `@tagName(builtin.cpu.arch)` and `@tagName(builtin.os.tag)`,
/// which is exactly the spelling `extension/target.zig` puts into a version id,
/// so this is a comparison and never a translation. If the two ever drift apart,
/// the fix belongs on the reporting side.
const RemoteTargetProbe = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    spec: []const u8,
    answer: ?[]u8 = null,

    fn ask(ptr: *anyopaque) anyerror![]const u8 {
        const self: *RemoteTargetProbe = @ptrCast(@alignCast(ptr));
        if (self.answer) |cached| return cached;
        var ch = try remote.Channel.connect(self.alloc, self.io, try remote.parseSpec(self.spec), launch.version, .default);
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

// ── `nulya session *` (DESIGN §14, PLAN §3.2) ───────────────────────────────
//
// The one session driver surface. There is deliberately no setTools / setModel /
// replaceHistory: changing composition means a new session. Each subcommand is a
// separate process over the durable session file, and only `step` ever WRITES
// that file: `append` and `cancel` deposit into the session's siblings
// (`<id>.inbox/`, `<id>.cancel`) for `step` to consume at its next step
// boundary, and `events` tails the file read-only. `step` streams the events it
// appends as JSONL; its `--max-steps` budget is enforced by the kernel.

pub fn dispatchSession(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return sessionUsage(io);
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "new")) return sessionNew(alloc, io, rest);
    if (std.mem.eql(u8, sub, "append")) return sessionAppend(alloc, io, rest);
    if (std.mem.eql(u8, sub, "step")) return sessionStep(alloc, io, rest);
    if (std.mem.eql(u8, sub, "events")) return sessionEvents(alloc, io, rest);
    if (std.mem.eql(u8, sub, "cancel")) return sessionCancel(alloc, io, rest);
    if (std.mem.eql(u8, sub, "outcome")) return sessionOutcome(alloc, io, rest);
    if (std.mem.eql(u8, sub, "list")) return session_list.sessionList(alloc, io, sliceHasFlag(rest, "--json"));
    try printErr(io, "unknown `session` subcommand; try new|append|step|events|cancel|outcome|list\n");
    return 1;
}

/// `nulya session outcome <id> <verdict> [--note <text>] [--seq N]` — record how
/// a session turned out (DESIGN §3.3). The verdict is a judgment ABOUT the
/// session, not a turn IN it, so this writes only the outcome journal: it never
/// opens the session file and never takes its writer lease, which is what lets a
/// session still running (or being stepped by another process) be judged right
/// now. `--seq` narrows a line to one assistant turn; it stays a projection, so
/// the number is validated as a positive integer and NOT checked against the
/// session's length — reading the ledger to bounds-check it would trade the one
/// property that makes this command safe on a live session for a fact the reader
/// can derive itself.
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
    // names the live session — so a session grading itself is a fact the journal
    // can record instead of a fact the slow loop has to guess (DESIGN §3.3).
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
/// every `--with <id>[@<version>]` in argv order (the flag is repeatable).
///
/// Exactly `pinRefs`' shape, for exactly its reason (DESIGN §5.1): config says
/// "in this workspace, every session", `--with` says "for this session", and
/// they are two spellings of one axis. Config first so a command line naming the
/// same id — with a version, typically — overrides it: `composition.unionWith`
/// keeps the last mention of an id.
///
/// Slices borrow `configured` and `args`; the caller owns only the returned
/// array.
fn withRefs(
    alloc: std.mem.Allocator,
    configured: []const []const u8,
    args: []const []const u8,
) ![]composition.WithRef {
    var out: std.ArrayList(composition.WithRef) = .empty;
    errdefer out.deinit(alloc);
    // Bare ids: a standing member follows `current`, so `ext activate` keeps
    // meaning something for it and a rollback stays one verb (`config.Extensions`).
    for (configured) |id| try out.append(alloc, .{ .id = id });
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--with")) continue;
        try out.append(alloc, withRef(args[i + 1]));
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// `--bare`: compose from argv alone (DESIGN §14).
///
/// The two standing config lists — `[extensions] with` and
/// `registry.pinned_native_tools` — plus the store's own standing layer (every
/// activated package that declares `apply: "auto"`, DESIGN §5.1) are how "every
/// session on this machine gets this" gets said. A session opened FOR a job by
/// something other than a person (a delegated sub-agent, whose whole tool face
/// is its own definition) is not one of those, and inheriting a workspace's
/// standing composition would give it capabilities its author never wrote down.
///
/// `max_tools` is still read: it is a ceiling, not a selection, and a `--bare`
/// session that could exceed it would be a way around the budget rather than a
/// way out of the config.
///
/// Nothing about the flag reaches the header. A resume reads the members and
/// pins the header froze, which is the same list either way — a flag recording
/// how the list was ARRIVED at would be a second fact to keep true.
fn bareComposition(args: []const []const u8) bool {
    return sliceHasFlag(args, "--bare");
}

/// The session's native tool pins: the config's `registry.pinned_native_tools`
/// first, then every `--pin <ext:id/tool>` in argv order (the flag is
/// repeatable). Both spellings mean the same thing and are equally strict —
/// config says "in this workspace, always", `--pin` says "for this session"
/// (DESIGN §5.1). An id already present is not added twice, so naming a
/// configured pin again is a no-op rather than a `DuplicateToolId`. Slices
/// borrow `configured` and `args`; the caller owns only the returned array.
fn pinRefs(alloc: std.mem.Allocator, configured: []const []const u8, args: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (configured) |pin| {
        if (!containsString(out.items, pin)) try out.append(alloc, pin);
    }
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--pin")) continue;
        if (!containsString(out.items, args[i + 1])) try out.append(alloc, args[i + 1]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Every `--prompt <file>` (repeatable), read HERE, at creation time, into the
/// bytes the header freezes (DESIGN §3, §5). A path or a store id would make the
/// session's identity text depend on something outside the session file staying
/// put; the bytes do not.
///
/// Null means the request was refused and the reason is already on stderr —
/// before a session id exists, so nothing was created (the same discipline as a
/// missing credential). The caller owns the array and every string in it.
fn promptRefs(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !?[]ledger.InlinePrompt {
    var out: std.ArrayList(ledger.InlinePrompt) = .empty;
    // Covers both ways this can end early — a refusal and an allocation failure
    // — because a successful `toOwnedSlice` leaves the list empty and this
    // frees nothing.
    defer {
        freePrompts(alloc, out.items);
        out.deinit(alloc);
    }
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--prompt")) continue;
        const path = args[i + 1];
        i += 1;
        // The same limit composition reads an extension's system prompt with, so
        // a file accepted here is a file every later session boundary can carry.
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
        // Text, not bytes — and the boundary is here because everything
        // downstream of it assumes so. `std.json.Stringify` writes a `[]const
        // u8` that is not valid UTF-8 as an ARRAY OF NUMBERS rather than a
        // string, and it does that in both places these bytes are serialized:
        // the durable header stops being what §3's schema says it is (readable
        // only by a parser that happens to accept the same fallback, so not by
        // anything else looking at the file), and the provider request body
        // carries `"text":[89,111,…]`, which every real model API rejects.
        // Refusing costs a message; accepting creates a session that looks
        // fine, resumes fine, and cannot take a single step against a real
        // model.
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            alloc.free(bytes);
            try printErrFmt(alloc, io, "--prompt {s}: not valid UTF-8\n", .{path});
            return null;
        }
        // The label the block carries for the rest of the session's life. The
        // kernel never reads it; whoever wrote the file decides what it means.
        try out.append(alloc, .{ .source = try alloc.dupe(u8, std.fs.path.stem(path)), .text = bytes });
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
/// The two callers genuinely want opposite things, and neither is a default the
/// other could live with (DESIGN §9.5):
///
///   refuse    — `session new`. A session freezes its identity for life, so one
///               created without the credential it asked for would be answered
///               by the offline stand-in from then on, while looking exactly
///               like the model that was requested. That is worse than failing.
///   stand_in  — `nulya demo`. Running with no key at all is what a demo IS: it
///               exists to show the durable path on a machine that has nothing
///               configured, and refusing there would refuse the demonstration.
pub const KeylessPolicy = enum { refuse, stand_in };

/// Create a durable session file from `session new`'s own flags and return its
/// id (owned by the caller), or null when the request was refused and the
/// reason has already been printed. `session new` is a thin printer over this;
/// the `nulya demo` verb is its other caller, so the two cannot drift on how a
/// session is composed (DESIGN §14) — `keyless` is the one thing they differ on,
/// and it is named at both call sites rather than inferred.
pub fn createSession(
    alloc: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    keyless: KeylessPolicy,
) !?[]u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    if (!try storeTrusted(alloc, io, &host, cwd_path)) {
        try printErr(io, "session new failed: the workspace extension store is not trusted (see the lines above)\n");
        return null;
    }

    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    // `--parent <id>:<seq>` names the lineage this session continues — a fork,
    // or the new file a compaction opens (DESIGN §3.4, §11). The parent must
    // exist: a lineage pointer into nothing is not provenance. Its header is
    // also where an unnamed model comes from, below.
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
    // run (default: the profile's own default). A typo'd profile is refused
    // rather than silently frozen as scripted; a real profile whose credential
    // is missing still resolves scripted (the offline stand-in) but says so.
    const named_profile = flagValue(args, "--profile");
    const model_id = flagValue(args, "--model");

    // A fork continues its parent's model unless told otherwise: a compaction
    // opens a new file for the same conversation, and who that conversation is
    // with must not change because `active_profile` moved meanwhile (physics §2
    // in spirit — the identity was frozen once, at the root). Composition
    // deliberately does NOT come along: a new session is exactly where today's
    // pins and newly activated versions are meant to take hold (DESIGN §5.1,
    // §7.5), and a fork is a session boundary like any other.
    //
    // Two levels of continuing, because the two flags mean different things:
    // `--profile` names a different way to reach a provider, so it replaces the
    // parent's; `--model` only picks another id WITHIN a profile, so the
    // parent's profile still carries. Naming either re-resolves the identity
    // against today's config; naming neither takes the parent's frozen
    // descriptor verbatim, which is the compaction case.
    // An empty one is a legacy header that never recorded a profile: absent, not
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

    // An inherited identity needs no resolution — and no credential warning: it
    // never degrades to scripted, so there is nothing to explain here. A missing
    // credential is reported, loudly and once, by the `step` that needs it.
    var identity: ledger.ModelDescriptor = undefined;
    if (inherited) |d| {
        identity = d;
    } else {
        const profile_cfg = cfg.provider.findProfile(profile) orelse {
            try printErrFmt(alloc, io, "no such profile '{s}' (see `nulya config show`)\n", .{profile});
            return null;
        };
        // No credential, no session. This used to warn and freeze the identity
        // as `scripted`, which is the one failure mode worse than failing: the
        // session started, looked like the model that was asked for, and was
        // answered by the offline stand-in — and being frozen, it stayed that
        // way for its whole life (DESIGN §3). Refusing here is the creation-time
        // twin of resume's `MissingCredential` (§9.5): the same fact, reported at
        // the same volume, at both ends of a session's life.
        //
        // `nulya demo` deliberately keeps the fallback — running with no key at
        // all is what a demo IS — and it does not come through here.
        if (!launch.credentialAvailable(alloc, io, profile_cfg, &host)) {
            var paths = try config.ConfigPaths.init(alloc, &host);
            defer paths.deinit(alloc);
            const creds = (try launch.credentialFilePath(alloc, &host)) orelse try alloc.dupe(u8, launch.credentials_file);
            defer alloc.free(creds);
            const msg = if (profile_cfg.kind == .codex)
                try std.fmt.allocPrint(alloc, "profile '{s}' has no credential: run `codex login` (see `nulya config show`)\n", .{profile})
            else
                try std.fmt.allocPrint(
                    alloc,
                    "profile '{s}' has no credential: set {s}, or put `{s} = \"…\"` in {s}, or api_key in {s} (see `nulya config show`)\n",
                    .{ profile, profile_cfg.api_key_env, profile_cfg.api_key_env, creds, paths.user },
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
        // creation, and a later config edit can never change this session's
        // model (DESIGN §3).
        identity = launch.resolveDescriptor(alloc, io, cfg.provider, &host, profile, model_id);
    }

    // Where this session's `shell` commands will run, for its whole life
    // (DESIGN §8). Checked here, before a session id exists, for the same reason
    // a bad `--prompt` is: a session frozen onto a machine it cannot reach would
    // fail identically on every step it ever takes.
    const exec = environment.normalizeExecSpec(flagValue(args, "--env") orelse "");
    if (launch.execTargetRefusal(exec)) |why| {
        try printErrFmt(alloc, io, "--env {s}: {s}\n", .{ exec, why });
        return null;
    }

    // Which directory ON THAT MACHINE this session works in. Only a remote
    // environment has the question: a local session works where nulya was
    // started, and a `wsl` / `ssh` exec target does not move the workspace at
    // all (DESIGN §8.1). Accepting the flag anyway would freeze a fact nothing
    // ever reads — the kind of field this repo keeps deleting.
    const remote_workspace = flagValue(args, "--workspace") orelse "";
    if (remote_workspace.len != 0 and !launch.isRemoteSpec(exec)) {
        try printErrFmt(
            alloc,
            io,
            "--workspace names a directory on the machine a remote session runs on; it applies only with --env remote:… ({s})\n",
            .{launch.remote_spec_syntax},
        );
        return null;
    }

    // Read before anything exists on disk: a `--prompt` that cannot be read must
    // leave no session behind at all (D8 — the missing-credential discipline).
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
    // a tool, so nothing here can start a background task. The exec target is
    // passed anyway so this environment is the one the session describes — and
    // `exec` was already vetted above, so the two target errors cannot land here.
    //
    // A REMOTE spec is deliberately not passed: building that environment means
    // opening a connection, and `session new` runs nothing. Freezing the spec is
    // the whole of its job here; the first `step` is where that machine has to
    // answer, and where an unreachable one fails loudly (DESIGN §8.1).
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

    // Which machine's binaries will serve this session's extension calls. Only a
    // REMOTE session has the question, and even then it is asked lazily — a
    // remote session that composes nothing compiled never connects here, which
    // is why this is a probe rather than an answer (DESIGN §8.2).
    var target_probe: RemoteTargetProbe = .{ .alloc = alloc, .io = io, .spec = exec };
    defer target_probe.deinit();

    // `--bare` composes from argv alone: the two standing config lists below are
    // read as empty, the store's own standing layer (`apply: "auto"`) is turned
    // off, and everything else about the session is unchanged.
    const bare = bareComposition(args);

    // The session's members: config's standing `[extensions] with`, then every
    // `--with <id>[@<version>]` on the command line (DESIGN §5.1, §14). A
    // package joins a session only by being on this list or by being dragged in
    // by a pin — activating one never puts it here.
    const with = try withRefs(alloc, if (bare) &.{} else cfg.extensions.with, args);
    defer alloc.free(with);

    // `--pin ext:<id>/<tool>` (repeatable), unioned with the configured pins:
    // the whole native tool selection, and the only one there is — the usage
    // journal never puts a tool on the model's face by itself (DESIGN §5.1).
    const pins = try pinRefs(alloc, if (bare) &.{} else cfg.registry.pinned_native_tools, args);
    defer alloc.free(pins);

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
            .pinned_native_tools = pins,
            .max_tools = cfg.registry.max_tools,
            .with = with,
            .apply_auto = !bare,
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
        // The caller named these extensions, so an unusable one is not a warning.
        // A pin names them too, silently: it brings its own package into the
        // composition (DESIGN §5.1), so this refusal can be about a package
        // nothing on the command line spelled out — hence the second line.
        error.WithVersionNotFound => {
            try printErrFmt(alloc, io, "session new failed: an extension this session names has no such built version (see `nulya ext list`)\n", .{});
            try printPinImplied(alloc, io, pins, with);
            return null;
        },
        // A member named without a version resolves through `current`, and that
        // pointer led to something unusable. `composition.resolveCurrent` already
        // named the offending `id@version` and the two ways back on stderr; this
        // line only says what it cost.
        error.ActiveExtensionBroken => {
            try printErrFmt(alloc, io, "session new failed: an extension this session names has a broken current version (see the line above)\n", .{});
            return null;
        },
        // This session's tools run on another machine, and one of its packages
        // has no build for that machine. The line above already named the
        // package, the target and the two commands that fix it.
        error.ExecVersionNotFound => {
            try printErrFmt(alloc, io, "session new failed: an extension this session composes has no build for the machine its tools run on (see the line above)\n", .{});
            return null;
        },
        // The machine itself has to answer before its target can be known, so
        // an unreachable one stops creation rather than freezing a session onto
        // a guess. Same volume as a missing credential, at the same moment.
        error.RemoteChannelLost, error.RemoteChannelStalled, error.RemoteVersionMismatch, error.RemoteSpecUnsupportedOnHost => {
            try printErrFmt(alloc, io, "session new failed: '{s}' did not answer, and this session composes an extension whose build for that machine has to be identified now\n", .{exec});
            return null;
        },
        // Same rule for pins: a session missing a tool the operator asked for is
        // not the session that was asked for. Name the pins so the fix is
        // obvious — the bad one is in that list, in `.nulya/config.toml` or on
        // the command line.
        error.PinNamesUnknownExtension => {
            try printPinFailure(alloc, io, pins, "names an extension no store root holds — never built on this machine, or a typo (see `nulya ext list`)");
            return null;
        },
        error.PinToolNotDeclared => {
            try printPinFailure(alloc, io, pins, "names a tool its active version does not declare (see `nulya ext inspect <id>`)");
            return null;
        },
        error.PinToolNotPinnable => {
            try printPinFailure(alloc, io, pins, "names a tool whose manifest surface is not `manual`; compose the package with `--with` if the tool is surface `auto`, or call it with `nulya ext run` if it is surface `internal`");
            return null;
        },
        error.InvalidStableToolId => {
            try printPinFailure(alloc, io, pins, "is not a stable tool id (want ext:<extension-id>/<tool-name>)");
            return null;
        },
        error.ToolBudgetExceeded => {
            try printPinFailure(alloc, io, pins, "does not fit registry.max_tools (builtins included)");
            return null;
        },
        else => {
            try printErrFmt(alloc, io, "session new failed: {s}\n", .{@errorName(err)});
            return null;
        },
    };
    sess.deinit();

    return try alloc.dupe(u8, id);
}

/// The workspace-store gate (DESIGN §9), asked before a session composes
/// anything. `.nulya/extensions` is checkout content AND the first store root, so
/// a store that arrived with a clone would otherwise put its active versions into
/// the composition — system prompts into the system blocks, tools one `ext run`
/// away — with nothing in between. False means the session was refused and the
/// reason is already on stderr.
///
/// The refusal is HARD rather than "start without that root": a session missing a
/// capability it was composed with is not the session that was asked for, the same
/// rule a broken active version gets (DESIGN §7.5).
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

/// One line for a refused pin: what went wrong plus the pins this session asked
/// for, so the reader does not have to guess which of the two sources carried it.
fn printPinFailure(alloc: std.mem.Allocator, io: std.Io, pins: []const []const u8, reason: []const u8) !void {
    const listed = try std.mem.join(alloc, " ", pins);
    defer alloc.free(listed);
    try printErrFmt(alloc, io, "session new failed: a pin {s}; pinned: {s}\n", .{ reason, listed });
}

/// The packages nobody spelled out but the pins asked for anyway.
///
/// `--with` is visible on the command line; the membership a pin implies
/// (DESIGN §5.1) is not, so without this line "an extension this session names"
/// would be about a name the reader cannot find anywhere. Printed only when
/// there IS such a package: a plain `--with` failure keeps saying only what it
/// always said. Which one of them is the unresolvable one is not knowable here
/// — a Zig error carries no payload — but the list is short, exactly derived,
/// and the way out is the same for every entry on it.
fn printPinImplied(
    alloc: std.mem.Allocator,
    io: std.Io,
    pins: []const []const u8,
    with: []const composition.WithRef,
) !void {
    var implied: std.ArrayList([]const u8) = .empty;
    defer implied.deinit(alloc);
    for (pins) |pin| {
        const rest = if (std.mem.startsWith(u8, pin, "ext:")) pin["ext:".len..] else continue;
        const id = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse continue];
        if (containsString(implied.items, id)) continue;
        for (with) |ref| {
            if (std.mem.eql(u8, ref.id, id)) break;
        } else try implied.append(alloc, id);
    }
    if (implied.items.len == 0) return;
    const listed = try std.mem.join(alloc, " ", implied.items);
    defer alloc.free(listed);
    try printErrFmt(
        alloc,
        io,
        "  a pin brings its own package into the session, so these were named too: {s}\n" ++
            "  one of them has no `current` here; give it a version with `--with <id>@<version>`, or `nulya ext activate <id> <version>` (see `nulya ext list`)\n",
        .{listed},
    );
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
    // The same boundary `--prompt` draws above, for the same reason (BUGS.md
    // #22). A user turn is the person's own words, so it is refused rather than
    // repaired the way a tool's output is.
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

    // Images: the gates (DESIGN §9's "decisions live in the shell") — can this
    // session's frozen model see an image at all, is this file even an image,
    // is it small enough. Every one of them refuses BEFORE anything is
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
    var nonce: [4]u8 = undefined;
    io.random(&nonce);
    const name = try std.fmt.allocPrint(alloc, "msg-{d}-{x}", .{
        std.Io.Timestamp.now(io, .real).toNanoseconds(),
        std.mem.readInt(u32, &nonce, .little),
    });
    defer alloc.free(name);
    try ledger.depositEvent(alloc, io, std.Io.Dir.cwd(), spath, name, .{
        .user_text = .{ .text = text, .images = images.items },
    });
    return 0;
}

/// The largest image one turn may carry, raw bytes before base64 (the tightest
/// per-image limit among the providers we speak, DESIGN §13). Refusing here is
/// the honest place: nulya does not silently rescale a user's picture.
const max_image_bytes: u64 = 5 << 20;

const ImageError = error{ UnreadableImage, UnsupportedImageType, ImageTooLarge };

/// Read one image file and inline it as base64. The type comes from the file's
/// MAGIC, never its extension — the bytes are the fact, and a provider that
/// rejects a mislabeled `.png` would do it mid-run, one step later.
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

/// png / jpeg, by magic. Two types is the whole v1 list; a third is a decision
/// about what the wires accept, not a parser.
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

/// The vision gate (DESIGN §14): may THIS session be handed an image?
///
/// It asks the session's FROZEN identity (§3.4) — not today's active profile —
/// and looks the model id up in the `[[models]]` catalog, which is descriptive
/// and trusted-layer only (§9.5). No entry, or an entry that does not say
/// `vision = true`, is a refusal: the catalog is an explicit claim, and nothing
/// here guesses on the model's behalf. Prints its own refusal (stderr) and
/// returns false; the kernel never learns this gate exists.
fn visionAccepted(alloc: std.mem.Allocator, io: std.Io, spath: []const u8) !bool {
    var header = ledger.readHeader(alloc, io, std.Io.Dir.cwd(), spath) catch {
        try printErr(io, "session append failed: cannot read this session's header\n");
        return false;
    };
    defer header.deinit();
    const model_id = header.value.model_identity.model;

    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();
    var paths = try config.ConfigPaths.init(alloc, &host);
    defer paths.deinit(alloc);

    for (cfg.models) |m| {
        if (!std.mem.eql(u8, m.id, model_id)) continue;
        if (m.vision) return true;
        try printErrFmt(alloc, io, "session append refused: model '{s}' is not marked as accepting images\n", .{model_id});
        try printVisionHint(alloc, io, model_id, paths.user);
        return false;
    }
    try printErrFmt(
        alloc,
        io,
        "session append refused: no [[models]] entry for '{s}', so nothing claims it accepts images\n",
        .{if (model_id.len != 0) model_id else "(unnamed model)"},
    );
    try printVisionHint(alloc, io, model_id, paths.user);
    return false;
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
/// are not the ones frozen into the session (DESIGN §3.4). Those constants enter
/// the session's model-visible state but live in the BINARY, so an upgrade moves
/// them under an existing session — the stamp is what makes that visible.
///
/// It is provenance, not a gate: nothing is refused, and a header with no stamp
/// (written before this existed) says nothing, so it warns about nothing. The
/// line goes to stderr, which keeps `--stream` stdout pure JSON (DESIGN §14).
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
    // `--gate` asks the caller before every tool call, on the same wire the
    // stream uses (DESIGN §14): a request line on stdout, a verdict line on
    // stdin. Without `--stream` there is no such wire — and a step that silently
    // ran ungated would be the one refusal this flag exists to prevent — so the
    // combination is refused rather than approximated.
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
    var in_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
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
    // header, but the extension BYTES are read from the store on each resume
    // (DESIGN §7.5), so a store that arrived between two steps must not be
    // executed either.
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

    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    // The session this step's background tasks belong to: their supervisor
    // deposits `task_finished` into this file's inbox, and their directories
    // live beside this session's spills (DESIGN §6.1).
    const tasks_dir = try launch.sessionTasksDir(alloc, id);
    defer alloc.free(tasks_dir);
    // Where this session's commands run comes from the HEADER, never from a flag
    // or today's config: it was decided once, at creation (DESIGN §8). A target
    // this host cannot reach fails loudly, the way a missing credential does —
    // running the commands here instead would be the same silent substitution.
    const ext_roots = try launch.extensionRoots(alloc, &host, &cfg);
    defer launch.freeExtensionRoots(alloc, ext_roots);
    var lenv = launch.sessionEnvironment(alloc, io, &cfg, .{
        .session_path = spath,
        .tasks_dir = tasks_dir,
    }, hdr.value.environment, hdr.value.remote_workspace, ext_roots) catch |err| switch (err) {
        error.UnsupportedEnvironmentBackend => {
            return stepFail(alloc, io, stream, "environment backend '{s}' is not implemented; only local", .{@tagName(cfg.environment.backend)});
        },
        error.InvalidExecTarget, error.ExecTargetUnsupportedOnHost, error.InvalidRemoteSpec, error.RemoteSpecUnsupportedOnHost => {
            return stepFail(alloc, io, stream, "session '{s}' runs its commands in '{s}', which this binary on this host cannot reach; refusing to run them here instead", .{ id, hdr.value.environment });
        },
        // The machine is named and reachable in principle, but did not answer.
        // Distinct from the line above on purpose: one is "this host has no way
        // to get there", the other is "it is not answering right now", and the
        // two have different fixes. The transport's own diagnostic (ssh's
        // "Permission denied", wsl's "no distribution") has already gone to
        // stderr unmodified — this only says which session it stopped.
        error.RemoteChannelLost, error.RemoteChannelStalled => {
            return stepFail(alloc, io, stream, "session '{s}' runs its commands on '{s}', which did not answer; nothing was run here instead", .{ id, hdr.value.environment });
        },
        error.RemoteVersionMismatch => {
            return stepFail(alloc, io, stream, "session '{s}' reached '{s}', but the nulya there speaks a different remote protocol; install a matching build on that machine", .{ id, hdr.value.environment });
        },
        else => return err,
    };
    defer lenv.deinit();
    // Let this session's children name it (DESIGN §5.3): the FILE path, so
    // `nulya ext activate` can deposit a capability note into its inbox, and the
    // ID, which is true on whichever machine the child runs — see
    // `SessionEnvironment.publishSession`.
    try lenv.publishSession(spath, id);

    // Reconstruct the model frozen at creation, re-resolving only the credential.
    // No silent fallback: a real session whose key is gone fails loudly rather
    // than quietly becoming a scripted session (DESIGN §3). The session id is
    // also the prompt-cache scope, so a provider that keys its cache explicitly
    // keeps hitting it across separate `step` processes.
    // The credential is re-resolved every step: the profile's own `api_key`
    // (user config, found by the header's profile name), else the env var the
    // header names, else the Codex auth file.
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

    // Effort is a generation option, not identity (DESIGN §3): the driver may
    // set it per step; otherwise the profile / catalog default applies.
    const effort = flagValue(args[1..], "--effort") orelse
        cfg.defaultEffort(hdr.value.model, hdr.value.model_identity.model);

    // Workspace-relative, and deliberately so: a spill is written through the
    // environment's `putWorkspaceFile`, so this one string is the path on
    // whichever machine this session's workspace lives on (DESIGN §8.2).
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
        .model_options = .{ .effort = effort },
        .extension_roots = ext_roots,
    }, .{ .workspace = std.Io.Dir.cwd(), .session_path = spath }) catch |err| {
        return stepFail(alloc, io, stream, "session open failed: {s}", .{@errorName(err)});
    };
    defer sess.deinit();

    const before = sess.l.len();
    if (stream) |s| {
        s.printed = before;
        // Read-only, and only so a drained inbox turn reaches the reader when it
        // lands rather than at the end of the step it opened (step_stream.zig).
        s.ledger_view = &sess.l;
    }
    const steps = sess.run(max_steps) catch |err| {
        // Whatever this run did append before it faulted is still fact; report
        // those lines, then the error.
        if (stream) |s| s.flushEvents(sess.l.view()) catch {};
        // Not a fault but a state: the last reply was cut off, and stepping it
        // again would send it back as a prefill (DESIGN §4). Say what to do
        // instead of naming an error code the caller has to look up.
        if (err == error.TruncatedTurnNeedsInput) {
            return stepFail(alloc, io, stream, "the last reply was cut off at its output cap; append a message before stepping again", .{});
        }
        return stepFail(alloc, io, stream, "session step failed: {s}", .{@errorName(err)});
    };

    if (stream) |s| {
        // Every event was already flushed at its step boundary; only the run
        // verdict is left.
        try s.runDone(steps, stoppedReason(s.last_status, sess.lastStopReason(), sess.lastAssistantDone()));
        // A dropped observation is not a broken step, but the reader's picture is
        // incomplete — say so on stderr (stdout stays pure JSON) and exit non-zero.
        if (s.err) |e| {
            try printErr(io, "stream write failed: ");
            try printErr(io, @errorName(e));
            try printErr(io, "\n");
            return 1;
        }
        // A broken approval channel is the same kind of news: the step is legal
        // (everything it could not ask about was denied), the caller's picture
        // is not. Reaching the end of stdin is not a failure and sets nothing.
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

    // Poll for newly appended events (DESIGN §14 / PLAN §3.2: polling is enough).
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
/// ONE line shape is not passed through verbatim: a `user_text` carrying images
/// is re-encoded with each image's base64 replaced by `[image <media_type>, N
/// base64 bytes]`, because a screenshot is hundreds of kilobytes of payload that
/// no reader of a transcript wants (DESIGN §14). It is a presentation choice on
/// top of the stored fact — `seq`, `origin` and every other column survive it,
/// and a line that will not parse is printed raw rather than dropped. The
/// unredacted bytes stay one `cat` away, and `session step --stream` (the driver
/// surface) prints ledger lines unredacted so a front end sees the file's shape.
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
    return try ledger.encodeEventLineOrigin(
        alloc,
        .{ .user_text = .{ .text = event.user_text.text, .images = placeholders } },
        seq,
        parsed.value.origin,
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

fn parseParent(s: []const u8) ?ledger.ParentRef {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const session_id = s[0..colon];
    if (session_id.len == 0) return null;
    const seq = std.fmt.parseInt(u64, s[colon + 1 ..], 10) catch return null;
    return .{ .session = session_id, .seq = seq };
}

/// Bare `nulya session` prints this family's block from the one CLI map, rather
/// than a second description of the same verbs that would drift from it.
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
    defer alloc.free(refs);

    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("evolution", refs[0].id);
    try std.testing.expect(refs[0].version == null); // no @version = its current
    try std.testing.expectEqualStrings("web.search", refs[1].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", refs[1].version.?);

    const none = try withRefs(alloc, &.{}, &.{ "--profile", "scripted" });
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // Config's standing members come FIRST and carry no version — they follow
    // `current`, so `ext activate` still moves them. A command line naming the
    // same id lands after, which is what lets it override (`unionWith` keeps
    // the last mention of an id).
    const configured = [_][]const u8{ "guide", "std" };
    const both = try withRefs(alloc, &configured, &.{ "--with", "std@v-0123456789abcdef01234567" });
    defer alloc.free(both);
    try std.testing.expectEqual(@as(usize, 3), both.len);
    try std.testing.expectEqualStrings("guide", both[0].id);
    try std.testing.expect(both[0].version == null);
    try std.testing.expectEqualStrings("std", both[1].id);
    try std.testing.expect(both[1].version == null);
    try std.testing.expectEqualStrings("std", both[2].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", both[2].version.?);

    // `--bare` is the shell reading the standing list as empty; the argv half
    // is untouched (`bareComposition`, DESIGN §14).
    try std.testing.expect(bareComposition(&.{ "--profile", "scripted", "--bare" }));
    try std.testing.expect(!bareComposition(&args));
}

test "--pin unions with the configured pins, in order, without duplicating one" {
    const alloc = std.testing.allocator;
    const configured = [_][]const u8{ "ext:web.search/web_search", "ext:notes/append" };
    const args = [_][]const u8{
        "--profile", "scripted",
        "--pin",     "ext:demo/greet",
        // Re-naming a configured pin is a no-op, not a duplicate id.
        "--pin",     "ext:notes/append",
        "--pinned",  "ignored",
        "--pin",
    }; // a trailing --pin with no value is not a pin
    const pins = try pinRefs(alloc, &configured, &args);
    defer alloc.free(pins);

    try std.testing.expectEqual(@as(usize, 3), pins.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", pins[0]);
    try std.testing.expectEqualStrings("ext:notes/append", pins[1]);
    try std.testing.expectEqualStrings("ext:demo/greet", pins[2]);

    // Neither source: an empty native selection, which is the default face.
    const none = try pinRefs(alloc, &.{}, &.{ "--profile", "scripted" });
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // Config alone is enough; the flag is only the per-session addition.
    const configured_only = try pinRefs(alloc, &configured, &.{});
    defer alloc.free(configured_only);
    try std.testing.expectEqual(@as(usize, 2), configured_only.len);
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
