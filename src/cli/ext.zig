//! `nulya ext …` (DESIGN §7, §14): the extension lifecycle as a CLI — scaffold,
//! build into an immutable version, point `current` at one, run one, and read
//! what the store roots hold. The model reaches all of it through `shell`; none
//! of it is a model-facing tool.

const std = @import("std");
const environment = @import("../environment.zig");
const build_ext = @import("../extension/build/build_ext.zig");
const store = @import("../extension/store.zig");
const roots_mod = @import("../extension/roots.zig");
const invoke = @import("../extension/invoke.zig");
const manifest = @import("../extension/manifest.zig");
const templates = @import("../extension/build/templates.zig");
const notes = @import("../extension/notes.zig");
// `tool` is a common local name below (a tool NAME), so the module keeps a
// distinct one rather than forcing every call site to rename.
const tool_mod = @import("../tool.zig");
const tool_stats = @import("../journals/tool_stats.zig");
const trust = @import("../journals/trust.zig");
const launch = @import("../launch.zig");
const bundled = @import("../bundled.zig");
const ext_seed = @import("ext_seed.zig");
const cli_src = @import("src.zig");
const cli_toolchain = @import("toolchain.zig");
const ZigExe = cli_toolchain.ZigExe;
const resolveZig = cli_toolchain.resolveZig;
const noteUnpinnedZig = cli_toolchain.noteUnpinnedZig;
const common = @import("common.zig");
const RootSearch = common.RootSearch;
const writeRootSpec = common.writeRootSpec;
const takeUserFlag = common.takeUserFlag;
const targetRootSpec = common.targetRootSpec;
const envSessionId = common.envSessionId;
const cwdRealPath = common.cwdRealPath;
const withRef = common.withRef;
const writeInto = common.writeInto;
const printOut = common.printOut;
const printErrFmt = common.printErrFmt;
const printRaw = common.printRaw;
const printErr = common.printErr;

pub fn dispatchExt(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return common.usageSection(io, common.ext_usage);
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "init")) return extInit(alloc, io, rest);
    if (std.mem.eql(u8, sub, "build")) return extBuild(alloc, io, rest);
    if (std.mem.eql(u8, sub, "run")) return extRun(alloc, io, rest);
    if (std.mem.eql(u8, sub, "activate")) return extActivate(alloc, io, rest);
    if (std.mem.eql(u8, sub, "deactivate")) return extDeactivate(alloc, io, rest);
    if (std.mem.eql(u8, sub, "sync")) return extSync(alloc, io, rest);
    if (std.mem.eql(u8, sub, "seed")) return ext_seed.extSeed(alloc, io, rest);
    if (std.mem.eql(u8, sub, "prune")) return extPrune(alloc, io, rest);
    if (std.mem.eql(u8, sub, "list")) return extList(alloc, io);
    if (std.mem.eql(u8, sub, "inspect")) return extInspect(alloc, io, rest);
    if (std.mem.eql(u8, sub, "trust")) return extTrust(alloc, io);
    if (std.mem.eql(u8, sub, "api")) return extApi(alloc, io, rest);

    try printErrFmt(alloc, io, "unknown `ext` subcommand '{s}'; run `nulya help`\n", .{sub});
    return 1;
}

