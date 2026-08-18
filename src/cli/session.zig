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
const session = @import("../session.zig");
const loop = @import("../loop.zig");
const provider = @import("../provider.zig");
const composition = @import("../composition.zig");
const launch = @import("../launch.zig");
const common = @import("common.zig");
const cli_ext = @import("ext.zig");
const session_list = @import("session_list.zig");
const StepStream = @import("step_stream.zig").StepStream;
const cwdRealPath = common.cwdRealPath;
const flagValue = common.flagValue;
const sliceHasFlag = common.sliceHasFlag;
const withRef = common.withRef;
const envSessionId = common.envSessionId;
const printOut = common.printOut;
const printErrFmt = common.printErrFmt;
const printRaw = common.printRaw;
const printErr = common.printErr;

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

/// Collect every `--with <id>[@<version>]` (the flag is repeatable). Slices
/// borrow `args`; the caller owns only the returned array.
fn withRefs(alloc: std.mem.Allocator, args: []const []const u8) ![]composition.WithRef {
    var out: std.ArrayList(composition.WithRef) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--with")) continue;
        try out.append(alloc, withRef(args[i + 1]));
        i += 1;
    }
    return out.toOwnedSlice(alloc);
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

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn sessionNew(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const id = (try createSession(alloc, io, args)) orelse return 1;
    defer alloc.free(id);
    try printOut(alloc, io, "{s}\n", .{id});
    return 0;
}

