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
    // actually compiles and runs a real extension.
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });
    const e2e_env_mod = b.createModule(.{ .root_source_file = b.path("src/environment.zig"), .target = target, .optimize = optimize });
    const e2e_extension_mod = b.createModule(.{ .root_source_file = b.path("src/extension.zig"), .target = target, .optimize = optimize });
    e2e_extension_mod.addAnonymousImport("zig_archive", .{ .root_source_file = zig_archive });
    e2e_mod.addImport("environment", e2e_env_mod);
    e2e_mod.addImport("extension", e2e_extension_mod);
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e = b.addRunArtifact(e2e_tests);
    run_e2e.setEnvironmentVariable("NULYA_TEST_ZIG", b.graph.zig_exe);
    run_e2e.has_side_effects = true; // exercises the filesystem; always run
    const e2e_step = b.step("e2e", "Run the extension closed-loop end-to-end test");
    e2e_step.dependOn(&run_e2e.step);
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
