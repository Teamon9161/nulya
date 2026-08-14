//! Execution Environment boundary (DESIGN §8, §9).
//!
//! shell/extension execution goes through an `Environment`, never a raw process
//! spawn. This is the single seam that:
//!   1. picks the shell dialect (bash | powershell) — DESIGN §6.1;
//!   2. sanitizes the child environment so host secrets (API keys, SSH agent,
//!      cloud creds) never reach an AI-authored subprocess — DESIGN §9;
//!   3. later swaps `local` execution for sandbox/remote/acp without touching a
//!      single line of tool code — DESIGN §8.
//!
//! v0.1 ships only the `local` backend. The interface is in place so new
//! backends are drop-in; `authority` stays coupled to the environment (shell and
//! extension share one `session_authority` in v0.1, DESIGN §9).

const std = @import("std");
const builtin = @import("builtin");

pub const Dialect = enum {
    bash,
    powershell,

    pub fn label(self: Dialect) []const u8 {
        return switch (self) {
            .bash => "bash",
            .powershell => "powershell",
        };
    }
};

/// A completed shell run. `stdout`/`stderr` are owned by the caller's allocator.
pub const ShellOutcome = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: ShellOutcome, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

pub const ShellRequest = struct {
    command: []const u8,
    cwd: []const u8,
    /// Runner-level capture cap; the `emit` budget does the model-facing trim.
    max_output_bytes: usize,
};

/// One oneshot extension invocation (DESIGN §7.3). `request_json` is the full
/// wire request written to the child's stdin; `stdout` on return is the raw
/// response the child wrote before exiting — the caller decodes it with
/// `extension/protocol.zig`, so a malformed reply is a decode error, not a host
/// crash.
pub const ExtensionRequest = struct {
    /// Absolute path to the built extension executable (the active version's bin).
    entry_path: []const u8,
    cwd: []const u8,
    request_json: []const u8,
    max_output_bytes: usize,
};

/// A completed extension run. `stdout` is owned by the caller's allocator.
pub const ExtensionOutcome = struct {
    stdout: []u8,
    exit_code: u8,

    pub fn deinit(self: ExtensionOutcome, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
    }
};

/// The environment handle carried in every tool's `CtxHeader`. `io` is how a
/// tool reaches its filesystem (host today, sandbox/remote later); the vtable
/// covers process execution and dialect. Fixed-shape — nothing grows with the
/// conversation, so it is safe in `CtxHeader` (DESIGN §7.6).
pub const Environment = struct {
    io: std.Io,
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        dialect: *const fn (ptr: *anyopaque) Dialect,
        runShell: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, req: ShellRequest) anyerror!ShellOutcome,
        runExtension: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, req: ExtensionRequest) anyerror!ExtensionOutcome,
    };

    pub fn dialect(self: Environment) Dialect {
        return self.vtable.dialect(self.ptr);
    }

    pub fn runShell(self: Environment, alloc: std.mem.Allocator, req: ShellRequest) !ShellOutcome {
        return self.vtable.runShell(self.ptr, alloc, req);
    }

    pub fn runExtension(self: Environment, alloc: std.mem.Allocator, req: ExtensionRequest) !ExtensionOutcome {
        return self.vtable.runExtension(self.ptr, alloc, req);
    }
};

fn defaultDialect(io: std.Io, env: *const std.process.Environ.Map) Dialect {
    return switch (builtin.os.tag) {
        .windows => if (findWindowsBash(io, env) != null) .bash else .powershell,
        else => .bash,
    };
}

const default_bash_exe = "bash";
const windows_git_bash_paths = [_][]const u8{
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
    "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
    "C:\\Program Files (x86)\\Git\\usr\\bin\\bash.exe",
};

fn findWindowsBash(io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    if (bashOnPath(io, env)) return default_bash_exe;
    for (windows_git_bash_paths) |path| {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return path;
    }
    return null;
}

