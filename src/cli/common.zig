//! Plumbing every `nulya` verb file shares (DESIGN §14): stdout/stderr writing,
//! argv scanning, the workspace cwd, and the ordered store-root search each
//! `ext` / `skill` / `session` command opens. Nothing here decides anything
//! about a verb — a helper lands in this file exactly when two verb files need
//! it, so `cli.zig` itself can stay a dispatcher over the files beside it.

const std = @import("std");
const builtin = @import("builtin");
const store = @import("../extension/store.zig");
const roots_mod = @import("../extension/roots.zig");
const config = @import("../config.zig");
const composition = @import("../composition.zig");
const launch = @import("../launch.zig");
const environment = @import("../environment.zig");

/// The ordered store roots this invocation searches (DESIGN §7.2), opened once.
/// Every `ext` / `skill` command goes through this instead of assuming the
/// workspace store is the only one: an extension may live in the user's
/// `~/.nulya/extensions` or in a trusted `extensions.paths` entry, and the first
/// root holding an ACTIVE version of an id wins.
pub const RootSearch = struct {
    specs: []const []const u8,
    roots: roots_mod.Roots,

    pub fn open(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) !RootSearch {
        const specs = try rootSpecs(alloc, io);
        errdefer launch.freeExtensionRoots(alloc, specs);
        const roots = try roots_mod.Roots.open(alloc, io, cwd, specs);
        return .{ .specs = specs, .roots = roots };
    }

    pub fn deinit(self: *RootSearch, alloc: std.mem.Allocator) void {
        self.roots.deinit();
        launch.freeExtensionRoots(alloc, self.specs);
    }
};

/// Resolve the ordered root specs from the environment + config chain. Caller
/// owns the result (`launch.freeExtensionRoots`).
pub fn rootSpecs(alloc: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();
    return launch.extensionRoots(alloc, &host, &cfg);
}

/// Where a write-side command puts things: the user store under `--user`, else
/// the workspace store. Null means `--user` on a machine with no home. Caller
/// owns the result.
pub fn writeRootSpec(alloc: std.mem.Allocator, user: bool) !?[]u8 {
    if (!user) return try alloc.dupe(u8, store.workspace_root_rel);
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    return launch.userExtensionsRoot(alloc, &host);
}

/// Split `args` into `(has --user, everything else)` — the one flag every
/// write-side `ext` verb shares. Caller owns the returned positionals.
pub fn takeUserFlag(alloc: std.mem.Allocator, args: []const []const u8) !struct { user: bool, rest: [][]const u8 } {
    var rest: std.ArrayList([]const u8) = .empty;
    errdefer rest.deinit(alloc);
    var user = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--user")) user = true else try rest.append(alloc, a);
    }
    return .{ .user = user, .rest = try rest.toOwnedSlice(alloc) };
}

/// The root spec an `activate` / `deactivate` acts on. `--user`
/// names the user store outright. Otherwise the root whose copy of `id` is IN
/// EFFECT (`Roots.firstActive`, DESIGN §7.2): the operation lands on what a
/// session would use — an activate there takes effect, an activate anywhere
/// else would succeed and change nothing. Only when no root has an active copy
/// does a `version` pick the first root that holds it built. Null means there
/// is nowhere to act (and, for `--user`, no home directory). Caller owns it.
pub fn targetRootSpec(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd_path: []const u8,
    id: []const u8,
    version: ?[]const u8,
    user: bool,
) !?[]u8 {
    if (user) return writeRootSpec(alloc, true);
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const index = if (try search.roots.firstActive(alloc, id)) |active| blk: {
        alloc.free(active.version);
        break :blk active.root;
    } else search.roots.firstWithVersion(alloc, id, version orelse return null, .structural) orelse return null;
    return try alloc.dupe(u8, search.roots.entries[index].spec);
}

