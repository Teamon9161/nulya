//! The OS glue around a child process: spawn it so its whole TREE can be
//! terminated, and wait for it under a wall-clock budget.
//!
//! `environment.zig` owns the seams (what a shell / extension run IS, which
//! dialect, which env survives); this file owns the platform mechanics — job
//! objects on Windows, process groups on POSIX, and the bounded wait that turns
//! a timeout into an actual kill rather than only a label.

const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

/// The kernel32 job-object calls `std.os.windows` does not declare (0.16 ships
/// only `CreateProcessW` there). A job object is the only reliable way to
/// terminate a process TREE on Windows. Analyzed lazily — nothing here is
/// referenced off Windows, so the externs never reach a POSIX link.
///
/// The job carries NO limits (see `Tree`), so `SetInformationJobObject` is not
/// needed and is not declared.
const win32 = struct {
    extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*anyopaque, lpName: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(hJob: windows.HANDLE, hProcess: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(hJob: windows.HANDLE, uExitCode: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) callconv(.winapi) windows.DWORD;
};

/// A child process plus whatever the OS needs to terminate its whole TREE.
///
/// `std.process.Child.kill` reaches only the direct child, and the direct child
/// is usually not the process doing the work: `bash -lc "a; b"` forks for the
/// last command, and Windows Git Bash's `bin\bash.exe` is a launcher that
/// re-execs the real shell as a grandchild. A survivor keeps the pipe write-ends
/// open, so the drain never reaches EOF — a timeout would then MARK the result
/// without ever unblocking the step, and a cancel would wait out the command it
/// was supposed to interrupt. So both kill a tree:
///
///   POSIX:   the child starts its own process group (`pgid = 0`, applied
///            between fork and exec), and `killAll` signals the negative pid,
///            which is the whole group.
///   Windows: the child starts suspended, is assigned to a job object, and only
///            then resumed — so it cannot fork anything outside the job.
///            `killAll` terminates the job.
///
/// Terminating is what kills the tree; returning normally does not. The job is
/// created with NO limits — notably not `KILL_ON_JOB_CLOSE`, which would kill
/// everything the command started the moment `deinit` closed the handle. That
/// would diverge from POSIX (which only signals on timeout / cancel) and destroy
/// `some-server >/dev/null 2>&1 &` in one shell call, used by the next.
///
/// A detached background process must still redirect its stdio, or the call
/// blocks until it exits: it inherits the pipe write-ends, and the drain reads
/// both pipes to EOF.
///
/// If the OS refuses a job object (an older Windows' nested-job restriction, or
/// nulya itself running inside a restrictive job), this degrades to the plain
/// single-process kill and says so once.
pub const Tree = struct {
    child: std.process.Child,
    /// POSIX: the direct child's pid — which is also the group id — kept here
    /// because `child.id` does not survive a canceled `wait` (std 0.16 runs the
    /// same cleanup on cancel as on success: `id` nulled, stdio closed, but the
    /// child NOT reaped), and `killAll` must work exactly then, right after a
    /// timeout or cancellation interrupted the wait.
    pid: if (builtin.os.tag == .windows) void else std.posix.pid_t,
    /// POSIX: set once `killAll` reaped a wait-canceled child, so a second call
    /// (defer + explicit) cannot wait on a pid the OS may have reused.
    reaped: if (builtin.os.tag == .windows) void else bool,
    /// Windows: the job the child and its descendants belong to, or null when
    /// the OS refused one. POSIX needs no handle — the group IS the child's pid.
    job: if (builtin.os.tag == .windows) ?windows.HANDLE else void,

    pub fn spawn(io: std.Io, options: std.process.SpawnOptions) !Tree {
        if (builtin.os.tag != .windows) {
            var opts = options;
            opts.pgid = 0; // become a group leader, so `killAll` can signal the group
            const child = try std.process.spawn(io, opts);
            return .{ .child = child, .pid = child.id.?, .reaped = false, .job = {} };
        }

        // Create the job FIRST: if the OS refuses one, spawn the ordinary way
        // rather than suspending a child that would then need resuming anyway.
        const job = win32.CreateJobObjectW(null, null) orelse {
            std.debug.print("nulya: no job object available; a timed-out or canceled command can only kill its direct child\n", .{});
            return .{ .child = try std.process.spawn(io, options), .pid = {}, .reaped = {}, .job = null };
        };
        errdefer windows.CloseHandle(job);

        var opts = options;
        opts.start_suspended = true; // assign to the job before it can fork
        var child = try std.process.spawn(io, opts);
        errdefer child.kill(io);

        const assigned = win32.AssignProcessToJobObject(job, child.id.?).toBool();
        // Resume either way — a child left suspended would hang forever.
        _ = win32.ResumeThread(child.thread_handle);
        if (!assigned) {
            windows.CloseHandle(job);
            std.debug.print("nulya: could not assign the command to a job object; a timed-out or canceled command can only kill its direct child\n", .{});
            return .{ .child = child, .pid = {}, .reaped = {}, .job = null };
        }
        return .{ .child = child, .pid = {}, .reaped = {}, .job = job };
    }

    /// Terminate the command AND everything it started, then reap the direct
    /// child. Idempotent. Works whether or not a `wait` on the child was
    /// canceled first — the situation every caller is in when it calls this.
    pub fn killAll(self: *Tree, io: std.Io) void {
        if (builtin.os.tag == .windows) {
            // The job handle names the tree independently of `child.id`, and
            // terminating an already-empty job is harmless.
            if (self.job) |job| _ = win32.TerminateJobObject(job, 1);
            self.child.kill(io); // no-op after a completed (or canceled) wait
            return;
        }
        if (self.reaped) return;
        // A negative pid signals the whole process group. `child.kill` signals
        // only the one pid (`Io.Threaded.childKillPosix`), which is exactly why
        // this extra shot is needed.
        _ = std.posix.system.kill(-self.pid, .KILL);
        if (self.child.id != null) {
            self.child.kill(io); // reaps the direct child
        } else {
            // A canceled `wait` got here first: std already nulled `child.id`
            // and closed the handles without reaping, so `child.kill` would
            // no-op and the child just killed would sit as a zombie for the
            // life of this process. Reap it ourselves; SIGKILL guarantees the
            // wait returns promptly.
            reapDirectChild(self.pid);
        }
        self.reaped = true;
    }

    /// Reap a child whose `wait` was canceled before it could (std 0.16 cancel
    /// cleanup nulls `child.id` without reaping). Only ever called after the
    /// group SIGKILL, so the wait cannot block. EINTR (the io's own SIG.IO
    /// wakeups) is the one errno worth retrying; anything else means there is
    /// nothing left to reap.
    fn reapDirectChild(pid: std.posix.pid_t) void {
        var status: if (builtin.link_libc) c_int else u32 = undefined;
        while (true) switch (std.posix.errno(std.posix.system.wait4(pid, &status, 0, null))) {
            .INTR => continue,
            else => return,
        };
    }

    /// Release the job handle. Nothing is killed here — the job carries no
    /// limits, so whatever the command deliberately left running keeps running
    /// (see `Tree`). The job object itself goes away once its last process exits.
    pub fn deinit(self: *Tree) void {
        if (builtin.os.tag == .windows) {
            if (self.job) |job| {
                windows.CloseHandle(job);
                self.job = null;
            }
        }
    }
};

/// How a bounded wait ended: the child exited on its own, or the budget did.
pub const Waited = union(enum) {
    term: std.process.Child.Term,
    timed_out,
};

/// Runs `child.wait` under a wall-clock budget. `null` waits forever.
///
/// The wait runs as its own task and reports through `Waiter` rather than
/// through the `Select` union, because the two answers are not symmetric: on a
/// timeout the loser must still be asked whether it nevertheless reaped the
/// child. If the process exited in the same instant the budget expired,
/// `outcome` holds its `Term` and this reports a normal exit, not a timeout.
///
/// What the caller does with a timeout is `Tree.killAll` — the command's whole
/// process tree, not just the direct child.
pub fn waitBounded(io: std.Io, child: *std.process.Child, timeout_ms: ?u32) !Waited {
    const ms = timeout_ms orelse return .{ .term = try child.wait(io) };

    var waiter: Waiter = .{ .io = io, .child = child };
    const Race = union(enum) { waited: void, expired: void };
    var buf: [2]Race = undefined;
    var sel: std.Io.Select(Race) = .init(io, &buf);
    sel.concurrent(.expired, sleepMs, .{ io, ms }) catch return .{ .term = try child.wait(io) };
    sel.concurrent(.waited, Waiter.run, .{&waiter}) catch {
        sel.cancelDiscard();
        return .{ .term = try child.wait(io) };
    };
    const first = sel.await() catch |err| {
        sel.cancelDiscard();
        return err;
    };
    sel.cancelDiscard(); // cancels and JOINS the loser, so `waiter` is settled
    if (waiter.outcome) |outcome| return .{ .term = try outcome };
    // The wait did not complete. Normally that means the budget expired; if
    // the wait task is what finished, it finished by being canceled, which is
    // this whole call being canceled — not a timeout.
    if (first == .waited) return error.Canceled;
    return .timed_out;
}

/// Owns the one `child.wait` call so its result survives the task boundary.
/// `outcome` stays null exactly when the wait never completed — i.e. it was
/// canceled mid-wait and the child is still ours to kill.
const Waiter = struct {
    io: std.Io,
    child: *std.process.Child,
    outcome: ?std.process.Child.WaitError!std.process.Child.Term = null,

    fn run(self: *Waiter) void {
        const result = self.child.wait(self.io);
        // A canceled wait never reaped, so leave `outcome` null: the child is
        // still alive and still the caller's to kill.
        if (result) |_| {} else |err| {
            if (err == error.Canceled) return;
        }
        self.outcome = result;
    }
};

fn sleepMs(io: std.Io, ms: u32) void {
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}