fn extInit(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    // A script is the default (PLAN §0.1 #3): the manufacturing loop happens on
    // the machine the AI is on, and friction there decides how many attempts get
    // made. `--zig` is for when a compiled runtime has been MEASURED to be
    // needed. `--script` says what is now the default, so it is accepted and does
    // nothing — the drafts and docs already written with it keep working — and it
    // is no longer listed.
    var want_zig = false;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(alloc);
    for (flags.rest) |a| {
        if (std.mem.eql(u8, a, "--zig")) {
            want_zig = true;
        } else if (std.mem.eql(u8, a, "--script")) {
            // no-op alias
        } else try positional.append(alloc, a);
    }
    if (positional.items.len < 1) {
        try printErr(io, "usage: nulya ext init [--zig] [--user] <id> [tool]\n");
        return 1;
    }
    const id = positional.items[0];
    const tool = if (positional.items.len >= 2) positional.items[1] else id;

    // The draft goes into the chosen store root (`--user` = the user-level one),
    // and everything below is written through that root's handle, so an absolute
    // user root needs no absolute sub-paths.
    const root_spec = (try writeRootSpec(alloc, flags.user)) orelse {
        try printErr(io, "no home directory for --user (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(root_spec);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd = try store.openOrCreateRoot(io, try cwdRealPath(io, &cwd_buf), root_spec);
    defer cwd.close(io);

    const dir = try alloc.dupe(u8, id);
    defer alloc.free(dir);
    const src_dir = try std.fs.path.join(alloc, &.{ dir, "src" });
    defer alloc.free(src_dir);
    const tests_dir = try std.fs.path.join(alloc, &.{ dir, "tests" });
    defer alloc.free(tests_dir);
    try cwd.createDirPath(io, src_dir);
    try cwd.createDirPath(io, tests_dir);

    if (!want_zig) {
        // Both platforms at once, in ONE version: the manifest names an entry
        // and an interpreter per OS, and the snapshot carries both files, so
        // `v-…` is the same package everywhere and only which script runs
        // differs (DESIGN §7.1).
        const manifest_bytes = try templates.scriptManifestJson(alloc, id, tool);
        defer alloc.free(manifest_bytes);
        const sh = try templates.scriptSh(alloc, id);
        defer alloc.free(sh);
        const ps1 = try templates.scriptPs1(alloc, id);
        defer alloc.free(ps1);
        try writeInto(alloc, io, cwd, dir, "extension.json", manifest_bytes);
        try writeInto(alloc, io, cwd, src_dir, "run.sh", sh);
        try writeInto(alloc, io, cwd, src_dir, "run.ps1", ps1);
        try writeInto(alloc, io, cwd, tests_dir, "example.json", templates.example_test_json);
        try printOut(alloc, io, "initialized script extension '{s}' at {s}{c}{s}\n", .{ id, root_spec, std.fs.path.sep, id });
        return 0;
    }

    const manifest_bytes = try templates.manifestJson(alloc, id, tool);
    defer alloc.free(manifest_bytes);
    try writeInto(alloc, io, cwd, dir, "extension.json", manifest_bytes);
    try writeInto(alloc, io, cwd, src_dir, "main.zig", templates.main_zig);
    try writeInto(alloc, io, cwd, tests_dir, "example.json", templates.example_test_json);

    try printOut(alloc, io, "initialized extension '{s}' at {s}{c}{s}\n", .{ id, root_spec, std.fs.path.sep, id });
    return 0;
}

fn extBuild(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    if (flags.rest.len < 1) {
        try printErr(io, "usage: nulya ext build <path> [--user]\n");
        return 1;
    }
    const ext_dir = flags.rest[0];

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const dest_spec = (try buildDestRoot(alloc, io, &search, ext_dir, flags.user)) orelse {
        try printErr(io, "no home directory for --user (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(dest_spec);

    // Was the workspace store empty BEFORE this build? If so, and if this build
    // fills it, the store was born here — see `recordBirthTrust` below. Asked now
    // because after the build the answer is always "occupied".
    const workspace_store_was_empty = blk: {
        const occupied = (try launch.occupiedWorkspaceStore(alloc, io, cwd_path)) orelse break :blk true;
        alloc.free(occupied);
        break :blk false;
    };

    var dest_root = try store.openOrCreateRoot(io, cwd_path, dest_spec);
    defer dest_root.close(io);

    // The other roots this machine searches, in that order: a version is content
    // addressed, so one of them already holding these exact bytes means this
    // build is a copy rather than a compile (DESIGN §7.4).
    var donors = try donorRoots(alloc, &search, dest_spec);
    defer donors.deinit(alloc);

    // A script extension needs no toolchain; only a compiled one does. Resolve
    // zig best-effort and let the build decide — it reports ZigVersionUnreadable
    // only if it actually has to compile.
    const zig_exe: ?ZigExe = resolveZig(alloc, io) catch null;
    defer if (zig_exe) |z| z.deinit(alloc);
    var zig = build_ext.Zig.init(if (zig_exe) |z| z.path else "");
    defer zig.deinit(alloc);

    var result = build_ext.buildExtensionReusing(alloc, io, std.Io.Dir.cwd(), ext_dir, dest_root, &zig, donors.dirs.items) catch |err| switch (err) {
        // Either nothing answered, or what answered could not say its own
        // version — and that difference is the whole repair hint, so it is not
        // flattened into one sentence.
        error.ZigVersionUnreadable => {
            const hint = try cli_toolchain.noZigHint(alloc);
            defer alloc.free(hint);
            if (zig_exe) |z| {
                try printOut(alloc, io, "the zig at {s} ({s}) could not report its version ({s}), and a compiled extension needs one; {s}\n", .{ z.path, z.origin(), zig.whyUnreadable() orelse "`zig version` failed here", hint });
            } else {
                try printOut(alloc, io, "no zig toolchain (needed to compile this extension); put zig on PATH, {s}\n", .{hint});
            }
            return 1;
        },
        // A path that holds no `extension.json` is a mistyped positional, not a
        // broken host: `ext build` takes a draft directory, and pointing at the
        // wrong one is the commonest way to get here.
        error.ManifestUnreadable => {
            try printErrFmt(alloc, io, "ext build: no readable extension.json in '{s}'; `nulya ext init <id>` scaffolds one\n", .{ext_dir});
            return 1;
        },
        else => {
            // Everything the manifest itself can refuse is a fault in the draft
            // being built — the author's own file, edited seconds ago. A host
            // fault (allocation, a failed write) still propagates.
            if (isManifestFault(err)) {
                try printErrFmt(alloc, io, "ext build: {s}/extension.json is not a valid manifest ({s}); `nulya ext api` prints the wire contract and `nulya ext init` a working manifest\n", .{ ext_dir, @errorName(err) });
                return 1;
            }
            return err;
        },
    };
    defer result.deinit(alloc);

    // `entry_rel` is set only for a COMPILED package, i.e. exactly when the
    // compiler above was used and its identity entered the version id.
    if (result.entry_rel != null) {
        if (zig_exe) |z| try noteUnpinnedZig(alloc, io, z);
    }

    if (!result.compile_ok) {
        try printOut(alloc, io, "build FAILED for {s}:\n{s}\n", .{ ext_dir, result.stderr });
        return 1;
    }
    const state = try buildState(alloc, result, donors.specs.items);
    defer alloc.free(state);
    try printOut(alloc, io, "{s}: {s} ({s}, in {s})\n", .{ ext_dir, result.version, state, dest_spec });

    if (workspace_store_was_empty and std.mem.eql(u8, dest_spec, store.workspace_root_rel)) {
        try recordBirthTrust(alloc, io, cwd_path);
    }
    return 0;
}

/// Whether `err` is one of the manifest's own structural or rule errors — a
/// fault in the `extension.json` being built, never in the host. Derived from
/// the error sets `manifest.zig` declares, so a new rule there needs no edit
/// here; `OutOfMemory` is deliberately left out of the union, because reporting
/// a resource fault as a bad manifest would send the author editing a file that
/// is fine.
fn isManifestFault(err: anyerror) bool {
    const Faults = manifest.ValidateError || error{ InvalidJson, NotAnObject, MissingField, WrongType };
    inline for (@typeInfo(Faults).error_set.?) |candidate| {
        if (err == @field(anyerror, candidate.name)) return true;
    }
    return false;
}

/// Trust a workspace store this build just BROUGHT INTO EXISTENCE (DESIGN §9).
///
/// The gate on `.nulya/extensions` distinguishes "born on this machine" from
/// "arrived with a checkout", and the only thing that can tell them apart is
/// where the store came from — so the moment a local `ext build` puts the first
/// version into an empty (or absent) workspace store, that store is by
/// construction local, and saying so here is what keeps the self-evolution loop
/// free of prompts: an agent building and activating its own capability is the
/// harness working, not an event to confirm. A store that ALREADY held something
/// is deliberately not trusted by this path — that is exactly the case a person
/// has to look at, through `nulya ext trust`.
///
/// Best-effort in one direction only: a machine with no home has nowhere to
/// record trust, and failing the build the model just did would be worse than
/// leaving the gate to explain itself at `session new`. Real I/O faults propagate.
fn recordBirthTrust(alloc: std.mem.Allocator, io: std.Io, cwd_path: []const u8) !void {
    const occupied = (try launch.occupiedWorkspaceStore(alloc, io, cwd_path)) orelse return;
    defer alloc.free(occupied);
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    const home = (try launch.userHomeDir(alloc, &host)) orelse return;
    defer alloc.free(home);
    if (try trust.isTrusted(alloc, io, home, occupied)) return;
    try trust.append(alloc, io, home, occupied);
}

/// Which store root a build lands in: `--user` forces the user store; otherwise
/// a draft that already lives inside one of the search roots builds into THAT
/// root (so `.nulya/extensions/<id>` keeps building exactly where it always
/// did), and a draft anywhere else — one kept in git, say — builds into the
/// workspace store. Caller owns the result; null means `--user` with no home.
fn buildDestRoot(
    alloc: std.mem.Allocator,
    io: std.Io,
    search: *const RootSearch,
    ext_dir: []const u8,
    user: bool,
) !?[]u8 {
    if (user) return writeRootSpec(alloc, true);

    var draft = std.Io.Dir.cwd().openDir(io, ext_dir, .{}) catch
        return try alloc.dupe(u8, store.workspace_root_rel); // let the build report it
    defer draft.close(io);
    var draft_buf: [std.fs.max_path_bytes]u8 = undefined;
    const draft_real = draft_buf[0..try draft.realPath(io, &draft_buf)];

    for (search.roots.entries) |entry| {
        if (isInside(entry.real, draft_real)) return try alloc.dupe(u8, entry.spec);
    }
    return try alloc.dupe(u8, store.workspace_root_rel);
}

/// The roots a build may take a copy FROM: every searched root except the one it
/// is building into, in search order. The handles belong to `search`; only the
/// two parallel lists are owned here.
const DonorRoots = struct {
    dirs: std.ArrayList(std.Io.Dir),
    specs: std.ArrayList([]const u8),

    fn deinit(self: *DonorRoots, alloc: std.mem.Allocator) void {
        self.dirs.deinit(alloc);
        self.specs.deinit(alloc);
    }
};

fn donorRoots(alloc: std.mem.Allocator, search: *const RootSearch, dest_spec: []const u8) !DonorRoots {
    var out: DonorRoots = .{ .dirs = .empty, .specs = .empty };
    errdefer out.deinit(alloc);
    for (search.roots.entries) |entry| {
        if (std.mem.eql(u8, entry.spec, dest_spec)) continue;
        try out.dirs.append(alloc, entry.dir);
        try out.specs.append(alloc, entry.spec);
    }
    return out;
}

/// The parenthesised state in a build line: what happened, and — when the
/// version came from another root rather than a compiler — which root supplied
/// it. Caller owns the result.
fn buildState(alloc: std.mem.Allocator, result: build_ext.BuildResult, donor_specs: []const []const u8) ![]u8 {
    if (result.copied_from) |i| {
        return std.fmt.allocPrint(alloc, "built, copied from {s}", .{donor_specs[i]});
    }
    return alloc.dupe(u8, if (result.already_built) "already built" else "built");
}

/// Whether `path` sits under directory `dir` (both already resolved to real
/// absolute paths).
fn isInside(dir: []const u8, path: []const u8) bool {
    if (path.len <= dir.len) return false;
    if (!std.mem.eql(u8, path[0..dir.len], dir)) return false;
    return path[dir.len] == std.fs.path.sep or path[dir.len] == '/';
}

/// Errors that are a fault in the DRAFT rather than in this machine: everything
/// `ext build` answers with one line about a source tree — the manifest's own
/// rules plus what freezing the package can find wrong with the files it names.
/// A host fault (out of memory, a failed read of a directory that is there) is
/// deliberately absent, so `ext sync` keeps going past a bad draft but not past
/// a broken machine.
fn isDraftFault(err: anyerror) bool {
    if (isManifestFault(err)) return true;
    return switch (err) {
        error.ManifestUnreadable,
        error.SourceUnreadable,
        error.DuplicateSnapshotPath,
        error.SkillFileMissing,
        error.SkillFileTooLarge,
        error.InvalidSkillDirectoryName,
        error.SkillNameDoesNotMatchDirectory,
        error.DuplicateSkillName,
        error.MissingSkillFrontmatter,
        error.MissingSkillFrontmatterEnd,
        error.MissingSkillName,
        error.MissingSkillDescription,
        error.InvalidSkillName,
        error.InvalidSkillDescription,
        error.SystemPromptFileMissing,
        error.SystemPromptTooLarge,
        error.InvalidUtf8,
        error.UiEntryFileMissing,
        => true,
        else => false,
    };
}

/// `nulya ext sync [--user] [--activate] [--dry-run]` — build every draft a store
/// root holds (DESIGN §7.2, §7.4).
///
/// The layout has always been that a draft lives at `<root>/<id>/` with its
/// frozen versions beside it. What was missing was the verb for "make what is in
/// this directory usable", so installing an extension meant knowing to run
/// `ext build` on each one by name. With this, putting the source in
/// `<root>/<id>/` and running this once IS the installation — and on a machine
/// with no toolchain it still works for anything another root already holds,
/// because a build adopts such a copy rather than compiling (§7.4).
///
/// One draft failing never stops the others: a root is a directory of
/// independent things, and stopping at the first bad manifest would hide every
/// id after it. Building is mechanical, so it is the default; `--activate` is
/// separate because pointing `current` somewhere is a decision (§7.4).
fn extSync(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    var activate = false;
    var dry_run = false;
    var seed = false;
    for (flags.rest) |a| {
        if (std.mem.eql(u8, a, "--activate")) {
            activate = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--seed")) {
            seed = true;
        } else {
            try printErr(io, "usage: nulya ext sync [--user] [--activate] [--dry-run] [--seed]\n");
            return 1;
        }
    }

    // `--seed` is `ext seed [--user]` (never `--force`: sync should not
    // overwrite someone's edited draft on their behalf) followed by this same
    // sync, sharing `--dry-run` with it — the drafts it writes (or, dry-run,
    // only plans to write) are picked up by the build loop below like any
    // other draft (DESIGN §7.2). `ext_seed.extSeed` owns the printing; its
    // exit code folds into this command's.
    var seed_failed = false;
    if (seed) {
        var seed_args: std.ArrayList([]const u8) = .empty;
        defer seed_args.deinit(alloc);
        if (flags.user) try seed_args.append(alloc, "--user");
        if (dry_run) try seed_args.append(alloc, "--dry-run");
        if ((try ext_seed.extSeed(alloc, io, seed_args.items)) != 0) seed_failed = true;
    }

    const root_spec = (try writeRootSpec(alloc, flags.user)) orelse {
        try printErr(io, "no home directory for --user (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(root_spec);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

    // Asked before anything is built, because after a successful sync the answer
    // is always "occupied" — the same birth-trust question `ext build` asks.
    const workspace_store_was_empty = blk: {
        const occupied = (try launch.occupiedWorkspaceStore(alloc, io, cwd_path)) orelse break :blk true;
        alloc.free(occupied);
        break :blk false;
    };

    var root_dir = store.openRoot(io, cwd_path, root_spec) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try printOut(alloc, io, "no drafts in {s}\n", .{root_spec});
            return 0;
        },
        else => return err,
    };
    defer root_dir.close(io);

    const drafts = try draftIds(alloc, io, root_dir);
    defer {
        for (drafts) |d| alloc.free(d);
        alloc.free(drafts);
    }
    if (drafts.len == 0) {
        try printOut(alloc, io, "no drafts in {s}\n", .{root_spec});
        return 0;
    }

    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    var donors = try donorRoots(alloc, &search, root_spec);
    defer donors.deinit(alloc);

    const zig_exe: ?ZigExe = resolveZig(alloc, io) catch null;
    defer if (zig_exe) |z| z.deinit(alloc);
    // One probe for the whole pass: every draft here builds from the same root,
    // and `zig version` is a subprocess (`build_ext.Zig`).
    var zig = build_ext.Zig.init(if (zig_exe) |z| z.path else "");
    defer zig.deinit(alloc);
    // The same three ways out `ext build` names, spelled once for the whole
    // pass: a front end relays this line as-is, so the directory has to be in it.
    const no_zig_hint = try cli_toolchain.noZigHint(alloc);
    defer alloc.free(no_zig_hint);

    var produced: usize = 0;
    var already: usize = 0;
    var failed: usize = 0;
    for (drafts) |draft| {
        // The draft is inside this root, so the root is both the tree the build
        // reads from and the store it writes into — no absolute sub-path anywhere,
        // which is what makes an absolute user root work the same as `.nulya/…`.
        var result = (if (dry_run)
            build_ext.planExtension(alloc, io, root_dir, draft, root_dir, &zig, donors.dirs.items)
        else
            build_ext.buildExtensionReusing(alloc, io, root_dir, draft, root_dir, &zig, donors.dirs.items)) catch |err| switch (err) {
            error.ZigVersionUnreadable => {
                failed += 1;
                // Two different walls behind one word: no compiler at all, or one
                // that answered `zig version` with a failure from this directory
                // (a version-manager shim that reads a build.zig.zon from the
                // cwd does exactly that in a store root). Name which.
                if (zig_exe) |z| {
                    try printOut(alloc, io, "{s}: needs zig (compiled draft; the zig at {s} ({s}) could not report its version from the store root — {s}; {s})\n", .{ draft, z.path, z.origin(), zig.whyUnreadable() orelse "`zig version` failed there", no_zig_hint });
                } else {
                    try printOut(alloc, io, "{s}: needs zig (compiled draft; put zig on PATH, {s})\n", .{ draft, no_zig_hint });
                }
                continue;
            },
            else => {
                if (!isDraftFault(err)) return err;
                failed += 1;
                try printOut(alloc, io, "{s}: failed: {s}\n", .{ draft, @errorName(err) });
                continue;
            },
        };
        defer result.deinit(alloc);

        if (!result.compile_ok) {
            failed += 1;
            try printOut(alloc, io, "{s}: failed: does not compile (`nulya ext build {s}` prints the diagnostics)\n", .{ result.id, draft });
            continue;
        }
        if (result.already_built) {
            already += 1;
        } else {
            produced += 1;
        }

        const state = if (result.already_built)
            "already built"
        else if (dry_run)
            "not built"
        else
            "built";
        var line: std.Io.Writer.Allocating = .init(alloc);
        defer line.deinit();
        try line.writer.print("{s}: {s} {s}", .{ result.id, result.version, state });
        if (result.copied_from) |i| {
            // A plan can only report where the copy would come from; a real sync
            // has already taken it.
            if (dry_run) {
                try line.writer.print(" (available from {s})", .{donors.specs.items[i]});
            } else {
                try line.writer.print(" (copied from {s})", .{donors.specs.items[i]});
            }
        }
        try appendActivation(alloc, io, &line.writer, root_dir, result, .{ .activate = activate, .dry_run = dry_run, .user = flags.user });
        try line.writer.writeByte('\n');
        try printRaw(io, line.written());
    }

    try printOut(alloc, io, "{d} {s}, {d} already built, {d} failed\n", .{
        produced,
        if (dry_run) "not built" else "built",
        already,
        failed,
    });

    if (!dry_run and produced != 0 and workspace_store_was_empty and std.mem.eql(u8, root_spec, store.workspace_root_rel)) {
        try recordBirthTrust(alloc, io, cwd_path);
    }
    return if (failed != 0 or seed_failed) 1 else 0;
}

const SyncMode = struct { activate: bool, dry_run: bool, user: bool };

/// The tail of a sync line: what `current` says about this version, and what
/// `--activate` did about it.
///
/// The rule is one sentence (DESIGN §7.4): sync points `current` at a version it
/// just brought into this root, and at a draft's version for an id that has no
/// `current` at all — but never over a `current` that names something else. That
/// pointer was somebody's decision (a rollback, an activate), and a sync that
/// silently undid it would make rollback survive only until the next start-up.
fn appendActivation(
    alloc: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    root_dir: std.Io.Dir,
    result: build_ext.BuildResult,
    mode: SyncMode,
) !void {
    const st = store.Store.init(io, root_dir);
    const current = try st.activeVersion(alloc, result.id);
    defer if (current) |c| alloc.free(c);

    if (current) |c| {
        if (std.mem.eql(u8, c, result.version)) return out.writeAll(" (active)");
    }
    if (!mode.activate or mode.dry_run) return;
    if (result.already_built and current != null) {
        return out.print(" (current stays {s})", .{current.?});
    }
    // `--activate` activates. It used to refuse this one case — a package
    // declaring `apply: "auto"` with no `current` yet — on the grounds that
    // turning a mode on is not a bulk decision. Two things were wrong with
    // that. The guard had a hole it could not close: `apply` is a per-version
    // field, so v1 (manual, current) -> v2 (auto) walked in through the branch
    // above, and auto -> manual walked out, both silently — "moving the pointer
    // changes the version, not the reach" is simply false across a change of
    // `apply`. And the flag is typed by a person: an unattended sync is a
    // FRONT END's problem, and the one that has it (the TUI's start-up sync)
    // has its own guard. So this verb means the same thing as `ext activate`
    // now, and says the same sentence when the consequence is a standing one.
    try warnUserScope(alloc, io, result.id, result.version, mode.user);
    try st.activate(alloc, result.id, result.version);
    depositSessionNote(alloc, io, root_dir, result.id, result.version) catch {};
    try noteStandingMembership(alloc, io, root_dir, result.id);
    try out.writeAll(" -> current");
}

/// `nulya ext prune [--user] [<id>] [--dry-run]` — drop the version directories a
/// store root keeps that `current` does not name (DESIGN §7.4).
///
/// Versions accumulate on purpose: every build of a changed draft is a new
/// immutable directory, and that is what makes rollback a pointer move. The cost
/// is disk, and after a few dozen iterations of one compiled tool it is real. So
/// this is the counterweight, and it is deliberately narrow: only `current` is
/// safe to keep by rule, so an id whose `current` is missing keeps EVERYTHING —
/// with no pointer there is nothing to preserve it BY, and guessing (newest?
/// biggest?) would delete the one somebody meant to roll back to.
///
/// What it costs is printed rather than assumed: a session frozen on a deleted
/// version can no longer resume, and the way back is the draft — building the
/// same source yields the same version id.
fn extPrune(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    var dry_run = false;
    var only_id: ?[]const u8 = null;
    for (flags.rest) |a| {
        if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (only_id == null and !std.mem.startsWith(u8, a, "-")) {
            only_id = a;
        } else {
            try printErr(io, "usage: nulya ext prune [--user] [<id>] [--dry-run]\n");
            return 1;
        }
    }

    if (only_id) |id| {
        if (!manifest.isValidId(id)) {
            try printErrFmt(alloc, io, "not an extension id: '{s}'; see `nulya ext list`\n", .{id});
            return 1;
        }
    }

    const root_spec = (try writeRootSpec(alloc, flags.user)) orelse {
        try printErr(io, "no home directory for --user (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(root_spec);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    var root_dir = store.openRoot(io, cwd_path, root_spec) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try printOut(alloc, io, "nothing to prune in {s}\n", .{root_spec});
            return 0;
        },
        else => return err,
    };
    defer root_dir.close(io);

    const ids = try pruneTargets(alloc, io, root_dir, only_id);
    defer {
        for (ids) |i| alloc.free(i);
        alloc.free(ids);
    }

    const st = store.Store.init(io, root_dir);
    var removed: usize = 0;
    var kept: usize = 0;
    var bytes_freed: u64 = 0;
    for (ids) |id| {
        // Look before leasing: an id with nothing built is nothing to prune, and
        // taking the writer lease would CREATE `<id>/` — a mistyped id would then
        // leave a directory behind instead of doing nothing.
        {
            const versions = try st.listVersions(alloc, id);
            defer {
                for (versions) |v| alloc.free(v);
                alloc.free(versions);
            }
            if (versions.len == 0) continue;
        }
        // The same writer lease every mutation of `<id>/` runs under, so a prune
        // cannot delete a directory another process is building or activating.
        var held: ?std.Io.File = if (dry_run) null else try st.lease(alloc, id);
        defer if (held) |*h| h.close(io);

        const current = try st.activeVersion(alloc, id);
        defer if (current) |c| alloc.free(c);
        const versions = try st.listVersions(alloc, id);
        defer {
            for (versions) |v| alloc.free(v);
            alloc.free(versions);
        }
        if (versions.len == 0) continue;
        if (current == null) {
            kept += versions.len;
            try printOut(alloc, io, "{s}: no current — nothing pruned (a deactivated id keeps every version; delete by hand if you mean it)\n", .{id});
            continue;
        }
        for (versions) |v| {
            if (std.mem.eql(u8, v, current.?)) {
                kept += 1;
                continue;
            }
            const version_rel = try std.fs.path.join(alloc, &.{ id, "versions", v });
            defer alloc.free(version_rel);
            const size = try treeSize(alloc, io, root_dir, version_rel);
            if (!dry_run) try root_dir.deleteTree(io, version_rel);
            removed += 1;
            bytes_freed += size;
            try printOut(alloc, io, "{s}@{s} {s} ({d} KB)\n", .{ id, v, if (dry_run) "would be removed" else "removed", (size + 1023) / 1024 });
        }
    }

    if (removed == 0) {
        try printOut(alloc, io, "nothing to prune in {s}\n", .{root_spec});
        return 0;
    }
    try printOut(alloc, io, "{d} version(s) {s}, {d} kept, {d} KB\n", .{
        removed,
        if (dry_run) "would be removed" else "removed",
        kept,
        (bytes_freed + 1023) / 1024,
    });
    // Said plainly, because it is the one thing a pruner cannot undo by rerunning
    // this command — and the one thing that IS recoverable, from the draft.
    try printOut(alloc, io, "note: a session frozen on a removed version can no longer resume; rebuilding the same source restores the same version id\n", .{});
    return 0;
}

/// Which ids a prune touches: the one named, or every directory in the root that
/// holds built versions. Caller owns the result.
fn pruneTargets(alloc: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, only_id: ?[]const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |i| alloc.free(i);
        out.deinit(alloc);
    }
    if (only_id) |id| {
        try out.append(alloc, try alloc.dupe(u8, id));
        return out.toOwnedSlice(alloc);
    }
    var it = root_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!manifest.isValidId(entry.name)) continue;
        try out.append(alloc, try alloc.dupe(u8, entry.name));
    }
    const items = try out.toOwnedSlice(alloc);
    std.mem.sort([]u8, items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return items;
}

/// Total bytes of the files under `sub_path`. Best-effort: a file that cannot be
/// stated contributes nothing rather than failing the prune.
fn treeSize(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, sub_path: []const u8) !u64 {
    var dir = root.openDir(io, sub_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var total: u64 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        var file = dir.openFile(io, entry.path, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        total += stat.size;
    }
    return total;
}

/// Every draft directly under a store root: `<root>/<id>/extension.json` is the
/// file `ext init` writes, so its presence IS the definition of a draft. Sorted,
/// so a sync reads the same way twice. One level only — a version's frozen
/// manifest lives further down and is not a draft. Caller owns the result.
fn draftIds(alloc: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |d| alloc.free(d);
        out.deinit(alloc);
    }
    var it = root_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const manifest_rel = try std.fs.path.join(alloc, &.{ entry.name, "extension.json" });
        defer alloc.free(manifest_rel);
        root_dir.access(io, manifest_rel, .{}) catch continue;
        try out.append(alloc, try alloc.dupe(u8, entry.name));
    }
    const items = try out.toOwnedSlice(alloc);
    std.mem.sort([]u8, items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return items;
}

const ext_run_usage = "usage: nulya ext run <id>[@<version>] <tool> [<json-args> | --arg k=v ...] [--timeout-ms N]\n";

fn extRun(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, ext_run_usage);
        return 1;
    }

    // Split off `--arg k=v` pairs and an optional `--timeout-ms N` from
    // positional args ([id, tool, json?]).
    var pairs: std.ArrayList([]const u8) = .empty;
    defer pairs.deinit(alloc);
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(alloc);
    var timeout_ms_arg: ?[]const u8 = null;
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--arg") and i + 1 < args.len) {
                try pairs.append(alloc, args[i + 1]);
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--timeout-ms") and i + 1 < args.len) {
                timeout_ms_arg = args[i + 1];
                i += 1;
            } else try positional.append(alloc, args[i]);
        }
    }
    // The tool is required (C2, ext-review-2 §2): [id, tool] is the shortest
    // legal shape, JSON args (or lack of them) come after.
    if (positional.items.len < 2) {
        try printErr(io, ext_run_usage);
        return 1;
    }
    // `<id>` runs the version in effect; `<id>@<version>` runs exactly that
    // built version, active or not — how a session invokes a tool it composed
    // with `--with <id>@<version>` (DESIGN §14), and how anything else names a
    // frozen version without touching `current`.
    const with_ref = withRef(positional.items[0]);
    const id = with_ref.id;
    const tool = positional.items[1];
    const use_args = pairs.items.len > 0;
    for (pairs.items) |p| {
        if (std.mem.indexOfScalar(u8, p, '=') == null) {
            try printErr(io, "--arg must be of the form k=v\n");
            return 1;
        }
    }
    var cwd_real: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_real);

    // Whichever root holds the version — the first active copy of the id, or
    // the first copy of the pinned version (DESIGN §7.2). One shared lookup
    // (`Roots.Resolved`) does search order, integrity validation, and the
    // frozen manifest, so this path cannot drift from session composition.
    // That frozen manifest is the runtime truth: the source tree's may already
    // have changed while `current` still points at an older immutable version.
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const resolved: roots_mod.Roots.Resolved = if (with_ref.version) |v|
        search.roots.resolveVersion(alloc, id, v, .sealed) catch |err| switch (err) {
            error.Canceled => return err,
            error.VersionNotFound => {
                try printOut(alloc, io, "no store root holds {s}@{s}; see `nulya ext list`\n", .{ id, v });
                return 1;
            },
            else => {
                try printOut(alloc, io, "version {s}@{s} failed integrity validation ({s})\n", .{ id, v, @errorName(err) });
                return 1;
            },
        }
    else
        (search.roots.resolveActive(alloc, id, .sealed) catch |err| switch (err) {
            error.Canceled => return err,
            // `current` names a version this root cannot serve. Name the fault;
            // `nulya ext list` names the version it points at.
            else => {
                try printOut(alloc, io, "active version of '{s}' failed integrity validation ({s}); see `nulya ext list`\n", .{ id, @errorName(err) });
                return 1;
            },
        }) orelse {
            try printOut(alloc, io, "extension '{s}' has no active version; run `nulya ext build` then `nulya ext activate`, or name a built version as {s}@<version>\n", .{ id, id });
            return 1;
        };
    defer resolved.deinit(alloc);
    const m = resolved.manifest;

    const rt = m.runtime orelse {
        try printOut(alloc, io, "extension '{s}' has no runtime\n", .{id});
        return 1;
    };
    const spec: ?manifest.ToolSpec = blk: {
        for (m.tools) |declared_tool| {
            if (std.mem.eql(u8, declared_tool.name, tool)) break :blk declared_tool;
        }
        break :blk null;
    };
    if (spec == null) {
        try printOut(alloc, io, "extension '{s}' does not declare tool '{s}'\n", .{ id, tool });
        return 1;
    }

    // Build the arguments JSON: from --arg pairs (typed by the tool's input
    // schema) when given, otherwise the trailing positional JSON if there is
    // one beyond [id, tool], otherwise `{}` — the tool is required, its
    // arguments are optional (C2, ext-review-2 §2).
    const owned_args: ?[]u8 = if (use_args) try buildArgsJson(alloc, pairs.items, spec.?.input_schema) else null;
    defer if (owned_args) |a| alloc.free(a);
    const args_json = owned_args orelse
        if (positional.items.len >= 3) positional.items[positional.items.len - 1] else "{}";

    // A compiled binary lives under `bin/`; a script under `package/`. The
    // resolution dispatches on runtime kind so this CLI path and session
    // composition never drift on how a frozen entry is located.
    const entry_abs = resolved.entryPathAbs(alloc, &search.roots) catch |err| switch (err) {
        // A per-OS `runtime.entry` that names no variant for this machine
        // (DESIGN §7.1). `entryPathAbs` already named the package and the host
        // on stderr, so this only decides the exit code.
        error.EntryUnsupportedOnHost => return 1,
        else => return err,
    };
    defer alloc.free(entry_abs);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    // `ext run` applies NO timeout by default (D6, DESIGN §7.3/§7.8): the
    // manifest's own `timeout_ms` bounds a call reaching a model's tool face
    // (a natively pinned tool, or the loop path a `session step` drives) —
    // that path is unchanged. A driver running the same tool in its own
    // process, on its own clock, opts into a bound with `--timeout-ms`; given,
    // it is clamped to the same ceiling a manifest-declared timeout would be
    // (`extension_max_ms`). `std.math.maxInt(u32)` (~49.7 days) is the
    // practical "no bound" sentinel `invoke.Options.timeout_ms` accepts —
    // there is no `?u32` on that type to carry an explicit "none" through.
    const timeout_ms: u32 = if (timeout_ms_arg) |raw| blk: {
        const parsed = std.fmt.parseInt(u32, raw, 10) catch {
            try printErr(io, "--timeout-ms must be a positive integer\n");
            return 1;
        };
        if (parsed == 0) {
            try printErr(io, "--timeout-ms must be a positive integer\n");
            return 1;
        }
        break :blk @min(parsed, tool_mod.Timeouts.extension_max_ms);
    } else std.math.maxInt(u32);

    // Resolution (active version, integrity, frozen manifest, tool declaration,
    // exact entry path) is the CLI's job; from here on the helper owns the
    // spawn, the capture, and the diagnostics.
    const invocation = invoke.invokeTool(alloc, lenv.environment(), entry_abs, cwd_path, tool, args_json, .{
        .timeout_ms = timeout_ms,
        .max_output_bytes = 1 << 20,
        .interpreter = if (rt.interpreter) |ip| ip.forHost() else null,
    }) catch |err| switch (err) {
        // The trailing positional IS the arguments, so a malformed one is a
        // usage error rather than a host fault — and `ext run <id> <tool>` with
        // no JSON at all arrives here too, its tool name having been read as the
        // arguments. Either way the reader needs a sentence, not a stack trace.
        error.InvalidArgumentsJson, error.ArgumentsNotObject => {
            try printErr(io, "ext run: the last argument must be a JSON object (use '{}' for no arguments), or pass --arg k=v instead\n");
            return 1;
        },
        else => return err,
    };
    defer invocation.deinit(alloc);

    // Resolution already proved both `id` and `tool` against the frozen
    // manifest, so the durable stats id is exactly `ext:<id>/<tool>` —
    // version-free on purpose, the same stable identity a natively exposed
    // ToolDefinition.id carries, so CLI usage accumulates across versions.
    const stable_id = try std.fmt.allocPrint(alloc, "ext:{s}/{s}", .{ id, tool });
    defer alloc.free(stable_id);
    // This command reaches the model through `shell`, whose env names the live
    // session (DESIGN §5.3) — so a tool invoked through the CLI, which is how
    // every UNPINNED extension tool is used, lands in the journal attributed to
    // the same session a natively pinned one would be.
    const in_session = try envSessionId(alloc);
    defer if (in_session) |s| alloc.free(s);
    try tool_stats.append(alloc, io, cwd_path, .{
        .tool_id = stable_id,
        .ok = invocation.ok,
        .session = in_session,
        // …and beside that version-free identity, the implementation that
        // actually ran: whichever version resolution settled on above, whether
        // the caller named it or `current` chose it. The one resolution this
        // command already performed answers it — no second lookup can disagree.
        .version = resolved.version,
    });

    try printOut(alloc, io, "{s}\n", .{invocation.output});
    return if (invocation.ok) 0 else 1;
}

