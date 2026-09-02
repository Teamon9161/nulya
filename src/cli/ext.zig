//! `nulya ext …` — the extension lifecycle as a CLI: scaffold, build into an
//! immutable version, point a `current` at one, run one, and read what this
//! machine holds. The model reaches all of it through `shell`; none of it is a
//! model-facing tool.

const std = @import("std");
const environment = @import("../environment.zig");
const build_ext = @import("../extension/build/build_ext.zig");
const store = @import("../extension/store.zig");
const site_mod = @import("../extension/site.zig");
const invoke = @import("../extension/invoke.zig");
const manifest = @import("../extension/manifest.zig");
const target_mod = @import("../extension/target.zig");
const templates = @import("../extension/build/templates.zig");
const notes = @import("../extension/notes.zig");
// `tool` is a common local name below (a tool NAME), hence the distinct import.
const tool_mod = @import("../tool.zig");
const tool_stats = @import("../journals/tool_stats.zig");
const launch = @import("../launch.zig");
const bundled = @import("../bundled.zig");
const ext_seed = @import("ext_seed.zig");
const ext_push = @import("ext_push.zig");
const cli_src = @import("src.zig");
const cli_toolchain = @import("toolchain.zig");
const ZigExe = cli_toolchain.ZigExe;
const resolveZig = cli_toolchain.resolveZig;
const noteUnpinnedZig = cli_toolchain.noteUnpinnedZig;
const common = @import("common.zig");
const StoreView = common.StoreView;
const flagValue = common.flagValue;
const draftRootSpec = common.draftRootSpec;
const takeUserFlag = common.takeUserFlag;
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
    if (std.mem.eql(u8, sub, "push")) return ext_push.extPush(alloc, io, rest);
    if (std.mem.eql(u8, sub, "prune")) return extPrune(alloc, io, rest);
    if (std.mem.eql(u8, sub, "list")) return extList(alloc, io);
    if (std.mem.eql(u8, sub, "inspect")) return extInspect(alloc, io, rest);
    if (std.mem.eql(u8, sub, "migrate")) return extMigrate(alloc, io, rest);
    if (std.mem.eql(u8, sub, "api")) return extApi(alloc, io, rest);

    try printErrFmt(alloc, io, "unknown `ext` subcommand '{s}'; run `nulya help`\n", .{sub});
    return 1;
}

