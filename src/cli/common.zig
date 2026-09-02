//! Plumbing every `nulya` verb file shares: stdout/stderr writing, argv
//! scanning, the workspace cwd, and the store-plus-pointer-layers view each
//! `ext` / `skill` / `session` command opens. Nothing here decides anything
//! about a verb — a helper lands here exactly when two verb files need it.

const std = @import("std");
const builtin = @import("builtin");
const site_mod = @import("../extension/site.zig");
const config = @import("../config.zig");
const composition = @import("../composition.zig");
const launch = @import("../launch.zig");
const environment = @import("../environment.zig");

/// This invocation's view of the machine: the one store, the workspace's
/// pointer layer, and the standing member list, all opened once.
pub const StoreView = struct {
    site: site_mod.Site,
    /// The merged config's `[extensions] with` — the ids that are a member of
    /// every session opened here. Read from the same config load as the store
    /// path: the store says where an id's code lives, this says whether a
    /// session gets it.
    with: []const []const u8,

    pub fn open(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) !StoreView {
        const resolved = try storeAndWith(alloc, io);
        defer alloc.free(resolved.store);
        errdefer launch.freeStringList(alloc, resolved.with);
        const site = try site_mod.Site.open(alloc, io, cwd, resolved.store, stderr_diag);
        return .{ .site = site, .with = resolved.with };
    }

    pub fn deinit(self: *StoreView, alloc: std.mem.Allocator) void {
        self.site.deinit();
        launch.freeStringList(alloc, self.with);
    }
};

/// Where the kernel's repair lines go on this side of the seam: stderr, so
/// `session step --stream` keeps stdout pure JSON. Stateless, so a `Site` may be
/// copied and moved freely once it holds one.
pub const stderr_diag: site_mod.Diag = .{ .reportFn = writeDiagLine };

fn writeDiagLine(_: ?*anyopaque, io: std.Io, line: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, line) catch {};
}

/// The two things one config load answers: where this machine's store is, and
/// the standing member ids (`[extensions] with`). Caller owns both.
pub fn storeAndWith(alloc: std.mem.Allocator, io: std.Io) !struct {
    store: []const u8,
    with: []const []const u8,
} {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();
    const path = try launch.storePath(alloc, &host);
    errdefer alloc.free(path);
    return .{ .store = path, .with = try dupeOwnedList(alloc, cfg.extensions.with) };
}

/// This machine's store path alone, for a caller with no `with` question.
/// Caller owns it; empty means the machine has no home directory.
pub fn storePath(alloc: std.mem.Allocator) ![]u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    return launch.storePath(alloc, &host);
}

/// Copy a config-arena string list into caller-owned memory — the config dies
/// with the load, and `StoreView` outlives it.
fn dupeOwnedList(alloc: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, list.len);
    errdefer alloc.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |s| alloc.free(s);
    while (filled < list.len) : (filled += 1) out[filled] = try alloc.dupe(u8, list[filled]);
    return out;
}