/// Build a JSON object from `k=v` pairs, typing each value by the tool's input
/// schema (`properties.<k>.type`): integer/number/boolean are emitted as JSON
/// scalars, everything else (and any parse failure, and a missing schema) as a
/// string. Caller owns the result.
fn buildArgsJson(alloc: std.mem.Allocator, pairs: []const []const u8, input_schema: []const u8) ![]u8 {
    const parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, alloc, input_schema, .{}) catch null;
    defer if (parsed) |p| p.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    for (pairs) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=').?; // pre-checked by caller
        const key = pair[0..eq];
        const val = pair[eq + 1 ..];
        try jw.objectField(key);
        try writeTypedValue(&jw, val, schemaType(parsed, key));
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

fn schemaType(parsed: ?std.json.Parsed(std.json.Value), key: []const u8) ?[]const u8 {
    const p = parsed orelse return null;
    const root = switch (p.value) {
        .object => |o| o,
        else => return null,
    };
    const props = switch (root.get("properties") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const prop = switch (props.get(key) orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (prop.get("type") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn writeTypedValue(jw: *std.json.Stringify, val: []const u8, ty: ?[]const u8) !void {
    if (ty) |t| {
        if (std.mem.eql(u8, t, "integer")) {
            if (std.fmt.parseInt(i64, val, 10)) |n| return jw.write(n) else |_| {}
        } else if (std.mem.eql(u8, t, "number")) {
            if (std.fmt.parseFloat(f64, val)) |n| return jw.write(n) else |_| {}
        } else if (std.mem.eql(u8, t, "boolean")) {
            if (std.mem.eql(u8, val, "true")) return jw.write(true);
            if (std.mem.eql(u8, val, "false")) return jw.write(false);
        }
    }
    return jw.write(val); // string, or an unparseable scalar left as text
}

/// `nulya ext activate [--user] <id> <version>` — point `current` at one built
/// version. There is no second verb for going backwards: a rollback IS this,
/// aimed at an older version (DESIGN §7.4), and a `rollback` that shared every
/// line of this function only made the CLI look like it had two powers.
fn extActivate(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    if (flags.rest.len < 2) {
        try printErr(io, "usage: nulya ext activate [--user] <id> <version>\n");
        return 1;
    }
    const id = flags.rest[0];
    const version = flags.rest[1];

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const target = (try targetRootSpec(alloc, io, cwd_path, id, version, flags.user)) orelse {
        try printOut(alloc, io, "no store root holds {s}@{s} (or no home for --user); see `nulya ext list`\n", .{ id, version });
        return 1;
    };
    defer alloc.free(target);
    var ext_root = try store.openOrCreateRoot(io, cwd_path, target);
    defer ext_root.close(io);
    const st = store.Store.init(io, ext_root);
    try warnUserScope(alloc, io, id, version, flags.user);
    st.activate(alloc, id, version) catch |err| {
        try printOut(alloc, io, "activate failed: {s} ({s}@{s} in {s})\n", .{ @errorName(err), id, version, target });
        if (err == error.VersionNotFound) {
            // The version exists, just not in the root whose copy is in effect
            // — say so, or "but I built it" is the next question.
            var search = try RootSearch.open(alloc, io, cwd_path);
            defer search.deinit(alloc);
            if (search.roots.firstWithVersion(alloc, id, version, .structural)) |i| {
                try printOut(alloc, io, "note: {s}@{s} is built in {s}, which {s} shadows; activate a version built in {s}, or `--user` to act on the user store\n", .{ id, version, search.roots.entries[i].spec, target, target });
            }
        }
        return 1;
    };

    // What is IN EFFECT now (`Roots.firstActive`, DESIGN §7.2) — not merely
    // what this root's `current` says: an earlier root's active copy still wins.
    // Only a version that is actually in effect gets announced to a live session
    // (NULYA_SESSION names its file) by depositing a capability note into its
    // inbox for the next step boundary (DESIGN §3, §5.3). Best-effort: a
    // note-deposit failure never fails the activation the model just performed.
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const effective = try search.roots.firstActive(alloc, id);
    defer if (effective) |e| alloc.free(e.version);
    const shadowed_by: ?roots_mod.Roots.ActiveVersion = blk: {
        const e = effective orelse break :blk null;
        if (std.mem.eql(u8, e.version, version) and std.mem.eql(u8, search.roots.entries[e.root].spec, target)) break :blk null;
        break :blk e;
    };
    if (shadowed_by == null) depositSessionNote(alloc, io, ext_root, id, version) catch {};

    try printOut(alloc, io, "{s}: current -> {s} in {s}\n", .{ id, version, target });
    if (shadowed_by) |s| {
        try printOut(alloc, io, "note: not in effect — {s}@{s} in {s} shadows it\n", .{ id, s.version, search.roots.entries[s.root].spec });
    } else {
        try noteStandingMembership(alloc, io, ext_root, id);
    }
    return 0;
}

/// One stderr line when the package just activated declares `apply: "auto"`
/// (DESIGN §5.1): activation is normally only "which version `<id>` means", and
/// for this package it is also "every new session composes it from now on" —
/// its system prompt in every prefix, its `surface: auto` tools on every face.
/// The precedent is `warnUserScope`: the act is allowed and is not refused, but
/// it must not be INVISIBLE. `ext activate` says it only when this copy is the
/// one in effect, for the same reason the capability note is deposited only
/// then; `ext sync --activate` says it for each id it just switched on.
///
/// Read from the pointer this activation just wrote (`Store.readCurrent`),
/// which is where the answer now lives — not from the manifest a second time.
fn noteStandingMembership(
    alloc: std.mem.Allocator,
    io: std.Io,
    ext_root: std.Io.Dir,
    id: []const u8,
) !void {
    const active = (try store.Store.init(io, ext_root).readCurrent(alloc, id)) orelse return;
    defer alloc.free(active.version);
    if (!active.standing) return;
    try printErrFmt(
        alloc,
        io,
        "note: {s} declares apply: auto — every new session composes it as a standing member from now on; `nulya ext deactivate {s}` turns that off\n",
        .{ id, id },
    );
}

/// Say, on stderr, when a model running inside a session reaches OUT of that
/// session's workspace: `--user` moves `current` in the user store, so `<id>`
/// means this version for every workspace on this machine (DESIGN §7.2). It is
/// not refused — the model is allowed to do this, and a refusal here would be a
/// policy in the kernel's shell. What is not allowed is doing it INVISIBLY.
/// Silent outside `--user`, and silent when no session is running.
///
/// The sentence used to have a second half about the package's system prompt
/// entering every future session. That is no longer what activating does: a
/// package joins a session only when somebody names it (config's `[extensions]
/// with`, or `--with`, DESIGN §5.1), so this move changes WHICH VERSION those
/// sessions get and nothing about who gets it. Which is why no manifest is read
/// here any more.
fn warnUserScope(
    alloc: std.mem.Allocator,
    io: std.Io,
    id: []const u8,
    version: []const u8,
    user: bool,
) !void {
    if (!user) return;
    const sid = (try envSessionId(alloc)) orelse return;
    defer alloc.free(sid);

    const line = try std.fmt.allocPrint(
        alloc,
        "note: activating {s}@{s} in the user store from inside session {s}: {s} now means this version for every workspace on this machine\n",
        .{ id, version, sid, id },
    );
    defer alloc.free(line);
    try printErr(io, line);
}

/// Deposit a capability note for `id@version` into the current session's inbox
/// when `NULYA_SESSION` is set. The variable holds the session file path relative
/// to the workspace cwd, so both the file and its `<stem>.inbox` sibling resolve
/// against `cwd()`.
fn depositSessionNote(alloc: std.mem.Allocator, io: std.Io, ext_root: std.Io.Dir, id: []const u8, version: []const u8) !void {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    const session_path = host.get("NULYA_SESSION") orelse return;
    if (session_path.len == 0) return;
    try notes.depositActiveNote(alloc, io, std.Io.Dir.cwd(), session_path, ext_root, id, version);
}

fn extDeactivate(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    if (flags.rest.len < 1) {
        try printErr(io, "usage: nulya ext deactivate [--user] <id>\n");
        return 1;
    }
    const id = flags.rest[0];
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const target = (try targetRootSpec(alloc, io, cwd_path, id, null, flags.user)) orelse {
        try printOut(alloc, io, "extension '{s}' has no active version in any store root\n", .{id});
        return 1;
    };
    defer alloc.free(target);
    var ext_root = try store.openOrCreateRoot(io, cwd_path, target);
    defer ext_root.close(io);
    try store.Store.init(io, ext_root).deactivate(alloc, id);
    try printOut(alloc, io, "{s}: deactivated\n", .{id});

    // Deactivating the copy in effect can UNSHADOW one in a later root — say so,
    // or "I deactivated it, why is it still in my session?" is the next question.
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    if (try search.roots.firstActive(alloc, id)) |still| {
        defer alloc.free(still.version);
        try printOut(alloc, io, "note: {s}@{s} in {s} is now the active copy\n", .{ id, still.version, search.roots.entries[still.root].spec });
    }
    return 0;
}

/// Every extension directory in every root, in search order, with the root it
/// came from. The second column is exactly what `current` points at, and nothing
/// more: which version `<id>` means when somebody names it without one. An id
/// whose `current` an earlier root also sets is marked `(shadowed)` — only the
/// first is ever used (`Roots.firstActive`), and silently hiding the duplicate is
/// how a stale user-level copy becomes a mystery. A directory with no `current`
/// shadows nothing and says `(no current)` for its root alone — unless it holds
/// no built version either, in which case it is a bare writer lease, not an
/// extension, and is skipped.
///
/// Two more markers, and between them they answer "will a session have this?".
/// `[tools skills prompt]` is what the version CONTRIBUTES, from its frozen
/// manifest, plus `standing` when that manifest says `apply: "auto"` — this
/// package is in every new session for as long as it has a `current` (DESIGN
/// §5.1). `[with]` says this id is in the merged config's `[extensions] with`,
/// the person's own standing list. Without one of those two, `prompt` reads as
/// a threat it is not: a system prompt costs a session nothing until something
/// puts its package in one.
/// Unreadable manifest → no contribution marker, never a failed listing.
fn extList(alloc: std.mem.Allocator, io: std.Io) !u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var search = try RootSearch.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer search.deinit(alloc);

    var seen_active: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen_active.items) |s| alloc.free(s);
        seen_active.deinit(alloc);
    }

    var printed: usize = 0;
    for (search.roots.entries, 0..) |entry, root_index| {
        var it = entry.dir.iterate();
        while (try it.next(io)) |dir_entry| {
            if (dir_entry.kind != .directory) continue;
            const st = store.Store.init(io, entry.dir);
            const active = (st.readCurrent(alloc, dir_entry.name) catch |err| switch (err) {
                error.InvalidId => continue,
                else => return err,
            });
            defer if (active) |a| alloc.free(a.version);
            // A directory with neither an active pointer nor a built version is
            // not an extension — it is where `<id>/.lock` lives. Both `ext build`
            // and `ext activate` take that lease before they validate anything, so
            // a typo'd id or a manifest that failed to parse leaves an empty shell
            // behind; listing it invents an extension nobody made. A directory
            // holding versions is real whether or not one is active (a draft, a
            // deactivated copy), and so is one with a `current` pointer even if
            // its versions are gone — that one is broken, and saying so beats
            // hiding it.
            if (active == null) {
                const versions = try st.listVersions(alloc, dir_entry.name);
                defer {
                    for (versions) |v| alloc.free(v);
                    alloc.free(versions);
                }
                if (versions.len == 0) continue;
            }
            const shadowed = active != null and sliceHasString(seen_active.items, dir_entry.name);
            if (active != null and !shadowed) try seen_active.append(alloc, try alloc.dupe(u8, dir_entry.name));
            const contributes = if (active) |a|
                try contributionMarker(alloc, &search.roots, .{ .id = dir_entry.name, .root = root_index, .version = a.version, .standing = a.standing })
            else
                try alloc.dupe(u8, "");
            defer alloc.free(contributes);
            printed += 1;
            try printOut(alloc, io, "{s}\t{s}\t{s}{s}{s}{s}\n", .{
                dir_entry.name,
                if (active) |a| a.version else "(no current)",
                entry.spec,
                contributes,
                if (sliceHasString(search.with, dir_entry.name)) "\t[with]" else "",
                if (shadowed) "\t(shadowed)" else "",
            });
        }
    }
    if (printed == 0) try printOut(alloc, io, "no extensions\n", .{});
    return 0;
}

/// `\t[tools skills prompt]` for what this frozen version contributes. Empty
/// string when the version contributes nothing nameable or cannot be read.
/// Caller owns the result.
fn contributionMarker(alloc: std.mem.Allocator, roots: *const roots_mod.Roots, entry: roots_mod.Roots.ActiveEntry) ![]u8 {
    // `.structural`: this column reports what a version DECLARES. Re-digesting
    // every megabyte of built binary to print `[tools]` made `ext list` cost
    // most of a second in a store with a few compiled extensions — and a front
    // end runs it constantly. What is about to run is checked where it runs.
    const resolved = roots.resolveEntry(alloc, entry, .structural) catch return alloc.dupe(u8, "");
    defer resolved.deinit(alloc);
    const m = resolved.manifest;
    // The one word here that is NOT read from the manifest: this column answers
    // "will a session have this?", and the answer to that lives in `current`,
    // written when the activation verified it (`store.Active`, DESIGN §5.1). A
    // manifest declaring `apply: "auto"` that no activation ever recorded — an
    // edited version directory, a pointer written before the record existed —
    // is not standing, and a listing that said otherwise would be describing a
    // session nobody is going to get.
    const standing = entry.standing;
    if (!standing and m.tools.len == 0 and m.skills.len == 0 and m.system_prompts.len == 0) return alloc.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("\t[");
    var first = true;
    for ([_]struct { on: bool, word: []const u8 }{
        .{ .on = m.tools.len != 0, .word = "tools" },
        .{ .on = m.skills.len != 0, .word = "skills" },
        .{ .on = m.system_prompts.len != 0, .word = "prompt" },
        // Last, because it is not a contribution but what the package asks
        // happen with the three before it.
        .{ .on = standing, .word = "standing" },
    }) |part| {
        if (!part.on) continue;
        if (!first) try out.writer.writeByte(' ');
        try out.writer.writeAll(part.word);
        first = false;
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn sliceHasString(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// `nulya ext trust` — say, once and explicitly, that this workspace's extension
/// store may take part in sessions (DESIGN §9).
///
/// What gets recorded is the STORE, not a hash of what is in it: an agent that
/// builds and activates its own tools would otherwise invalidate the record every
/// loop. So this is a judgement about origin, and the only honest way to make it
/// is to look — which is why the inventory is printed BEFORE the record is
/// written, and why `ext list` / `ext inspect` are never gated.
///
/// There is no `untrust`: withdrawing means deleting the line from
/// `~/.nulya/trusted-stores.jsonl` by hand. A verb for it can wait for someone
/// who needs one.
fn extTrust(alloc: std.mem.Allocator, io: std.Io) !u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

    const occupied = (try launch.occupiedWorkspaceStore(alloc, io, cwd_path)) orelse {
        try printOut(alloc, io, "nothing to trust: {s} holds no extensions\n", .{store.workspace_root_rel});
        return 0;
    };
    defer alloc.free(occupied);

    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    const home = (try launch.userHomeDir(alloc, &host)) orelse {
        try printErr(io, "no home directory to record trust in (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(home);

    if (try trust.isTrusted(alloc, io, home, occupied)) {
        try printOut(alloc, io, "already trusted: {s}\n", .{occupied});
        return 0;
    }

    try printOut(alloc, io, "trusting {s}, which holds:\n", .{occupied});
    try printStoreInventory(alloc, io, cwd_path, false);
    try trust.append(alloc, io, home, occupied);
    try printOut(alloc, io, "recorded in {s}{c}{s}\n", .{ home, std.fs.path.sep, trust.journal_name });
    return 0;
}

/// The stderr block a session prints when it refuses an untrusted workspace store
/// (DESIGN §9). It names the store, shows what composing it would bring in, and
/// points at the two read-only verbs plus `ext trust` — everything a person needs
/// to decide, without having to trust anything first. The caller adds its own
/// one-line verdict, the same shape `ActiveExtensionBroken` uses.
///
/// Best-effort about the inventory: a store this machine cannot fully read is
/// still refused, and a half-listed refusal beats a failed one.
pub fn printUntrustedStoreRefusal(alloc: std.mem.Allocator, io: std.Io, cwd_path: []const u8) !void {
    const occupied = (try launch.occupiedWorkspaceStore(alloc, io, cwd_path)) orelse return;
    defer alloc.free(occupied);
    try printErrFmt(alloc, io, "the extension store {s} came with this checkout and is not trusted on this machine; it holds:\n", .{occupied});
    printStoreInventory(alloc, io, cwd_path, true) catch {};
    try printErr(io, "review it (`nulya ext list`, `nulya ext inspect <id>`), then `nulya ext trust` to allow it — or delete the store\n");
}

/// One indented line per extension the WORKSPACE store holds: `<id>@<version>`
/// with the contribution marker `ext list` uses (`prompt` is the load-bearing
/// one — an active version's system prompt enters every session's system
/// blocks), and the ids that hold built versions without activating one, since
/// `--with` and `ext run <id>@<version>` reach those too. Written to stderr when
/// `to_err`, else stdout.
fn printStoreInventory(alloc: std.mem.Allocator, io: std.Io, cwd_path: []const u8, to_err: bool) !void {
    var roots = try roots_mod.Roots.open(alloc, io, cwd_path, &.{store.workspace_root_rel});
    defer roots.deinit();
    if (roots.entries.len == 0) return;

    const active = try roots.listActive(alloc);
    defer roots_mod.Roots.freeActive(alloc, active);
    for (active) |entry| {
        const contributes = try contributionMarker(alloc, &roots, entry);
        defer alloc.free(contributes);
        try printLine(alloc, io, to_err, "  {s}@{s}{s}\n", .{ entry.id, entry.version, contributes });
    }

    // Built but not active: not in composition by discovery, still nameable.
    const st = store.Store.init(io, roots.entries[0].dir);
    var it = roots.entries[0].dir.iterate();
    while (try it.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        if (hasActiveId(active, dir_entry.name)) continue;
        const versions = st.listVersions(alloc, dir_entry.name) catch continue;
        defer {
            for (versions) |v| alloc.free(v);
            alloc.free(versions);
        }
        if (versions.len == 0) continue;
        try printLine(alloc, io, to_err, "  {s} ({d} built version(s), none active)\n", .{ dir_entry.name, versions.len });
    }
}

fn hasActiveId(active: []const roots_mod.Roots.ActiveEntry, id: []const u8) bool {
    for (active) |e| {
        if (std.mem.eql(u8, e.id, id)) return true;
    }
    return false;
}

fn printLine(alloc: std.mem.Allocator, io: std.Io, to_err: bool, comptime fmt: []const u8, args: anytype) !void {
    if (to_err) return printErrFmt(alloc, io, fmt, args);
    return printOut(alloc, io, fmt, args);
}

/// `<id>` prints the manifest of the version IN EFFECT (`Roots.firstActive`) —
/// what a plain `session new` would compose if it named this id — with NO
/// draft fallback (D9: inspect answers the STORE; a draft is asked for by
/// where it lives, below). No active version is a named refusal, not a
/// silent read of whatever happens to be lying around.
/// `<id>@<version>` prints the FROZEN manifest of that exact built version,
/// from the first root holding it — the shape a session header records for
/// every member (DESIGN §3.4), so this is how anything answering a question
/// ABOUT A RUNNING SESSION — a driver's approval policy, a reader of
/// `session list` — reads the manifest that session actually composed with,
/// instead of whatever `current` points at today.
/// `<path>` — an argument that names a directory holding `extension.json`,
/// which a bare separator already makes unambiguous — prints THAT draft,
/// unbuilt and unfrozen: the one form that answers "what would `ext build`
/// freeze next", spelled exactly the way `ext build <path>` already takes it.
/// A path never falls back to an id lookup, and an id never falls back to a
/// draft: the two questions ("what does this workspace have lying around" vs.
/// "what does the store say") are asked with different arguments, not
/// disambiguated by guessing which one the caller meant.
fn extInspect(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya ext inspect <id>[@<version>] | <path>\n");
        return 1;
    }
    const arg = args[0];

    // Try it as a path first — a bare directory name (no separator) that
    // happens to hold `extension.json` counts too, the same as `ext build .`
    // would take it. This can only ever answer for a PATH, never for an
    // `<id>[@<version>]` reference: `manifest.isValidId` forbids a separator
    // in an id, so a real id can never collide with this check.
    if (try draftManifestAtPath(alloc, io, arg)) |bytes| {
        defer alloc.free(bytes);
        try printOut(alloc, io, "{s}\n", .{bytes});
        return 0;
    }
    // A path with nothing readable at it is a mistyped path, not an id in
    // disguise — `nulya ext build <path>` reports the identical fault the
    // identical way, and falling back to an id lookup here would silently
    // answer a different question than the one asked.
    if (looksLikePathArg(arg)) {
        try printErrFmt(alloc, io, "ext inspect: no readable extension.json in '{s}'\n", .{arg});
        return 1;
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var search = try RootSearch.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer search.deinit(alloc);

    const ref = withRef(arg);
    if (ref.version) |v| {
        // A malformed version is simply a version no root holds — inspect is a
        // projection, so it answers rather than faults.
        for (search.roots.entries, 0..) |entry, i| {
            const manifest_rel = search.roots.store(i).versionManifestPath(alloc, ref.id, v) catch break;
            defer alloc.free(manifest_rel);
            const bytes = entry.dir.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20)) catch continue;
            defer alloc.free(bytes);
            try printOut(alloc, io, "{s}\n", .{bytes});
            return 0;
        }
        try printOut(alloc, io, "no store root holds {s}@{s}; see `nulya ext list`\n", .{ ref.id, v });
        return 1;
    }

    // Bare id: the version IN EFFECT, never a draft (D9) — a draft is the
    // `<path>` form above, tried and ruled out before we ever got here.
    if (try search.roots.firstActive(alloc, ref.id)) |active| {
        defer alloc.free(active.version);
        const manifest_rel = try search.roots.store(active.root).versionManifestPath(alloc, ref.id, active.version);
        defer alloc.free(manifest_rel);
        if (search.roots.entries[active.root].dir.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20))) |bytes| {
            defer alloc.free(bytes);
            try printOut(alloc, io, "{s}\n", .{bytes});
            return 0;
        } else |_| {}
    }
    try printErrFmt(alloc, io, "no active version of '{s}'; see `nulya ext list`\n", .{ref.id});
    return 1;
}

/// Whether an `ext inspect` argument names a PATH rather than an
/// `<id>[@<version>]` store reference: a path separator makes that
/// unambiguous on its own. `manifest.isValidId` forbids `/` and `\` in an id,
/// so this can never misclassify a real id.
fn looksLikePathArg(arg: []const u8) bool {
    return std.mem.indexOfAny(u8, arg, "/\\") != null;
}

/// Read `<arg>/extension.json` as a draft manifest — the exact file `ext
/// build <arg>` would freeze next. Null when there is nothing readable there
/// (arg is not a directory, has no manifest, or is a plain id with no local
/// directory of the same name); the caller decides from `looksLikePathArg`
/// whether that null means "fall back to a store lookup" or "report the path
/// as broken". `error.Canceled` propagates — a host fault, never "not found".
fn draftManifestAtPath(alloc: std.mem.Allocator, io: std.Io, arg: []const u8) !?[]u8 {
    const rel = try std.fs.path.join(alloc, &.{ arg, "extension.json" });
    defer alloc.free(rel);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, rel, alloc, .limited(1 << 20)) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    return bytes;
}

