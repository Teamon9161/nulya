//! Execution Environment boundary.
//!
//! shell/extension execution goes through an `Environment`, never a raw process
//! spawn. This is the single seam that:
//!   1. picks the shell dialect (bash | powershell);
//!   2. sanitizes the child environment so host secrets (API keys, SSH agent,
//!      cloud creds) never reach an AI-authored subprocess;
//!   3. swaps `local` execution for sandbox/remote without touching a single
//!      line of tool code.
//!
//! Authority stays coupled to the environment: shell and extension share one
//! `session_authority`.

const std = @import("std");
const builtin = @import("builtin");
const tool = @import("tool.zig");
const emit = @import("emit.zig");
const ext_exec = @import("extension/exec.zig");
const protocol = @import("extension/protocol.zig");
const process_tree = @import("environment/tree.zig");
const testkit = @import("extension/testkit.zig");
const ext_store = @import("extension/store.zig");
const Tree = process_tree.Tree;
const waitBounded = process_tree.waitBounded;

/// The host process environment. std 0.16 removed the ambient global environ
/// (`.{ .block = .global }`): the OS block is handed to `main` via
/// `std.process.Init` and to the test runner via `std.testing.environ`, and
/// nowhere else. `main` registers its copy here once at startup.
var host_environ: std.process.Environ = .empty;
var host_environ_registered = false;

pub fn registerHostEnviron(env: std.process.Environ) void {
    host_environ = env;
    host_environ_registered = true;
}

/// The host environment as a fresh `Map` (caller deinits). Test builds fall back
/// to the test runner's environ; a production process whose main never
/// registered gets the EMPTY environment, never a hidden global.
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

/// WHERE a `shell` command runs.
///
/// A third axis: `Dialect` says which language the command is written in,
/// `config.EnvironmentBackend` says how confined it is, this says which
/// machine's shell reads it. A WSL distribution is neither narrower nor wider
/// than the host — it is ELSEWHERE, not a fourth `EnvironmentBackend` word.
///
/// **Only the `shell` builtin's commands move.** Extension processes, the task
/// supervisor, the extension store, the journals and every spill file stay on
/// the host — a `remote` shell does not make the harness remote. The
/// consequences are spelled out at `shellArgv`. Moving the WHOLE workspace
/// (including over ssh, `remote:ssh:<dest>`) is `--env remote:…`, a second
/// `Environment` implementation in `environment/remote/mod.zig`.
pub const ExecTarget = union(enum) {
    local,
    /// `wsl.exe [-d <distro>] -e bash -lc …`; an empty payload means WSL's
    /// default distribution.
    wsl: []const u8,
};

/// The spelling of an `ExecTarget`, in one place: it is what `session new
/// --env` takes, what the session header freezes, and what a supervisor is
/// handed on its command line.
pub const exec_target_syntax = "local | wsl | wsl:<distro>";

/// Parse the spec. Pure syntax — whether THIS host can reach the target is a
/// separate question (`execTargetSupportedOnHost`), because the two have
/// different fixes: a typo versus the wrong machine.
///
/// The returned payload borrows `spec`.
pub fn parseExecTarget(spec: []const u8) error{InvalidExecTarget}!ExecTarget {
    if (spec.len == 0 or std.mem.eql(u8, spec, "local")) return .local;
    if (std.mem.eql(u8, spec, "wsl")) return .{ .wsl = "" };
    if (std.mem.startsWith(u8, spec, "wsl:")) {
        const distro = spec["wsl:".len..];
        if (distro.len == 0) return error.InvalidExecTarget;
        return .{ .wsl = distro };
    }
    return error.InvalidExecTarget;
}

/// `wsl.exe` is a Windows program; nothing else can reach a WSL distribution.
pub fn execTargetSupportedOnHost(target: ExecTarget) bool {
    return switch (target) {
        .local => true,
        .wsl => builtin.os.tag == .windows,
    };
}

/// The spelling a session freezes: `local` and the empty string are the same
/// answer, and the header records the ABSENCE rather than the word, so a header
/// written before this column existed reads back identically. Everything else is
/// stored verbatim — the kernel does not rewrite what the operator typed.
pub fn normalizeExecSpec(spec: []const u8) []const u8 {
    return if (std.mem.eql(u8, spec, "local")) "" else spec;
}

/// A Windows path as a WSL distribution sees it: `C:\code\x` → `/mnt/c/code/x`.
///
/// Null when the path is not drive-lettered — a UNC share has no `/mnt/` name.
/// The caller then passes the path through UNTRANSLATED: `cd 'C:\…'` fails
/// inside the distro with the distro's own message, whereas dropping the `cd`
/// would run the command in some other directory and call it a success.
pub fn wslPath(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len < 2 or path[1] != ':' or !std.ascii.isAlphabetic(path[0])) return null;
    if (path.len > 2 and path[2] != '\\' and path[2] != '/') return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "/mnt/");
    try out.append(alloc, std.ascii.toLower(path[0]));
    for (path[2..]) |c| try out.append(alloc, if (c == '\\') '/' else c);
    return try out.toOwnedSlice(alloc);
}

