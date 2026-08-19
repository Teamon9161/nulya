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
const tool = @import("tool.zig");
const emit = @import("emit.zig");
const process_tree = @import("environment/tree.zig");
// Aliased so the two run paths keep naming the primitives they use, not the
// module they now live in.
const Tree = process_tree.Tree;
const waitBounded = process_tree.waitBounded;

/// The host process environment. std 0.16 removed the ambient global environ
/// (`.{ .block = .global }`): the OS block is handed to `main` via
/// `std.process.Init` and to the test runner via `std.testing.environ`, and
/// nowhere else. `main` registers its copy here once at startup; this module is
/// the keeper because sanitizing that environment is already its job (§9).
var host_environ: std.process.Environ = .empty;
var host_environ_registered = false;

pub fn registerHostEnviron(env: std.process.Environ) void {
    host_environ = env;
    host_environ_registered = true;
}

/// The host environment as a fresh `Map` (caller deinits) — what
/// `createMap(.{ .block = .global })` returned before the global was removed.
/// Test builds fall back to the test runner's environ, so in-process tests see
/// the real environment exactly as they used to; a production process whose
/// main never registered gets the empty environment, never a hidden global.
pub fn hostEnvironMap(alloc: std.mem.Allocator) !std.process.Environ.Map {
    if (host_environ_registered) return host_environ.createMap(alloc);
    if (builtin.is_test) return std.testing.environ.createMap(alloc);
    return host_environ.createMap(alloc);
}

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
    /// The wall-clock budget ran out and the child was killed. `stdout`/`stderr`
    /// are then whatever had been captured before the kill (base-tools.md §3:
    /// a timeout still returns the output it already has).
    timed_out: bool = false,

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
    /// Wall-clock cap for the command (`tool.Timeouts`, base-tools.md §3). The
    /// `shell` tool always sets one; `null` runs unguarded and is for tests that
    /// are about something else.
    timeout_ms: ?u32 = null,
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
    /// Wall-clock cap for the oneshot call (`tool.Timeouts`, base-tools.md §3).
    /// `null` disables the guard; callers should only do that in controlled tests.
    timeout_ms: ?u32 = tool.Timeouts.extension_ms,
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

/// A command to run DETACHED, outliving the step process that asked for it
/// (DESIGN §6.1). Deliberately unlike `ShellRequest`: there is no capture cap
/// (the whole of the output goes to the task's log file), and `timeout_ms` has
/// no default and no ceiling — a task that outlives its step is the point, and
/// what ends one is `nulya task kill`.
pub const TaskRequest = struct {
    command: []const u8,
    cwd: []const u8,
    timeout_ms: ?u32 = null,
};

/// What starting a task tells the caller, immediately: which task this is and
/// where to watch it. Both strings are caller-owned.
pub const TaskStart = struct {
    /// The task's FULL name, `<session-id>/t<N>` (DESIGN §6.1). Full so that a
    /// task whose report was retargeted to another session still names itself
    /// unambiguously, and so no workspace-wide counter is needed.
    task_id: []u8,
    /// The log accumulating this task's stdout+stderr, relative to the workspace.
    log_path: []u8,

    pub fn deinit(self: TaskStart, alloc: std.mem.Allocator) void {
        alloc.free(self.task_id);
        alloc.free(self.log_path);
    }
};

/// The durable session an environment's background tasks belong to (DESIGN §8),
/// when it has one. Both halves are decided by the SHELL layer and handed down —
/// the same division of labour as `StepContext.scratch_dir`, which the kernel
/// only writes into: `session_path` is the file the supervisor deposits its
/// `task_finished` into (and whose stem names the task), `tasks_dir` is where
/// this workspace keeps that session's tasks (`launch.sessionTasksDir`). Absent
/// means `startShellTask` has nowhere to report to, and says so instead of
/// guessing a session.
pub const SessionRef = struct {
    session_path: []const u8,
    tasks_dir: []const u8,
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
        startShellTask: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, req: TaskRequest) anyerror!TaskStart,
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

    /// Start `req` detached and return at once. The ONE entry point for a
    /// background task: `shell {background:true}` and `nulya task run` both
    /// arrive here, so allocating the slot and launching the supervisor exist
    /// in exactly one place. `error.NoDurableSession` when this environment
    /// belongs to no session — there would be nowhere to report the result.
    pub fn startShellTask(self: Environment, alloc: std.mem.Allocator, req: TaskRequest) !TaskStart {
        return self.vtable.startShellTask(self.ptr, alloc, req);
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
    /// The durable session background tasks started here belong to, when there
    /// is one. `session new`, `nulya demo` and the tests leave it null: nothing
    /// they do can start a task.
    session: ?SessionRef = null,
};

