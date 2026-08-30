//! The build-target vocabulary: the two words a version's identity records
//! (DESIGN §7.4).
//!
//! A compiled version id is `hash(snapshot + compiler + target)`, and `target`
//! has always been the two words `<arch>-<os>` — never a full triple. So this
//! module speaks exactly those two words: `ext build --target` accepts them, the
//! seal records them, and a donor lookup matches on them. Taking a full zig
//! triple at the CLI would put a third word into a key the store compares
//! byte for byte, and `x86_64-linux-musl` would then be a DIFFERENT version from
//! the `x86_64-linux` a native build on that machine writes.
//!
//! The abi half is therefore chosen here rather than asked for — one answer per
//! os, for EVERY build of that os, cross or not:
//!
//!   linux   -> musl   statically linked; no glibc version to match
//!   windows -> gnu    what a native zig build on Windows already uses
//!   macos   -> none   zig's own libSystem stubs; no SDK needed
//!
//! **The two words decide the compile, they do not merely describe it.** A
//! version id names "these package bytes, built for this target, by this
//! compiler", so two builds recording the same two words must issue the same
//! compiler invocation. That is what `effectiveTriple` is for: a build that
//! named no target is still given this host's own triple, so it is the same
//! invocation a cross build for those words would be — same abi, same baseline
//! cpu.
//!
//! It was not always so, and the reason the old arrangement had to go is worth
//! keeping. A native build used to be left native: it detected the machine's own
//! abi (glibc on Linux) while a cross build for the same two words picked musl,
//! and both recorded `x86_64-linux`. Inside ONE store that never showed, because
//! the reuse path (`build_ext.findMatchingVersion`) finds whichever copy is
//! already there and builds nothing. But version ids leave a store: `ext push`
//! asks the far machine "have you got this id" and it answers by id alone, and
//! `exec_version` (DESIGN §3.4) names one id as the implementation that serves a
//! call over there. Two stores could then hold one id over two builds that
//! behave differently — one needing a glibc that machine may not have.
//!
//! **What the two words still do not distinguish.** Not the exact bytes: two
//! machines running the same compiler for the same target can differ, and
//! nothing here promises otherwise. What an id fixes is the invocation — one
//! behavioural equivalence class — and every machine re-validates `.sealed`
//! against the bytes IT holds (a donor copy, a pushed copy), so nothing ever
//! runs bytes it did not verify.
//!
//! Nor the HOST, and that is the exception `effectiveTriple` keeps: a machine
//! whose own pair is outside the vocabulary below (riscv64-linux, say) is left
//! native, because `--target` cannot spell its words — so no cross build can
//! collide with what it produces, and it must still be able to build for itself.
//!
//! The alternative — putting the abi, or the host, into the id — buys a
//! distinction nobody asked a question about and costs the property the whole
//! store rests on: one id, one answer to "have I got this already".

const std = @import("std");
const builtin = @import("builtin");

/// The architectures `--target` accepts. A closed set, because every member is
/// a promise that this build can produce that binary.
pub const Arch = enum { x86_64, aarch64 };

/// The operating systems `--target` accepts.
pub const Os = enum { linux, windows, macos };

pub const Target = struct {
    arch: Arch,
    os: Os,

    /// The two words, exactly as they enter the version id and the seal.
    pub fn words(self: Target) []const u8 {
        return switch (self.os) {
            inline else => |os| switch (self.arch) {
                inline else => |arch| @tagName(arch) ++ "-" ++ @tagName(os),
            },
        };
    }

    /// What `zig build-exe -target` is given. The abi is this module's choice,
    /// per the table at the top.
    pub fn zigTriple(self: Target) []const u8 {
        return switch (self.os) {
            inline else => |os| switch (self.arch) {
                inline else => |arch| @tagName(arch) ++ "-" ++ comptime abi(os),
            },
        };
    }

    pub fn exeSuffix(self: Target) []const u8 {
        return exeSuffixFor(self.words());
    }
};

fn abi(comptime os: Os) []const u8 {
    return switch (os) {
        .linux => "linux-musl",
        .windows => "windows-gnu",
        .macos => "macos-none",
    };
}

/// This machine's own two words — what a build with no `--target` records.
///
/// Built from `builtin` rather than from the enums above on purpose: it must
/// name whatever this binary actually runs on, including a pair `--target` does
/// not offer. Which is also why `exeSuffixFor` below takes the raw words: it has
/// to answer for a seal written by any host, not only for a parsed `Target`.
pub const host: []const u8 = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

/// The accepted spellings, in the one place a refusal can quote them.
pub const vocabulary = "<arch>-<os>, arch = x86_64 | aarch64, os = linux | windows | macos";

/// What `zig build-exe -target` is given for a build that named `requested`, or
/// null for "compile natively, pass no `-target` at all".
///
/// The one place a build's compiler invocation is decided, so that the two words
/// a version id records determine it (module header). A named target answers
/// with its own triple; an unnamed one answers with this host's, which is only
/// spellable when the host's pair is in the vocabulary above — outside it, null.
pub fn effectiveTriple(requested: ?Target) ?[]const u8 {
    return tripleFor(requested, host);
}