/// The bash script a WSL command is wrapped in: enter the workspace as the
/// distribution sees it, then the command verbatim.
///
/// `|| exit 1` and a NEWLINE, not `;`: a `cd` that failed must not be followed
/// by the command running somewhere else, and a command whose first line is a
/// comment must not swallow what a `;` put after it.
fn wslScript(alloc: std.mem.Allocator, cwd: []const u8, command: []const u8) ![]u8 {
    const translated = try wslPath(alloc, cwd);
    defer if (translated) |t| alloc.free(t);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "cd ");
    try appendSingleQuoted(alloc, &out, translated orelse cwd);
    try out.appendSlice(alloc, " || exit 1\n");
    try out.appendSlice(alloc, command);
    return try out.toOwnedSlice(alloc);
}

/// Append `s` as one POSIX single-quoted word. Inside single quotes a shell
/// interprets nothing at all, so the only thing to handle is the quote itself:
/// close, escape one, reopen.
fn appendSingleQuoted(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(alloc, "'\\''") else try out.append(alloc, c);
    }
    try out.append(alloc, '\'');
}

/// A completed shell run. `stdout`/`stderr` are owned by the caller's allocator.
pub const ShellOutcome = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    /// The wall-clock budget ran out and the child was killed. `stdout`/`stderr`
    /// are then whatever had been captured before the kill: a timeout still
    /// returns the output it already has.
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
    /// Wall-clock cap for the command (`tool.Timeouts`). The `shell` tool always
    /// sets one; `null` runs unguarded and is for tests about something else.
    timeout_ms: ?u32 = null,
};