/// How many `t<N>` slots one session may hand out. High enough that no real
/// session reaches it, finite so a corrupted tasks directory cannot spin here.
const max_tasks_per_session: usize = 10_000;

/// One assembled shell invocation: the argv and whatever heap string it borrows.
pub const ShellCommandLine = struct {
    argv: []const []const u8,
    /// The one string the powershell form allocates; null for bash.
    owned_script: ?[]u8,

    pub fn deinit(self: ShellCommandLine, alloc: std.mem.Allocator) void {
        if (self.owned_script) |s| alloc.free(s);
    }
};

/// The `local` backend: runs in the host process with a sanitized child
/// environment. v0.1 honest version (DESIGN §9): shell authority == session
/// authority, so the *only* enforced boundary is that host secrets are stripped
/// before they can reach a subprocess. OS-level confinement arrives with the
/// `sandbox` backend.
pub const LocalEnvironment = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    dialect_val: Dialect,
    bash_exe: []const u8,
    env: std.process.Environ.Map,
    /// The session this environment's background tasks belong to, copied so it
    /// cannot outlive the caller's strings. Null = no session, so
    /// `startShellTask` refuses (see `SessionRef`).
    session_path: ?[]u8 = null,
    tasks_dir: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, opts: LocalOptions) !LocalEnvironment {
        var host = try hostEnvironMap(alloc);
        defer host.deinit();

        var sanitized: std.process.Environ.Map = .init(alloc);
        errdefer sanitized.deinit();
        var it = host.iterator();
        while (it.next()) |entry| {
            if (isSecretKey(entry.key_ptr.*)) continue;
            try sanitized.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Children get to find the harness that spawned them. A driver written
        // as an extension (`extensions/compact`, PLAN §3.6) has to run
        // `nulya session append|step|new`, and it cannot assume a `nulya` on
        // PATH — the one that matters is THIS binary, not whichever copy an
        // installer left behind. Not a secret and not model-visible state: an
        // absolute path to the running executable, next to `NULYA_SESSION`
        // (which `session step` puts here to name the live session file).
        // Unknowable path (a deleted binary, an exotic OS) leaves it unset:
        // building an environment must never fail over provenance.
        if (std.process.executablePathAlloc(io, alloc)) |exe_path| {
            defer alloc.free(exe_path);
            try sanitized.put("NULYA_EXE", exe_path);
        } else |_| {}

        const bash_exe = if (builtin.os.tag == .windows) findWindowsBash(io, &host) orelse default_bash_exe else default_bash_exe;

        var session_path: ?[]u8 = null;
        errdefer if (session_path) |p| alloc.free(p);
        var tasks_dir: ?[]u8 = null;
        errdefer if (tasks_dir) |p| alloc.free(p);
        if (opts.session) |s| {
            session_path = try alloc.dupe(u8, s.session_path);
            tasks_dir = try alloc.dupe(u8, s.tasks_dir);
        }

        return .{
            .io = io,
            .alloc = alloc,
            .dialect_val = opts.dialect orelse defaultDialect(io, &host),
            .bash_exe = bash_exe,
            .env = sanitized,
            .session_path = session_path,
            .tasks_dir = tasks_dir,
        };
    }

    pub fn deinit(self: *LocalEnvironment) void {
        self.env.deinit();
        if (self.session_path) |p| self.alloc.free(p);
        if (self.tasks_dir) |p| self.alloc.free(p);
        self.* = undefined;
    }

    pub fn environment(self: *LocalEnvironment) Environment {
        return .{ .io = self.io, .ptr = self, .vtable = &vtable };
    }

    fn dialectImpl(ptr: *anyopaque) Dialect {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));
        return self.dialect_val;
    }

    /// The argv that runs `command` in this environment's dialect — the ONE
    /// place that decision is made. Two consumers: an in-process `shell` call
    /// below, and `nulya task supervise`, which runs a BACKGROUND command and
    /// must reach the same interpreter with the same flags (DESIGN §6.1).
    ///
    /// `buf` backs the argv and must outlive the returned value; the powershell
    /// form additionally owns one heap string, released by `deinit`.
    pub fn shellArgv(
        self: *const LocalEnvironment,
        alloc: std.mem.Allocator,
        command: []const u8,
        buf: *[5][]const u8,
    ) !ShellCommandLine {
        switch (self.dialect_val) {
            .bash => {
                buf[0] = self.bash_exe;
                buf[1] = "-lc";
                buf[2] = command;
                return .{ .argv = buf[0..3], .owned_script = null };
            },
            .powershell => {
                const script = try std.fmt.allocPrint(
                    alloc,
                    "try {{ [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 }} catch {{}}; {s}",
                    .{command},
                );
                buf.* = .{ "powershell", "-NoProfile", "-NonInteractive", "-Command", script };
                return .{ .argv = buf[0..5], .owned_script = script };
            },
        }
    }

    fn runShellImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: ShellRequest) anyerror!ShellOutcome {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));

        var argv_buf: [5][]const u8 = undefined;
        const cmdline = try self.shellArgv(alloc, req.command, &argv_buf);
        defer cmdline.deinit(alloc);
        const argv = cmdline.argv;
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
        // nor the kill ever closes a pipe the drain task is mid-read on
        // (`child.wait` reaps only the process handle). That removes every race
        // between draining and process cleanup; this code owns the read-ends and
        // closes them once the drain has finished (DESIGN §8/§9).
        //
        // `Tree` rather than a bare spawn: a shell forks, and killing only the
        // direct child would leave a grandchild holding these very write-ends, so
        // the drain below would never reach EOF (see `Tree`).
        var tree = try Tree.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = req.cwd },
            .environ_map = &self.env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        defer tree.deinit(); // last defer to run: releases the job handle
        const child = &tree.child;
        const out_file = child.stdout.?;
        const err_file = child.stderr.?;
        child.stdout = null; // detach: process cleanup must not touch the read-ends.
        child.stderr = null;
        defer out_file.close(self.io);
        defer err_file.close(self.io);

        // `child.wait` reaps the process on the normal path. If we leave this scope
        // any other way (cancel, StreamTooLong, allocation failure), the tree is
        // still running, so terminate+reap it here. `child_reaped` guards against a
        // double reap (a second `kill` after `child.id` was cleared would panic).
        var child_reaped = false;
        defer if (!child_reaped) tree.killAll(self.io);

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(alloc, self.io, multi_reader_buffer.toStreams(), &.{ out_file, err_file });
        var multi_reader_live = true;
        defer if (multi_reader_live) multi_reader.deinit();

        // Drain both pipes to EOF on a worker so a large writer cannot fill a pipe
        // and stall the child. This task only ever touches the MultiReader, never
        // `child`, so it cannot race process cleanup.
        var drain = self.io.async(drainShellOutput, .{ &multi_reader, req.max_output_bytes });

        // The wall-clock budget races the child's own exit (base-tools.md §3).
        // `child.wait` stays the cancelation point either way — `waitBounded`
        // just runs it as one of two tasks, exactly the `Select` shape the stall
        // watchdog uses (`providers/wire.zig` `Watched`). If the io cannot give
        // the pair their own units of concurrency, the wait runs unguarded: no
        // false timeout, just no guard.
        const waited = waitBounded(self.io, child, req.timeout_ms) catch |err| {
            // Cancellation (or a wait failure): the tree is still alive. Terminate
            // ALL of it so every write-end closes, which lets the blocked drain
            // reach EOF and finish; only then is it safe to unwind the MultiReader
            // and read-ends. Killing just the direct child would leave the drain
            // blocked on a grandchild for the command's full duration.
            tree.killAll(self.io);
            child_reaped = true;
            drain.await(self.io) catch {};
            return err;
        };

        if (waited == .timed_out) {
            // Same unwind as the cancel path, and for the same reason: kill the
            // whole tree first so the pipes reach EOF, then join the drain, then
            // take what it got. A timeout returns the output captured before the
            // kill rather than an empty result (base-tools.md §3).
            tree.killAll(self.io);
            child_reaped = true;
            drain.await(self.io) catch {};
            const partial_out = try multi_reader.toOwnedSlice(0);
            errdefer alloc.free(partial_out);
            const partial_err = try multi_reader.toOwnedSlice(1);
            errdefer alloc.free(partial_err);
            multi_reader.deinit();
            multi_reader_live = false;
            return .{ .stdout = partial_out, .stderr = partial_err, .exit_code = 1, .timed_out = true };
        }
        child_reaped = true; // `child.wait` reaped the process handle.

        try drain.await(self.io); // propagate StreamTooLong / a real read error.

        const stdout = try multi_reader.toOwnedSlice(0);
        errdefer alloc.free(stdout);
        const stderr = try multi_reader.toOwnedSlice(1);
        errdefer alloc.free(stderr);
        multi_reader.deinit();
        multi_reader_live = false;

        const exit_code: u8 = switch (waited.term) {
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
        // Same tree discipline as the shell (see `Tree`): an extension is free to
        // spawn helpers of its own, and the timeout below has to end all of them.
        var tree = try Tree.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = req.cwd },
            .environ_map = &self.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        defer tree.deinit();
        const child = &tree.child;
        errdefer tree.killAll(self.io);

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
                tree.killAll(self.io);
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

    /// Start a detached background command and return the moment it is launched
    /// (DESIGN §6.1). What is started is NOT the command itself but
    /// `nulya task supervise` — the same binary, in its supervisor role: it
    /// holds the task's lease, runs the real command under a `Tree` so
    /// `nulya task kill` ends the whole subtree, and deposits the
    /// `task_finished` event when it is over. Nothing is waited on here.
    ///
    /// The slot is allocated with an exclusive `mkdir` (the handoff file's
    /// discipline, one directory up): the first free `t<N>` wins, so two callers
    /// racing cannot be handed the same name, and the name is monotonic within a
    /// session.
    fn startShellTaskImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: TaskRequest) anyerror!TaskStart {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));
        const session_path = self.session_path orelse return error.NoDurableSession;
        const tasks_dir = self.tasks_dir orelse return error.NoDurableSession;
        // The supervisor IS this binary. `NULYA_EXE` is where every child of a
        // nulya process learns which one that is (DESIGN §7.6); without it there
        // is no honest way to start one.
        const exe = self.env.get("NULYA_EXE") orelse return error.HarnessPathUnknown;

        const session_id = std.fs.path.stem(std.fs.path.basename(session_path));
        if (session_id.len == 0) return error.NoDurableSession;

        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, tasks_dir);

        var slot: usize = 1;
        var task_dir: ?[]u8 = null;
        errdefer if (task_dir) |d| alloc.free(d);
        while (slot <= max_tasks_per_session) : (slot += 1) {
            const name = try std.fmt.allocPrint(alloc, "t{d}", .{slot});
            defer alloc.free(name);
            // `/` on every OS: this path ends up in the model's receipt (`emit.joinRel`).
            const candidate = try emit.joinRel(alloc, &.{ tasks_dir, name });
            if (cwd.createDir(self.io, candidate, .default_dir)) |_| {
                task_dir = candidate;
                break;
            } else |err| {
                alloc.free(candidate);
                if (err != error.PathAlreadyExists) return err;
            }
        }
        const dir_rel = task_dir orelse return error.TooManyTasks;

        const task_id = try std.fmt.allocPrint(alloc, "{s}/t{d}", .{ session_id, slot });
        errdefer alloc.free(task_id);
        const log_path = try emit.joinRel(alloc, &.{ dir_rel, task_log_name });
        errdefer alloc.free(log_path);

        var timeout_buf: [16]u8 = undefined;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.appendSlice(alloc, &.{ exe, "task", "supervise", "--dir", dir_rel, "--session", session_path, "--cwd", req.cwd });
        if (req.timeout_ms) |ms| {
            try argv.appendSlice(alloc, &.{ "--timeout-ms", try std.fmt.bufPrint(&timeout_buf, "{d}", .{ms}) });
        }
        try argv.appendSlice(alloc, &.{ "--", req.command });

        // A PLAIN spawn, not a `Tree`: this call returns normally and kills
        // nothing, and the supervisor must survive both this process and the
        // terminal it was started from — hence its own process group on POSIX
        // and no console on Windows. Its stdio is null because it inherits this
        // process's pipes otherwise, and a step's drain would then wait for a
        // process designed to outlive it (see `Tree`'s note on detaching).
        var detached: DetachedStdio = .take();
        defer detached.restore();
        var child = try std.process.spawn(self.io, .{
            .argv = argv.items,
            // The workspace, NOT `req.cwd`: `--dir` and `--session` are
            // workspace-relative, and where the COMMAND runs is `--cwd`'s job.
            .cwd = .inherit,
            .environ_map = &self.env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
            .pgid = if (builtin.os.tag == .windows) null else 0,
        });
        // Nothing is waited on: the supervisor outlives this call by design. On
        // Windows the handle is ours to release; on POSIX the exiting step
        // process hands the child to init.
        if (builtin.os.tag == .windows) {
            if (child.id) |handle| std.os.windows.CloseHandle(handle);
            std.os.windows.CloseHandle(child.thread_handle);
            child.id = null;
        }

        alloc.free(dir_rel);
        task_dir = null;
        return .{ .task_id = task_id, .log_path = log_path };
    }

    const vtable: Environment.VTable = .{
        .dialect = dialectImpl,
        .runShell = runShellImpl,
        .runExtension = runExtensionImpl,
        .startShellTask = startShellTaskImpl,
    };
};

