const std = @import("std");

/// The package manifest, read at configure time so the binary's version string
/// has exactly one source (DESIGN §3.4: it is stamped into every session header).
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // DESIGN §10: the host Zig archive is @embedFile'd into the binary. Gated so
    // day-to-day `zig build test` stays light; the shipped binary and the e2e
    // build turn it on. `-Dzig-archive=<path>` points at a downloaded pinned
    // archive (windows `.zip`, else `.tar.xz`).
    const embed_toolchain = b.option(bool, "embed-toolchain", "Embed the host Zig toolchain into the binary (DESIGN §10)") orelse false;
    const zig_archive_path = b.option([]const u8, "zig-archive", "Path to the host Zig release archive to embed");
    const zig_archive = zigArchiveLazyPath(b, embed_toolchain, zig_archive_path);

    // `zig build test|e2e -Dtest-filter="…"` runs only tests whose NAME contains
    // the substring (repeatable; zig's own convention). Iterating on one failing
    // e2e case without it means paying the whole real-binary suite per attempt.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name contains the given substring (may be repeated)",
    ) orelse &.{};

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const toml = b.createModule(.{
        .root_source_file = b.path("vendor/zig-toml/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const config_options = b.addOptions();
    config_options.addOption([]const u8, "default_toml", @embedFile("default.toml"));
    config_options.addOption([]const u8, "version", zon.version);
    root.addImport("toml", toml);
    root.addOptions("config_options", config_options);
    root.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });

    // PLAN §3.10: the whole `src/**` tree is @embedFile'd so the running binary
    // can print its own real source (`nulya src`) with zero API drift. Source is
    // ~200KB next to the ~90MB toolchain, so this is always on (no gate).
    root.addAnonymousImport("src_embed", .{ .root_source_file = srcEmbedIndex(b) });

    // DESIGN §7.8: the repo's own `extensions/**` drafts ride along the same way
    // (~500KB), so `nulya ext seed` can write them into a store root on a machine
    // that never saw this checkout — distribution is the binary alone.
    root.addAnonymousImport("ext_embed", .{ .root_source_file = extEmbedIndex(b) });

    const exe = b.addExecutable(.{
        .name = "nulya",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // `demo` rather than nothing: a bare `nulya` prints its usage now, and this
    // step's job is the smoke test — one real session, end to end. Arguments
    // given on the command line replace it (`zig build run -- session list`).
    if (b.args) |args| run_cmd.addArgs(args) else run_cmd.addArg("demo");
    const run_step = b.step("run", "Run the built-in demo session (or `-- <args>`)");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root, .filters = test_filters });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setEnvironmentVariable("NULYA_TEST_ZIG", b.graph.zig_exe);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // The bundled `std` extension is the one shipped package with pure logic
    // worth unit-testing (glob / gitignore matching, freshness, output shaping,
    // a vendored regex engine). Its tests ride the same `test` step; `nulya ext
    // build` compiles the very same sources with `zig build-exe`, which ignores
    // test blocks, so the version id is unaffected.
    const std_ext_mod = b.createModule(.{
        .root_source_file = b.path("extensions/std/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const std_ext_tests = b.addTest(.{ .root_module = std_ext_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(std_ext_tests).step);

    // The bundled `agent` package's definition reader: the front matter dialect,
    // the three-layer search and its shadowing, and the personas this package
    // ships (`extensions/agent/src/defs.zig`). It is the ONE reader of that
    // format — the front end asks it rather than parsing — so it is the one
    // place those answers can be pinned down.
    const agent_ext_mod = b.createModule(.{
        .root_source_file = b.path("extensions/agent/src/defs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_ext_tests = b.addTest(.{ .root_module = agent_ext_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(agent_ext_tests).step);

    // …and that package's delegation journal (`record.zig`): the id shape, the
    // append-only rows the exchange budget is counted from, and the runner lease
    // the wake invariant is built on (contract D4). Its own root because nothing
    // the definition reader does reaches it — a test only runs where the file it
    // lives in is analysed.
    const agent_record_mod = b.createModule(.{
        .root_source_file = b.path("extensions/agent/src/record.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_record_tests = b.addTest(.{ .root_module = agent_record_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(agent_record_tests).step);

    // …and the queue that journal sits beside (`mailbox.zig`): the publish
    // order, the cursor a round offers messages by, and the at-least-once
    // acknowledgement. Its own root for the reason above — `record.zig` does not
    // import it, the traffic goes the other way.
    const agent_mailbox_mod = b.createModule(.{
        .root_source_file = b.path("extensions/agent/src/mailbox.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_mailbox_tests = b.addTest(.{ .root_module = agent_mailbox_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(agent_mailbox_tests).step);

    // …and the arm that lets a runner live OUTSIDE this package
    // (`external.zig`): which frozen version a delegation is nailed to, read off
    // the kernel's own listing. Its own root for the reason above.
    const agent_external_mod = b.createModule(.{
        .root_source_file = b.path("extensions/agent/src/external.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_external_tests = b.addTest(.{ .root_module = agent_external_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(agent_external_tests).step);

    // …and the `ground` package, whose whole job is shaping text: the two-level
    // map's per-directory budget and the cut that must not split a character.
    // Rooted at its `main.zig`, which imports the three modules that do the
    // work — none of them imports another, so one root reaches them all.
    const ground_ext_mod = b.createModule(.{
        .root_source_file = b.path("extensions/ground/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ground_ext_tests = b.addTest(.{ .root_module = ground_ext_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(ground_ext_tests).step);

    // End-to-end closed-loop test (DESIGN §16 milestone): init -> build -> run.
    // It uses the host's own zig (no embed needed) via NULYA_TEST_ZIG, so it
    // actually compiles and runs a real extension. Everything reachable from a
    // group root lives in the single `support` facade module rooted under src/,
    // so no file straddles two module graphs (Zig 0.16 forbids that); the
    // facade's own anonymous `zig_archive` import covers build/toolchain.zig's
    // @embedFile.
    const e2e_support_mod = b.createModule(.{ .root_source_file = b.path("src/e2e_support.zig"), .target = target, .optimize = optimize });
    e2e_support_mod.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });
    // The facade re-exports config.zig, which reads the baked-in default.toml.
    e2e_support_mod.addImport("toml", toml);
    e2e_support_mod.addOptions("config_options", config_options);

    // A `codex app-server` that answers the protocol offline (`tests/fake_codex.zig`).
    // The Codex runner is a JSON-RPC conversation, and everything worth pinning
    // down about it is on THIS side of that conversation — so the e2e suite
    // points `NULYA_CODEX_EXE` at this instead of at a real Codex, and stays
    // offline. Built like the binary under test and handed over the same way.
    const fake_codex = b.addExecutable(.{
        .name = "fake-codex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fake_codex.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Into a directory of its own, and only when a step asks for it: it is a
    // test fixture, not something this project ships.
    const install_fake_codex = b.addInstallArtifact(fake_codex, .{
        .dest_dir = .{ .override = .{ .custom = "test-bin" } },
    });
    // …and the same for Claude Code (`tests/fake_claude.zig`), handed over as
    // `NULYA_CLAUDE_EXE`. Offline for the reasons the Codex one is, and for one
    // more: `claude` is the harness this repository is developed in, so an e2e
    // that spawned a real one would be spending somebody's tokens on a fixture.
    const fake_claude = b.addExecutable(.{
        .name = "fake-claude",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fake_claude.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_fake_claude = b.addInstallArtifact(fake_claude, .{
        .dest_dir = .{ .override = .{ .custom = "test-bin" } },
    });
    // …and for pi (`tests/fake_pi.zig`), handed over as `NULYA_PI_EXE`.
    const fake_pi = b.addExecutable(.{
        .name = "fake-pi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fake_pi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_fake_pi = b.addInstallArtifact(fake_pi, .{
        .dest_dir = .{ .override = .{ .custom = "test-bin" } },
    });

    // The suite is FOUR test binaries, not one: `zig build` runs independent run
    // artifacts concurrently, and one binary is one core. The split is by what a
    // group proves — `e2e-ext` the extension lifecycle, `e2e-core` the kernel
    // session surface, `e2e-agent` delegation, `e2e-std` the bundled file/search
    // package — and the four happen to be within a factor of two of each other
    // in cost, so the wall clock is roughly the largest rather than the sum.
    // `zig build e2e` depends on all four, so it is still the whole thing, and
    // `-Dtest-filter` reaches every group.
    //
    // What the four share on disk is the compile-once cache under
    // `.zig-cache/nulya-e2e-prebuilt` (tests/e2e/support.zig). Concurrent
    // writers there are serialized by the store's own `<id>/.lock`, the same
    // exclusive lease two `nulya ext build` processes take (DESIGN §7.4), so
    // the group that gets there second waits and then finds the version built.
    const e2e_step = b.step("e2e", "Run the whole end-to-end suite (ext + core + agent + std)");
    const e2e_groups = [_]struct {
        step: []const u8,
        root: []const u8,
        desc: []const u8,
        /// The offline stand-ins for Codex / Claude / pi. Only the delegation
        /// group speaks to them, and a group that does not should not have to
        /// build them before it can start.
        fakes: bool = false,
    }{
        .{
            .step = "e2e-ext",
            .root = "tests/e2e_ext.zig",
            .desc = "Run the end-to-end extension lifecycle: build, store roots, the wire, self-manufacture",
        },
        .{
            .step = "e2e-core",
            .root = "tests/e2e_core.zig",
            .desc = "Run the end-to-end kernel surface: the durable ledger, `session *`, the gate, background tasks",
        },
        .{
            .step = "e2e-agent",
            .root = "tests/e2e_agent.zig",
            .desc = "Run the end-to-end delegation tests (the bundled `agent` package and its runners)",
            .fakes = true,
        },
        .{
            .step = "e2e-std",
            .root = "tests/e2e_std.zig",
            .desc = "Run the end-to-end tests for the bundled `std` extension",
        },
    };
    for (e2e_groups) |group| {
        const mod = b.createModule(.{
            .root_source_file = b.path(group.root),
            .target = target,
            .optimize = optimize,
        });
        mod.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });
        mod.addImport("support", e2e_support_mod);
        const group_tests = b.addTest(.{ .root_module = mod, .filters = test_filters });
        const run_group = b.addRunArtifact(group_tests);
        run_group.setEnvironmentVariable("NULYA_TEST_ZIG", b.graph.zig_exe);
        // The CLI tests spawn the real `nulya` binary (the runner's own stdout
        // is the test protocol, so an in-process `cli.dispatch` would corrupt
        // it). Point at the installed binary, relative to where `zig build` was
        // run.
        run_group.step.dependOn(b.getInstallStep());
        run_group.setEnvironmentVariable("NULYA_EXE", b.getInstallPath(.bin, exe.out_filename));
        // The repo root, so a test can build the extensions this repo ships
        // (`extensions/evolution`) from their real source rather than a copy.
        run_group.setEnvironmentVariable("NULYA_REPO", b.build_root.path orelse ".");
        if (group.fakes) {
            run_group.step.dependOn(&install_fake_codex.step);
            run_group.setEnvironmentVariable(
                "NULYA_FAKE_CODEX",
                b.getInstallPath(.{ .custom = "test-bin" }, fake_codex.out_filename),
            );
            run_group.step.dependOn(&install_fake_claude.step);
            run_group.setEnvironmentVariable(
                "NULYA_FAKE_CLAUDE",
                b.getInstallPath(.{ .custom = "test-bin" }, fake_claude.out_filename),
            );
            run_group.step.dependOn(&install_fake_pi.step);
            run_group.setEnvironmentVariable(
                "NULYA_FAKE_PI",
                b.getInstallPath(.{ .custom = "test-bin" }, fake_pi.out_filename),
            );
        }
        run_group.has_side_effects = true; // exercises the filesystem; always run
        b.step(group.step, group.desc).dependOn(&run_group.step);
        e2e_step.dependOn(&run_group.step);
    }

    // Live-provider checks (PLAN §1 M4 acceptance). Kept out of `test` / `e2e`,
    // which stay offline: this one talks to a real endpoint and skips itself
    // unless NULYA_INTEGRATION_PROFILE names a profile with a usable credential.
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("support", e2e_support_mod);
    const integration_tests = b.addTest(.{ .root_module = integration_mod, .filters = test_filters });
    const run_integration = b.addRunArtifact(integration_tests);
    run_integration.has_side_effects = true; // network; never cached
    const integration_step = b.step("integration", "Run live-provider integration tests (needs NULYA_INTEGRATION_PROFILE)");
    integration_step.dependOn(&run_integration.step);
}

/// Generate the `src_embed` index module: a WriteFiles tree holding a copy of
/// every `src/**/*.zig` file plus an `index.zig` that `@embedFile`s each one.
/// `nulya src` reads the exact bytes the binary was built from (PLAN §3.10).
fn srcEmbedIndex(b: *std.Build) std.Build.LazyPath {
    return embedIndex(b, "src", true, "//! GENERATED by build.zig — the embedded src/** self-view (PLAN §3.10).\n");
}

/// The same move for the repo's bundled extension drafts: every file under
/// `extensions/**` (manifests, sources, skills — not just .zig), so `nulya ext
/// seed` can materialize the drafts anywhere (DESIGN §7.8).
fn extEmbedIndex(b: *std.Build) std.Build.LazyPath {
    return embedIndex(b, "extensions", false, "//! GENERATED by build.zig — the embedded extensions/** drafts (DESIGN §7.8).\n");
}

/// Walk `dir_name` at configure time and emit an `index.zig` that `@embedFile`s
/// each file. `zig_only` keeps the source self-view down to what `nulya src` can
/// print; the drafts embed takes every regular file. Hidden components (a stray
/// `.zig-cache`, editor droppings) are skipped in both.
fn embedIndex(b: *std.Build, dir_name: []const u8, zig_only: bool, header: []const u8) std.Build.LazyPath {
    const wf = b.addWriteFiles();

    // Collect paths at configure time; walker reuses its path buffer, so each
    // relative path is duped (and slash-normalized) immediately.
    const io = b.graph.io;
    var paths: std.ArrayList([]const u8) = .empty;
    var dir = b.build_root.handle.openDir(io, dir_name, .{ .iterate = true }) catch @panic(b.fmt("nulya build: cannot open {s}/", .{dir_name}));
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch @panic("nulya build: walk failed")) |entry| {
        if (entry.kind != .file) continue;
        if (zig_only and !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const rel = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
        for (rel) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        if (hasHiddenComponent(rel)) continue;
        paths.append(b.allocator, rel) catch @panic("OOM");
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanStr);

    var idx: std.ArrayList(u8) = .empty;
    idx.appendSlice(b.allocator, header) catch @panic("OOM");
    idx.appendSlice(b.allocator, "pub const Entry = struct { path: []const u8, bytes: []const u8 };\n") catch @panic("OOM");
    idx.appendSlice(b.allocator, "pub const files = [_]Entry{\n") catch @panic("OOM");
    for (paths.items) |rel| {
        _ = wf.addCopyFile(b.path(b.fmt("{s}/{s}", .{ dir_name, rel })), rel);
        idx.appendSlice(b.allocator, b.fmt("    .{{ .path = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ rel, rel })) catch @panic("OOM");
    }
    idx.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    return wf.add("index.zig", idx.items);
}

fn hasHiddenComponent(rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len > 0 and part[0] == '.') return true;
    }
    return false;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The file `@embedFile("zig_archive")` resolves to. When embedding is off (or no
/// path was given) this is an empty stub, and `toolchain.ensureExtracted`
/// reports `error.ToolchainNotEmbedded`.
fn zigArchiveLazyPath(b: *std.Build, embed: bool, path: ?[]const u8) std.Build.LazyPath {
    if (embed) {
        if (path) |p| return .{ .cwd_relative = p };
        std.debug.print("warning: -Dembed-toolchain set without -Dzig-archive; embedding empty stub\n", .{});
    }
    const wf = b.addWriteFiles();
    return wf.add("zig_archive_stub", "");
}