/// One oneshot extension invocation. `request_json` is this call's arguments
/// object, written to the child's stdin; `stdout` on return is exactly what the
/// child printed before exiting, which IS the tool's result — this seam never
/// interprets it.
///
/// It names an IDENTITY, not a path. Which file to spawn, which entry variant
/// this OS uses, which interpreter, and whether the version still matches its
/// seal are all answers only the machine holding the bytes can give, so they are
/// given there, by `extension/exec.zig`, on both sides of the seam. A host that
/// resolved a path here would verify its own copy while a different one ran.
pub const ExtensionRequest = struct {
    /// The extension, and the FROZEN VERSION that serves this call — for a
    /// session whose tools run elsewhere that is the header's `exec_version`.
    /// Chosen once at session freeze time and merely carried here.
    id: []const u8,
    version: []const u8,
    /// The tool name the frozen manifest declared; it reaches the child as
    /// `NULYA_TOOL`.
    tool: []const u8,
    cwd: []const u8,
    /// The arguments for this call: one compact JSON object (`{}` when there
    /// are none), written to stdin verbatim — and the sole source of the
    /// `NULYA_ARG_<k>` variables the executing side derives (`protocol.callEnv`).
    request_json: []const u8,
    max_output_bytes: usize,
    /// Wall-clock cap for the oneshot call (`tool.Timeouts`). `null` disables the
    /// guard; callers should only do that in controlled tests.
    timeout_ms: ?u32 = tool.Timeouts.extension_ms,
    /// Workspace-relative file the child may write UI-only presentation JSON
    /// into. It is not stdout and never reaches the model.
    ///
    /// A remote environment deliberately does NOT forward it: who READS a file
    /// decides which machine it lives on, and this one's reader is the front end,
    /// on the host. A package asked to render over there sees no presentation
    /// file and renders nothing, exactly as when the driver offers none.
    presentation_file: ?[]const u8 = null,
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

/// A command to run DETACHED, outliving the step process that asked for it.
/// Deliberately unlike `ShellRequest`: there is no capture cap (the whole output
/// goes to the task's log file), and `timeout_ms` has no default and no ceiling
/// — what ends such a task is `nulya task kill`.
pub const TaskRequest = struct {
    command: []const u8,
    cwd: []const u8,
    timeout_ms: ?u32 = null,
};

/// What starting a task tells the caller, immediately: which task this is and
/// where to watch it. Both strings are caller-owned.
pub const TaskStart = struct {
    /// The task's FULL name, `<session-id>/t<N>`. Full so that a task whose
    /// report was retargeted to another session still names itself
    /// unambiguously, and so no workspace-wide counter is needed.
    task_id: []u8,
    /// The log accumulating this task's stdout+stderr, relative to the workspace.
    log_path: []u8,

    pub fn deinit(self: TaskStart, alloc: std.mem.Allocator) void {
        alloc.free(self.task_id);
        alloc.free(self.log_path);
    }
};

/// The durable session an environment's background tasks belong to, when it has
/// one. Both halves are decided by the shell layer and handed down:
/// `session_path` is the file the supervisor deposits its report note into
/// (and whose stem names the task), `tasks_dir` is where this workspace keeps
/// that session's tasks (`launch.sessionTasksDir`). Absent means `startShellTask`
/// has nowhere to report to, and says so instead of guessing a session.
pub const SessionRef = struct {
    session_path: []const u8,
    tasks_dir: []const u8,
};

/// The environment handle carried in every tool's `ToolContext`. The vtable
/// covers process execution and dialect. Fixed-shape — nothing grows with the
/// conversation, so it is safe in `ToolContext`.
pub const Environment = struct {
    io: std.Io,
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        dialect: *const fn (ptr: *anyopaque) Dialect,
        runShell: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, req: ShellRequest) anyerror!ShellOutcome,
        runExtension: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, req: ExtensionRequest) anyerror!ExtensionOutcome,
        startShellTask: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, req: TaskRequest) anyerror!TaskStart,
        putWorkspaceFile: *const fn (ptr: *anyopaque, rel_path: []const u8, bytes: []const u8) anyerror!void,
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
    /// arrive here. `error.NoDurableSession` when this environment belongs to no
    /// session — there would be nowhere to report the result.
    pub fn startShellTask(self: Environment, alloc: std.mem.Allocator, req: TaskRequest) !TaskStart {
        return self.vtable.startShellTask(self.ptr, alloc, req);
    }

    /// Write `bytes` into this session's workspace at `rel_path`, creating the
    /// parent directories. The fourth verb, and the one `emit` spills through.
    ///
    /// `rel_path` is workspace-relative and spelled with `/` — it is the SAME
    /// string the model reads in the footer that points at the file. Where the
    /// bytes land and where the reader is sent are one string, on whichever
    /// machine the workspace is.
    ///
    /// No allocator: an implementation that needs one has its own, and every
    /// caller here is handing over bytes it already owns.
    pub fn putWorkspaceFile(self: Environment, rel_path: []const u8, bytes: []const u8) !void {
        return self.vtable.putWorkspaceFile(self.ptr, rel_path, bytes);
    }

    /// This environment as the sink `emit` spills through. `emit.FileSink` is
    /// the same shape as the vtable entry, so there is no adapter: if either
    /// signature moves, the compiler says so at this line.
    pub fn fileSink(self: Environment) emit.FileSink {
        return .{ .ptr = self.ptr, .writeFn = self.vtable.putWorkspaceFile };
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

/// The host environment as a child of this process may see it: every
/// secret-shaped variable stripped (`isSecretKey`), plus the one thing children
/// are ADDED (`NULYA_EXE`). Caller deinits.
///
/// One implementation, two callers: the local backend builds its children's
/// environment from this, and so does the remote backend's transport — so a
/// `wsl.exe` / `ssh` / `docker` process this harness starts can never be handed
/// a key, whatever `WSLENV` or `SendEnv` is set to. The remote agent runs this
/// same function on its own machine for its own children, so the denylist holds
/// on both ends without a second implementation.
pub fn sanitizedChildEnv(alloc: std.mem.Allocator, io: std.Io) !std.process.Environ.Map {
    var host = try hostEnvironMap(alloc);
    defer host.deinit();

    var sanitized: std.process.Environ.Map = .init(alloc);
    errdefer sanitized.deinit();
    var it = host.iterator();
    while (it.next()) |entry| {
        if (isSecretKey(entry.key_ptr.*)) continue;
        try sanitized.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // Children get to find the harness that spawned them: a driver written as
    // an extension has to run `nulya session append|step|new`, and it cannot
    // assume a `nulya` on PATH — the one that matters is THIS binary, not
    // whichever copy an installer left behind. An unknowable path (a deleted
    // binary, an exotic OS) leaves it unset: building an environment must never
    // fail over provenance.
    if (std.process.executablePathAlloc(io, alloc)) |exe_path| {
        defer alloc.free(exe_path);
        try sanitized.put("NULYA_EXE", exe_path);
    } else |_| {}

    return sanitized;
}

pub const LocalOptions = struct {
    /// Override the OS-derived shell dialect. Ignored when `exec` names a
    /// target: which shell runs a WSL command is the target's answer, not this
    /// host's.
    dialect: ?Dialect = null,
    /// The durable session background tasks started here belong to, when there
    /// is one. `session new`, `nulya demo` and the tests leave it null: nothing
    /// they do can start a task.
    session: ?SessionRef = null,
    /// Where `shell` commands run (`ExecTarget`), as its spec string — `""` is
    /// local. A string rather than the parsed union so this struct owns nothing;
    /// the environment keeps the ONE copy both the parsed payload and a
    /// supervisor's `--env` argument borrow from.
    exec: []const u8 = "",
    /// Where THIS machine keeps extension versions, in search order. Supplied by
    /// the shell layer: which directories may supply code is a configuration
    /// decision, and the kernel does not read config.
    ///
    /// Copied, and opened only when an extension is actually run — relative
    /// specs resolve against the workspace the CALL names, which is the far
    /// machine's workspace on a remote agent. Empty means this environment runs
    /// no extensions and refuses if asked.
    extension_store: []const u8 = "",
};

/// How many `t<N>` slots one session may hand out. High enough that no real
/// session reaches it, finite so a corrupted tasks directory cannot spin here.
const max_tasks_per_session: usize = 10_000;

/// One assembled shell invocation: the argv and whatever heap string it borrows.
pub const ShellCommandLine = struct {
    argv: []const []const u8,
    /// The one string a wrapping form allocates (powershell's encoding
    /// preamble, the WSL `cd` prefix); null for plain bash.
    owned_script: ?[]u8,

    pub fn deinit(self: ShellCommandLine, alloc: std.mem.Allocator) void {
        if (self.owned_script) |s| alloc.free(s);
    }
};

/// The `local` backend: runs in the host process with a sanitized child
/// environment. Shell authority == session authority, so the *only* enforced
/// boundary is that host secrets are stripped before they can reach a
/// subprocess. OS-level confinement arrives with the `sandbox` backend.
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
    /// The normalized `--env` spec, owned; null for `local`. It is both what a
    /// supervisor is handed (so a background command runs where the foreground
    /// one does) and the backing store for `target`'s payload.
    exec_spec: ?[]u8 = null,
    /// Where `shell` commands go. Payload borrows `exec_spec`.
    target: ExecTarget = .local,
    /// How `(id, version)` becomes something to spawn on this machine. Owned;
    /// opens nothing until the first extension call (`extension/exec.zig`).
    resolver: ext_exec.Resolver,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, opts: LocalOptions) !LocalEnvironment {
        var host = try hostEnvironMap(alloc);
        defer host.deinit();

        var sanitized = try sanitizedChildEnv(alloc, io);
        errdefer sanitized.deinit();

        const bash_exe = if (builtin.os.tag == .windows) findWindowsBash(io, &host) orelse default_bash_exe else default_bash_exe;

        // The exec target is validated HERE, once, before anything can be
        // spawned: a spec that does not parse, or one this host cannot reach,
        // must not degrade into a local shell — a command written for a distro
        // and run on the host is the kind of failure that looks like success.
        const spec = normalizeExecSpec(opts.exec);
        var exec_spec: ?[]u8 = null;
        errdefer if (exec_spec) |p| alloc.free(p);
        var target: ExecTarget = .local;
        if (spec.len != 0) {
            if (!execTargetSupportedOnHost(try parseExecTarget(spec))) return error.ExecTargetUnsupportedOnHost;
            exec_spec = try alloc.dupe(u8, spec);
            // Re-parsed from the owned copy so the payload outlives the caller's
            // string: there is one allocation, and `target` points into it.
            target = try parseExecTarget(exec_spec.?);
        }

        // A targeted command is read by that target's bash, whatever this host
        // runs, so the dialect is decided by the target and the host's answer
        // (config or detection) does not apply.
        const dialect_val = if (target == .local) opts.dialect orelse defaultDialect(io, &host) else .bash;
        // Published so a package describing this session's environment does not
        // have to duplicate the host/config detection logic.
        try sanitized.put("NULYA_SHELL_DIALECT", dialect_val.label());

        var session_path: ?[]u8 = null;
        errdefer if (session_path) |p| alloc.free(p);
        var tasks_dir: ?[]u8 = null;
        errdefer if (tasks_dir) |p| alloc.free(p);
        if (opts.session) |s| {
            session_path = try alloc.dupe(u8, s.session_path);
            tasks_dir = try alloc.dupe(u8, s.tasks_dir);
        }

        var resolver = try ext_exec.Resolver.init(alloc, io, opts.extension_store);
        errdefer resolver.deinit();

        return .{
            .io = io,
            .alloc = alloc,
            .dialect_val = dialect_val,
            .bash_exe = bash_exe,
            .env = sanitized,
            .session_path = session_path,
            .tasks_dir = tasks_dir,
            .exec_spec = exec_spec,
            .target = target,
            .resolver = resolver,
        };
    }

    pub fn deinit(self: *LocalEnvironment) void {
        self.env.deinit();
        self.resolver.deinit();
        if (self.session_path) |p| self.alloc.free(p);
        if (self.tasks_dir) |p| self.alloc.free(p);
        if (self.exec_spec) |p| self.alloc.free(p);
        self.* = undefined;
    }

    /// Publish the live session to everything this environment spawns.
    /// `NULYA_SESSION` is the session FILE's path — a fact about this machine —
    /// and `NULYA_SESSION_ID` is the session's IDENTITY, true on any machine.
    /// They are two variables so a package that only wants the id (a scratch
    /// key, a journal column) works when the workspace lives elsewhere.
    pub fn publishSession(self: *LocalEnvironment, session_path: []const u8, session_id: []const u8) !void {
        if (session_path.len != 0) try self.env.put("NULYA_SESSION", session_path);
        if (session_id.len != 0) try self.env.put("NULYA_SESSION_ID", session_id);
    }

    pub fn environment(self: *LocalEnvironment) Environment {
        return .{ .io = self.io, .ptr = self, .vtable = &vtable };
    }

    fn dialectImpl(ptr: *anyopaque) Dialect {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));
        return self.dialect_val;
    }

    /// The argv that runs `command` in this environment's dialect AND on its
    /// exec target — the ONE place both decisions are made. Two consumers: an
    /// in-process `shell` call below, and `nulya task supervise`, which runs a
    /// BACKGROUND command and must reach the same interpreter, with the same
    /// flags, on the same machine.
    ///
    /// `buf` backs the argv and must outlive the returned value; every form but
    /// plain bash additionally owns one heap string, released by `deinit`.
    ///
    /// What the WSL target does NOT change:
    ///
    ///   - **Killing reaches the local client, not always the far side.** The
    ///     `Tree` around `wsl.exe` is terminated, so a timeout or a cancel
    ///     always ends this step. Whether the process on the other end dies
    ///     with it is the far side's business: killing the WSL relay usually
    ///     takes its Linux process down, but a detached command can survive it.
    ///   - **The child environment is the target's, not the sanitized map.**
    ///     WSL forwards only what `WSLENV` names, so `NULYA_EXE` /
    ///     `NULYA_SESSION` do not arrive on the far side. The secret denylist
    ///     still holds — the sanitized map is what `wsl.exe` itself gets, so
    ///     there is nothing secret left to forward.
    ///   - **`cwd` is translated.** The workspace is the same directory seen
    ///     through `/mnt/<drive>`, so the command is run from there.
    pub fn shellArgv(
        self: *const LocalEnvironment,
        alloc: std.mem.Allocator,
        command: []const u8,
        cwd: []const u8,
        buf: *[8][]const u8,
    ) !ShellCommandLine {
        switch (self.target) {
            .local => {},
            .wsl => |distro| {
                const script = try wslScript(alloc, cwd, command);
                errdefer alloc.free(script);
                var n: usize = 0;
                buf[n] = "wsl.exe";
                n += 1;
                if (distro.len != 0) {
                    buf[n] = "-d";
                    buf[n + 1] = distro;
                    n += 2;
                }
                // `-e` runs the named program directly rather than handing the
                // rest to the distribution's default shell, so `bash` is the
                // interpreter whatever that default happens to be.
                buf[n] = "-e";
                buf[n + 1] = "bash";
                buf[n + 2] = "-lc";
                buf[n + 3] = script;
                n += 4;
                return .{ .argv = buf[0..n], .owned_script = script };
            },
        }
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
                errdefer alloc.free(script);
                buf[0] = "powershell";
                buf[1] = "-NoProfile";
                buf[2] = "-NonInteractive";
                buf[3] = "-Command";
                buf[4] = script;
                return .{ .argv = buf[0..5], .owned_script = script };
            },
        }
    }

    fn runShellImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: ShellRequest) anyerror!ShellOutcome {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));

        var argv_buf: [8][]const u8 = undefined;
        const cmdline = try self.shellArgv(alloc, req.command, req.cwd, &argv_buf);
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
        // closes them once the drain has finished.
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

        // The wall-clock budget races the child's own exit. `child.wait` stays
        // the cancelation point either way — `waitBounded` just runs it as one
        // of two tasks. If the io cannot give the pair their own units of
        // concurrency, the wait runs unguarded: no false timeout, just no guard.
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
            // kill rather than an empty result.
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

        // WHICH FILE runs is decided here, on the machine that holds it: the
        // entry variant for THIS OS, the interpreter its frozen manifest names,
        // and the version checked against its own seal (`extension/exec.zig`).
        // The caller only ever named `(id, version, tool)`.
        const entry = try self.resolver.resolve(req.id, req.version);

        // Oneshot: spawn, feed one request, read one response, exit. Capture
        // stderr too: when an AI-authored extension crashes before it can write
        // a protocol error on stdout, stderr is the only repair signal.
        // A script extension runs through its interpreter (argv = [interpreter,
        // entry]); a compiled one runs directly (argv = [entry]).
        var argv_buf: [2][]const u8 = undefined;
        const argv: []const []const u8 = if (entry.interpreter) |interp| blk: {
            argv_buf = .{ interp, entry.path };
            break :blk argv_buf[0..2];
        } else blk: {
            argv_buf[0] = entry.path;
            break :blk argv_buf[0..1];
        };
        // Per-call variables (`NULYA_TOOL` / `NULYA_ARG_<k>`) are derived HERE,
        // from the same arguments JSON that goes to stdin — one implementation
        // of that rule, shared with the remote agent (`protocol.callEnv`). They
        // go into a COPY of the sanitized map: the process-wide map belongs to
        // every other spawn and must not be mutated for one call.
        var vars = try protocol.callEnv(alloc, req.tool, req.request_json, req.presentation_file);
        defer vars.deinit(alloc);
        var overlay: std.process.Environ.Map = .init(alloc);
        defer overlay.deinit();
        {
            var it = self.env.iterator();
            while (it.next()) |e| try overlay.put(e.key_ptr.*, e.value_ptr.*);
        }
        for (vars.list.items) |v| try overlay.put(v.name, v.value);
        const child_env: *const std.process.Environ.Map = &overlay;

        // Same tree discipline as the shell (see `Tree`): an extension is free to
        // spawn helpers of its own, and the timeout below has to end all of them.
        var tree = try Tree.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = req.cwd },
            .environ_map = child_env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        defer tree.deinit();
        const child = &tree.child;
        errdefer tree.killAll(self.io);

        // Write the arguments, then close stdin so the child sees EOF. They are
        // a small JSON object (< pipe buffer), so writing before draining stdout
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

    /// Start a detached background command and return the moment it is launched.
    /// What is started is NOT the command itself but `nulya task supervise` —
    /// the same binary, in its supervisor role: it holds the task's lease, runs
    /// the real command under a `Tree` so `nulya task kill` ends the whole
    /// subtree, and deposits the report note when it is over. Nothing
    /// is waited on here.
    ///
    /// The slot is allocated with an exclusive `mkdir`: the first free `t<N>`
    /// wins, so two callers racing cannot be handed the same name, and the name
    /// is monotonic within a session.
    fn startShellTaskImpl(ptr: *anyopaque, alloc: std.mem.Allocator, req: TaskRequest) anyerror!TaskStart {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));
        const session_path = self.session_path orelse return error.NoDurableSession;
        const tasks_dir = self.tasks_dir orelse return error.NoDurableSession;
        // The supervisor IS this binary. `NULYA_EXE` is where every child of a
        // nulya process learns which one that is; without it there is no honest
        // way to start one.
        const exe = self.env.get("NULYA_EXE") orelse return error.HarnessPathUnknown;

        const session_id = std.fs.path.stem(std.fs.path.basename(session_path));
        if (session_id.len == 0) return error.NoDurableSession;

        var claimed = try claimTaskSlot(alloc, self.io, tasks_dir, session_id);
        errdefer claimed.deinit(alloc);

        try spawnSupervisor(alloc, self.io, &self.env, .{
            .exe = exe,
            .dir_rel = claimed.dir_rel,
            .session_path = session_path,
            .cwd = req.cwd,
            // The supervisor is a HOST process either way (it holds the lease,
            // drains the log, deposits the event); what it is told here is where
            // the COMMAND it watches runs, so a background command lands on the
            // same machine as the foreground ones of the same session.
            .exec_spec = self.exec_spec,
            .timeout_ms = req.timeout_ms,
            .command = req.command,
        });

        return claimed.intoStart(alloc);
    }

    /// The ONE place in this repository where a workspace file is written from
    /// bytes. A remote session does not get a second copy: its environment
    /// forwards the bytes over the channel and `nulya remote serve` on the other
    /// side calls exactly this function (`cli/remote.zig`).
    fn putWorkspaceFileImpl(ptr: *anyopaque, rel_path: []const u8, bytes: []const u8) anyerror!void {
        const self: *LocalEnvironment = @ptrCast(@alignCast(ptr));
        const cwd = std.Io.Dir.cwd();
        // `createDirPath` is idempotent (an existing directory answers
        // `.existed`), so `try` only surfaces genuine failures — crucially
        // `error.Canceled`, which has to reach the step boundary rather than be
        // swallowed as "could not spill".
        if (std.fs.path.dirname(rel_path)) |dir| try cwd.createDirPath(self.io, dir);
        try cwd.writeFile(self.io, .{ .sub_path = rel_path, .data = bytes });
    }

    const vtable: Environment.VTable = .{
        .dialect = dialectImpl,
        .runShell = runShellImpl,
        .runExtension = runExtensionImpl,
        .startShellTask = startShellTaskImpl,
        .putWorkspaceFile = putWorkspaceFileImpl,
    };
};