/// Create a durable session file from `session new`'s own flags and return its
/// id (owned by the caller), or null when the request was refused and the
/// reason has already been printed. `session new` is a thin printer over this;
/// the bare-`nulya` demo is its other caller, so the two cannot drift on how a
/// session is composed (DESIGN §14).
pub fn createSession(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !?[]u8 {
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
        if (!launch.credentialAvailable(alloc, io, profile_cfg, &host)) {
            var paths = try config.ConfigPaths.init(alloc, &host);
            defer paths.deinit(alloc);
            const warn = if (profile_cfg.kind == .codex)
                try std.fmt.allocPrint(alloc, "warning: profile '{s}' has no credential (run `codex login`); session frozen as scripted\n", .{profile})
            else
                try std.fmt.allocPrint(alloc, "warning: profile '{s}' has no credential (put api_key in {s}, or set {s}); session frozen as scripted\n", .{ profile, paths.user, profile_cfg.api_key_env });
            defer alloc.free(warn);
            try printErr(io, warn);
        }
        // Freeze the RESOLVED model identity now: config chooses the model at
        // creation, and a later config edit can never change this session's
        // model (DESIGN §3).
        identity = launch.resolveDescriptor(alloc, io, cfg.provider, &host, profile, model_id);
    }

    const id = try launch.genSessionId(alloc, io);
    defer alloc.free(id);
    const created = try journal.rfc3339Now(alloc, io);
    defer alloc.free(created);
    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);

    try std.Io.Dir.cwd().createDirPath(io, launch.sessions_dir);

    var lenv = launch.localEnvironment(alloc, io, &cfg) catch |err| switch (err) {
        error.UnsupportedEnvironmentBackend => {
            try printErrFmt(alloc, io, "environment backend '{s}' is not implemented; only local\n", .{@tagName(cfg.environment.backend)});
            return null;
        },
        else => return err,
    };
    defer lenv.deinit();

    const ext_roots = try launch.extensionRoots(alloc, &host, &cfg);
    defer launch.freeExtensionRoots(alloc, ext_roots);

    // `--with <id>[@<version>]` (repeatable) brings a BUILT version into this
    // one session's composition without activating it anywhere (DESIGN §14).
    const with = try withRefs(alloc, args);
    defer alloc.free(with);

    // `--pin ext:<id>/<tool>` (repeatable), unioned with the configured pins:
    // the whole native tool selection, and the only one there is — the usage
    // journal never puts a tool on the model's face by itself (DESIGN §5.1).
    const pins = try pinRefs(alloc, cfg.registry.pinned_native_tools, args);
    defer alloc.free(pins);

    // A placeholder handle is enough since `new` never steps.
    var holder: launch.ModelHolder = .{ .scripted = .{} };
    const scratch = try launch.sessionScratchDir(alloc, id);
    defer alloc.free(scratch);
    var sess = session.AgentSession.createDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = scratch,
        },
        .extension_roots = ext_roots,
        .registry = .{
            .pinned_native_tools = pins,
            .max_tools = cfg.registry.max_tools,
            .with = with,
        },
    }, .{
        .workspace = std.Io.Dir.cwd(),
        .session_path = spath,
        .session_id = id,
        .model_profile = profile,
        .model_identity = identity,
        .created = created,
        .nulya_version = launch.version,
        .parent = parent,
    }) catch |err| switch (err) {
        // The caller named these extensions, so an unusable one is not a warning.
        error.WithVersionNotFound => {
            try printErrFmt(alloc, io, "session new failed: --with names an extension with no such built version (see `nulya ext list`)\n", .{});
            return null;
        },
        // Activation is a statement of intent too, so a broken active version
        // stops the session instead of vanishing from it. `resolveActiveExtensions`
        // already named the offending `id@version` and the two repair verbs on
        // stderr; this line only says what it cost.
        error.ActiveExtensionBroken => {
            try printErrFmt(alloc, io, "session new failed: an activated extension does not validate (see the line above)\n", .{});
            return null;
        },
        // Same rule for pins: a session missing a tool the operator asked for is
        // not the session that was asked for. Name the pins so the fix is
        // obvious — the bad one is in that list, in `.nulya/config.toml` or on
        // the command line.
        error.PinNamesUnknownExtension => {
            try printPinFailure(alloc, io, pins, "names an extension with no active version here (see `nulya ext list`)");
            return null;
        },
        error.PinToolNotDeclared => {
            try printPinFailure(alloc, io, pins, "names a tool its active version does not declare (see `nulya ext inspect <id>`)");
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

fn sessionAppend(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session append <id> <text> | --file <path>\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }

    const text = if (flagValue(args[1..], "--file")) |path|
        std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20)) catch {
            try printErrFmt(alloc, io, "cannot read --file '{s}'\n", .{path});
            return 1;
        }
    else if (args.len >= 2)
        try alloc.dupe(u8, args[1])
    else {
        try printErr(io, "usage: nulya session append <id> <text> | --file <path>\n");
        return 1;
    };
    defer alloc.free(text);

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printErrFmt(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
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
    try ledger.depositEvent(alloc, io, std.Io.Dir.cwd(), spath, name, .{ .user_text = .{ .text = text } });
    return 0;
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
        try printErr(io, "usage: nulya session step <id> [--max-steps N] [--effort E] [--stream]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const streaming = sliceHasFlag(args[1..], "--stream");
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var stream_state: StepStream = .{ .alloc = alloc, .out = &stdout.interface };
    const stream: ?*StepStream = if (streaming) &stream_state else null;
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

    var lenv = launch.localEnvironment(alloc, io, &cfg) catch |err| switch (err) {
        error.UnsupportedEnvironmentBackend => {
            return stepFail(alloc, io, stream, "environment backend '{s}' is not implemented; only local", .{@tagName(cfg.environment.backend)});
        },
        else => return err,
    };
    defer lenv.deinit();
    // Let shell children (e.g. `nulya ext activate`) find the live session so
    // they can deposit capability notes into its inbox (DESIGN §5.3).
    try lenv.env.put("NULYA_SESSION", spath);

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

    const ext_roots = try launch.extensionRoots(alloc, &host, &cfg);
    defer launch.freeExtensionRoots(alloc, ext_roots);

    const scratch = try launch.sessionScratchDir(alloc, id);
    defer alloc.free(scratch);
    var sess = session.AgentSession.openDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = scratch,
            .retry = cfg.provider.retry,
            .observer = if (stream) |s| s.observer() else null,
        },
        .model_options = .{ .effort = effort },
        .extension_roots = ext_roots,
    }, .{ .workspace = std.Io.Dir.cwd(), .session_path = spath }) catch |err| {
        return stepFail(alloc, io, stream, "session open failed: {s}", .{@errorName(err)});
    };
    defer sess.deinit();

    const before = sess.l.len();
    if (stream) |s| s.printed = before;
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

test "--with is repeatable and splits <id>[@<version>]" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{
        "--profile",      "scripted",
        "--with",         "evolution",
        "--with",         "web.search@v-0123456789abcdef01234567",
        "--parent",       "s-1:4",
        "--with-nothing", "ignored",
        "--with",
    }; // a trailing --with with no value is not a ref
    const refs = try withRefs(alloc, &args);
    defer alloc.free(refs);

    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("evolution", refs[0].id);
    try std.testing.expect(refs[0].version == null); // no @version = its current
    try std.testing.expectEqualStrings("web.search", refs[1].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", refs[1].version.?);

    const none = try withRefs(alloc, &.{ "--profile", "scripted" });
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
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
