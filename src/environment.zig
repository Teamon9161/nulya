//! Execution Environment boundary (DESIGN §8, §9).
//!
//! shell/extension execution goes through an `Environment`, never a raw process
//! spawn. This is the single seam that:
//!   1. picks the shell dialect (bash | powershell) — DESIGN §6.1;
//!   2. sanitizes the child environment so host secrets (API keys, SSH agent,
//!      cloud creds) never reach an AI-authored subprocess — DESIGN §9;
//!   3. later swaps `local` execution for sandbox/remote without touching a
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
    /// Absolute path to the extension entry: a built binary for a compiled
    /// extension, or a frozen script for a script extension (DESIGN §7.1).
    entry_path: []const u8,
    /// For a script extension, the interpreter to run `entry_path` with (becomes
    /// argv[0], with the entry as argv[1]). `null` runs the entry directly.
    interpreter: ?[]const u8 = null,
    cwd: []const u8,
    request_json: []const u8,
    max_output_bytes: usize,
    /// Wall-clock cap for the oneshot call. `null` disables the guard; callers
    /// should only do that in controlled tests.
    timeout_ms: ?u32 = 30_000,
};

/// A completed extension run. `stdout`/`stderr` are owned by the caller's allocator.
pub const ExtensionOutcome = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    timed_out: bool = false,

    pub fn deinit(self: ExtensionOutcome, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

/// Filesystem operations available to builtin tools inside the workspace.
///
/// The local backend is host-backed today; sandbox/remote backends can supply a
/// different implementation without letting tools reach `std.Io.Dir.cwd()`.
pub const WorkspaceFs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readFileAlloc: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) anyerror![]u8,
        atomicWriteFile: *const fn (ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void,
    };

    pub fn readFileAlloc(self: WorkspaceFs, alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
        return self.vtable.readFileAlloc(self.ptr, alloc, path, max_bytes);
    }

    pub fn atomicWriteFile(self: WorkspaceFs, path: []const u8, data: []const u8) !void {
        return self.vtable.atomicWriteFile(self.ptr, path, data);
    }
};