/// The one file a task's stdout and stderr are appended to, in arrival order.
/// Named here because both halves of the mechanism need it: the environment
/// tells the caller where it is, and `nulya task supervise` writes it.
pub const task_log_name = "output.log";

/// One claimed `t<N>`: the directory, the full name, and the log the receipt
/// points at. All three are workspace-relative and `/`-spelled, so the same
/// three strings are true on whichever machine that workspace lives on.
pub const TaskSlot = struct {
    dir_rel: []u8,
    task_id: []u8,
    log_path: []u8,

    pub fn deinit(self: TaskSlot, alloc: std.mem.Allocator) void {
        alloc.free(self.dir_rel);
        alloc.free(self.task_id);
        alloc.free(self.log_path);
    }

    /// The receipt half, consuming the rest. `dir_rel` has done its job by the
    /// time a task is started.
    pub fn intoStart(self: TaskSlot, alloc: std.mem.Allocator) TaskStart {
        alloc.free(self.dir_rel);
        return .{ .task_id = self.task_id, .log_path = self.log_path };
    }
};

/// Claim the next free `t<N>` for `session_id` under `tasks_dir`, by exclusive
/// `mkdir`: the first free name wins, so two callers racing cannot be handed the
/// same one, and names are monotonic within a session.
///
/// The claim always happens HERE, on the host, whichever machine the command
/// will run on: the name is what the ledger, the receipt and every `task` verb
/// speak, so the machine that owns the ledger is the one that hands it out.
pub fn claimTaskSlot(
    alloc: std.mem.Allocator,
    io: std.Io,
    tasks_dir: []const u8,
    session_id: []const u8,
) !TaskSlot {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, tasks_dir);

    var slot: usize = 1;
    var task_dir: ?[]u8 = null;
    errdefer if (task_dir) |d| alloc.free(d);
    while (slot <= max_tasks_per_session) : (slot += 1) {
        const name = try std.fmt.allocPrint(alloc, "t{d}", .{slot});
        defer alloc.free(name);
        // `/` on every OS: this path ends up in the model's receipt (`emit.joinRel`).
        const candidate = try emit.joinRel(alloc, &.{ tasks_dir, name });
        if (cwd.createDir(io, candidate, .default_dir)) |_| {
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
    return .{ .dir_rel = dir_rel, .task_id = task_id, .log_path = log_path };
}

/// How `nulya task supervise` is started — the one shape, so the two machines
/// that start one cannot drift.
pub const SupervisorSpawn = struct {
    /// This binary, on whichever machine is doing the spawning (`NULYA_EXE`).
    exe: []const u8,
    /// The task's directory, relative to `spawn_cwd`.
    dir_rel: []const u8,
    /// Exactly one of these two says who the task is and where its report goes:
    /// `session_path` means "deposit it into that session file's inbox" (the
    /// session is on this machine), `task_name` means "you are `<sid>/t<N>` and
    /// there is no session file here — leave the report beside your log, for the
    /// host to collect".
    session_path: ?[]const u8 = null,
    task_name: ?[]const u8 = null,
    /// Where the watched COMMAND runs.
    cwd: []const u8,
    /// The exec target the command is wrapped in, when there is one. Never a
    /// `remote:` spec: a supervisor wraps commands, it does not open channels.
    exec_spec: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
    command: []const u8,
    /// Where the SUPERVISOR process itself starts — the workspace, since
    /// `--dir` is relative to it. Null inherits this process's directory, which
    /// is what a host session wants; the far agent names the session's workspace
    /// because it may not have been started in it.
    spawn_cwd: ?[]const u8 = null,
};

/// Start a supervisor and return the moment it is launched.
///
/// A PLAIN spawn, not a `Tree`: this call returns normally and kills nothing,
/// and the supervisor must survive both this process and the terminal it was
/// started from — hence its own process group on POSIX and no console on
/// Windows. Its stdio is null because it inherits this process's pipes
/// otherwise, and the caller's drain would then wait for a process designed to
/// outlive it. On the far side that caller is the channel itself, so the same
/// care keeps a background task from holding the host's reader open.
pub fn spawnSupervisor(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    s: SupervisorSpawn,
) !void {
    var timeout_buf: [16]u8 = undefined;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ s.exe, "task", "supervise", "--dir", s.dir_rel, "--cwd", s.cwd });
    if (s.session_path) |p| try argv.appendSlice(alloc, &.{ "--session", p });
    if (s.task_name) |t| try argv.appendSlice(alloc, &.{ "--task", t });
    if (s.exec_spec) |spec| try argv.appendSlice(alloc, &.{ "--env", spec });
    if (s.timeout_ms) |ms| {
        try argv.appendSlice(alloc, &.{ "--timeout-ms", try std.fmt.bufPrint(&timeout_buf, "{d}", .{ms}) });
    }
    try argv.appendSlice(alloc, &.{ "--", s.command });

    var detached: DetachedStdio = .take();
    defer detached.restore();
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        // The workspace, NOT the command's cwd: `--dir` and `--session` are
        // workspace-relative, and where the COMMAND runs is `--cwd`'s job.
        .cwd = if (s.spawn_cwd) |p| .{ .path = p } else .inherit,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    // Nothing is waited on: the supervisor outlives this call by design. On
    // Windows the handle is ours to release; on POSIX the exiting parent hands
    // the child to init.
    if (builtin.os.tag == .windows) {
        if (child.id) |handle| std.os.windows.CloseHandle(handle);
        std.os.windows.CloseHandle(child.thread_handle);
        child.id = null;
    }
}

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
/// EOF until the background command finished — the task would be background in
/// name only.
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

