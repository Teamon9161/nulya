//! `nulya task …`'s remote-machine half: talking to another workspace's
//! supervisors over an already-open channel, and turning what they answer
//! into the same `Row` a local task reads as.
//!
//! `task.zig` owns naming, `status.json` and every verb; it reaches in here
//! only through `Far` and `readRemoteRow`. A task's machine is `Far.linkFor`'s
//! answer — that session's frozen header, not a guess made per call — so no
//! verb can disagree with where a task started.

const std = @import("std");
const environment = @import("../environment.zig");
const ledger = @import("../ledger.zig");
const launch = @import("../launch.zig");
const remote = @import("../environment/remote/mod.zig");
const task = @import("task.zig");

// ── Tasks on another machine ────────────────────────────────────────────────
//
// A remote session's tasks are split down one line: the far machine holds the
// COMMAND — supervisor, log, status, lease — and this one holds the NAME and
// the DELIVERY, because the name is what the ledger speaks and the ledger is
// here. So every reading verb in `task.zig` asks that machine about the tasks
// it started there and turns any undelivered finished report into the
// report note the session's inbox already understands; a driver still
// sees only an inbox event at a step boundary.
//
// Delivery is done by whichever verb asks first — `task list`, `task wait`,
// `task status`, or a `session step` over its own already-open channel —
// since nobody over there can deposit, so the next question asked IS the
// moment. It is idempotent twice over (the `delivered` marker here, the
// ledger's `origin` column behind it), so several askers cost nothing.

/// The machines this verb has had to ask, one channel each. Opened lazily —
/// a `task list --session <local>` opens none — and closed when the verb ends.
///
/// A machine that does not answer costs ONE attempt, not one per task: the
/// failure is remembered, and its tasks then read `unreachable`.
pub const Far = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Pointers, not values: a `Channel` holds a reader wound around its own
    /// buffer, so it may not be moved — and an `ArrayList` of them would move
    /// them all the first time a second machine turned up.
    links: std.ArrayList(*Link),
    /// A channel someone else already opened, and the spec it reaches.
    /// Borrowed, never closed here. Keyed by SPEC, not by session: a retargeted
    /// task still belongs to the machine its OWNER was frozen to, so "can this
    /// be reused" is a question about the machine.
    lent_spec: []const u8 = "",
    lent: ?*remote.Channel = null,

    const Link = struct {
        session: []u8,
        /// Empty when this session's commands run here: nothing to ask.
        spec: []u8,
        /// The far workspace, or "." — what the frames carry as `cwd`.
        cwd: []u8,
        ch: ?remote.Channel,
        /// We tried to reach that machine and could not. Distinct from "this
        /// session is not remote": one is silence, the other is local.
        unreached: bool,
    };

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Far {
        return .{ .alloc = alloc, .io = io, .links = .empty };
    }

    pub fn deinit(self: *Far) void {
        for (self.links.items) |l| {
            if (l.ch) |*ch| ch.deinit();
            self.alloc.free(l.session);
            self.alloc.free(l.spec);
            self.alloc.free(l.cwd);
            self.alloc.destroy(l);
        }
        self.links.deinit(self.alloc);
    }

    /// What is known about where `session_id`'s tasks run. The answer comes
    /// from that session's frozen HEADER — the one place "where does this run"
    /// is recorded — so a reading verb cannot disagree with the step that
    /// started the task.
    fn linkFor(self: *Far, session_id: []const u8) !*Link {
        for (self.links.items) |l| {
            if (std.mem.eql(u8, l.session, session_id)) return l;
        }
        const link = try self.alloc.create(Link);
        errdefer self.alloc.destroy(link);
        link.* = .{
            .session = try self.alloc.dupe(u8, session_id),
            .spec = try self.alloc.dupe(u8, ""),
            .cwd = try self.alloc.dupe(u8, "."),
            .ch = null,
            .unreached = false,
        };
        errdefer {
            self.alloc.free(link.session);
            self.alloc.free(link.spec);
            self.alloc.free(link.cwd);
        }

        const spath = try launch.sessionPath(self.alloc, session_id);
        defer self.alloc.free(spath);
        var hdr = try ledger.readHeader(self.alloc, self.io, std.Io.Dir.cwd(), spath);
        defer hdr.deinit();
        if (launch.isRemoteSpec(hdr.value.environment)) {
            self.alloc.free(link.spec);
            link.spec = try self.alloc.dupe(u8, environment.normalizeExecSpec(hdr.value.environment));
            if (hdr.value.remote_workspace.len != 0) {
                self.alloc.free(link.cwd);
                link.cwd = try self.alloc.dupe(u8, hdr.value.remote_workspace);
            }
        }
        try self.links.append(self.alloc, link);
        return link;
    }

    /// Hand this collector a channel the caller already has open, for whichever
    /// machine `session_id` was frozen to. The channel stays the caller's. The
    /// spec comes from `linkFor` — that session's own header — so lending
    /// cannot introduce a second answer to "where does this run".
    fn lend(self: *Far, session_id: []const u8, ch: *remote.Channel) !void {
        const link = try self.linkFor(session_id);
        if (link.spec.len == 0) return; // a local session has no machine to lend
        self.lent_spec = link.spec;
        self.lent = ch;
    }

    /// The open channel to that session's machine, or null when there is nothing
    /// to ask (local) or nothing answering (unreachable, already reported).
    pub fn channelFor(self: *Far, session_id: []const u8) !?*remote.Channel {
        const link = try self.linkFor(session_id);
        if (link.spec.len == 0 or link.unreached) return null;
        if (self.lent) |ch| {
            if (std.mem.eql(u8, link.spec, self.lent_spec)) return ch;
        }
        if (link.ch) |*ch| return ch;
        const l = remote.parseSpec(link.spec) catch {
            link.unreached = true;
            return null;
        };
        link.ch = remote.Channel.connect(self.alloc, self.io, l, launch.version, .default) catch {
            link.unreached = true;
            return null;
        };
        return &link.ch.?;
    }

    pub fn isRemote(self: *Far, session_id: []const u8) !bool {
        return (try self.linkFor(session_id)).spec.len != 0;
    }

    pub fn cwdFor(self: *Far, session_id: []const u8) ![]const u8 {
        return (try self.linkFor(session_id)).cwd;
    }
};