/// The environment handle carried in every tool's `ToolContext`. The vtable
/// covers process execution and dialect. Fixed-shape — nothing grows with the
/// conversation, so it is safe in `ToolContext` (DESIGN §7.6).
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

    pub fn workspaceFs(self: *LocalEnvironment) WorkspaceFs {
        return .{ .ptr = self, .vtable = &fs_vtable };
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
        //
        // We spawn+drain by hand rather than calling `std.process.run` because that
        // helper drains the child's stdout pipe with a *blocking* read, and on
        // Windows such a read is not promptly interruptible by cancellation (nor by
        // a timeout) — it only returns once the child produces output or exits. A
        // canceled step would then hang until the command finished on its own (a
        // `sleep 3600` would block the whole step for an hour). The only reliably
        // cancelable wait is `child.wait` (an alertable wait on Windows, a
        // signal-interrupted syscall on POSIX), so we make THAT the cancelation
        // point and drain the pipes on a separate task.
        //
        // The read-ends are detached from `child` up front, so neither `child.wait`
        // nor `child.kill` ever closes a pipe the drain task is mid-read on
        // (`child.wait` reaps only the process handle). That removes every race
        // between draining and process cleanup; this code owns the read-ends and
        // closes them once the drain has finished (DESIGN §8/§9).
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = req.cwd },
            .environ_map = &self.env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        const out_file = child.stdout.?;
        const err_file = child.stderr.?;
        child.stdout = null; // detach: process cleanup must not touch the read-ends.
        child.stderr = null;
        defer out_file.close(self.io);
        defer err_file.close(self.io);

        // `child.wait` reaps the process on the normal path. If we leave this scope
        // any other way (cancel, StreamTooLong, allocation failure), the process is
        // still running, so terminate+reap it here. `child_reaped` guards against a
        // double reap (a second `kill` after `child.id` was cleared would panic).
        var child_reaped = false;
        defer if (!child_reaped) child.kill(self.io);

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(alloc, self.io, multi_reader_buffer.toStreams(), &.{ out_file, err_file });
        var multi_reader_live = true;
        defer if (multi_reader_live) multi_reader.deinit();

        // Drain both pipes to EOF on a worker so a large writer cannot fill a pipe
        // and stall the child. This task only ever touches the MultiReader, never
        // `child`, so it cannot race process cleanup.
        var drain = self.io.async(drainShellOutput, .{ &multi_reader, req.max_output_bytes });

        const term = child.wait(self.io) catch |err| {
            // Cancellation (or a wait failure): the child is still alive. Terminate
            // it so its write-ends close, which lets the blocked drain reach EOF and
            // finish; only then is it safe to unwind the MultiReader and read-ends.
            child.kill(self.io);
            child_reaped = true;
            drain.await(self.io) catch {};
            return err;
        };
        child_reaped = true; // `child.wait` reaped the process handle.

        try drain.await(self.io); // propagate StreamTooLong / a real read error.

        const stdout = try multi_reader.toOwnedSlice(0);
        errdefer alloc.free(stdout);
        const stderr = try multi_reader.toOwnedSlice(1);
        errdefer alloc.free(stderr);
        multi_reader.deinit();
        multi_reader_live = false;

        const exit_code: u8 = switch (term) {
            .exited => |c| c,
            else => 1,
        };
        return .{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code };
    }

    /// Read both of a child's pipes to EOF. Runs on its own task while the caller
    /// waits on the child, so it must touch nothing but the MultiReader. Output is
    /// capped at `max`: once a stream crosses it the buffers are tossed and reading
    /// continues (so the child never blocks on a full pipe), and `StreamTooLong` is
    /// reported at the end.
    fn drainShellOutput(multi_reader: *std.Io.File.MultiReader, max: usize) anyerror!void {
        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);
        var too_long = false;
        while (multi_reader.fill(64, .none)) |_| {
            if (stdout_reader.bufferedLen() > max or stderr_reader.bufferedLen() > max) too_long = true;
            if (too_long) {
                stdout_reader.tossBuffered();
                stderr_reader.tossBuffered();
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        if (too_long) return error.StreamTooLong;
        try multi_reader.checkAnyError();
    }

    fn runExtensionImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: ExtensionRequest) anyerror!ExtensionOutcome {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));

        // Oneshot (DESIGN §7.3): spawn, feed one request, read one response, exit.
        // Capture stderr too: when an AI-authored extension crashes before it can
        // write a protocol error on stdout, stderr is the only repair signal.
        // A script extension runs through its interpreter (argv = [interpreter,
        // entry]); a compiled one runs directly (argv = [entry]).
        var argv_buf: [2][]const u8 = undefined;
        const argv: []const []const u8 = if (req.interpreter) |interp| blk: {
            argv_buf = .{ interp, req.entry_path };
            break :blk argv_buf[0..2];
        } else blk: {
            argv_buf[0] = req.entry_path;
            break :blk argv_buf[0..1];
        };
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = req.cwd },
            .environ_map = &self.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        errdefer child.kill(self.io);

        // Write the request, then close stdin so the child sees EOF. v1 requests
        // are small JSON lines (< pipe buffer), so writing before draining stdout
        // cannot deadlock.
        try child.stdin.?.writeStreamingAll(self.io, req.request_json);
        child.stdin.?.close(self.io);
        child.stdin = null;

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(alloc, self.io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        var multi_reader_live = true;
        defer if (multi_reader_live) multi_reader.deinit();

        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);
        const timeout = extensionTimeout(self.io, req.timeout_ms);

        while (multi_reader.fill(64, timeout)) |_| {
            if (stdout_reader.buffered().len > req.max_output_bytes or stderr_reader.buffered().len > req.max_output_bytes) {
                return error.StreamTooLong;
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.Timeout => {
                const stdout = try alloc.dupe(u8, stdout_reader.buffered());
                errdefer alloc.free(stdout);
                const stderr = try alloc.dupe(u8, stderr_reader.buffered());
                errdefer alloc.free(stderr);
                multi_reader.deinit();
                multi_reader_live = false;
                child.kill(self.io);
                return .{ .stdout = stdout, .stderr = stderr, .exit_code = 1, .timed_out = true };
            },
            else => |e| return e,
        }

        try multi_reader.checkAnyError();

        const term = try child.wait(self.io);
        const stdout = try multi_reader.toOwnedSlice(0);
        errdefer alloc.free(stdout);
        const stderr = try multi_reader.toOwnedSlice(1);
        errdefer alloc.free(stderr);
        multi_reader.deinit();
        multi_reader_live = false;

        const exit_code: u8 = switch (term) {
            .exited => |c| c,
            else => 1,
        };
        return .{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code };
    }

    fn extensionTimeout(io: std.Io, timeout_ms: ?u32) std.Io.Timeout {
        const ms = timeout_ms orelse return .none;
        const duration: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromMilliseconds(ms) };
        return .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, duration) };
    }

    fn readFileAllocImpl(ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) anyerror![]u8 {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, alloc, .limited(max_bytes));
    }

    fn atomicWriteFileImpl(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));
        const cwd = std.Io.Dir.cwd();
        var original = try cwd.openFile(self.io, path, .{});
        defer original.close(self.io);
        const permissions = (try original.stat(self.io)).permissions;

        var atomic = try cwd.createFileAtomic(self.io, path, .{ .replace = true, .permissions = permissions });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    const fs_vtable: WorkspaceFs.VTable = .{
        .readFileAlloc = readFileAllocImpl,
        .atomicWriteFile = atomicWriteFileImpl,
    };

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

fn runShellCall(env: Environment, alloc: std.mem.Allocator, req: ShellRequest) anyerror!ShellOutcome {
    return env.runShell(alloc, req);
}

fn markerExists(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    dir.access(io, name, .{}) catch return false;
    return true;
}