/// Host secret-shaped environment variables must not reach an AI-authored
/// subprocess. Matched case-insensitively as a substring so provider keys, cloud
/// creds, and SSH agents are all covered without maintaining an exhaustive
/// allowlist. Non-secret vars (PATH, HOME, …) pass through so commands keep
/// working — the boundary is "no obvious secret env leakage", not full
/// non-inheritance or filesystem confinement.
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

test "local environment publishes the resolved shell dialect to children" {
    var lenv = try LocalEnvironment.init(std.testing.allocator, std.testing.io, .{});
    defer lenv.deinit();

    const published = lenv.env.get("NULYA_SHELL_DIALECT") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(lenv.dialect_val.label(), published);
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

test "exec target specs parse into the two targets, and nothing else does" {
    try std.testing.expectEqual(ExecTarget.local, try parseExecTarget(""));
    try std.testing.expectEqual(ExecTarget.local, try parseExecTarget("local"));
    try std.testing.expectEqualStrings("", (try parseExecTarget("wsl")).wsl);
    try std.testing.expectEqualStrings("Ubuntu-22.04", (try parseExecTarget("wsl:Ubuntu-22.04")).wsl);

    // A prefix with nothing after it names no distro: refused, not read as
    // "the default one" — the colon says something was meant to follow.
    // `ssh:<dest>` is refused unconditionally: moving work to another machine
    // is `remote:ssh:<dest>`, which moves the whole workspace rather than
    // wrapping one command.
    for ([_][]const u8{ "wsl:", "ssh:", "ssh:me@build-box", "ssh", "docker:x", "WSL", " wsl" }) |bad| {
        try std.testing.expectError(error.InvalidExecTarget, parseExecTarget(bad));
    }

    // `local` and absence are the same session, so they freeze the same way.
    try std.testing.expectEqualStrings("", normalizeExecSpec("local"));
    try std.testing.expectEqualStrings("", normalizeExecSpec(""));
    try std.testing.expectEqualStrings("wsl:Ubuntu", normalizeExecSpec("wsl:Ubuntu"));
}

test "a windows path becomes the /mnt path a distribution sees, or nothing" {
    const alloc = std.testing.allocator;

    const c = (try wslPath(alloc, "C:\\code\\zig\\nulya")).?;
    defer alloc.free(c);
    try std.testing.expectEqualStrings("/mnt/c/code/zig/nulya", c);

    // Drive letters are folded and forward slashes are already fine.
    const d = (try wslPath(alloc, "D:/work")).?;
    defer alloc.free(d);
    try std.testing.expectEqualStrings("/mnt/d/work", d);

    const root = (try wslPath(alloc, "E:\\")).?;
    defer alloc.free(root);
    try std.testing.expectEqualStrings("/mnt/e/", root);

    // No drive letter, no honest answer (the caller then passes the original
    // through so the distro reports the failure itself).
    for ([_][]const u8{ "\\\\server\\share\\x", "/already/posix", "relative\\x", "1:\\x" }) |p| {
        try std.testing.expectEqual(@as(?[]u8, null), try wslPath(alloc, p));
    }
}

test "a targeted environment wraps the command and leaves the local one byte-identical" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var buf: [8][]const u8 = undefined;

    // Local: exactly the argv this has always produced.
    {
        var lenv = try LocalEnvironment.init(alloc, io, .{ .dialect = .bash });
        defer lenv.deinit();
        const cl = try lenv.shellArgv(alloc, "echo hi", "/anywhere", &buf);
        defer cl.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 3), cl.argv.len);
        try std.testing.expectEqualStrings("-lc", cl.argv[1]);
        try std.testing.expectEqualStrings("echo hi", cl.argv[2]);
    }

    // WSL is reachable only from Windows; elsewhere the environment refuses to
    // exist rather than quietly running the command on this host.
    if (builtin.os.tag != .windows) {
        try std.testing.expectError(
            error.ExecTargetUnsupportedOnHost,
            LocalEnvironment.init(alloc, io, .{ .exec = "wsl" }),
        );
    } else {
        var lenv = try LocalEnvironment.init(alloc, io, .{ .exec = "wsl:Ubuntu" });
        defer lenv.deinit();
        const cl = try lenv.shellArgv(alloc, "make", "C:\\code\\nulya", &buf);
        defer cl.deinit(alloc);
        try std.testing.expectEqualStrings("wsl.exe", cl.argv[0]);
        try std.testing.expectEqualStrings("-d", cl.argv[1]);
        try std.testing.expectEqualStrings("Ubuntu", cl.argv[2]);
        try std.testing.expectEqualStrings("bash", cl.argv[4]);
        try std.testing.expectEqualStrings("cd '/mnt/c/code/nulya' || exit 1\nmake", cl.argv[6]);

        // No distro named: WSL's own default, and two fewer argv words.
        var dflt = try LocalEnvironment.init(alloc, io, .{ .exec = "wsl" });
        defer dflt.deinit();
        const cl2 = try dflt.shellArgv(alloc, "make", "C:\\code\\nulya", &buf);
        defer cl2.deinit(alloc);
        try std.testing.expectEqualStrings("-e", cl2.argv[1]);
    }

    // A spec that does not parse never becomes a silently-local environment.
    try std.testing.expectError(error.InvalidExecTarget, LocalEnvironment.init(alloc, io, .{ .exec = "podman:x" }));
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

