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

    const tests = b.addTest(.{ .root_module = root });
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
    const std_ext_tests = b.addTest(.{ .root_module = std_ext_mod });
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
    const agent_ext_tests = b.addTest(.{ .root_module = agent_ext_mod });
    test_step.dependOn(&b.addRunArtifact(agent_ext_tests).step);

    // End-to-end closed-loop test (DESIGN §16 milestone): init -> build -> run.
    // It uses the host's own zig (no embed needed) via NULYA_TEST_ZIG, so it
    // actually compiles and runs a real extension. Everything reachable from
    // e2e.zig lives in the single `support` facade module rooted under src/, so
    // no file straddles two module graphs (Zig 0.16 forbids that); the facade's
    // own anonymous `zig_archive` import covers build/toolchain.zig's @embedFile.
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });
    const e2e_support_mod = b.createModule(.{ .root_source_file = b.path("src/e2e_support.zig"), .target = target, .optimize = optimize });
    e2e_support_mod.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });
    // The facade re-exports config.zig, which reads the baked-in default.toml.
    e2e_support_mod.addImport("toml", toml);
    e2e_support_mod.addOptions("config_options", config_options);
    e2e_mod.addImport("support", e2e_support_mod);
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e = b.addRunArtifact(e2e_tests);
    run_e2e.setEnvironmentVariable("NULYA_TEST_ZIG", b.graph.zig_exe);
    // The CLI tests spawn the real `nulya` binary (the runner's own stdout is
    // the test protocol, so an in-process `cli.dispatch` would corrupt it).
    // Point at the installed binary, relative to where `zig build` was run.
    run_e2e.step.dependOn(b.getInstallStep());
    run_e2e.setEnvironmentVariable("NULYA_EXE", b.getInstallPath(.bin, exe.out_filename));
    // The repo root, so a test can build the extensions this repo ships
    // (`extensions/evolution`) from their real source rather than a copy.
    run_e2e.setEnvironmentVariable("NULYA_REPO", b.build_root.path orelse ".");
    run_e2e.has_side_effects = true; // exercises the filesystem; always run
    const e2e_step = b.step("e2e", "Run the extension closed-loop end-to-end test");
    e2e_step.dependOn(&run_e2e.step);

    // Live-provider checks (PLAN §1 M4 acceptance). Kept out of `test` / `e2e`,
    // which stay offline: this one talks to a real endpoint and skips itself
    // unless NULYA_INTEGRATION_PROFILE names a profile with a usable credential.
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("support", e2e_support_mod);
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
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
