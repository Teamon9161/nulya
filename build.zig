const std = @import("std");

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
    root.addImport("toml", toml);
    root.addOptions("config_options", config_options);
    root.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });

    // PLAN §3.10: the whole `src/**` tree is @embedFile'd so the running binary
    // can print its own real source (`nulya src`) with zero API drift. Source is
    // ~200KB next to the ~90MB toolchain, so this is always on (no gate).
    root.addAnonymousImport("src_embed", .{ .root_source_file = srcEmbedIndex(b) });

    const exe = b.addExecutable(.{
        .name = "nulya",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run nulya");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setEnvironmentVariable("NULYA_TEST_ZIG", b.graph.zig_exe);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // End-to-end closed-loop test (DESIGN §16 milestone): init -> build -> run.
    // It uses the host's own zig (no embed needed) via NULYA_TEST_ZIG, so it
    // actually compiles and runs a real extension. Everything reachable from
    // e2e.zig lives in the single `support` facade module rooted under src/, so
    // no file straddles two module graphs (Zig 0.16 forbids that); the facade's
    // own anonymous `zig_archive` import covers toolchain.zig's @embedFile.
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });
    const e2e_support_mod = b.createModule(.{ .root_source_file = b.path("src/e2e_support.zig"), .target = target, .optimize = optimize });
    e2e_support_mod.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });
    e2e_mod.addImport("support", e2e_support_mod);
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e = b.addRunArtifact(e2e_tests);
    run_e2e.setEnvironmentVariable("NULYA_TEST_ZIG", b.graph.zig_exe);
    // The CLI tests spawn the real `nulya` binary (the runner's own stdout is
    // the test protocol, so an in-process `cli.dispatch` would corrupt it).
    // Point at the installed binary, relative to where `zig build` was run.
    run_e2e.step.dependOn(b.getInstallStep());
    run_e2e.setEnvironmentVariable("NULYA_EXE", b.getInstallPath(.bin, exe.out_filename));
    run_e2e.has_side_effects = true; // exercises the filesystem; always run
    const e2e_step = b.step("e2e", "Run the extension closed-loop end-to-end test");
    e2e_step.dependOn(&run_e2e.step);
}

/// Generate the `src_embed` index module: a WriteFiles tree holding a copy of
/// every `src/**/*.zig` file plus an `index.zig` that `@embedFile`s each one.
/// `nulya src` reads the exact bytes the binary was built from (PLAN §3.10).
fn srcEmbedIndex(b: *std.Build) std.Build.LazyPath {
    const wf = b.addWriteFiles();

    // Collect every .zig under src/ at configure time; walker reuses its path
    // buffer, so each relative path is duped (and slash-normalized) immediately.
    const io = b.graph.io;
    var paths: std.ArrayList([]const u8) = .empty;
    var dir = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch @panic("nulya build: cannot open src/");
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch @panic("nulya build: walk src/ failed")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const rel = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
        for (rel) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        paths.append(b.allocator, rel) catch @panic("OOM");
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanStr);

    var idx: std.ArrayList(u8) = .empty;
    idx.appendSlice(b.allocator, "//! GENERATED by build.zig — the embedded src/** self-view (PLAN §3.10).\n") catch @panic("OOM");
    idx.appendSlice(b.allocator, "pub const Entry = struct { path: []const u8, bytes: []const u8 };\n") catch @panic("OOM");
    idx.appendSlice(b.allocator, "pub const files = [_]Entry{\n") catch @panic("OOM");
    for (paths.items) |rel| {
        _ = wf.addCopyFile(b.path(b.fmt("src/{s}", .{rel})), rel);
        idx.appendSlice(b.allocator, b.fmt("    .{{ .path = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ rel, rel })) catch @panic("OOM");
    }
    idx.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    return wf.add("index.zig", idx.items);
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
