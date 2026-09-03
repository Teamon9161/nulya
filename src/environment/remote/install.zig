//! Putting nulya on the far machine, and finding it once it is there.
//!
//! The pure half of that: the exact shell text sent over the launcher's own
//! transport, and the decision about whether this build's own bytes can serve
//! as the far agent. The spawning lives next to the channel's other spawning
//! (`mod.zig`) — what is here is what a test can read without a machine.
//!
//! **Two facts make this small.** A nulya binary is statically linked and
//! carries its extensions and its own source inside it, so "install" is one
//! file and nothing else; and the host, when it runs on the same os and cpu as
//! the far machine, already HOLDS a byte-identical copy of what belongs over
//! there — the binary it is running. Nothing is compiled, downloaded or
//! unpacked in that case. A far machine that is something else needs a binary
//! built for it, which is why the host also carries its own checkout
//! (`selfbuild.zig`) — but building is the shell layer's job, and this file's
//! part in it is naming the machine.
//!
//! **Everything crosses as one shell command.** These are sent before there is
//! any agent to speak frames to, so they go through whatever shell the far side
//! greets a command with, and they must be plain POSIX: `$HOME` is expanded
//! THERE (the host does not know that path and must not guess it).

const std = @import("std");
const target_mod = @import("../../extension/target.zig");

/// The directory nulya owns on a far machine, and the file it puts there.
///
/// `$HOME` is unexpanded on purpose: it is the far shell's answer, not ours.
///
/// The name is NOT `nulya`, and there is no `bin/` around it, because that
/// machine's own user may run nulya too — a `~/.nulya/bin/nulya` would collide
/// with the copy they installed, and `~/.nulya/bin` is exactly the kind of
/// directory that ends up on a PATH, which would make somebody else's transport
/// artifact answer to `nulya` on their own machine. What lands here is one
/// file, named for the only thing it is: the far half of somebody's session.
pub const far_dir = "$HOME/.nulya";
pub const far_exe = far_dir ++ "/remote-agent";

/// Which copy of nulya the far shell is asked to run.
pub const Entry = enum {
    /// The copy nulya installs, with whatever is on PATH as the fallback — one
    /// command that resolves both, so the ordinary case is still one connection
    /// and a machine that was set up by hand keeps working untouched.
    installed_or_path,
    /// Bare `nulya`, resolved by the far PATH — the exact words every build
    /// before installs existed sent, down to having no `exec` in front of them:
    /// this rung exists for a far side whose shell is not POSIX (a Windows peer
    /// greeting commands with cmd.exe), and `exec` is not a word cmd.exe knows.
    path,
};

/// The far shell command that starts the agent.
///
/// The preferred form is `exec` twice with `&&`/`||` between them: the first
/// `exec` never returns when it succeeds, so the fallback runs only when the
/// test failed, and neither leaves a shell process sitting there for the life
/// of the session with nothing to do but wait.
pub fn serveCommand(entry: Entry) []const u8 {
    return switch (entry) {
        .installed_or_path => "[ -x \"" ++ far_exe ++ "\" ] && exec \"" ++ far_exe ++
            "\" remote serve || exec nulya remote serve",
        .path => "nulya remote serve",
    };
}

/// What the far machine is, in its own words. One round trip, and the only
/// question asked before anything is sent.
pub const probe_command = "uname -sm";

/// Land the bytes arriving on stdin as the far `nulya`, atomically.
///
/// The rename is what makes it atomic: a concurrent session launching the agent
/// sees either the old file or the new one, never a half-written one. `$$` keeps
/// two installs onto the same machine from writing the same temporary.
pub const install_command =
    "mkdir -p \"" ++ far_dir ++ "\" && cat > \"" ++ far_exe ++ ".$$\" && " ++
    "chmod 755 \"" ++ far_exe ++ ".$$\" && " ++
    "mv -f \"" ++ far_exe ++ ".$$\" \"" ++ far_exe ++ "\"";

/// The far machine, named in the vocabulary this repository already uses for
/// build targets. One table, so the machine an extension is compiled for and
/// the machine an agent is compiled for are spelled the same way — and the
/// triple a cross-build is given comes from it rather than being assembled here.
pub const Target = target_mod.Target;

