//! Running `nulya` as a child process, and reading what it said.
//!
//! Every tool in this package talks to the kernel the same way: spawn the binary
//! that spawned us (`NULYA_EXE`), capture both streams, read the exit code. A
//! delegation is started by the `agent` tool and driven by the `run` tool, in
//! two processes, so "how do we call nulya" must be one answer for both.

const std = @import("std");

const max_child_output: usize = 4 << 20;

pub const Run = struct { code: u8, stdout: []u8, stderr: []u8 };

/// One `nulya <args…>` invocation, in this process's working directory — which is
/// the workspace, because that is where the host spawns an extension. Output is
/// captured, never inherited: stdout here is data.
pub fn run(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Run {
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_child_output),
        .stderr_limit = .limited(max_child_output),
    });
    return .{
        .code = switch (result.term) {
            .exited => |c| c,
            else => 1,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

const max_detail_bytes: usize = 400;

/// What a failed child said, trimmed to something quotable. stderr first (that
/// is where the CLI writes diagnostics), stdout as the fallback.
pub fn detail(r: Run) []const u8 {
    const err = std.mem.trim(u8, r.stderr, " \t\r\n");
    const said = if (err.len != 0) err else std.mem.trim(u8, r.stdout, " \t\r\n");
    if (said.len == 0) return "no output";
    return said[said.len -| max_detail_bytes..];
}

pub fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const at = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    return trimmed[0..at];
}

// ── starting the task that drives a delegation ──────────────────────────────

/// `agent@<version>` for the version running right now.
///
/// A frozen extension binary lives at `<root>/<id>/versions/<v>/bin/<id>`, so the
/// version is two directories up from this executable. Named rather than left to
/// `current`: this package is never activated — it is brought into a session with
/// `--with` — so there is no `current` to fall back on.
pub fn selfRef(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    const exe = std.process.executablePathAlloc(io, alloc) catch return "agent";
    const bin_dir = std.fs.path.dirname(exe) orelse return "agent";
    const version_dir = std.fs.path.dirname(bin_dir) orelse return "agent";
    const version = std.fs.path.basename(version_dir);
    if (!std.mem.startsWith(u8, version, "v-")) return "agent";
    return std.fmt.allocPrint(alloc, "agent@{s}", .{version});
}

/// Start the background task that drives one delegation.
///
/// It belongs to the PARENT, so its report is deposited as a `note` into the
/// parent's inbox when it ends. Each round gets a new `t<N>`: nothing is reused,
/// nothing is resumed, and two reports are two events in the parent's ledger.
///
/// TWO ARGUMENTS, and that is the whole command. Everything else about a
/// delegation — which harness, which remote conversation, what it may do, how
/// many steps a round may take — is in its RECORD, which `runner.run` reads.
/// Copying those facts onto a command line would make the record advisory, and
/// would put the remote handle — which an external runner may return as ANY
/// string — inside a shell command.
///
/// `depth` is the exception and stays an argument: it is a fact about this CHAIN
/// of delegations, not about the one being driven, and the same delegation driven
/// from two depths is two different answers to "is this a cycle".
pub fn startDelegationTask(
    alloc: std.mem.Allocator,
    io: std.Io,
    exe: []const u8,
    self_ref: []const u8,
    parent: []const u8,
    delegation: []const u8,
    depth: u32,
) !Run {
    // Quoted: the executable path may contain spaces, and the command is handed
    // to a shell by the supervisor. Nothing else in it can carry one — a
    // delegation id is `d-<hex>` and a depth is a number.
    const cmd = try std.fmt.allocPrint(
        alloc,
        "\"{s}\" ext run {s} run --arg delegation={s} --arg depth={d}",
        .{ exe, self_ref, delegation, depth },
    );
    return run(alloc, io, &.{ exe, "task", "run", "--session", parent, "--", cmd });
}