fn bashOnPath(io: std.Io, env: *const std.process.Environ.Map) bool {
    const path_value = env.get("PATH") orelse return false;
    var dirs = std.mem.splitScalar(u8, path_value, ';');
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (dirs.next()) |raw_dir| {
        const dir = std.mem.trim(u8, raw_dir, " \t\"");
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir) or isWindowsBashLauncherDir(dir)) continue;
        const candidate = std.fmt.bufPrint(&buf, "{s}\\bash.exe", .{dir}) catch continue;
        std.Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return true;
    }
    return false;
}

fn isWindowsBashLauncherDir(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(path, "C:\\Windows\\System32") or
        std.ascii.eqlIgnoreCase(path, "C:\\Windows\\SysWOW64") or
        std.ascii.eqlIgnoreCase(path, "C:\\Windows\\Sysnative") or
        std.ascii.endsWithIgnoreCase(path, "\\Microsoft\\WindowsApps");
}

pub const LocalOptions = struct {
    /// Override the OS-derived shell dialect.
    dialect: ?Dialect = null,
};

/// The `local` backend: runs in the host process with a sanitized child
/// environment. v0.1 honest version (DESIGN §9): shell authority == session
/// authority, so the *only* enforced boundary is that host secrets are stripped
/// before they can reach a subprocess. OS-level confinement arrives with the
/// `sandbox` backend.
pub const LocalEnvironment = struct {
    io: std.Io,
    dialect_val: Dialect,
    bash_exe: []const u8,
    env: std.process.Environ.Map,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, opts: LocalOptions) !LocalEnvironment {
        var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
        defer host.deinit();

        var sanitized: std.process.Environ.Map = .init(alloc);
        errdefer sanitized.deinit();
        var it = host.iterator();
        while (it.next()) |entry| {
            if (isSecretKey(entry.key_ptr.*)) continue;
            try sanitized.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        const bash_exe = if (builtin.os.tag == .windows) findWindowsBash(io, &host) orelse default_bash_exe else default_bash_exe;

        return .{
            .io = io,
            .dialect_val = opts.dialect orelse defaultDialect(io, &host),
            .bash_exe = bash_exe,
            .env = sanitized,
        };
    }

    pub fn deinit(self: *LocalEnvironment) void {
        self.env.deinit();
        self.* = undefined;
    }

    pub fn environment(self: *LocalEnvironment) Environment {
        return .{ .io = self.io, .ptr = self, .vtable = &vtable };
    }

    fn dialectImpl(ptr: *anyopaque) Dialect {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));
        return self.dialect_val;
    }

    fn runShellImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: ShellRequest) anyerror!ShellOutcome {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));

        const bash_argv = [_][]const u8{ self.bash_exe, "-lc", req.command };
        var powershell_argv: [5][]const u8 = undefined;
        var owned_script: ?[]u8 = null;
        defer if (owned_script) |script| alloc.free(script);

        const argv: []const []const u8 = switch (self.dialect_val) {
            .bash => bash_argv[0..],
            .powershell => blk: {
                const script = try std.fmt.allocPrint(
                    alloc,
                    "try {{ [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 }} catch {{}}; {s}",
                    .{req.command},
                );
                owned_script = script;
                powershell_argv = .{ "powershell", "-NoProfile", "-NonInteractive", "-Command", script };
                break :blk powershell_argv[0..];
            },
        };
        // `argv[0]` is resolved via the *parent* PATH (std.process contract), so a
        // stripped child env still finds `bash`/`powershell` when an absolute Git
        // Bash path was not detected.
        const result = try std.process.run(alloc, self.io, .{
            .argv = argv,
            .cwd = .{ .path = req.cwd },
            .environ_map = &self.env,
            .stdout_limit = .limited(req.max_output_bytes),
            .stderr_limit = .limited(req.max_output_bytes),
        });
        const exit_code: u8 = switch (result.term) {
            .exited => |c| c,
            else => 1,
        };
        return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
    }

    fn runExtensionImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: ExtensionRequest) anyerror!ExtensionOutcome {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));

        // Oneshot (DESIGN §7.3): spawn, feed one request, read one response, exit.
        // stderr is ignored in v1 — the extension reports failure through the
        // protocol's error response on stdout; a crash surfaces as a non-zero
        // exit with no valid response, which the decoder turns into an error.
        var child = try std.process.spawn(self.io, .{
            .argv = &.{req.entry_path},
            .cwd = .{ .path = req.cwd },
            .environ_map = &self.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .create_no_window = true,
        });
        errdefer child.kill(self.io);

        // Write the request, then close stdin so the child sees EOF. v1 requests
        // are small JSON lines (< pipe buffer), so writing before draining stdout
        // cannot deadlock.
        try child.stdin.?.writeStreamingAll(self.io, req.request_json);
        child.stdin.?.close(self.io);
        child.stdin = null;

        var read_buf: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(self.io, &read_buf);
        const stdout = try reader.interface.allocRemaining(alloc, .limited(req.max_output_bytes));
        errdefer alloc.free(stdout);

        const term = try child.wait(self.io);
        const exit_code: u8 = switch (term) {
            .exited => |c| c,
            else => 1,
        };
        return .{ .stdout = stdout, .exit_code = exit_code };
    }

    const vtable: Environment.VTable = .{
        .dialect = dialectImpl,
        .runShell = runShellImpl,
        .runExtension = runExtensionImpl,
    };
};