test "a named version is resolved and spawned here, and both its streams are captured" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_real: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = root_real[0..try tmp.dir.realPath(io, &root_real)];
    var root = try ext_store.openOrCreateRoot(io, root_path, "store");
    defer root.close(io);

    // A real frozen SCRIPT version, because that is what the request now names:
    // the environment picks the entry variant for this OS, finds the
    // interpreter in the frozen manifest and checks the seal — none of which a
    // loose file on disk could exercise.
    const script = if (builtin.os.tag == .windows)
        "Write-Error 'stderr-marker'; Write-Output 'not-json'\n"
    else
        "echo stderr-marker >&2\necho not-json\n";
    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"noisy","runtime":{"entry":{"windows":"src/run.ps1","default":"src/run.sh"},"interpreter":{"windows":"powershell","default":"sh"}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    const version = try testkit.writeFrozenVersion(alloc, io, root, "noisy", manifest_bytes, &.{
        .{ .rel = "src/run.sh", .bytes = script },
        .{ .rel = "src/run.ps1", .bytes = script },
    });
    defer alloc.free(version);

    const store_path = try std.fs.path.join(alloc, &.{ root_path, "store" });
    defer alloc.free(store_path);
    var lenv = try LocalEnvironment.init(alloc, io, .{ .extension_store = store_path });
    defer lenv.deinit();

    const outcome = try lenv.environment().runExtension(alloc, .{
        .id = "noisy",
        .version = version,
        .tool = "t",
        .cwd = root_path,
        .request_json = "{}",
        .max_output_bytes = 1024,
        // This test is about capture, not about the timeout, so it uses the
        // production default: a one-second budget would turn "the machine was
        // busy while a script interpreter started" into a failure about
        // something else entirely.
        .timeout_ms = 30_000,
    });
    defer outcome.deinit(alloc);

    try std.testing.expect(!outcome.timed_out);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "not-json") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "stderr-marker") != null);

    // A version this machine does not hold is a refusal, not a spawn of
    // something else.
    try std.testing.expectError(error.VersionNotFound, lenv.environment().runExtension(alloc, .{
        .id = "noisy",
        .version = "v-000000000000000000000000",
        .tool = "t",
        .cwd = root_path,
        .request_json = "{}",
        .max_output_bytes = 1024,
    }));
}
