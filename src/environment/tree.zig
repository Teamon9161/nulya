//! The OS glue around a child process: spawn it so its whole TREE can be
//! terminated, and wait for it under a wall-clock budget.
//!
//! `environment.zig` owns the seams (what a shell / extension run IS, which
//! dialect, which env survives); this file owns the platform mechanics those
//! seams need and nothing else — job objects on Windows, process groups on
//! POSIX, and the bounded wait that turns a timeout into an actual kill rather
//! than only a label.

const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

/// The kernel32 job-object calls `std.os.windows` does not declare (0.16 ships
/// only `CreateProcessW` there). A job object is the only reliable way to
/// terminate a process TREE on Windows, so the three calls plus `ResumeThread`
/// are declared locally. Analyzed lazily — nothing here is referenced off
/// Windows, so the externs never reach a POSIX link.
///
/// The job carries NO limits: it is a handle on the tree for `TerminateJobObject`
/// and nothing else. In particular not `KILL_ON_JOB_CLOSE`, which would make a
/// NORMAL return kill the tree (see `Tree`), so `SetInformationJobObject` is not
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
/// The rule is the same on both, and it is deliberately narrow: **terminating is
/// what kills the tree; returning normally does not.** The job is created with NO
/// limits — notably not `KILL_ON_JOB_CLOSE`, which would kill everything the
/// command started the moment `deinit` closed the handle. That would both diverge
/// from POSIX (which only ever signals on timeout / cancel) and destroy a
/// legitimate pattern: `some-server >/dev/null 2>&1 &` in one shell call, used by
/// the next. Nothing is lost by dropping it — the error paths are already covered
/// by the callers' `killAll` (`defer if (!child_reaped)` / `errdefer`).
///
/// A detached background process must still redirect its stdio, or the call
/// blocks until it exits: it inherits the pipe write-ends, and the drain reads
/// both pipes to EOF. That is pre-existing drain behavior, not something the tree
/// introduced.
///
/// If the OS refuses a job object (an older Windows' nested-job restriction, or
/// nulya itself running inside a restrictive job), this degrades to the plain
/// single-process kill and says so once: a shell that runs is worth more than a
/// guarantee about its grandchildren.
pub const Tree = struct {
    child: std.process.Child,
    /// Windows: the job the child and its descendants belong to, or null when
    /// the OS refused one. POSIX needs no handle — the group IS the child's pid.
    job: if (builtin.os.tag == .windows) ?windows.HANDLE else void,

    pub fn spawn(io: std.Io, options: std.process.SpawnOptions) !Tree {
        if (builtin.os.tag != .windows) {
            var opts = options;
            opts.pgid = 0; // become a group leader, so `killAll` can signal the group
            return .{ .child = try std.process.spawn(io, opts), .job = {} };
        }

        // Create the job FIRST: if the OS refuses one, spawn the ordinary way
        // rather than suspending a child that would then need resuming anyway.
        const job = win32.CreateJobObjectW(null, null) orelse {
            std.debug.print("nulya: no job object available; a timed-out or canceled command can only kill its direct child\n", .{});
            return .{ .child = try std.process.spawn(io, options), .job = null };
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
            return .{ .child = child, .job = null };
        }
        return .{ .child = child, .job = job };
    }

    /// Terminate the command AND everything it started, then reap the direct
    /// child so the caller's bookkeeping (`child.id`, the pipe handles) is left
    /// exactly as `child.kill` alone used to leave it. Idempotent.
    pub fn killAll(self: *Tree, io: std.Io) void {
        if (self.child.id) |id| {
            if (builtin.os.tag == .windows) {
                if (self.job) |job| _ = win32.TerminateJobObject(job, 1);
            } else {
                // A negative pid signals the whole process group. `child.kill`
                // signals only the one pid (`Io.Threaded.childKillPosix`), which
                // is exactly why this extra shot is needed.
                _ = std.posix.system.kill(-id, .KILL);
            }
        }
        self.child.kill(io); // idempotent; reaps the direct child
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

/// Runs `child.wait` under a wall-clock budget. `null` waits forever (the
/// pre-timeout behavior, still used by tests).
///
/// The wait runs as its own task and reports through `Waiter` rather than
/// through the `Select` union, because the two answers are not symmetric: on
/// a timeout the loser must be asked whether it nevertheless reaped the
/// child. It usually did not — the child is still running, which is the whole
/// point — but if the process exited in the same instant the budget expired,
/// `outcome` holds its `Term` and this reports a normal exit instead of a
/// timeout. Cancellation is unchanged: `await` returns `error.Canceled`, the
/// tasks are joined, and the caller kills + drains exactly as before.
///
/// What the caller does with a timeout is `Tree.killAll` — the command's whole
/// process tree, not just the direct child (see `Tree`), which is what makes
/// the budget actually end the step rather than only label it.
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