fn testSleepMs(io: std.Io, ms: i64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

test "canceling a running shell surfaces cancellation and kills the child" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_real: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_real);
    const cwd = root_real[0..root_len];

    // Pin the dialect so the marker-writing process IS the direct child (DESIGN
    // §9 scope). On Windows the default dialect is Git Bash, whose `bin\bash.exe`
    // is a launcher that re-execs the real shell as a *grandchild* — killing the
    // direct child would not stop it, which is explicitly out of scope. PowerShell
    // runs `Start-Sleep` in-process, so it is itself the process cancellation must
    // terminate; on other platforms `bash` runs the whole line directly.
    const forced: LocalOptions = if (builtin.os.tag == .windows) .{ .dialect = .powershell } else .{ .dialect = .bash };
    var lenv = try LocalEnvironment.init(alloc, io, forced);
    defer lenv.deinit();

    // The child announces `started`, sleeps, then would write `done`. Killing the
    // direct child means the `done` step never runs — the observable proof that
    // cancellation terminated the process rather than waiting for it to finish.
    const command = switch (lenv.dialect_val) {
        .bash => "touch started; sleep 2; touch done",
        .powershell => "New-Item started -ItemType File -Force > $null; Start-Sleep -Seconds 2; New-Item done -ItemType File -Force > $null",
    };

    var fut = io.async(runShellCall, .{
        lenv.environment(), alloc, ShellRequest{ .command = command, .cwd = cwd, .max_output_bytes = 1 << 20 },
    });

    // Wait until the child has actually launched, then cancel. The bound only
    // exists so a broken spawn fails instead of hanging: it is not a statement
    // about how fast a shell starts. A loaded machine — another nulya process,
    // a parallel test run, a virus scanner opening the interpreter — can take
    // seconds to get there, so give it far more room than it will ever need.
    // The loop breaks the moment the marker appears, so an idle run pays
    // nothing for the headroom.
    const spawn_budget_ticks = 1500; // 30s at 20ms
    var waited: usize = 0;
    while (waited < spawn_budget_ticks) : (waited += 1) {
        if (markerExists(io, tmp.dir, "started")) break;
        testSleepMs(io, 20);
    }
    try std.testing.expect(markerExists(io, tmp.dir, "started"));

    // Cancellation surfaces AS cancellation — never a normal ShellOutcome — and
    // the child is terminated promptly (the drain loop's checkCancel fires within
    // one poll interval, then `errdefer child.kill` runs).
    if (fut.cancel(io)) |ok| {
        ok.deinit(alloc);
        return error.TestExpectedCancellation;
    } else |err| try std.testing.expectEqual(error.Canceled, err);

    // The child was killed mid-sleep, so it never reached the `done` step. Wait
    // comfortably past its 2s sleep to make the absence conclusive.
    var elapsed: usize = 0;
    while (elapsed < 180) : (elapsed += 1) {
        try std.testing.expect(!markerExists(io, tmp.dir, "done"));
        testSleepMs(io, 20);
    }
}

test "shell run captures stdout and exit code without cancellation" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_real: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = root_real[0..try tmp.dir.realPath(io, &root_real)];

    var lenv = try LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const command = switch (lenv.dialect_val) {
        .bash => "echo hello-nulya",
        .powershell => "Write-Output hello-nulya",
    };
    const outcome = try lenv.environment().runShell(alloc, .{ .command = command, .cwd = cwd, .max_output_bytes = 1 << 20 });
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 0), outcome.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "hello-nulya") != null);
}

test "runExtension captures stderr when response is invalid" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_name = if (builtin.os.tag == .windows) "bad-extension.cmd" else "bad-extension.sh";
    const script = if (builtin.os.tag == .windows)
        "@echo off\r\necho stderr-marker 1>&2\r\necho not-json\r\n"
    else
        "#!/bin/sh\necho stderr-marker >&2\necho not-json\n";
    try tmp.dir.writeFile(io, .{ .sub_path = script_name, .data = script });
    if (builtin.os.tag != .windows) {
        var f = try tmp.dir.openFile(io, script_name, .{});
        defer f.close(io);
        try f.setPermissions(io, .executable_file);
    }

    var root_real: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_real);
    const root_path = root_real[0..root_len];
    const entry_path = try std.fs.path.join(alloc, &.{ root_path, script_name });
    defer alloc.free(entry_path);

    var lenv = try LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const outcome = try lenv.environment().runExtension(alloc, .{
        .entry_path = entry_path,
        .cwd = root_path,
        .request_json = "{}",
        .max_output_bytes = 1024,
        // This test is about stderr capture, not about the timeout, so it uses
        // the production default: a one-second budget would turn "the machine
        // was busy while a script interpreter started" into a failure about
        // something else entirely.
        .timeout_ms = 30_000,
    });
    defer outcome.deinit(alloc);

    try std.testing.expect(!outcome.timed_out);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "not-json") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "stderr-marker") != null);
}
