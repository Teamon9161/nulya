const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