/// `effectiveTriple` with the host's words handed in, so the branch that depends
/// on which machine is running can be exercised for machines that are not.
fn tripleFor(requested: ?Target, host_words: []const u8) ?[]const u8 {
    if (requested) |t| return t.zigTriple();
    const parsed = parse(host_words) catch return null;
    return parsed.zigTriple();
}

/// Parse the two words. Unknown either half is a refusal, never a guess: a
/// mistyped target that silently became something else would produce a version
/// whose id says one machine and whose bytes are for another.
pub fn parse(spec: []const u8) error{UnknownTarget}!Target {
    const dash = std.mem.lastIndexOfScalar(u8, spec, '-') orelse return error.UnknownTarget;
    const arch = std.meta.stringToEnum(Arch, spec[0..dash]) orelse return error.UnknownTarget;
    const os = std.meta.stringToEnum(Os, spec[dash + 1 ..]) orelse return error.UnknownTarget;
    return .{ .arch = arch, .os = os };
}

/// The executable suffix a version built for `target_words` carries on its
/// `bin/<entry>`.
///
/// A property of the TARGET, not of the machine asking: a version cross-built
/// for Windows has `bin/x.exe` wherever it is stored, and one built for Linux
/// has `bin/x` even on a Windows host. That is why validation reads it off the
/// seal (`integrity.openVersion`) instead of off `builtin`.
///
/// Words this module does not know — a host pair outside the two enums, or the
/// empty string a data/script version records — answer "no suffix", which for
/// the empty case is the only right answer (there is no binary) and for the
/// others is what every non-Windows platform wants anyway.
pub fn exeSuffixFor(target_words: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, target_words, '-') orelse return "";
    return if (std.mem.eql(u8, target_words[dash + 1 ..], @tagName(Os.windows))) ".exe" else "";
}

test "a target's words are what enters the id, and its triple is what the compiler is told" {
    const linux: Target = .{ .arch = .x86_64, .os = .linux };
    try std.testing.expectEqualStrings("x86_64-linux", linux.words());
    try std.testing.expectEqualStrings("x86_64-linux-musl", linux.zigTriple());
    try std.testing.expectEqualStrings("", linux.exeSuffix());

    const win: Target = .{ .arch = .aarch64, .os = .windows };
    try std.testing.expectEqualStrings("aarch64-windows", win.words());
    try std.testing.expectEqualStrings("aarch64-windows-gnu", win.zigTriple());
    try std.testing.expectEqualStrings(".exe", win.exeSuffix());

    // Round trip: the words a target prints are the words `--target` accepts.
    for ([_]Target{ linux, win, .{ .arch = .aarch64, .os = .macos } }) |t| {
        try std.testing.expectEqual(t, try parse(t.words()));
    }

    // This machine names itself in the same shape, whatever it is.
    try std.testing.expect(std.mem.indexOfScalar(u8, host, '-') != null);
}

test "an unrecognized target is refused rather than guessed at" {
    // A full triple is the likeliest mistake, and it must NOT quietly become
    // `x86_64-linux`: the third word would be dropped from a key the store
    // compares byte for byte.
    for ([_][]const u8{ "x86_64-linux-musl", "x86_64", "linux", "", "x86_64-plan9", "riscv64-linux", "X86_64-LINUX" }) |bad| {
        try std.testing.expectError(error.UnknownTarget, parse(bad));
    }
}

// The property the version id rests on: the two words a build records decide
// which compiler invocation produced it. So a build that named nothing must ask
// for the same triple a build that named this host's words would.
test "a build that names no target still compiles for this host's words, when they are words --target can spell" {
    // Named: its own triple, whoever is asking.
    try std.testing.expectEqualStrings(
        "x86_64-linux-musl",
        tripleFor(.{ .arch = .x86_64, .os = .linux }, "aarch64-macos").?,
    );

    // Unnamed, host inside the vocabulary: the host's triple, not native.
    try std.testing.expectEqualStrings("aarch64-macos-none", tripleFor(null, "aarch64-macos").?);
    try std.testing.expectEqualStrings("x86_64-windows-gnu", tripleFor(null, "x86_64-windows").?);

    // Unnamed, host outside it: native, because `--target` could not spell this
    // machine's words — nothing can cross-build for it, and it must still be
    // able to build for itself.
    try std.testing.expect(tripleFor(null, "riscv64-linux") == null);

    // And whatever this machine is, the two answers agree with each other.
    const parsed_host = parse(host) catch null;
    if (parsed_host) |t| {
        try std.testing.expectEqualStrings(t.zigTriple(), effectiveTriple(null).?);
    } else {
        try std.testing.expect(effectiveTriple(null) == null);
    }
}

test "the exe suffix follows the target, not the machine reading it" {
    try std.testing.expectEqualStrings(".exe", exeSuffixFor("x86_64-windows"));
    try std.testing.expectEqualStrings("", exeSuffixFor("x86_64-linux"));
    // A data or script version records no target and has no binary either.
    try std.testing.expectEqualStrings("", exeSuffixFor(""));
    // A host outside the `--target` vocabulary still gets an answer: seals are
    // written by whatever machine built them.
    try std.testing.expectEqualStrings("", exeSuffixFor("riscv64-freebsd"));
}
