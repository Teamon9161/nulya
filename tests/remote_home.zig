//! A transport that gives the agent a HOME of its own.
//!
//! `nulya ext push` copies a version into the far machine's USER store, and the
//! only way to test that is to have a far machine whose user store is somewhere
//! else. Offline, "the far machine" is this very binary over a pipe
//! (`remote:exec:`), which inherits the harness's environment — including
//! `NULYA_HOME`, so both ends resolve the same user store and the test would be
//! asserting about one directory while claiming two.
//!
//! So this stands where `ssh` or `wsl.exe` stands: it spawns the command it was
//! given with one variable added, wires the pipes straight through, and exits
//! with the child's code. It is a transport, not a fake peer.
//!
//!     remote:exec:<this binary> <home> <nulya>   →   NULYA_HOME=<home> nulya remote serve
//!
//! The argv shape is fixed by `exec:` having no quoting (`remote.launcherArgv`):
//! everything is space-separated words, and the launcher appends `remote serve`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(alloc);
    if (argv.len < 3) {
        std.debug.print("usage: remote_home <home> <command> [args…]\n", .{});
        return error.MissingArguments;
    }

    const env = init.environ_map;
    try env.put("NULYA_HOME", argv[1]);

    // Inherited stdio: this process IS the channel's middle, so the frames must
    // pass through untouched — the same thing `ssh` does for a real remote.
    var child = try std.process.spawn(io, .{
        .argv = argv[2..],
        .environ_map = env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}
