//! End-to-end proof of the milestone (DESIGN §16): "Nulya v0.1 ships two tools.
//! The third is created by Nulya itself."
//!
//! This scaffolds a real extension, builds it with the HOST's zig (injected via
//! NULYA_TEST_ZIG by build.zig so the ~90MB embed is not needed), activates the
//! immutable version, then invokes it through the same Environment seam a live
//! agent would use — and checks the wire response round-trips. Run with
//! `zig build e2e`.

const std = @import("std");
const environment = @import("environment");
const extension = @import("extension");

const build_ext = extension.build_ext;
const protocol = extension.protocol;
const store = extension.store;
const templates = extension.templates;

const ext_dir_rel = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "demo";

test "closed loop: init -> build -> activate -> run round-trips JSON" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // 1. `ext init`: scaffold a real, buildable extension.
    try ws.createDirPath(io, ext_dir_rel ++ std.fs.path.sep_str ++ "src");
    const manifest_bytes = try templates.manifestJson(alloc, "demo", "greet");
    defer alloc.free(manifest_bytes);
    try ws.writeFile(io, .{ .sub_path = ext_dir_rel ++ std.fs.path.sep_str ++ "extension.json", .data = manifest_bytes });
    try ws.writeFile(io, .{ .sub_path = ext_dir_rel ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "main.zig", .data = templates.main_zig });

    // 2. `ext build`: compile into an immutable, content-addressed version.
    var result = try build_ext.buildExtension(alloc, io, ws, ext_dir_rel, zig_exe);
    defer result.deinit(alloc);
    if (!result.compile_ok) {
        std.debug.print("extension failed to compile:\n{s}\n", .{result.stderr});
        return error.ExtensionBuildFailed;
    }
    try std.testing.expect(std.mem.startsWith(u8, result.version, "v-"));

    // Building again is a reproducible no-op on the same version.
    var again = try build_ext.buildExtension(alloc, io, ws, ext_dir_rel, zig_exe);
    defer again.deinit(alloc);
    try std.testing.expect(again.already_built);
    try std.testing.expectEqualStrings(result.version, again.version);

    // 3. `ext activate`: point `current` at the built version.
    var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer ext_root.close(io);
    const st = store.Store.init(io, ext_root);
    try st.activate(alloc, "demo", result.version);
    {
        const active = (try st.activeVersion(alloc, "demo")).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings(result.version, active);
    }

    // 4. `ext run`: invoke the built binary through the Environment seam and
    //    decode the wire response — the same path a live agent uses.
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_real_len = try ws.realPath(io, &ws_real);
    const ws_path = ws_real[0..ws_real_len];

    try std.testing.expect(result.entry_rel != null);
    const entry_abs = try std.fs.path.join(alloc, &.{ ws_path, ext_dir_rel, "versions", result.version, result.entry_rel.? });
    defer alloc.free(entry_abs);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const req: protocol.ToolCallRequest = .{ .id = "call-1", .name = "greet", .arguments_json = "{}" };
    const request_json = try req.encode(alloc);
    defer alloc.free(request_json);

    const outcome = try lenv.environment().runExtension(alloc, .{
        .entry_path = entry_abs,
        .cwd = ws_path,
        .request_json = request_json,
        .max_output_bytes = 1 << 20,
    });
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), outcome.exit_code);

    const decoded = try protocol.decodeResponse(alloc, req.id, outcome.stdout);
    defer decoded.deinit(alloc);
    try std.testing.expect(decoded.ok);
    try std.testing.expect(std.mem.indexOf(u8, decoded.value_json, "greeting") != null);
}