/// The id of the session this process is running INSIDE, or null when it is not.
/// `session step` puts the live session's file path in `NULYA_SESSION` for its
/// shell children (DESIGN §5.3), so anything the model runs can name the session
/// it is in without being told. Caller owns the result.
pub fn envSessionId(alloc: std.mem.Allocator) !?[]u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    const path = host.get("NULYA_SESSION") orelse return null;
    const stem = std.fs.path.stem(path);
    if (stem.len == 0) return null;
    return try alloc.dupe(u8, stem);
}

/// Find `--flag <value>` in args; returns the value or null.
pub fn flagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

/// `<id>[@<version>]` — the one spelling of "an extension, maybe at an exact
/// version" shared by `session new --with` and `ext run`. Version ids contain
/// no `@`, extension ids neither, so the last `@` splits unambiguously.
pub fn withRef(spec: []const u8) composition.WithRef {
    const at = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return .{ .id = spec };
    return .{ .id = spec[0..at], .version = spec[at + 1 ..] };
}

pub fn cwdRealPath(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ![]u8 {
    // Not `Dir.cwd().realPath`: that resolves the handle through
    // /proc/self/fd/<fd>, and cwd()'s handle is the AT_FDCWD sentinel, which
    // is not an fd (std 0.16 turns it into FileNotFound).
    const len = try std.process.currentPath(io, buf);
    return buf[0..len];
}

pub fn sliceHasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

pub fn dataDir(alloc: std.mem.Allocator, host: *const std.process.Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = host.get("LOCALAPPDATA") orelse ".";
        return std.fs.path.join(alloc, &.{ base, "nulya" });
    }
    if (host.get("XDG_DATA_HOME")) |x| return std.fs.path.join(alloc, &.{ x, "nulya" });
    const home = host.get("HOME") orelse ".";
    return std.fs.path.join(alloc, &.{ home, ".local", "share", "nulya" });
}

