//! Replace a release-installed nulya with the newest GitHub Release binary.
//! The staged executable is verified before the installed file is touched.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const version = @import("config_options").version;

const repository = "Teamon9161/nulya";
const api_url = "https://api.github.com/repos/" ++ repository ++ "/releases/latest";

pub fn dispatchUpdate(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len != 0) {
        try common.printErr(io, "usage: nulya update\n");
        return 1;
    }
    update(alloc, io) catch |err| {
        try common.printErrFmt(alloc, io, "update failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn update(alloc: std.mem.Allocator, io: std.Io) !void {
    const asset = releaseAsset() orelse return error.UnsupportedPlatform;
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const metadata = try downloadText(alloc, &client, api_url);
    defer alloc.free(metadata);
    const Release = struct { tag_name: []const u8 };
    const parsed = try std.json.parseFromSlice(Release, alloc, metadata, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const tag = parsed.value.tag_name;
    if (tag.len < 2 or tag[0] != 'v') return error.InvalidReleaseTag;
    const latest = tag[1..];
    switch (try compareVersions(latest, version)) {
        .eq => {
            try common.printOut(alloc, io, "nulya {s} is already up to date\n", .{version});
            return;
        },
        .lt => {
            try common.printOut(alloc, io, "nulya {s} is newer than the latest release ({s})\n", .{ version, latest });
            return;
        },
        .gt => {},
    }

    const base = try std.fmt.allocPrint(alloc, "https://github.com/{s}/releases/download/{s}", .{ repository, tag });
    defer alloc.free(base);
    const executable = try std.process.executablePathAlloc(io, alloc);
    defer alloc.free(executable);
    var nonce: [8]u8 = undefined;
    try io.randomSecure(&nonce);
    const staged = try std.fmt.allocPrint(alloc, "{s}.{x}.new", .{ executable, nonce });
    defer alloc.free(staged);
    errdefer std.Io.Dir.deleteFileAbsolute(io, staged) catch {};
    const checksum_url = try std.fmt.allocPrint(alloc, "{s}/checksums.txt", .{base});
    defer alloc.free(checksum_url);
    const checksums = try downloadText(alloc, &client, checksum_url);
    defer alloc.free(checksums);
    const expected = checksumFor(checksums, asset) orelse return error.ChecksumMissing;
    const asset_url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, asset });
    defer alloc.free(asset_url);

    try common.printOut(alloc, io, "Downloading nulya {s} ({s})...\n", .{ latest, asset });
    try downloadFile(&client, io, asset_url, staged);
    const actual = try sha256File(io, staged);
    if (!std.ascii.eqlIgnoreCase(actual[0..], expected)) return error.ChecksumMismatch;

    if (builtin.os.tag == .windows) {
        try scheduleWindowsReplacement(alloc, io, staged, executable);
        try common.printOut(alloc, io, "Verified nulya {s}; it will replace this executable after nulya exits.\n", .{latest});
    } else {
        var file = try std.Io.Dir.openFileAbsolute(io, staged, .{});
        defer file.close(io);
        try file.setPermissions(io, @enumFromInt(0o755));
        try std.Io.Dir.renameAbsolute(staged, executable, io);
        try common.printOut(alloc, io, "Updated nulya to {s}. Restart it to use the new version.\n", .{latest});
    }
}

fn releaseAsset() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "nulya-x86_64-linux",
            .aarch64 => "nulya-aarch64-linux",
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "nulya-x86_64-macos",
            .aarch64 => "nulya-aarch64-macos",
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "nulya-x86_64-windows.exe",
            .aarch64 => "nulya-aarch64-windows.exe",
            else => null,
        },
        else => null,
    };
}

const Order = enum { lt, eq, gt };

fn compareVersions(left: []const u8, right: []const u8) !Order {
    var a = std.mem.splitScalar(u8, left, '.');
    var b = std.mem.splitScalar(u8, right, '.');
    var left_numbers: [3]u32 = undefined;
    var right_numbers: [3]u32 = undefined;
    for (0..3) |i| {
        left_numbers[i] = std.fmt.parseInt(u32, a.next() orelse return error.InvalidReleaseTag, 10) catch return error.InvalidReleaseTag;
        right_numbers[i] = std.fmt.parseInt(u32, b.next() orelse return error.InvalidCurrentVersion, 10) catch return error.InvalidCurrentVersion;
    }
    if (a.next() != null or b.next() != null) return error.InvalidReleaseTag;
    for (left_numbers, right_numbers) |x, y| {
        if (x < y) return .lt;
        if (x > y) return .gt;
    }
    return .eq;
}