/// Where a draft-side command writes: the store under `--user` — where a draft
/// installed for the whole machine lives beside its versions — else this
/// workspace's `.nulya/extensions`. Null means `--user` on a machine with no
/// home. Caller owns the result.
pub fn draftRootSpec(alloc: std.mem.Allocator, user: bool) !?[]u8 {
    if (!user) return try alloc.dupe(u8, site_mod.workspace_rel);
    const path = try storePath(alloc);
    if (path.len == 0) {
        alloc.free(path);
        return null;
    }
    return path;
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

/// Which pointer layer an `ext activate` writes: `--user` says the store's own
/// `current` outright; otherwise the workspace layer when this workspace
/// already has a `<id>/` — a draft, a pointer, or both — and the store layer
/// when it does not. One rule, so "where did my activate land" has one answer
/// a person can predict from what is on disk.
pub fn activateLayer(site: *const site_mod.Site, id: []const u8, user: bool) site_mod.Layer {
    if (user) return .user;
    return if (site.workspaceHas(id)) .workspace else .user;
}

/// Which pointer layer an `ext deactivate` drops: `--user` the store's own,
/// otherwise the layer whose pointer is IN EFFECT — dropping any other would
/// succeed and change nothing.
pub fn deactivateLayer(alloc: std.mem.Allocator, site: *const site_mod.Site, id: []const u8, user: bool) !?site_mod.Layer {
    if (user) return .user;
    const active = (try site.activePointer(alloc, id)) orelse return null;
    defer alloc.free(active.version);
    return active.layer;
}

/// The id of the session this process is running INSIDE, or null when it is
/// not: `session step` publishes it as `NULYA_SESSION_ID` to everything it
/// runs. Caller owns the result.
///
/// The ID, not the stem of `NULYA_SESSION`: callers here want an identity (a
/// journal column, a task verb's default session, an outcome's `by:`), and a
/// session whose workspace lives on another machine has an identity there but
/// no session file. `NULYA_SESSION` stays for callers that need the file.
pub fn envSessionId(alloc: std.mem.Allocator) !?[]u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    const id = host.get("NULYA_SESSION_ID") orelse return null;
    if (id.len == 0) return null;
    return try alloc.dupe(u8, id);
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

/// `<id>[@<version>][:<tool>,<tool>…]` — one member of a session, the spelling
/// `session new --with` and config `[extensions] with` share. Neither an
/// extension id nor a version contains `:`, so the first one starts the tool
/// selection. `:none` and an empty selection both mean "a member with nothing
/// on the model's tool face".
///
/// Every string is BORROWED from `spec`, which outlives the composition; only
/// the names array is allocated, and `freeMemberRefs` releases it.
pub fn memberRef(alloc: std.mem.Allocator, spec: []const u8) !composition.WithRef {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return withRef(spec);
    var ref = withRef(spec[0..colon]);
    ref.tools = try toolSelection(alloc, spec[colon + 1 ..]);
    return ref;
}

fn toolSelection(alloc: std.mem.Allocator, text: []const u8) !composition.ToolSelection {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) return .none;
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(alloc);
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len != 0) try names.append(alloc, name);
    }
    if (names.items.len == 0) return .none;
    return .{ .named = try names.toOwnedSlice(alloc) };
}