/// Whether the far machine is the one this binary's own bytes already run on.
/// Compared as words rather than as a parsed pair, because a host outside the
/// vocabulary (a riscv64 developer) must answer "no" instead of failing to
/// answer at all.
pub fn isHost(far: Target) bool {
    return std.mem.eql(u8, far.words(), target_mod.host);
}

/// `uname -sm`'s two words as a target.
///
/// Unknown words are NOT guessed at: a machine whose name this build does not
/// know is a machine it cannot compile for either, and sending or building
/// something anyway would leave an unrunnable file on someone's disk.
pub fn parseUname(out: []const u8) ?Target {
    const line = std.mem.trim(u8, firstLine(out), " \t\r");
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const os_word = it.next() orelse return null;
    const arch_word = it.next() orelse return null;
    return .{
        .os = canonicalOs(os_word) orelse return null,
        .arch = canonicalArch(arch_word) orelse return null,
    };
}

fn firstLine(out: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, out, '\n') orelse out.len;
    return out[0..end];
}

/// `uname -s` has no word for Windows: the two named transports reach a POSIX
/// shell (wsl is a Linux, and an ssh to Windows answers this command with
/// nothing this understands), so a Windows far side is refused here rather than
/// half-supported.
fn canonicalOs(word: []const u8) ?target_mod.Os {
    if (std.ascii.eqlIgnoreCase(word, "Linux")) return .linux;
    if (std.ascii.eqlIgnoreCase(word, "Darwin")) return .macos;
    return null;
}

fn canonicalArch(word: []const u8) ?target_mod.Arch {
    if (std.ascii.eqlIgnoreCase(word, "x86_64") or std.ascii.eqlIgnoreCase(word, "amd64")) return .x86_64;
    if (std.ascii.eqlIgnoreCase(word, "aarch64") or std.ascii.eqlIgnoreCase(word, "arm64")) return .aarch64;
    return null;
}

test "the serve command prefers nulya's own copy and still falls back to PATH" {
    const preferred = serveCommand(.installed_or_path);
    // Both copies are reachable from the one command: that is the whole reason
    // a machine set up by hand does not break when installs arrive.
    try std.testing.expect(std.mem.indexOf(u8, preferred, far_exe) != null);
    try std.testing.expect(std.mem.indexOf(u8, preferred, "exec nulya remote serve") != null);
    // `$HOME` is not ours to expand.
    try std.testing.expect(std.mem.indexOf(u8, preferred, "$HOME") != null);
    // No `exec`, no test, no `$HOME`: cmd.exe understands none of those, and
    // this is the rung a peer running one still answers to.
    try std.testing.expectEqualStrings("nulya remote serve", serveCommand(.path));
}

test "the install command lands the file under one name only after it is whole" {
    const at = std.mem.indexOf(u8, install_command, "mv -f") orelse return error.NoRename;
    // chmod before the rename, or the visible file is briefly not executable.
    const chmod = std.mem.indexOf(u8, install_command, "chmod").?;
    try std.testing.expect(chmod < at);
    try std.testing.expect(std.mem.indexOf(u8, install_command, "$$") != null);
}

test "uname words become one machine's name, and an unknown one is refused" {
    try std.testing.expectEqual(Target{ .os = .linux, .arch = .x86_64 }, parseUname("Linux x86_64\n").?);
    try std.testing.expectEqual(Target{ .os = .macos, .arch = .aarch64 }, parseUname("Darwin arm64").?);
    // Same machine, another spelling.
    try std.testing.expectEqual(parseUname("Linux x86_64").?, parseUname("Linux amd64").?);
    // A shell that printed a banner first still answers on its first line only.
    try std.testing.expectEqual(Target{ .os = .linux, .arch = .aarch64 }, parseUname("Linux aarch64\nWelcome\n").?);

    for ([_][]const u8{ "SunOS sun4v", "Linux riscv64", "MINGW64_NT-10.0 x86_64", "Linux", "" }) |unknown| {
        try std.testing.expect(parseUname(unknown) == null);
    }
}

test "a far machine that is this one is recognized as this one" {
    // Not a literal target: the point is that one table names both sides, so a
    // peer reporting this machine's own words compares equal to it.
    const self = target_mod.parse(target_mod.host) catch return; // host outside the vocabulary
    try std.testing.expect(isHost(self));
    try std.testing.expect(!isHost(.{ .os = self.os, .arch = if (self.arch == .x86_64) .aarch64 else .x86_64 }));
}