pub fn writeInto(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(alloc, &.{ sub_dir, name });
    defer alloc.free(path);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

// ── The one-screen CLI map ──────────────────────────────────────────────────
//
// One block per verb family, so a bare `nulya ext` prints exactly its own lines
// and `nulya help` prints all of them in order: one text, so the two can never
// disagree about what a verb takes. Model-facing (it arrives through `shell`),
// so every line states behaviour and usage and cites no document.

pub const ext_usage =
    \\  nulya ext init [--zig] [--user] <id> [tool]       scaffold a draft: a script by default, --zig for a compiled one
    \\  nulya ext build <path> [--user]                   freeze a draft into an immutable version, print its id
    \\  nulya ext sync [--user] [--activate] [--dry-run]  build every draft in that root: source in <root>/<id>/ installs
    \\  nulya ext seed [--user] [<id>…] [--force] [--dry-run]  write the drafts this binary ships into that root; sync builds them
    \\  nulya ext run <id>[@<ver>] [tool] <json> | --arg k=v … [--timeout-ms N]   run the version in effect, or exactly that one; no timeout unless asked
    \\  nulya ext activate [--user] <id> <ver>            point `current` at a version; activating an older one is the rollback
    \\  nulya ext deactivate [--user] <id>                drop `current`; the versions stay
    \\  nulya ext prune [--user] [<id>] [--dry-run]       delete the versions `current` does not name
    \\  nulya ext list | inspect <id>[@<ver>] | <path>     every extension, or one manifest: the version in effect, an exact one, or a draft named by path
    \\  nulya ext trust                                   allow this workspace's store once, if it came with a checkout
    \\  nulya ext api [protocol|permissions|examples]     the tool wire protocol, the authority model, worked commands
    \\  --user acts on the user store, which every workspace on this machine sees
    \\
;

pub const session_usage =
    \\  nulya session new [--profile P] [--model ID] [--parent <id>:<seq>] [--with <id>[@<ver>]]… [--pin ext:<id>/<tool>]… [--prompt <file>]…
    \\                                                    freeze composition + model, print a new session id; --with composes a built
    \\                                                    version in, --pin puts one of its tools on the model's tool face, --parent
    \\                                                    forks that session, --prompt freezes a file as this session's system prompt
    \\  nulya session append <id> [<text> | --file <p>] [--image <p>]…
    \\                                                    queue a user turn for the next step boundary; --image inlines a
    \\                                                    png/jpeg ≤5 MB, if the model's catalog entry says vision = true
    \\  nulya session step <id> [--max-steps N] [--effort E] [--stream] [--gate]
    \\                                                    run to end of turn or budget; stdout = event JSONL, --stream adds
    \\                                                    live model/tool lines, --gate asks stdin to allow each tool call
    \\  nulya session events <id> [--since N] [--follow]  read-only tail of the event log
    \\  nulya session cancel <id>                         request cancel at the next step boundary
    \\  nulya session outcome <id> <success|partial|failure> [--note <text>] [--seq N]
    \\                                                    record how a session turned out (a journal, never the session file)
    \\  nulya session list [--json]                       every session here: composition, cost, latest verdict
    \\
;

pub const task_usage =
    \\  nulya task run [--session <id>] [--cwd <dir>] [--timeout-ms N] -- <command>
    \\                                                    start a detached command that outlives this step; you are told when
    \\                                                    it finishes, and its whole output is kept in a log
    \\  nulya task list [--session <id>] [--running] [--json] | status <task> [--json] | wait (<task> | --any) [--timeout-ms N] | kill <task> | retarget <task> --to <id>
    \\                                                    watch them; wait exits 0 finished / 2 timed out / 3 nothing to wait
    \\                                                    for; kill ends the whole tree; retarget delivers the result elsewhere
    \\
;

pub const config_usage =
    \\  nulya config show [--json]                        effective profiles, model catalog and pins; never a secret
    \\  nulya config refresh [--json]                     ask a subscription endpoint for today's models, then show
    \\
;

pub const skill_usage =
    \\  nulya skill list                                  the skill catalog: one line per skill available here
    \\  nulya skill load <skill-ref>                      print one frozen SKILL.md in full
    \\
;

pub const src_usage =
    \\  nulya src [path] [--tests]                        this binary's own source; no path lists the tree
    \\
;

pub const toolchain_usage =
    \\  nulya toolchain zig <args…>                       run the managed zig toolchain
    \\
;

pub fn usage(io: std.Io) !u8 {
    try printRaw(io,
        \\nulya — minimal self-evolving agent harness
        \\
        \\extensions — the tools, skills and system prompts you build; versions are immutable
        \\
    ++ ext_usage ++
        \\
        \\sessions — composition freezes at `new` and never changes; only `step` writes the file
        \\
    ++ session_usage ++ task_usage ++
        \\
        \\reading this harness
        \\
    ++ config_usage ++ skill_usage ++ src_usage ++ toolchain_usage ++
        \\  nulya help                                        this text, which a bare `nulya` prints too
        \\  nulya demo                                        one fixed-prompt session, end to end, to see it work
        \\
        \\a fuller reference ships with the nulya repo, as an extension you install once:
        \\  nulya ext build extensions/guide --user     then     nulya ext activate --user guide <version>
        \\
    );
    return 0;
}

/// Print one verb family's block — what a bare `nulya ext` / `nulya skill` says.
pub fn usageSection(io: std.Io, section: []const u8) !u8 {
    try printRaw(io, section);
    return 0;
}

pub fn printOut(alloc: std.mem.Allocator, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try printRaw(io, s);
}

/// `printOut`'s counterpart on stderr, for the diagnostics that need a value in
/// them. Refusals and warnings go here so stdout stays what a caller can parse:
/// ids, event JSONL, listings.
pub fn printErrFmt(alloc: std.mem.Allocator, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try printErr(io, s);
}

pub fn printRaw(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

pub fn printErr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}