fn extInit(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    // A script is the default; `--zig` is for when a compiled runtime has been
    // measured to be needed. `--script` names the default, so it is accepted
    // and does nothing.
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

    // The draft goes into the workspace, or beside the versions in the store
    // under `--user`; everything below is written through that directory's
    // handle, so an absolute store path needs no absolute sub-paths.
    const root_spec = (try draftRootSpec(alloc, flags.user)) orelse {
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
        // differs.
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

    // Parsed before anything is opened, so an unrecognized spelling can name
    // the closed set of words it failed against.
    var cross: ?target_mod.Target = null;
    if (flagValue(flags.rest, "--target")) |spec| {
        cross = target_mod.parse(spec) catch {
            try printErrFmt(alloc, io, "ext build --target {s}: not a target this build knows ({s})\n", .{ spec, target_mod.vocabulary });
            return 1;
        };
    }
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(alloc);
    {
        var i: usize = 0;
        while (i < flags.rest.len) : (i += 1) {
            if (std.mem.eql(u8, flags.rest[i], "--target")) {
                i += 1;
                continue;
            }
            try positional.append(alloc, flags.rest[i]);
        }
    }
    if (positional.items.len < 1) {
        try printErr(io, "usage: nulya ext build <path> [--user] [--target <arch>-<os>]\n");
        return 1;
    }
    const ext_dir = positional.items[0];

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    // Bytes have exactly one home on a machine, so `--user` says nothing here
    // and is simply the flag `init` / `seed` / `sync` share.
    const dest_spec = (try common.storePath(alloc));
    defer alloc.free(dest_spec);
    if (dest_spec.len == 0) {
        try printErr(io, "no home directory, so there is nowhere to build into (set NULYA_HOME or HOME)\n");
        return 1;
    }

    var dest_root = try store.openOrCreateRoot(io, cwd_path, dest_spec);
    defer dest_root.close(io);

    // A script extension needs no toolchain; only a compiled one does. Resolve
    // zig best-effort and let the build decide — it reports ZigVersionUnreadable
    // only if it actually has to compile.
    const zig_exe: ?ZigExe = resolveZig(alloc, io) catch null;
    defer if (zig_exe) |z| z.deinit(alloc);
    var zig = build_ext.Zig.init(if (zig_exe) |z| z.path else "");
    defer zig.deinit(alloc);

    var result = build_ext.buildExtensionFor(alloc, io, std.Io.Dir.cwd(), ext_dir, dest_root, &zig, .{
        .target = cross,
    }) catch |err| switch (err) {
        // Only a compiled package has a binary, so only a compiled package has
        // a target. Say what the draft is rather than what the flag is.
        error.TargetNotApplicable => {
            try printErrFmt(alloc, io, "ext build --target: '{s}' declares no compiled runtime, and a package without one is the same version on every machine\n", .{ext_dir});
            return 1;
        },
        // Either nothing answered, or what answered could not say its own
        // version — that difference is the whole repair hint.
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
        // broken host.
        error.ManifestUnreadable => {
            try printErrFmt(alloc, io, "ext build: no readable extension.json in '{s}'; `nulya ext init <id>` scaffolds one\n", .{ext_dir});
            return 1;
        },
        else => {
            // Everything the manifest itself can refuse is a fault in the
            // draft being built. A host fault (allocation, a failed write)
            // still propagates.
            if (isManifestFault(err)) {
                try printErrFmt(alloc, io, "ext build: {s}/extension.json is not a valid manifest ({s}); `nulya ext api` prints the wire contract and `nulya ext init` a working manifest\n", .{ ext_dir, @errorName(err) });
                return 1;
            }
            // The manifest parses but names a file this build cannot freeze: a
            // missing / oversized / non-UTF-8 system prompt, a skill with bad
            // frontmatter, a declared entry or front-end module never written.
            // Build is the moment the AUTHOR can learn it.
            if (isDraftFault(err)) {
                try printErrFmt(alloc, io, "ext build: {s} declares a file this build cannot freeze ({s}); `nulya ext api manifest` says what each contribution must be\n", .{ ext_dir, @errorName(err) });
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
    try printOut(alloc, io, "{s}: {s} ({s}, in {s})\n", .{
        ext_dir,
        result.version,
        if (result.already_built) "already built" else "built",
        dest_spec,
    });
    return 0;
}

/// Whether `err` is one of the manifest's own structural or rule errors — a
/// fault in the `extension.json` being built, never in the host. Derived from
/// the error sets `manifest.zig` declares, so a new rule there needs no edit
/// here. `OutOfMemory` is deliberately left out: reporting a resource fault as
/// a bad manifest would send the author editing a file that is fine.
fn isManifestFault(err: anyerror) bool {
    const Faults = manifest.ValidateError || error{ InvalidJson, NotAnObject, MissingField, WrongType };
    inline for (@typeInfo(Faults).error_set.?) |candidate| {
        if (err == @field(anyerror, candidate.name)) return true;
    }
    return false;
}

/// Errors that are a fault in the DRAFT rather than in this machine: the
/// manifest's own rules plus what freezing the package can find wrong with the
/// files it names. A host fault is deliberately absent, so `ext sync` keeps
/// going past a bad draft but not past a broken machine.
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

/// `nulya ext sync [--user] [--activate] [--dry-run]` — build every draft in
/// one place: this workspace's `.nulya/extensions`, or the store itself under
/// `--user`. Either way the versions land in the store.
///
/// A draft is `<dir>/<id>/extension.json`, so putting source there and running
/// this once IS the installation.
///
/// One draft failing never stops the others: stopping at the first bad manifest
/// would hide every id after it. Building is mechanical, so it is the default;
/// `--activate` is separate because pointing `current` somewhere is a
/// decision.
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

    // `--seed` is `ext seed [--user]` (never `--force`: sync must not overwrite
    // someone's edited draft on their behalf) followed by this same sync,
    // sharing `--dry-run` with it. `ext_seed.extSeed` owns the printing; its
    // exit code folds into this command's.
    var seed_failed = false;
    if (seed) {
        var seed_args: std.ArrayList([]const u8) = .empty;
        defer seed_args.deinit(alloc);
        if (flags.user) try seed_args.append(alloc, "--user");
        if (dry_run) try seed_args.append(alloc, "--dry-run");
        if ((try ext_seed.extSeed(alloc, io, seed_args.items)) != 0) seed_failed = true;
    }

    const root_spec = (try draftRootSpec(alloc, flags.user)) orelse {
        try printErr(io, "no home directory for --user (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(root_spec);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

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

    var view = try StoreView.open(alloc, io, cwd_path);
    defer view.deinit(alloc);
    const dest_root = try view.site.ensureStore();

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
        // Two directories now: the tree the draft is read from, and the one
        // store it is frozen into.
        var result = (if (dry_run)
            build_ext.planExtension(alloc, io, root_dir, draft, dest_root.root, &zig)
        else
            build_ext.buildExtension(alloc, io, root_dir, draft, dest_root.root, &zig)) catch |err| switch (err) {
            error.ZigVersionUnreadable => {
                failed += 1;
                // Two different walls behind one word: no compiler at all, or
                // one that answered `zig version` with a failure from this
                // directory (a version-manager shim reading a build.zig.zon
                // from the cwd does exactly that in a store root). Name which.
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
        try appendActivation(alloc, io, &line.writer, &view.site, result, .{ .activate = activate, .dry_run = dry_run, .user = flags.user });
        try line.writer.writeByte('\n');
        try printRaw(io, line.written());
    }

    try printOut(alloc, io, "{d} {s}, {d} already built, {d} failed\n", .{
        produced,
        if (dry_run) "not built" else "built",
        already,
        failed,
    });

    return if (failed != 0 or seed_failed) 1 else 0;
}

const SyncMode = struct { activate: bool, dry_run: bool, user: bool };

/// The tail of a sync line: what `current` says about this version, and what
/// `--activate` did about it.
///
/// The rule is one sentence: sync points `current` at a version it just brought
/// into this root, and at a draft's version for an id that has no `current` at
/// all — but never over a `current` that names something else. That pointer was
/// somebody's decision, and undoing it would make a rollback survive only until
/// the next start-up.
fn appendActivation(
    alloc: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    site: *site_mod.Site,
    result: build_ext.BuildResult,
    mode: SyncMode,
) !void {
    const layer = common.activateLayer(site, result.id, mode.user);
    const current = blk: {
        const p = (try site.activePointer(alloc, result.id)) orelse break :blk null;
        break :blk p.version;
    };
    defer if (current) |c| alloc.free(c);

    if (current) |c| {
        if (std.mem.eql(u8, c, result.version)) return out.writeAll(" (active)");
    }
    if (!mode.activate or mode.dry_run) return;
    if (result.already_built and current != null) {
        return out.print(" (current stays {s})", .{current.?});
    }
    try warnUserScope(alloc, io, result.id, result.version, mode.user);
    try site.activate(alloc, layer, result.id, result.version);
    depositSessionNote(alloc, io, site.store().?.root, result.id, result.version) catch {};
    try out.print(" -> current ({s})", .{layer.label()});
}

/// `nulya ext prune [<id>] [--dry-run]` — drop the version directories the
/// store keeps that no `current` here names.
///
/// Deliberately narrow: only a pointer is safe to keep by rule, so an id with
/// no pointer at all keeps EVERYTHING — with nothing naming a version there is
/// nothing to preserve it BY, and guessing (newest? biggest?) would delete the
/// one somebody meant to roll back to.
///
/// "Here" is this workspace's pointer plus the store's own. Another workspace's
/// pointer is not visible from this one, which is the same cost the printed
/// note already names: a session frozen on a deleted version can no longer
/// resume, and the way back is the draft — building the same source yields the
/// same version id.
fn extPrune(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var dry_run = false;
    var only_id: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (only_id == null and !std.mem.startsWith(u8, a, "-")) {
            only_id = a;
        } else {
            try printErr(io, "usage: nulya ext prune [<id>] [--dry-run]\n");
            return 1;
        }
    }

    if (only_id) |id| {
        if (!manifest.isValidId(id)) {
            try printErrFmt(alloc, io, "not an extension id: '{s}'; see `nulya ext list`\n", .{id});
            return 1;
        }
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    var view = try StoreView.open(alloc, io, cwd_path);
    defer view.deinit(alloc);
    const st = view.site.store() orelse {
        try printOut(alloc, io, "nothing to prune: this machine has no extension store\n", .{});
        return 0;
    };
    const root_spec = view.site.store_path;
    const root_dir = st.root;

    const ids = try pruneTargets(alloc, io, root_dir, only_id);
    defer {
        for (ids) |i| alloc.free(i);
        alloc.free(ids);
    }
    var removed: usize = 0;
    var kept: usize = 0;
    var bytes_freed: u64 = 0;
    for (ids) |id| {
        // Look before leasing: taking the writer lease would CREATE `<id>/`, so
        // a mistyped id would leave a directory behind instead of doing
        // nothing.
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

        // Whatever any pointer HERE names is kept: the store's own, and this
        // workspace's when it has one.
        const current = blk: {
            const p = (try view.site.activePointer(alloc, id)) orelse break :blk null;
            break :blk p.version;
        };
        defer if (current) |c| alloc.free(c);
        const store_current = try st.activeVersion(alloc, id);
        defer if (store_current) |c| alloc.free(c);
        const versions = try st.listVersions(alloc, id);
        defer {
            for (versions) |v| alloc.free(v);
            alloc.free(versions);
        }
        if (versions.len == 0) continue;
        if (current == null and store_current == null) {
            kept += versions.len;
            try printOut(alloc, io, "{s}: no current — nothing pruned (a deactivated id keeps every version; delete by hand if you mean it)\n", .{id});
            continue;
        }
        for (versions) |v| {
            if (current != null and std.mem.eql(u8, v, current.?)) {
                kept += 1;
                continue;
            }
            if (store_current != null and std.mem.eql(u8, v, store_current.?)) {
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
    // The one thing rerunning this command cannot undo, and the one thing that
    // IS recoverable, from the draft.
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
/// file `ext init` writes, so its presence IS the definition of a draft. One
/// level only — a version's frozen manifest lives further down and is not a
/// draft. Caller owns the result.
///
/// Ordered, so a sync reads the same way twice, and in TWO groups: the drafts
/// that need no compiler first (`data` / `script`, whose identity is the
/// snapshot alone), then the compiled ones, alphabetically inside each. Putting
/// the instant answers first means a watching reader sees the count move at
/// once and the wait that remains is visibly a compile. Presentation only:
/// each draft is built independently and the summary counts totals.
fn draftIds(alloc: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir) ![][]u8 {
    const Draft = struct { id: []u8, compiled: bool };
    var out: std.ArrayList(Draft) = .empty;
    errdefer {
        for (out.items) |d| alloc.free(d.id);
        out.deinit(alloc);
    }
    var it = root_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const manifest_rel = try std.fs.path.join(alloc, &.{ entry.name, "extension.json" });
        defer alloc.free(manifest_rel);
        root_dir.access(io, manifest_rel, .{}) catch continue;
        const id = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(id);
        try out.append(alloc, .{ .id = id, .compiled = try draftNeedsCompiler(alloc, io, root_dir, manifest_rel) });
    }
    const drafts = try out.toOwnedSlice(alloc);
    defer alloc.free(drafts);
    std.mem.sort(Draft, drafts, {}, struct {
        fn lessThan(_: void, a: Draft, b: Draft) bool {
            if (a.compiled != b.compiled) return b.compiled;
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
    const ids = try alloc.alloc([]u8, drafts.len);
    for (drafts, ids) |d, *slot| slot.* = d.id;
    return ids;
}

/// Would building this draft need a compiler? A manifest this function cannot
/// read answers `false` — it goes in the first group, where the build reports
/// its real fault straight away instead of after every compile in the root.
fn draftNeedsCompiler(alloc: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, manifest_rel: []const u8) !bool {
    const bytes = root_dir.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20)) catch return false;
    defer alloc.free(bytes);
    var m = manifest.parse(alloc, bytes) catch return false;
    defer m.deinit();
    return manifest.implementationKind(m) == .compiled;
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
    // The tool is required: [id, tool] is the shortest legal shape, JSON args
    // (or lack of them) come after.
    if (positional.items.len < 2) {
        try printErr(io, ext_run_usage);
        return 1;
    }
    // `<id>` runs the version in effect; `<id>@<version>` runs exactly that
    // built version, active or not — how a session invokes a tool it composed
    // with `--with <id>@<version>`, and how anything else names a frozen
    // version without touching `current`.
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

    // The version in effect for the id, or exactly the one named. One shared
    // lookup (`Site.Resolved`) does the pointer layers, integrity validation
    // and the frozen manifest, so this path cannot drift from session
    // composition. That frozen manifest is the runtime truth: the source tree's
    // may already have changed while `current` still points at an older
    // immutable version.
    var view = try StoreView.open(alloc, io, cwd_path);
    defer view.deinit(alloc);
    const resolved: site_mod.Site.Resolved = if (with_ref.version) |v|
        view.site.resolveVersion(alloc, id, v, .sealed) catch |err| switch (err) {
            error.Canceled => return err,
            error.VersionNotFound => {
                try printOut(alloc, io, "this machine does not hold {s}@{s}; see `nulya ext list`\n", .{ id, v });
                return 1;
            },
            else => {
                try printOut(alloc, io, "version {s}@{s} failed integrity validation ({s})\n", .{ id, v, @errorName(err) });
                return 1;
            },
        }
    else
        (view.site.resolveActive(alloc, id, .sealed) catch |err| switch (err) {
            error.Canceled => return err,
            // `current` names a version this store cannot serve. Name the fault;
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

    if (m.runtime == null) {
        try printOut(alloc, io, "extension '{s}' has no runtime\n", .{id});
        return 1;
    }
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
    // one beyond [id, tool], otherwise `{}`.
    const owned_args: ?[]u8 = if (use_args) try buildArgsJson(alloc, pairs.items, spec.?.input_schema) else null;
    defer if (owned_args) |a| alloc.free(a);
    const args_json = owned_args orelse
        if (positional.items.len >= 3) positional.items[positional.items.len - 1] else "{}";

    // This command hands the environment the same thing a session's tool
    // binding does — `(id, version, tool)` — and the environment resolves it
    // against this very store (`extension/exec.zig`). One resolution
    // implementation, so a tool called through the CLI and the same tool on the
    // model's face cannot drift on which file "this version" means.
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{ .extension_store = view.site.store_path, .diag = common.stderr_diag });
    defer lenv.deinit();

    // `ext run` applies NO timeout by default: the manifest's own `timeout_ms`
    // bounds a call reaching a model's tool face, and a driver running the same
    // tool on its own clock opts into a bound with `--timeout-ms` (clamped to
    // the same `extension_max_ms` ceiling). `std.math.maxInt(u32)` (~49.7 days)
    // is the practical "no bound" sentinel `invoke.Options.timeout_ms` accepts;
    // that type carries no explicit "none".
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
    const invocation = invoke.invokeTool(alloc, lenv.environment(), id, resolved.version, tool, cwd_path, args_json, .{
        .timeout_ms = timeout_ms,
        .max_output_bytes = 1 << 20,
    }) catch |err| switch (err) {
        // A per-OS `runtime.entry` that names no variant for this machine. The
        // resolver already named the package and the host on stderr, so this
        // only decides the exit code.
        error.EntryUnsupportedOnHost => return 1,
        // The trailing positional IS the arguments, so a malformed one is a
        // usage error rather than a host fault. `ext run <id> <tool>` with no
        // JSON arrives here too, its tool name having been read as arguments.
        error.InvalidArgumentsJson, error.ArgumentsNotObject => {
            try printErr(io, "ext run: the last argument must be a JSON object (use '{}' for no arguments), or pass --arg k=v instead\n");
            return 1;
        },
        else => return err,
    };
    defer invocation.deinit(alloc);

    // Resolution already proved both `id` and `tool` against the frozen
    // manifest, so the durable stats id is exactly `ext:<id>/<tool>` —
    // version-free, the same stable identity a natively exposed
    // `ToolDefinition.id` carries, so CLI usage accumulates across versions.
    const stable_id = try std.fmt.allocPrint(alloc, "ext:{s}/{s}", .{ id, tool });
    defer alloc.free(stable_id);
    // This command reaches the model through `shell`, whose env names the live
    // session, so a tool invoked through the CLI lands in the journal
    // attributed to the same session a natively pinned one would be.
    const in_session = try envSessionId(alloc);
    defer if (in_session) |s| alloc.free(s);
    try tool_stats.append(alloc, io, cwd_path, .{
        .tool_id = stable_id,
        .ok = invocation.ok,
        .session = in_session,
        // …and beside that version-free identity, the implementation that
        // actually ran: whichever version resolution settled on above. No
        // second lookup, so nothing can disagree with it.
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
/// aimed at an older version.
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
    var view = try StoreView.open(alloc, io, cwd_path);
    defer view.deinit(alloc);
    const layer = common.activateLayer(&view.site, id, flags.user);

    try warnUserScope(alloc, io, id, version, layer == .user);
    view.site.activate(alloc, layer, id, version) catch |err| {
        try printOut(alloc, io, "activate failed: {s} ({s}@{s})\n", .{ @errorName(err), id, version });
        if (err == error.NoExtensionStore) {
            try printErr(io, "this machine has no home directory, so it has no extension store (set NULYA_HOME or HOME)\n");
        }
        return 1;
    };

    // Only a version actually IN EFFECT is announced to a live session, by
    // depositing a capability note into its inbox for the next step boundary.
    // A user-layer activate under a workspace pointer is not in effect.
    // Best-effort: a failed deposit never fails the activation the model just
    // performed.
    const effective = try view.site.activePointer(alloc, id);
    defer if (effective) |e| alloc.free(e.version);
    const covered_by: ?site_mod.Site.Pointer = blk: {
        const e = effective orelse break :blk null;
        if (e.layer == layer) break :blk null;
        break :blk e;
    };
    if (covered_by == null) depositSessionNote(alloc, io, view.site.store().?.root, id, version) catch {};

    try printOut(alloc, io, "{s}: current -> {s} ({s})\n", .{ id, version, layer.label() });
    if (covered_by) |c| {
        try printOut(alloc, io, "note: not in effect — the {s} pointer names {s}@{s}\n", .{ c.layer.label(), id, c.version });
    } else {
        try noteMembership(alloc, io, &view.site, id, version);
    }
    return 0;
}

/// One stderr line saying what activation did NOT do: a package reaches a
/// session only by being one of its members, so the way in is `[extensions]
/// with` or `session new --with`. Without it, installing a package by hand
/// leaves it out of every session with no sign that anything is missing.
///
/// The line spells the member with a tool selection when the version declares
/// `manual` tools, because those are exactly the ones membership alone does not
/// put on the model's face.
///
/// A NOTE and not a write: which packages a person's sessions carry is their
/// config, and no kernel verb edits that file.
fn noteMembership(
    alloc: std.mem.Allocator,
    io: std.Io,
    site: *const site_mod.Site,
    id: []const u8,
    version: []const u8,
) !void {
    // `.structural`: this reads what a version DECLARES. The bytes about to
    // run are checked where they run, and the activation just above verified
    // this version's seal.
    const resolved = site.resolveVersion(alloc, id, version, .structural) catch return;
    defer resolved.deinit(alloc);

    var spec: std.Io.Writer.Allocating = .init(alloc);
    defer spec.deinit();
    try spec.writer.writeAll(id);
    var manual: usize = 0;
    for (resolved.manifest.tools) |t| {
        if (t.surfaceOf() != .manual) continue;
        try spec.writer.print("{s}{s}", .{ if (manual == 0) ":" else ",", t.name });
        manual += 1;
    }
    try printErrFmt(
        alloc,
        io,
        "note: activation only says which version {s} means — no session composes it yet; add \"{s}\" to [extensions] with, or pass `nulya session new --with {s}`\n",
        .{ id, spec.written(), spec.written() },
    );
}

/// Say, on stderr, when a model running inside a session reaches OUT of that
/// session's workspace: a user-layer `current` means `<id>` is this version for
/// every workspace on this machine that has no pointer of its own. Not refused
/// — what is not allowed is doing it INVISIBLY. Silent for a workspace-layer
/// move, and silent when no session is running.
///
/// No manifest is read here: a package joins a session only when somebody names
/// it, so this move changes WHICH VERSION those sessions get and nothing about
/// who gets it.
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
        "note: activating {s}@{s} in the user layer from inside session {s}: {s} now means this version for every workspace on this machine\n",
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
    var view = try StoreView.open(alloc, io, cwd_path);
    defer view.deinit(alloc);
    const layer = (try common.deactivateLayer(alloc, &view.site, id, flags.user)) orelse {
        try printOut(alloc, io, "extension '{s}' has no active version here\n", .{id});
        return 1;
    };
    try view.site.deactivate(alloc, layer, id);
    try printOut(alloc, io, "{s}: deactivated ({s})\n", .{ id, layer.label() });

    // Dropping the workspace pointer can reveal the store's — say so, or "why
    // is it still in my session?" is the next question.
    if (try view.site.activePointer(alloc, id)) |still| {
        defer alloc.free(still.version);
        try printOut(alloc, io, "note: the {s} pointer names {s}@{s}, which is now in effect\n", .{ still.layer.label(), id, still.version });
    }
    return 0;
}

/// Every extension this machine holds, sorted by id. The second column is what
/// `current` points at — which version `<id>` means when somebody names it
/// without one — and the third is WHICH LAYER said so, `workspace` or `user`.
/// A directory with no pointer says `(no current)` and `-`, unless it holds no
/// built version either, in which case it is a bare writer lease or a draft
/// nobody has built and is skipped.
///
/// Two more markers answer "will a session have this?".
/// `[tools skills prompt]` is what the version CONTRIBUTES, from its frozen
/// manifest. `[with]` says this id is in the merged config's
/// `[extensions] with`.
///
/// Unreadable manifest -> no contribution marker, never a failed listing.
fn extList(alloc: std.mem.Allocator, io: std.Io) !u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var view = try StoreView.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer view.deinit(alloc);

    const active = try view.site.listActive(alloc);
    defer site_mod.Site.freeActive(alloc, active);

    var printed: usize = 0;
    for (active) |entry| {
        const contributes = try contributionMarker(alloc, &view.site, entry);
        defer alloc.free(contributes);
        printed += 1;
        try printOut(alloc, io, "{s}\t{s}\t{s}{s}{s}\n", .{
            entry.id,
            entry.version,
            entry.layer.label(),
            contributes,
            if (sliceHasString(view.with, entry.id)) "\t[with]" else "",
        });
    }

    // Ids the store holds versions for with no pointer anywhere: `--with
    // <id>@<version>` and `ext run <id>@<version>` still reach those, so a
    // listing that hid them would be lying about what is here. A directory with
    // no version at all is where `<id>/.lock` lives — a typo's leftovers, not
    // an extension.
    if (view.site.store()) |st| {
        var it = st.root.iterate();
        while (try it.next(io)) |dir_entry| {
            if (dir_entry.kind != .directory) continue;
            if (hasActiveId(active, dir_entry.name)) continue;
            const versions = st.listVersions(alloc, dir_entry.name) catch continue;
            defer {
                for (versions) |v| alloc.free(v);
                alloc.free(versions);
            }
            if (versions.len == 0) continue;
            printed += 1;
            try printOut(alloc, io, "{s}\t(no current)\t-{s}\n", .{
                dir_entry.name,
                if (sliceHasString(view.with, dir_entry.name)) "\t[with]" else "",
            });
        }
    }
    if (printed == 0) try printOut(alloc, io, "no extensions\n", .{});
    return 0;
}

/// `\t[tools skills prompt]` for what this frozen version contributes. Empty
/// string when the version contributes nothing nameable or cannot be read.
/// Caller owns the result.
fn contributionMarker(alloc: std.mem.Allocator, site: *const site_mod.Site, entry: site_mod.Site.ActiveEntry) ![]u8 {
    // `.structural`: this column reports what a version DECLARES. Re-digesting
    // every megabyte of built binary to print `[tools]` costs most of a second
    // in a store with a few compiled extensions, and a front end runs this
    // constantly. What is about to run is checked where it runs.
    const resolved = site.resolveEntry(alloc, entry, .structural) catch return alloc.dupe(u8, "");
    defer resolved.deinit(alloc);
    const m = resolved.manifest;
    if (m.tools.len == 0 and m.skills.len == 0 and m.system_prompts.len == 0) return alloc.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("\t[");
    var first = true;
    for ([_]struct { on: bool, word: []const u8 }{
        .{ .on = m.tools.len != 0, .word = "tools" },
        .{ .on = m.skills.len != 0, .word = "skills" },
        .{ .on = m.system_prompts.len != 0, .word = "prompt" },
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

fn hasActiveId(active: []const site_mod.Site.ActiveEntry, id: []const u8) bool {
    for (active) |e| {
        if (std.mem.eql(u8, e.id, id)) return true;
    }
    return false;
}

/// `<id>` prints the manifest of the version IN EFFECT, with NO draft
/// fallback. No active version is a named refusal.
/// `<id>@<version>` prints the FROZEN manifest of that exact built version —
/// the shape a session header records for every member, so a question ABOUT A
/// RUNNING SESSION reads the manifest that session composed with rather than
/// whatever `current` points at today.
/// `<path>` — a directory holding `extension.json` — prints THAT draft, unbuilt
/// and unfrozen: what `ext build` would freeze next, spelled the way
/// `ext build <path>` takes it.
/// A path never falls back to an id lookup, and an id never falls back to a
/// draft: the two questions are asked with different arguments, not
/// disambiguated by guessing.
fn extInspect(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya ext inspect <id>[@<version>] | <path>\n");
        return 1;
    }
    const arg = args[0];

    // Try it as a path first — a bare directory name (no separator) holding
    // `extension.json` counts too, as `ext build .` would take it. A real id
    // cannot collide: `manifest.isValidId` forbids a separator in an id.
    if (try draftManifestAtPath(alloc, io, arg)) |bytes| {
        defer alloc.free(bytes);
        try printOut(alloc, io, "{s}\n", .{bytes});
        return 0;
    }
    // A path with nothing readable at it is a mistyped path, not an id in
    // disguise: falling back to an id lookup would silently answer a different
    // question than the one asked.
    if (looksLikePathArg(arg)) {
        try printErrFmt(alloc, io, "ext inspect: no readable extension.json in '{s}'\n", .{arg});
        return 1;
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var view = try StoreView.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer view.deinit(alloc);
    const st = view.site.store();

    const ref = withRef(arg);
    if (ref.version) |v| {
        // A malformed version is simply a version this machine does not hold —
        // inspect is a projection, so it answers rather than faults.
        if (try frozenManifestBytes(alloc, io, st, ref.id, v)) |bytes| {
            defer alloc.free(bytes);
            try printOut(alloc, io, "{s}\n", .{bytes});
            return 0;
        }
        try printOut(alloc, io, "this machine does not hold {s}@{s}; see `nulya ext list`\n", .{ ref.id, v });
        return 1;
    }

    // Bare id: the version IN EFFECT, never a draft — the `<path>` form above
    // was tried and ruled out before we got here.
    if (try view.site.activePointer(alloc, ref.id)) |active| {
        defer alloc.free(active.version);
        if (try frozenManifestBytes(alloc, io, st, ref.id, active.version)) |bytes| {
            defer alloc.free(bytes);
            try printOut(alloc, io, "{s}\n", .{bytes});
            return 0;
        }
    }
    try printErrFmt(alloc, io, "no active version of '{s}'; see `nulya ext list`\n", .{ref.id});
    return 1;
}

/// The frozen `extension.json` of one built version, verbatim, or null when the
/// store does not hold it. Caller owns the bytes.
fn frozenManifestBytes(alloc: std.mem.Allocator, io: std.Io, st: ?store.Store, id: []const u8, version: []const u8) !?[]u8 {
    const s = st orelse return null;
    const manifest_rel = s.versionManifestPath(alloc, id, version) catch return null;
    defer alloc.free(manifest_rel);
    return s.root.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20)) catch null;
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

/// `nulya ext migrate [--dry-run]` — move version directories written under the
/// OLD layout into the one store, once.
///
/// The old layout kept `versions/` in every searched root: this workspace's
/// `.nulya/extensions/<id>/versions/`, and the user root
/// `<NULYA_HOME | ~/.nulya>/extensions/<id>/versions/`. Both move here, and
/// the two `current` files follow the layer they already meant: the user root's
/// becomes the store's, the workspace's stays where it is.
///
/// A version already in the store is left alone rather than overwritten —
/// content addressing says the bytes are the same, and the old copy is what is
/// removed. Idempotent: running it twice finds nothing the second time.
fn extMigrate(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var dry_run = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else {
            try printErr(io, "usage: nulya ext migrate [--dry-run]\n");
            return 1;
        }
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const store_path = try common.storePath(alloc);
    defer alloc.free(store_path);
    if (store_path.len == 0) {
        try printErr(io, "no home directory, so there is no store to migrate into (set NULYA_HOME or HOME)\n");
        return 1;
    }

    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    const home = (try launch.userHomeDir(alloc, &host)).?; // a store path implies a home
    defer alloc.free(home);
    const old_user_root = try std.fs.path.join(alloc, &.{ home, "extensions" });
    defer alloc.free(old_user_root);

    var dest = try store.openOrCreateRoot(io, cwd_path, store_path);
    defer dest.close(io);

    var moved: usize = 0;
    var pointers: usize = 0;
    // The user root first: its `current` files become the store's, so a
    // workspace pointer written afterwards still wins.
    moved += try migrateRoot(alloc, io, cwd_path, old_user_root, dest, dest, dry_run, &pointers);
    moved += try migrateRoot(alloc, io, cwd_path, site_mod.workspace_rel, dest, null, dry_run, &pointers);

    if (moved == 0 and pointers == 0) {
        try printOut(alloc, io, "nothing to migrate: no version directories outside {s}\n", .{store_path});
        return 0;
    }
    try printOut(alloc, io, "{d} version(s) {s} into {s}, {d} pointer(s) {s}\n", .{
        moved,
        if (dry_run) "would move" else "moved",
        store_path,
        pointers,
        if (dry_run) "would move" else "moved",
    });
    return 0;
}

/// Move every `<id>/versions/<v>` under `root_spec` into `dest`, and — when
/// `pointer_dest` is given — that root's `<id>/current` too. Returns how many
/// version directories were taken; `pointers` counts the pointers.
///
/// A rename is tried first and a copy is the fallback: the old user root and
/// the store are usually on one filesystem, and the workspace is usually not.
fn migrateRoot(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd_path: []const u8,
    root_spec: []const u8,
    dest: std.Io.Dir,
    pointer_dest: ?std.Io.Dir,
    dry_run: bool,
    pointers: *usize,
) !usize {
    var root = store.openRoot(io, cwd_path, root_spec) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        else => return err,
    };
    defer root.close(io);
    // The store itself is never its own donor: `ext migrate` inside the home
    // directory would otherwise try to move a tree onto itself.
    {
        var a_buf: [std.fs.max_path_bytes]u8 = undefined;
        var b_buf: [std.fs.max_path_bytes]u8 = undefined;
        const a = a_buf[0..try root.realPath(io, &a_buf)];
        const b = b_buf[0..try dest.realPath(io, &b_buf)];
        if (std.mem.eql(u8, a, b)) return 0;
    }

    var count: usize = 0;
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!manifest.isValidId(entry.name)) continue;
        const src_st = store.Store.init(io, root);
        const versions = src_st.listVersions(alloc, entry.name) catch continue;
        defer {
            for (versions) |v| alloc.free(v);
            alloc.free(versions);
        }
        for (versions) |v| {
            const rel = try std.fs.path.join(alloc, &.{ entry.name, "versions", v });
            defer alloc.free(rel);
            count += 1;
            try printOut(alloc, io, "{s}@{s}: {s} {s} -> the store\n", .{ entry.name, v, if (dry_run) "would move from" else "moved from", root_spec });
            if (dry_run) continue;
            if (dest.access(io, rel, .{})) |_| {
                // Same version id, therefore the same bytes: keep the store's.
                root.deleteTree(io, rel) catch {};
                continue;
            } else |_| {}
            try dest.createDirPath(io, std.fs.path.dirname(rel).?);
            if (root.rename(rel, dest, rel, io)) |_| continue else |_| {}
            try copyVersionTree(alloc, io, root, dest, rel);
            root.deleteTree(io, rel) catch {};
        }
        // The now-empty `versions/` goes with them; a draft beside it stays
        // exactly where it is.
        if (!dry_run) {
            const versions_rel = try std.fs.path.join(alloc, &.{ entry.name, "versions" });
            defer alloc.free(versions_rel);
            root.deleteDir(io, versions_rel) catch {};
        }
        const pd = pointer_dest orelse continue;
        const current = try src_st.activeVersion(alloc, entry.name) orelse continue;
        defer alloc.free(current);
        pointers.* += 1;
        try printOut(alloc, io, "{s}: current -> {s} moves to the store\n", .{ entry.name, current });
        if (dry_run) continue;
        try store.Store.init(io, pd).activate(alloc, entry.name, current);
        try src_st.deactivate(alloc, entry.name);
    }
    return count;
}

fn copyVersionTree(alloc: std.mem.Allocator, io: std.Io, src_root: std.Io.Dir, dest_root: std.Io.Dir, rel: []const u8) !void {
    var src = try src_root.openDir(io, rel, .{ .iterate = true });
    defer src.close(io);
    try dest_root.createDirPath(io, rel);
    var dest = try dest_root.openDir(io, rel, .{});
    defer dest.close(io);
    var walker = try src.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dest.createDirPath(io, entry.path),
        // Permissions come from the source, so a frozen binary stays executable.
        .file => try src.copyFile(entry.path, dest, entry.path, io, .{ .make_path = true }),
        else => {},
    };
}

/// `ext api` is a curated `nulya src`: the wire-protocol topic prints the REAL
/// `extension/protocol.zig`, so the ABI the model reads can never drift from
/// the code that implements it. `manifest` and `examples` stay short notes —
/// authority, the manifest's three tiers, and CLI usage.
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
            \\  does; `manual` = only when the member names this tool, `--with
            \\  <id>:<tool>`; `internal` = never on the model face, called
            \\  through `nulya ext run`) / `.timeout_ms` (this tool's own cap on a
            \\  MODEL-FACE call, default 30s, ceiling 600s);
            \\  `skills`; `system_prompts`, whose entries are a bare path or
            \\  `{"path": "<p>", "position": "early"|"normal"|"late"}` — `normal` is the
            \\  default, and the three words order this package's blocks against the
            \\  OTHER packages' only: the kernel's own block stays first, `session new
            \\  --prompt` text stays after every package's, and the skills catalog stays
            \\  last. Nothing says how the runtime is talked to,
            \\  because there is one way: stdin is the call's arguments as one compact
            \\  JSON object, NULYA_TOOL names the tool, stdout is the result taken
            \\  verbatim, and a non-zero exit is a failed call whose text is `exit <code>`
            \\  plus stderr — `nulya ext api protocol` is the whole contract.
            \\
            \\  ONE axis decides what a session carries, and a manifest sits beside it:
            \\  MEMBERSHIP. A member is `<id>[@<version>][:<tool>,<tool>…]`, written in
            \\  `[extensions] with` or passed as `session new --with`; the part after `:`
            \\  names the tools this session puts on the model's face beyond the
            \\  package's `surface: auto` default, `:none` puts nothing there at all, and
            \\  a tool the manifest does not declare (or declares `internal`) is refused.
            \\  Reach is never something a package takes: `nulya ext activate` only says
            \\  "which version `<id>` means". `nulya config show` prints the standing
            \\  list; `nulya ext list` marks an id that is on it `[with]`; `session new
            \\  --bare` reads none of it and composes from its own flags alone.
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
            \\  Built versions live in ONE place per machine,
            \\  <NULYA_HOME | ~/.nulya>/store/<id>/versions/<v>/, whoever built them. A
            \\  workspace holds drafts and, optionally, its own `current` pointer under
            \\  .nulya/extensions/<id>/ — never versions, so a checkout can carry source
            \\  and never bytes that would run. A workspace pointer wins over the store's;
            \\  with neither, the id is not activated here.
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
            \\                                                 # `surface: auto`, so the bare id is all it needs
            \\  nulya ext activate my.helper v-<older>        # going back is the same verb: a pointer move, never a rebuild
            \\
            \\  # A tool a person assembles by hand instead: write `"surface": "manual"` on
            \\  # it, and the bare id will not put it in front of a model — name it.
            \\  nulya session new --with my.helper:do_thing    # member + that tool on the face
            \\  nulya session new --with my.helper:none        # member, and nothing on the face
            \\
            \\  # A mode — a package a session wears. It reaches only the sessions that
            \\  # name it; activating it says which version `<id>` means and no more.
            \\  nulya ext build extensions/evolution          # prints v-<hash>
            \\  nulya ext activate evolution v-<hash>         # `evolution` now means this version
            \\  nulya session new --with evolution            # this session wears it, at `current`
            \\  nulya session new --with evolution@v-<hash>   # or name a build, activated or not
            \\
            \\  # A mode you want everywhere: put its id in `[extensions] with` — that list
            \\  # is every session's standing membership in this workspace.
            \\
            \\  # Every workspace on this machine: activate in the user layer.
            \\  nulya ext build extensions/guide
            \\  nulya ext activate --user guide v-<hash>
            \\
            \\  # A whole directory of drafts at once: put the source in <dir>/<id>/,
            \\  # then one verb. Either directory builds INTO the one store.
            \\  cp -r some.tool ~/.nulya/store/                # or .nulya/extensions/ for this workspace only
            \\  nulya ext sync --user --activate               # builds every draft beside the versions
            \\  nulya ext sync --dry-run                       # what it would do, touching nothing
            \\  nulya ext prune                                # drop versions no `current` here names; the draft
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
        error.InvalidSkillPath,        error.DuplicateSkillPath,
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