/// `ext api` is a curated `nulya src` (PLAN §3.10): the wire-protocol topic prints
/// the REAL `extension/protocol.zig`, so the ABI the model reads can never drift
/// from the code that implements it. `manifest` and `examples` stay short notes
/// (authority, the manifest's three tiers, and CLI usage — not source that drifts).
///
/// The topic was called `permissions` while the manifest had a field by that
/// name. Both are gone; `manifest` is what this is about.
fn extApi(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const topic = if (args.len >= 1) args[0] else "protocol";
    if (std.mem.eql(u8, topic, "manifest")) {
        try printRaw(io,
            \\Authority — what an extension tool may do, honestly:
            \\
            \\  An extension runs with the same authority as `shell`: this user account,
            \\  this machine, no sandbox. Building one grants nothing new; it packages
            \\  what you could already do.
            \\
            \\  A child process gets a sanitized environment: secret-shaped host
            \\  variables (API keys, tokens, cloud and SSH credentials) are removed.
            \\  NULYA_EXE, the absolute path of this binary, is added; inside a session
            \\  NULYA_SESSION names that session's file.
            \\
            \\  A tool gets args, a working directory and that environment — never the
            \\  conversation. It cannot read or append to the session.
            \\
            \\  A driver can hold the veto: `nulya session step --gate --stream` asks it
            \\  before every tool call and runs only what it allows. A refusal comes back
            \\  as that call's result — the call never ran, nothing changed — and the rest
            \\  of the batch is decided one call at a time.
            \\
            \\  A manifest speaks to three different readers, and each one keeps its own
            \\  discipline for every field it owns rather than restating it field by field.
            \\
            \\  KERNEL-ENFORCED, checked at build time and acted on at run time: `id`;
            \\  `runtime.entry` and `runtime.interpreter` (either a plain string, or an
            \\  object keyed by OS — `windows`, `linux`, `macos`, … — plus an optional
            \\  `default`, so one version can carry a different script per platform; the
            \\  object form is script-only, and a host this build has no entry for is a
            \\  named refusal rather than a silent skip); `tools[].name` / `.input` /
            \\  `.surface`, three words about a tool in a package that IS a session
            \\  member (`auto`, the default = it reaches the model as soon as the package
            \\  does; `manual` = only when somebody pins this tool by name, and the only
            \\  surface a pin accepts; `internal` = never on the model face, called
            \\  through `nulya ext run`) / `.timeout_ms` (this tool's own cap on a
            \\  MODEL-FACE call, default 30s, ceiling 600s); `apply` (`manual`, the
            \\  default = this package joins the sessions that name it; `auto` = while it
            \\  has a `current` it is a member of every new session on this machine —
            \\  what a mode wants, and `nulya ext deactivate <id>` is how it stops);
            \\  `skills`; `system_prompts`. Nothing says how the runtime is talked to,
            \\  because there is one way: stdin is the call's arguments as one compact
            \\  JSON object, NULYA_TOOL names the tool, stdout is the result taken
            \\  verbatim, and a non-zero exit is a failed call whose text is `exit <code>`
            \\  plus stderr — `nulya ext api protocol` is the whole contract.
            \\
            \\  Two axes decide what a session carries, and a manifest sits on neither:
            \\  MEMBERSHIP (`[extensions] with`, or `session new --with <id>[@<version>]`)
            \\  and the INDEPENDENT PIN FACE (`[registry] pinned_native_tools`, or
            \\  `session new --pin ext:<id>/<tool>`, which accepts only `surface: manual`
            \\  tools and brings its own package in). All `apply` does is give the
            \\  MEMBERSHIP axis a default the author chose: `auto` means an activated
            \\  package is a standing member here, and a person adds one the author left
            \\  at `manual` with config just the same, or stops an `auto` one with `nulya
            \\  ext deactivate <id>`. Reach is never something a package takes. `nulya ext
            \\  activate` is otherwise only "which version `<id>` means". `nulya config
            \\  show` prints both standing lists; `nulya ext list` marks a standing
            \\  package `standing`; `session new --bare` reads none of it and composes
            \\  from its own flags alone.
            \\
            \\  DRIVER DECLARATIONS, parsed, frozen into the version, and never enforced by
            \\  the kernel: a claim for whoever DRIVES a session (a front end, `nulya ext
            \\  run`, a script) to read and act on however it likes. Absent reads as null,
            \\  "the package did not say", never a default value: `tools[].readonly` (this
            \\  tool only reads, in the package's own words); `policy`, `{"readonly": true}`
            \\  — one narrowing a package can ask an approval policy for while it is a
            \\  session member. There is no key that widens anything: a package that could
            \\  add to an allow table would gain authority just by being composed in.
            \\
            \\  FRONT-END DECLARATIONS, open vocabularies: the kernel checks only the
            \\  shape, never the word, so a word this build has never heard of is simply
            \\  something the reader falls back on, never a build-time refusal: `commands`,
            \\  slash commands this package offers whoever drives a session — `{"name",
            \\  "description", "action"}`, `name` lowercase letters, digits and `-` only,
            \\  `action` an object with exactly one key, the verb, whose value is the
            \\  verb's argument or a bare `true` when it takes none: `{"with": true}`,
            \\  `{"run": "<tool>"}`, `{"skill": "<ref>"}` today, more later; the one
            \\  reference the kernel DOES follow is that a `run` command names a tool this
            \\  SAME manifest declares; `tools[].ui`, `{"render", "panel"}` — a rendering
            \\  hint for whoever draws this tool's calls, and a request that its latest
            \\  call also show as a small standing status line above the input; `ui`, keyed
            \\  by front end — `{"tui": {"entry", "api"}}` — a module that front end can
            \\  load, `entry` following the same path rule as a system prompt (it cannot
            \\  escape the package directory) and required to exist when the package is
            \\  built, `api` the plugin-host version (checked only for being a real number,
            \\  never for being one this build recognizes). A front end reads its own key
            \\  and ignores the rest; a package with no key for it simply has no module
            \\  there.
            \\
            \\  Wall clock is enforced on the model's tool face only: an extension tool
            \\  placed in front of a model is killed at 30s unless the manifest's
            \\  `timeout_ms` says otherwise (600s maximum); `shell` there defaults to 120s
            \\  and accepts up to 600s. That field means nothing anywhere else, so a tool
            \\  that is only ever called by a driver has no reason to write one: `nulya ext
            \\  run` applies no timeout of its own — it is a driver's own process — but
            \\  takes an optional `--timeout-ms` for a driver that wants one. A timeout,
            \\  wherever it applies, kills the whole process tree and returns whatever was
            \\  captured.
            \\
            \\  A workspace store (.nulya/extensions) that arrived with a checkout takes
            \\  part in no session until `nulya ext trust` records it once on this
            \\  machine. A store this machine built into is trusted by birth.
            \\
        );
        return 0;
    }
    if (std.mem.eql(u8, topic, "examples")) {
        try printRaw(io,
            \\  # A script tool, from nothing to the model's tool face.
            \\  nulya ext init my.helper do_thing             # draft in .nulya/extensions/my.helper
            \\  # it scaffolds src/run.sh + src/run.ps1: stdin is the arguments JSON, each
            \\  # simple argument is also NULYA_ARG_<key>, and whatever the script prints
            \\  # IS the result. Three lines is a real tool:
            \\  #   #!/bin/sh
            \\  #   printf 'hello %s\n' "${NULYA_ARG_name:-world}"
            \\  # `--zig` scaffolds the same thing, compiled. `nulya ext api protocol` is it.
            \\  nulya ext build .nulya/extensions/my.helper    # prints v-<hash>; the version is immutable
            \\  nulya ext run my.helper@v-<hash> do_thing --arg name=world    # try it before anything else sees it
            \\  nulya ext activate my.helper v-<hash>         # `current` points at it; CLI callers need nothing more
            \\  nulya session new --with my.helper             # the NEXT session carries it: a scaffolded tool is
            \\                                                 # `surface: auto`, so membership is all it needs
            \\  nulya ext activate my.helper v-<older>        # going back is the same verb: a pointer move, never a rebuild
            \\
            \\  # A tool a person assembles by hand instead: write `"surface": "manual"` on
            \\  # it, and membership alone will not put it in front of a model.
            \\  nulya session new --pin ext:my.helper/do_thing  # the pin brings its package in too
            \\
            \\  # A mode — a package a session should CHOOSE, not one every session lives in.
            \\  # Nothing in the manifest marks it: `apply` is absent, which means `manual`,
            \\  # so it reaches only the sessions that name it.
            \\  nulya ext build extensions/evolution          # prints v-<hash>
            \\  nulya ext activate evolution v-<hash>         # `evolution` now means this version
            \\  nulya session new --with evolution            # this session wears it, at `current`
            \\  nulya session new --with evolution@v-<hash>   # or name a build, activated or not
            \\
            \\  # A mode you want everywhere: say `"apply": "auto"` at the top level of the
            \\  # manifest, and activating it IS installing it — every new session composes
            \\  # it until `nulya ext deactivate` says otherwise.
            \\
            \\  # Every workspace on this machine, and the one-time trust of a store.
            \\  nulya ext build extensions/guide --user
            \\  nulya ext activate --user guide v-<hash>
            \\  nulya ext trust                               # a .nulya/extensions that came with a checkout
            \\
            \\  # A whole store root at once: put the source in <root>/<id>/, then one verb.
            \\  cp -r some.tool ~/.nulya/extensions/           # or write it there in the first place
            \\  nulya ext sync --user --activate               # builds every draft there; a version another root
            \\                                                # already holds is copied, not compiled
            \\  nulya ext sync --dry-run                       # what it would do, touching nothing
            \\  nulya ext prune --user                         # drop versions `current` does not name; the draft
            \\                                                # can always rebuild the same version id
            \\
            \\  # A slash command, a narrowed policy, and a front-end module — all just
            \\  # declared; a driver reads them, the kernel never runs any of it.
            \\  #   "contributes": {
            \\  #     "commands": [{"name": "plan", "description": "…", "action": {"with": true}}],
            \\  #     "policy": {"readonly": true},
            \\  #     "ui": {"tui": {"entry": "tui/panel.ts", "api": 1}}
            \\  #   }
            \\
            \\  # Afterwards: say how it went, so later passes have evidence.
            \\  nulya session outcome <session-id> success --note "the helper did it"
            \\
        );
        return 0;
    }
    return cli_src.printSource(alloc, io, "extension/protocol.zig", false);
}

test "every manifest parse/validate error is a draft fault; a host fault is not" {
    // The whole surface `manifest.parse` and `Manifest.validate` can produce,
    // so `ext build` answers with a sentence rather than a stack trace.
    for ([_]anyerror{
        error.InvalidJson,             error.NotAnObject,               error.MissingField,
        error.WrongType,               error.UnsupportedSchema,         error.InvalidId,
        error.MissingRuntime,          error.InvalidEntry,              error.InvalidInterpreter,
        error.NoContributions,         error.InvalidToolName,           error.ReservedToolName,
        error.DuplicateToolName,       error.InvalidTimeout,            error.InvalidSurface,
        error.InvalidApply,            error.InvalidSkillPath,          error.DuplicateSkillPath,
        error.InvalidSystemPromptPath, error.DuplicateSystemPromptPath, error.InvalidCommandName,
        error.InvalidCommandAction,    error.UnknownCommandTool,        error.InvalidUiHost,
        error.InvalidUiEntry,          error.InvalidUiApi,
    }) |err| {
        std.testing.expect(isManifestFault(err)) catch |e| {
            std.debug.print("{s} should be reported as a bad manifest\n", .{@errorName(err)});
            return e;
        };
    }
    // A resource or host fault must keep propagating: telling the author their
    // manifest is wrong when the machine ran out of memory sends them nowhere.
    for ([_]anyerror{ error.OutOfMemory, error.AccessDenied, error.Canceled, error.ManifestUnreadable }) |err| {
        try std.testing.expect(!isManifestFault(err));
    }
}

test "buildArgsJson types values by the tool input schema" {
    const alloc = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"count":{"type":"integer"},"ratio":{"type":"number"},"on":{"type":"boolean"},"q":{"type":"string"}}}
    ;
    const pairs = [_][]const u8{ "count=3", "ratio=1.5", "on=true", "q=zig" };
    const out = try buildArgsJson(alloc, &pairs, schema);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"count\":3,\"ratio\":1.5,\"on\":true,\"q\":\"zig\"}", out);
}

test "buildArgsJson falls back to string without a schema or for unparseable scalars" {
    const alloc = std.testing.allocator;
    const pairs = [_][]const u8{ "a=1", "b=hi" };
    const out = try buildArgsJson(alloc, &pairs, "not a schema");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"a\":\"1\",\"b\":\"hi\"}", out);

    // An integer-typed field with a non-integer value stays a string.
    const schema = "{\"properties\":{\"n\":{\"type\":\"integer\"}}}";
    const bad = [_][]const u8{"n=notanumber"};
    const out2 = try buildArgsJson(alloc, &bad, schema);
    defer alloc.free(out2);
    try std.testing.expectEqualStrings("{\"n\":\"notanumber\"}", out2);
}