/// What one far task's own machine had to say. `bytes` is its `status.json`,
/// verbatim, and empty means its supervisor has not written one yet — the same
/// `starting` a local directory with no status reports. `lease_held` is that
/// machine's own answer to "is a supervisor still holding this task's lease",
/// carried in the SAME poll (`TaskSnapshot.lease_held`) so a far `lost` costs no
/// second question — null only when the far agent predates the column.
/// `report_present` says that machine is still holding a report file for this
/// task; whether THIS machine has taken it is a different question, answered
/// here by the `delivered` marker.
const FarAnswer = union(enum) {
    status: struct { bytes: []const u8, lease_held: ?bool, report_present: bool },
    /// This host could not get an answer: the machine did not answer, or
    /// refused the question. Nothing is known about the task — not that it is
    /// running, not that it died.
    unreached,
};

/// Ask one machine about one task, and deliver its report if it left one that
/// has not been delivered yet.
///
/// `host_dir` is the task's directory on THIS machine — where `notify` and
/// `delivered` live. The returned bytes belong to `arena`.
///
/// `deliver` false asks the state and nothing else. Depositing is a caller's
/// business, not a reader's: `session prune` asks this question while holding a
/// deposit lease, and delivering into that very session would then wait for a
/// lease this process itself is holding.
fn pollAndDeliver(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    ch: *remote.Channel,
    cwd: []const u8,
    session_id: []const u8,
    slot: []const u8,
    host_dir: []const u8,
    full: []const u8,
    deliver: bool,
) !FarAnswer {
    const snap = remote.pollTaskOn(ch, cwd, full) catch return .unreached;
    const status_bytes = try arena.dupe(u8, snap.status);
    const answer: FarAnswer = .{ .status = .{
        .bytes = status_bytes,
        .lease_held = snap.lease_held,
        .report_present = snap.report.len != 0,
    } };
    if (!deliver) return answer;
    if (snap.report.len == 0 or status_bytes.len == 0) return answer;
    if (task.markerPresent(alloc, io, host_dir, task.delivered_file)) return answer;

    // The far side writes its report BEFORE it says `done` (the write order in
    // `runShellTask` above), so one poll can land in between: report present,
    // `status.json` still `running` with a null exit code. Depositing on
    // report-presence alone would read THAT status for the exit code — wrong,
    // and permanently, since `delivered` is then written and the correct `done`
    // is never looked at. `state == .done` is what finished means; a report
    // without one yet is simply asked about again later.
    const parsed = std.json.parseFromSlice(task.Status, alloc, std.mem.trim(u8, status_bytes, " \t\r\n"), task.json_opts) catch
        return answer;
    defer parsed.deinit();
    if (parsed.value.state != .done) return answer;

    task.depositReport(alloc, io, .{
        .dir = host_dir,
        .session_id = session_id,
        .slot = slot,
        .full = full,
        .exit_code = parsed.value.exit_code orelse 1,
        .text = snap.report,
    }) catch |err| switch (err) {
        // The session it reports into is gone. That machine answered fine, so
        // this is not `unreached`, and `delivered` must not be written.
        error.NoSuchSession => return answer,
        else => return err,
    };
    // Only after the deposit landed: a marker written first would lose the
    // report if this process died between the two.
    const marker = try std.fs.path.join(alloc, &.{ host_dir, task.delivered_file });
    defer alloc.free(marker);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "" });
    return answer;
}

