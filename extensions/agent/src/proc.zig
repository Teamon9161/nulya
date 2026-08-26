//! Running `nulya` as a child process, and reading what it said.
//!
//! Every tool in this package talks to the kernel the same way: spawn the
//! binary that spawned us (`NULYA_EXE`, DESIGN §7.6), capture both streams,
//! read the exit code. It lives here rather than in `main.zig` because the
//! runner layer (`runners.zig`) makes the same calls — a delegation is started
//! by the `agent` tool and driven by the `run` tool, in two processes, and
//! "how do we call nulya" must be one answer for both.

const std = @import("std");

const max_child_output: usize = 4 << 20;

pub const Run = struct { code: u8, stdout: []u8, stderr: []u8 };

/// One `nulya <args…>` invocation, in this process's working directory — which
/// is the workspace, because that is where the host spawns an extension
/// (DESIGN §7.6). Output is captured, never inherited: stdout here is data.
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