pub fn freeMemberRefs(alloc: std.mem.Allocator, refs: []const composition.WithRef) void {
    for (refs) |ref| {
        switch (ref.tools) {
            .named => |names| alloc.free(names),
            else => {},
        }
    }
    alloc.free(refs);
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
    \\  nulya ext build <path> [--target <arch>-<os>]     freeze a draft into an immutable version in the store, print its id; --target builds it for another machine, which is another version
    \\  nulya ext push <id>@<ver> --env remote:…          copy that version into that machine's store, which re-checks the seal before it counts
    \\  nulya ext sync [--user] [--activate] [--seed] [--dry-run]  build every draft there into the store; --seed writes this binary's own drafts first
    \\  nulya ext seed [--user] [<id>…] [--force] [--dry-run]  write the drafts this binary ships there; sync builds them
    \\  nulya ext run <id>[@<ver>] <tool> [<json> | --arg k=v …] [--timeout-ms N]   run the version in effect, or exactly that one; no timeout unless asked
    \\  nulya ext activate [--user] <id> <ver>            point a `current` at a version; activating an older one is the rollback
    \\  nulya ext deactivate [--user] <id>                drop that `current`; the versions stay, and members naming no version stop resolving
    \\  nulya ext prune [<id>] [--dry-run]                delete the versions no `current` here names
    \\  nulya ext migrate [--dry-run]                     move versions written under the old per-root layout into the store, once
    \\  nulya ext list | inspect <id>[@<ver>] | <path>     every extension, or one manifest: the version in effect, an exact one, or a draft named by path
    \\  nulya ext api [protocol|manifest|examples]        the tool wire protocol, what a manifest may say, worked commands
    \\  versions live in <NULYA_HOME | ~/.nulya>/store; a workspace holds drafts and a `current` of its own, which wins; --user means the store's layer
    \\
;

pub const session_usage =
    \\  nulya session new [--profile P] [--model ID] [--parent <id>:<seq>] [--carry] [--with <id>[@<ver>][:<tool>,…]]… [--prompt <file>]… [--env <spec>] [--workspace <dir>] [--ssh-password-stdin] [--bare]
    \\                                                    freeze composition + model, print a new session id; --with composes a built
    \\                                                    version in, :tool,tool adds its manual tools to the model's tool face (:none adds
    \\                                                    nothing), --parent forks that session and --carry copies its events 1..seq along
    \\                                                    (how a live conversation changes model, tools or prompt), --prompt freezes a file as this session's
    \\                                                    system prompt, --env freezes where shell runs: local (default) or
    \\                                                    remote:wsl | remote:ssh:<dest> | remote:exec:<argv…>, which moves the whole workspace (--workspace says where),
    \\                                                    --bare reads no standing layer: the config `with` list is left out
    \\  nulya session append <id> [<text> | --file <p>] [--image <p>]…
    \\                                                    queue a user turn for the next step boundary, print the delivery name;
    \\                                                    --image inlines a png/jpeg ≤5 MB, if the model's catalog entry says vision = true
    \\  nulya session note <id> --source <label> [--meta <json>] (<text> | --file <p>)
    \\                                                    queue a machine fact instead of a user turn: --source names who saw it
    \\  nulya session step <id> [--max-steps N] [--effort E] [--gate] [--stream] [--ssh-password-stdin]
    \\                                                    run to end of turn or budget; stdout is one JSON line per model/tool and ledger
    \\                                                    event, ending in a run verdict; --gate asks stdin to allow each call; --stream does nothing (kept for one release)
    \\  nulya session events <id> [--since N] [--follow]  read-only tail of the event log
    \\  nulya session cancel <id>                         request cancel at the next step boundary
    \\  nulya session outcome <id> <success|partial|failure> [--note <text>] [--seq N]
    \\                                                    record how a session turned out (a journal, never the session file)
    \\  nulya session prune <id> [--force]                remove a session that recorded nothing and holds nothing; --force takes one
    \\                                                    with events or queued turns too, but never one being stepped, deposited into, or running a task
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

pub const remote_usage =
    \\  nulya remote check --env <spec> [--json] [--ssh-password-stdin]          open a channel to that machine and report what answered
    \\  nulya remote ls --env <spec> [<dir>] [--json] [--ssh-password-stdin]     list a directory on that machine, names and kinds exactly
    \\  nulya remote serve                                BE that machine's end of a channel; stdin/stdout are the wire
    \\  <spec> is remote:wsl | remote:wsl:<distro> | remote:ssh:<destination> | remote:exec:<argv…>
    \\
;

pub const journal_usage =
    \\  nulya journal append <path>                       append one JSON-line record read from stdin, lease-serialized
    \\  nulya journal read <path>                         print every complete line; a missing file is empty output, exit 0
    \\
;

pub const config_usage =
    \\  nulya config show [--json]                        effective profiles, model catalog and members; never a secret
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
    ++ session_usage ++ task_usage ++ remote_usage ++ journal_usage ++
        \\
        \\reading this harness
        \\
    ++ config_usage ++ skill_usage ++ src_usage ++ toolchain_usage ++
        \\  nulya help                                        this text, which a bare `nulya` prints too
        \\  nulya demo                                        one fixed-prompt session, end to end, to see it work
        \\
        \\a fuller reference ships with the nulya repo, as an extension you install once:
        \\  nulya ext build extensions/guide     then     nulya ext activate --user guide <version>
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