fn checksumFor(list: []const u8, asset: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| {
        if (line.len < 66) continue;
        const hash = line[0..64];
        var valid = true;
        for (hash) |c| {
            if (!std.ascii.isHex(c)) valid = false;
        }
        if (!valid) continue;
        const name = std.mem.trim(u8, line[64..], " \t\r*");
        if (std.mem.eql(u8, name, asset)) return hash;
    }
    return null;
}

fn downloadText(alloc: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = "nulya/" ++ version } },
    });
    if (result.status.class() != .success) return error.ReleaseHttpError;
    if (body.written().len > 1024 * 1024) return error.ReleaseMetadataTooLarge;
    return try alloc.dupe(u8, body.written());
}

fn downloadFile(client: *std.http.Client, io: std.Io, url: []const u8, path: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
        .headers = .{ .user_agent = .{ .override = "nulya/" ++ version } },
    });
    if (result.status.class() != .success) return error.ReleaseHttpError;
    try writer.interface.flush();
    try file.sync(io);
}

fn sha256File(io: std.Io, path: []const u8) ![64]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var remaining = (try file.stat(io)).size;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (remaining != 0) {
        const n: usize = @intCast(@min(remaining, chunk.len));
        try reader.interface.readSliceAll(chunk[0..n]);
        hasher.update(chunk[0..n]);
        remaining -= n;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn scheduleWindowsReplacement(alloc: std.mem.Allocator, io: std.Io, staged: []const u8, executable: []const u8) !void {
    if (builtin.os.tag != .windows) unreachable;
    const script_path = try std.fmt.allocPrint(alloc, "{s}.update.ps1", .{staged});
    defer alloc.free(script_path);
    const script =
        \\param([string]$Staged, [string]$Destination, [int]$ParentPid)
        \\$ErrorActionPreference = 'Stop'
        \\try { Wait-Process -Id $ParentPid -ErrorAction SilentlyContinue } catch {}
        \\$done = $false
        \\for ($i = 0; $i -lt 120; $i++) {
        \\  try { Move-Item -LiteralPath $Staged -Destination $Destination -Force -ErrorAction Stop; $done = $true; break }
        \\  catch { Start-Sleep -Milliseconds 500 }
        \\}
        \\if ($done) { Remove-Item -LiteralPath $PSCommandPath -Force }
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    errdefer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};
    const pid = try std.fmt.allocPrint(alloc, "{d}", .{std.os.windows.GetCurrentProcessId()});
    defer alloc.free(pid);
    _ = try std.process.spawn(io, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", script_path, "-Staged", staged, "-Destination", executable, "-ParentPid", pid },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
}

test "release checksums match only the named asset" {
    const list = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  nulya-x86_64-linux\n" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *nulya-x86_64-windows.exe\n";
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", checksumFor(list, "nulya-x86_64-windows.exe").?);
    try std.testing.expect(checksumFor(list, "nulya-aarch64-linux") == null);
}

test "update compares numeric release versions" {
    try std.testing.expectEqual(Order.gt, try compareVersions("0.10.0", "0.9.9"));
    try std.testing.expectEqual(Order.eq, try compareVersions("0.1.0", "0.1.0"));
    try std.testing.expectEqual(Order.lt, try compareVersions("0.1.0", "0.2.0"));
    try std.testing.expectError(error.InvalidReleaseTag, compareVersions("1.0.0-rc1", "0.1.0"));
}

test "update hashes an executable larger than one read buffer" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try alloc.alloc(u8, 128 * 1024 + 7);
    defer alloc.free(bytes);
    @memset(bytes, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "nulya", .data = bytes });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fs.path.join(alloc, &.{ path_buf[0..dir_len], "nulya" });
    defer alloc.free(path);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    const actual = try sha256File(io, path);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