/// Host secret-shaped environment variables should not reach an AI-authored
/// subprocess (DESIGN §9). Matched case-insensitively as a substring so
/// provider keys, cloud creds, and SSH agents are all covered without
/// maintaining an exhaustive allowlist. Non-secret vars (PATH, HOME, …) pass
/// through so commands keep working — the v0.1 boundary is "no obvious secret
/// env leakage", not full non-inheritance or filesystem confinement.
pub fn isSecretKey(key: []const u8) bool {
    const needles = [_][]const u8{
        "SECRET",     "TOKEN",         "PASSWORD",   "PASSWD",
        "API_KEY",    "APIKEY",        "ACCESS_KEY", "PRIVATE_KEY",
        "CREDENTIAL", "SSH_AUTH_SOCK",
    };
    var buf: [512]u8 = undefined;
    if (key.len > buf.len) return true; // absurdly long key: strip defensively
    const upper = std.ascii.upperString(buf[0..key.len], key);
    for (needles) |needle| {
        if (std.mem.indexOf(u8, upper, needle) != null) return true;
    }
    return false;
}

test "isSecretKey strips provider/cloud/ssh secrets and keeps PATH" {
    try std.testing.expect(isSecretKey("OPENAI_API_KEY"));
    try std.testing.expect(isSecretKey("ANTHROPIC_API_KEY"));
    try std.testing.expect(isSecretKey("AWS_SECRET_ACCESS_KEY"));
    try std.testing.expect(isSecretKey("AWS_SESSION_TOKEN"));
    try std.testing.expect(isSecretKey("ssh_auth_sock"));
    try std.testing.expect(isSecretKey("GITHUB_TOKEN"));
    try std.testing.expect(!isSecretKey("PATH"));
    try std.testing.expect(!isSecretKey("HOME"));
    try std.testing.expect(!isSecretKey("USERPROFILE"));
}

test "local environment sanitizes its child env map" {
    const alloc = std.testing.allocator;
    var lenv = try LocalEnvironment.init(alloc, std.testing.io, .{});
    defer lenv.deinit();
    // Whatever the host had, no secret-shaped key survives into the child env.
    var it = lenv.env.iterator();
    while (it.next()) |entry| {
        try std.testing.expect(!isSecretKey(entry.key_ptr.*));
    }
}

test "windows bash launcher dirs are not treated as native bash" {
    try std.testing.expect(isWindowsBashLauncherDir("C:\\Windows\\System32"));
    try std.testing.expect(isWindowsBashLauncherDir("C:\\Users\\me\\AppData\\Local\\Microsoft\\WindowsApps"));
    try std.testing.expect(!isWindowsBashLauncherDir("C:\\Program Files\\Git\\bin"));
}