/// `readRow`'s remote branch: same contract (arena-owned `?Row`, `deliver`
/// controls whether a finished report is turned into a deposit), reached only
/// once `task.zig` has already established `far.isRemote(ref.session)`.
pub fn readRemoteRow(arena: std.mem.Allocator, io: std.Io, far: *Far, ref: task.RowRef, deliver: bool) !?task.Row {
    var row: task.Row = .{
        .full = ref.full,
        .session = ref.session,
        .dir = ref.dir,
        .state = .@"unreachable",
        .status = null,
        .notify = ref.notify,
        .machine = (try far.linkFor(ref.session)).spec,
    };
    const ch = (try far.channelFor(ref.session)) orelse return row;
    const cwd = try far.cwdFor(ref.session);
    const answer = pollAndDeliver(far.alloc, arena, io, ch, cwd, ref.session, ref.slot, ref.dir, ref.full, deliver) catch
        FarAnswer.unreached;
    const outcome = switch (answer) {
        .unreached => return row,
        .status => |s| s,
    };
    // Its supervisor has not written a status yet: the same `starting` a
    // local directory with no status reports.
    if (outcome.bytes.len == 0) {
        row.state = .starting;
        return row;
    }
    const status = std.json.parseFromSliceLeaky(task.Status, arena, std.mem.trim(u8, outcome.bytes, " \t\r\n"), task.json_opts) catch
        return null;
    row.status = status;
    // The far lease answer rides the SAME `task-poll` round
    // (`TaskSnapshot.lease_held`, filled by that machine's own
    // `lease.taskHeld`): a done status wins outright, a free lease on a
    // not-done status is `lost`, and a held or unknown (older peer, no such
    // column) lease reports `running` — not knowing is not grounds to claim
    // the task died.
    row.state = if (status.state == .done)
        .done
    else if (outcome.lease_held == false)
        .lost
    else
        .running;
    // Asked after the poll, so a delivery this very call made counts: the
    // marker goes down only once the deposit landed.
    row.report_pending = outcome.report_present and row.state == .done and
        !task.markerPresent(far.alloc, io, ref.dir, task.delivered_file);
    return row;
}

/// Collect every finished-but-undelivered report of `session_id`'s tasks over
/// a channel that is ALREADY open — what `session step` does before it steps,
/// so a driver that never runs a `task` verb still gets its results.
///
/// This is `task list --session <id>` with the rows thrown away: which tasks
/// report into a session has exactly one answer (`task.collectRows`), and it
/// is not "the ones under this session's own directory" — a task another
/// session retargeted here reports here. `readRemoteRow` delivers on the way
/// past (`pollAndDeliver`), with each task's cwd taken from its OWNER's header.
///
/// The caller's channel is lent, not adopted: a task whose owner is frozen to
/// the same machine is polled over it, and an owner on a DIFFERENT machine
/// still costs a connection here.
///
/// Best effort: a report that cannot be fetched now is fetched by the next
/// asker, and a step must not fail because a task's machine hiccuped.
pub fn sweepRemoteReports(
    alloc: std.mem.Allocator,
    io: std.Io,
    ch: *remote.Channel,
    session_id: []const u8,
) void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var far: Far = .init(alloc, io);
    defer far.deinit();
    far.lend(session_id, ch) catch return;
    _ = task.collectRows(arena, io, &far, .{ .reports_into = session_id }) catch return;
}