/// The one file a task's stdout and stderr are appended to, in arrival order.
/// Named here because both halves of the mechanism need it: the environment
/// tells the caller where it is, and `nulya task supervise` writes it.
pub const task_log_name = "output.log";

/// The two kernel32 calls `DetachedStdio` needs, declared locally exactly as
/// `environment/tree.zig` declares the job-object calls — std 0.16 ships
/// neither. Analyzed lazily, so the externs never reach a POSIX link.
const win32 = struct {
    const windows = std.os.windows;
    const HANDLE_FLAG_INHERIT: windows.DWORD = 0x00000001;
    extern "kernel32" fn GetHandleInformation(hObject: windows.HANDLE, lpdwFlags: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetHandleInformation(hObject: windows.HANDLE, dwMask: windows.DWORD, dwFlags: windows.DWORD) callconv(.winapi) windows.BOOL;
};

/// Keep this process's own stdio out of a DETACHED child.
///
/// Windows `CreateProcessW` is called with `bInheritHandles = TRUE` and no
/// handle list, so a child inherits every INHERITABLE handle — not only the
/// three the startup info names. When nulya itself was spawned with pipes (a
/// driver running `session step`, a test running the CLI), those pipe write ends
/// are exactly such handles: a supervisor that inherited a duplicate would hold
/// them open for the task's whole life, and the caller's drain would not reach
/// EOF until the background command finished. That is precisely the wait
/// detaching exists to avoid — the task would be background in name only.
///
/// So the inherit flag is cleared on stdin/stdout/stderr across the spawn and
/// restored right after. POSIX needs nothing: std opens its own descriptors
/// `CLOEXEC`, and the child's three are redirected by `dup2`.
const DetachedStdio = struct {
    saved: if (builtin.os.tag == .windows) [3]?Saved else void =
        if (builtin.os.tag == .windows) .{ null, null, null } else {},

    const Saved = struct { handle: std.os.windows.HANDLE, flags: std.os.windows.DWORD };

    fn take() DetachedStdio {
        if (builtin.os.tag != .windows) return .{ .saved = {} };
        var self: DetachedStdio = .{};
        const files = [3]std.Io.File{ std.Io.File.stdin(), std.Io.File.stdout(), std.Io.File.stderr() };
        for (files, 0..) |f, i| {
            const handle = f.handle;
            if (handle == std.os.windows.INVALID_HANDLE_VALUE) continue;
            var flags: std.os.windows.DWORD = 0;
            if (!win32.GetHandleInformation(handle, &flags).toBool()) continue;
            if (flags & win32.HANDLE_FLAG_INHERIT == 0) continue;
            if (!win32.SetHandleInformation(handle, win32.HANDLE_FLAG_INHERIT, 0).toBool()) continue;
            self.saved[i] = .{ .handle = handle, .flags = flags };
        }
        return self;
    }

    fn restore(self: *DetachedStdio) void {
        if (builtin.os.tag != .windows) return;
        for (self.saved) |entry| {
            const e = entry orelse continue;
            _ = win32.SetHandleInformation(e.handle, win32.HANDLE_FLAG_INHERIT, e.flags & win32.HANDLE_FLAG_INHERIT);
        }
    }
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

test "local environment tells its children where the harness is" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    // What the OS says this process is. If it cannot say (a deleted binary),
    // the variable is deliberately absent and there is nothing to assert.
    const exe = std.process.executablePathAlloc(io, alloc) catch return error.SkipZigTest;
    defer alloc.free(exe);

    var lenv = try LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    try std.testing.expect(lenv.env.get("NULYA_EXE") != null);
    const seen = lenv.env.get("NULYA_EXE").?;
    try std.testing.expect(std.fs.path.isAbsolute(seen));
    try std.testing.expectEqualStrings(exe, seen);
    // Not secret-shaped, so sanitization keeps it (this is the pairing that
    // makes the variable reach an extension at all).
    try std.testing.expect(!isSecretKey("NULYA_EXE"));
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

    // The DEFAULT dialect: cancellation terminates the command's whole process
    // tree (`Tree`), so this no longer has to avoid Git Bash's launcher, whose
    // real shell is a grandchild. That is the point of running it unpinned.
    var lenv = try LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    // The child announces `started`, sleeps, then would write `done`. Killing the
    // tree means the `done` step never runs — the observable proof that
    // cancellation terminated the processes rather than waiting for them.
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
