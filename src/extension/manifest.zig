//! `extension.json` — the manifest.
//!
//! The single source of truth for an extension's identity and model-facing
//! schema: nulya never starts a binary to ask what tools it has.
//!
//! `parse` loads into arena-owned memory (the caller may free the source
//! bytes); `validate` enforces the kernel's deterministic rules.

const std = @import("std");
const builtin = @import("builtin");
const tool = @import("../tool.zig");

pub const schema_id = "nulya.extension/v2";

/// Reserved for the kernel builtin; no extension may declare these names.
pub const reserved_tool_names = [_][]const u8{"shell"};

/// A runtime string that may differ per host OS. Written either as a bare
/// string — one value everywhere — or as an object keyed by `builtin.os.tag`
/// names plus an optional `"default"`:
///
///     "entry": "src/run.sh"
///     "entry": { "windows": "src/run.ps1", "default": "src/run.sh" }
///
/// One package, one version id: every platform's variant is inside the same
/// content-addressed version, only WHICH file runs differs per host.
pub const PlatformValue = struct {
    variants: []const Variant,
    /// False = a bare string, so `variants` holds one entry with empty `os`.
    per_os: bool = false,

    pub const Variant = struct {
        /// A `std.Target.Os.Tag` name or `"default"`; empty in the bare form.
        os: []const u8,
        value: []const u8,
    };

    pub const default_key = "default";

    pub fn single(value: []const u8) PlatformValue {
        return .{ .variants = &.{.{ .os = "", .value = value }} };
    }

    /// An exact match first, then `"default"`, then null — "no entry on that
    /// host", a nameable state rather than a fault in the package.
    pub fn forOs(self: PlatformValue, os_name: []const u8) ?[]const u8 {
        if (!self.per_os) return if (self.variants.len == 0) null else self.variants[0].value;
        var fallback: ?[]const u8 = null;
        for (self.variants) |v| {
            if (std.mem.eql(u8, v.os, os_name)) return v.value;
            if (std.mem.eql(u8, v.os, default_key)) fallback = v.value;
        }
        return fallback;
    }

    pub fn forHost(self: PlatformValue) ?[]const u8 {
        return self.forOs(@tagName(builtin.os.tag));
    }
};

/// Which machine a call to this package runs on, when the session's commands
/// run on another one than the session itself:
///   - `workspace` : beside the files the commands touch. THE DEFAULT, and the
///                   only answer for a package that reads or writes them.
///   - `session`   : beside the ledger, on the machine driving the session —
///                   for a package whose work IS the session (it opens
///                   sub-sessions, reads the session file, starts host tasks).
///
/// Orthogonal to `ImplementationKind`. It says nothing when both are the same
/// machine, which is every ordinary session.
pub const RunsOn = enum {
    workspace,
    session,

    pub fn fromString(s: []const u8) ?RunsOn {
        if (std.mem.eql(u8, s, "workspace")) return .workspace;
        if (std.mem.eql(u8, s, "session")) return .session;
        return null;
    }
};

pub const Runtime = struct {
    /// A `bin/<name>` entry is a compiled Zig extension (built from
    /// `src/main.zig`); anything else is a script frozen as-is. The per-OS form
    /// is for scripts only — compiled cross-platform means cross compilation.
    entry: PlatformValue,
    /// The executable a script `entry` runs through, possibly per-OS. Absent
    /// means the entry is directly executable.
    interpreter: ?PlatformValue = null,
    /// Kept as WRITTEN; read through `runsOn`, which defaults `workspace`.
    runs_on: ?[]const u8 = null,
};

/// A package that runs nothing has no landing side to choose, so a manifest
/// with no `runtime` block is `workspace` like every other silence.
pub fn runsOn(m: Manifest) RunsOn {
    const rt = m.runtime orelse return .workspace;
    const written = rt.runs_on orelse return .workspace;
    // `validate` refuses a word outside the two, so the unwrap is safe.
    return RunsOn.fromString(written).?;
}

/// The `bin/` prefix is the sole distinguisher, checked on EVERY variant — one
/// package is one kind, and `validate` refuses the mixture.
pub fn isScript(rt: Runtime) bool {
    for (rt.entry.variants) |v| {
        if (std.mem.startsWith(u8, v.value, "bin/")) return false;
    }
    return true;
}

/// What enters the content-addressed version id:
///   - `data`     : no runtime; identity is the snapshot alone.
///   - `script`   : an entry frozen as-is; snapshot alone too.
///   - `compiled` : built into `bin/…`, so the compiler and target enter the
///                  id as well. The only kind needing a toolchain.
pub const ImplementationKind = enum { data, script, compiled };

pub fn implementationKind(m: Manifest) ImplementationKind {
    const rt = m.runtime orelse return .data;
    return if (isScript(rt)) .script else .compiled;
}

/// Given that this package IS a session member, does this tool reach the model?
///   - `auto`     : yes, with membership alone. THE DEFAULT.
///   - `manual`   : only when the member names it (`--with <id>:<tool>`).
///   - `internal` : never; called from outside through `nulya ext run`.
pub const Surface = enum {
    auto,
    manual,
    internal,

    pub fn fromString(s: []const u8) ?Surface {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "manual")) return .manual;
        if (std.mem.eql(u8, s, "internal")) return .internal;
        return null;
    }
};

/// Where this package's system prompt sits among the OTHER packages' — the only
/// thing a manifest may say about prompt order. `early` / `normal` (THE
/// DEFAULT, member order decides) / `late`, relative to the packages that said
/// nothing.
///
/// Scope is exactly the extension band of `PromptIR.system_blocks`: the kernel
/// block stays first, `--prompt` text after every extension, `skills:catalog`
/// last. A partition of the band, not a sort key that can jump the kernel.
pub const PromptPosition = enum {
    early,
    normal,
    late,

    pub fn fromString(s: []const u8) ?PromptPosition {
        if (std.mem.eql(u8, s, "early")) return .early;
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "late")) return .late;
        return null;
    }
};

/// A bare path, or an object also carrying a `position`; the bare form means
/// `normal`:
///
///     "system_prompts": ["prompts/base.md", {"path": "prompts/tail.md", "position": "late"}]
pub const SystemPromptSpec = struct {
    path: []const u8,
    /// Kept as WRITTEN; read through `positionOf`, which defaults `normal`.
    position: ?[]const u8 = null,

    pub fn positionOf(self: SystemPromptSpec) PromptPosition {
        if (self.position) |s| return PromptPosition.fromString(s).?;
        return .normal;
    }
};

/// Read by nobody but whoever draws a tool's calls on a screen.
pub const ToolUi = struct {
    /// An OPEN vocabulary (`"checklist"`, `"markdown"`, …), kept as WRITTEN;
    /// an unrecognized word is the reader's decision. Absent is null.
    render: ?[]const u8 = null,
    /// A request that the latest call also show as a foldable widget above the
    /// input. A declaration: absent is null, and the kernel does not act on it.
    panel: ?bool = null,
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON, fed to the model only once the tool is on its face.
    input_schema: []const u8,
    /// Absent means the host default (`tool.Timeouts.extension_ms`); the
    /// ceiling is `tool.Timeouts.extension_max_ms`.
    timeout_ms: ?u32 = null,
    /// The package's claim that this tool only reads: parsed and frozen,
    /// enforced by nobody but a driver's approval policy. Absent means the
    /// package did not say, which is not `false`.
    readonly: ?bool = null,
    /// Kept as WRITTEN; read through `surfaceOf` for the default.
    surface: ?[]const u8 = null,
    ui: ?ToolUi = null,

    /// `validate` refuses a word outside the three, so the unwrap is safe.
    pub fn surfaceOf(self: ToolSpec) Surface {
        if (self.surface) |s| return Surface.fromString(s).?;
        return .auto;
    }
};

/// A slash command this package offers whoever drives a session.
pub const Command = struct {
    name: []const u8,
    description: []const u8,
    action: Action,
};

/// A command's verb, written as an object with exactly one key:
///
///     "action": { "with": true }
///     "action": { "with": "Review the recent sessions and their outcomes…" }
///     "action": { "run": "propose" }
///     "action": { "skill": "review/checklist" }
///
/// The key is the verb, the value its argument — a bare `true` when the verb
/// takes none. The vocabulary is OPEN: an unrecognized key is the reader's
/// decision, never a refusal. `validate` checks only the shape (exactly one
/// key) and that a `run` names a tool this same manifest declares.
///
/// `with`'s string argument is the package's default first message, sent as the
/// opening user turn when the command was typed bare; text typed after the
/// command wins over it.
pub const Action = struct {
    /// Empty only when the object had no keys at all.
    verb: []const u8,
    /// Null when the verb takes no argument (`{"with": true}`).
    target: ?[]const u8 = null,
    /// `validate` demands exactly one.
    keys: usize = 1,

    /// Null for every other verb. The only reference `validate` follows.
    pub fn runTarget(self: Action) ?[]const u8 {
        if (!std.mem.eql(u8, self.verb, "run")) return null;
        return self.target;
    }

    /// Null when the verb is not `with`, or wrote `true`. A caller prefers
    /// whatever the person typed after the command; this is the fallback.
    pub fn withPrompt(self: Action) ?[]const u8 {
        if (!std.mem.eql(u8, self.verb, "with")) return null;
        return self.target;
    }
};

/// The narrowing this package asks an approval policy for while it is a session
/// member: parsed, frozen into the version, enforced by nobody but a driver.
/// One optional bool, so the shape can only NARROW — a key like `allow` needs
/// no special refusal, it is just an unknown key.
pub const Policy = struct {
    /// Absent is null, not `false` — the package said nothing.
    readonly: ?bool = null,
};

/// A declaration only: the kernel validates the shape (host-name charset, safe
/// relative path, non-zero API version) and never loads or executes anything.
pub const UiHost = struct {
    /// The object key in `"ui": {"tui": {…}}`. An open vocabulary: the kernel
    /// checks the charset (`[a-z0-9-]+`) and never the word.
    host: []const u8,
    /// Package-relative (`isSafeRelPath`); a build also checks it exists.
    entry: []const u8,
    /// The plugin-host API version this module was written against; a front end
    /// asks "is my major version at least this". Zero is refused.
    api: u32,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    schema: []const u8,
    id: []const u8,
    runtime: ?Runtime,
    tools: []const ToolSpec,
    skills: []const []const u8,
    system_prompts: []const SystemPromptSpec,
    commands: []const Command = &.{},
    /// Null when `contributes.policy` was never written, so null and a
    /// present-but-empty `{}` stay distinguishable — though
    /// `policyContributes` reads both as no contribution.
    policy: ?Policy = null,
    ui: []const UiHost = &.{},
    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The deterministic kernel rules. Whether a tool is "good taste" is
    /// policy, checked elsewhere.
    pub fn validate(self: Manifest) ValidateError!void {
        if (!std.mem.eql(u8, self.schema, schema_id)) return error.UnsupportedSchema;
        if (!isValidId(self.id)) return error.InvalidId;
        if (self.tools.len == 0 and self.skills.len == 0 and self.system_prompts.len == 0 and
            self.commands.len == 0 and !policyContributes(self.policy) and self.ui.len == 0) return error.NoContributions;

        if (self.runtime) |rt| {
            if (rt.entry.variants.len == 0) return error.InvalidEntry;
            const per_os = rt.entry.per_os;
            for (rt.entry.variants) |v| {
                if (per_os and !isKnownOsKey(v.os)) return error.InvalidEntry;
                if (!isSafeRelPath(v.value)) return error.InvalidEntry;
                // Compiled lives under `bin/` (the build output), script under
                // `src/`. In the per-OS form EVERY variant must be a script: two
                // implementation kinds cannot share one version id.
                if (per_os or isScript(rt)) {
                    if (!std.mem.startsWith(u8, v.value, "src/")) return error.InvalidEntry;
                }
            }
            // Refused rather than defaulted: a typo meaning `session` would
            // otherwise send the package to the machine it cannot work on.
            if (rt.runs_on) |s| {
                if (RunsOn.fromString(s) == null) return error.InvalidRunsOn;
            }
            if (rt.interpreter) |ip| {
                if (ip.variants.len == 0) return error.InvalidInterpreter;
                const ip_per_os = ip.per_os;
                for (ip.variants) |v| {
                    if (ip_per_os and !isKnownOsKey(v.os)) return error.InvalidInterpreter;
                    if (v.value.len == 0) return error.InvalidInterpreter;
                    for (v.value) |c| if (c < 0x20) return error.InvalidInterpreter;
                }
            }
        } else if (self.tools.len != 0) {
            return error.MissingRuntime;
        }

        for (self.tools, 0..) |t, i| {
            if (!isValidId(t.name)) return error.InvalidToolName;
            for (reserved_tool_names) |r| {
                if (std.mem.eql(u8, t.name, r)) return error.ReservedToolName;
            }
            if (t.timeout_ms) |ms| {
                if (ms == 0 or ms > tool.Timeouts.extension_max_ms) return error.InvalidTimeout;
            }
            // Refused rather than defaulted: a typo meaning `internal` would
            // otherwise land a driver tool on the model's face.
            if (t.surface) |s| {
                if (Surface.fromString(s) == null) return error.InvalidSurface;
            }
            for (self.tools[i + 1 ..]) |other| {
                if (std.mem.eql(u8, t.name, other.name)) return error.DuplicateToolName;
            }
        }

        for (self.skills, 0..) |skill, i| {
            if (!isSafeRelPath(skill)) return error.InvalidSkillPath;
            for (self.skills[i + 1 ..]) |other| {
                if (std.mem.eql(u8, skill, other)) return error.DuplicateSkillPath;
            }
        }

        for (self.system_prompts, 0..) |p, i| {
            if (!isSafeRelPath(p.path)) return error.InvalidSystemPromptPath;
            // Refused rather than defaulted: a typo would pick the wrong band.
            if (p.position) |s| {
                if (PromptPosition.fromString(s) == null) return error.InvalidPromptPosition;
            }
            for (self.system_prompts[i + 1 ..]) |other| {
                if (std.mem.eql(u8, p.path, other.path)) return error.DuplicateSystemPromptPath;
            }
        }

        for (self.commands, 0..) |c, i| {
            if (!isValidCommandName(c.name)) return error.InvalidCommandName;
            for (self.commands[i + 1 ..]) |other| {
                if (std.mem.eql(u8, c.name, other.name)) return error.DuplicateCommandName;
            }
            if (c.action.keys != 1 or c.action.verb.len == 0) return error.InvalidCommandAction;
            if (c.action.runTarget()) |target| {
                var found = false;
                for (self.tools) |t| {
                    if (std.mem.eql(u8, t.name, target)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnknownCommandTool;
            }
        }

        for (self.ui) |u| {
            if (!isValidUiHost(u.host)) return error.InvalidUiHost;
            if (!isSafeRelPath(u.entry)) return error.InvalidUiEntry;
            if (u.api == 0) return error.InvalidUiApi;
        }
    }
};

/// A policy that narrows nothing is no contribution.
fn policyContributes(p: ?Policy) bool {
    const policy = p orelse return false;
    return policy.readonly != null;
}

pub const ParseError = error{
    InvalidJson,
    NotAnObject,
    MissingField,
    WrongType,
} || std.mem.Allocator.Error;

pub const ValidateError = error{
    UnsupportedSchema,
    InvalidId,
    MissingRuntime,
    InvalidEntry,
    InvalidInterpreter,
    InvalidRunsOn,
    NoContributions,
    InvalidToolName,
    ReservedToolName,
    DuplicateToolName,
    InvalidTimeout,
    InvalidSurface,
    InvalidSkillPath,
    DuplicateSkillPath,
    InvalidSystemPromptPath,
    DuplicateSystemPromptPath,
    InvalidPromptPosition,
    InvalidCommandName,
    DuplicateCommandName,
    InvalidCommandAction,
    UnknownCommandTool,
    InvalidUiHost,
    InvalidUiEntry,
    InvalidUiApi,
};

/// Structural only — call `validate` for the kernel rules.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Manifest {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    const contributes = switch (obj.get("contributes") orelse return error.MissingField) {
        .object => |o| o,
        else => return error.WrongType,
    };

    const schema = try dupString(a, obj, "schema");
    const id = try dupString(a, obj, "id");
    const runtime = try dupRuntime(a, obj);
    const tools = try dupTools(a, contributes);
    const skills = try dupStringList(a, contributes, "skills");
    const system_prompts = try dupSystemPrompts(a, contributes);
    const commands = try dupCommands(a, contributes);
    const policy = try readPolicy(contributes);
    const ui = try dupUi(a, contributes);
    // Every field is read into a local BEFORE the result is built: `.arena =
    // arena` copies the arena by value and fields evaluate in written order, so
    // an allocation through `a` in a LATER field lands in a chunk the returned
    // arena does not know about, and nothing frees it.
    return .{
        .arena = arena,
        .schema = schema,
        .id = id,
        .runtime = runtime,
        .tools = tools,
        .skills = skills,
        .system_prompts = system_prompts,
        .commands = commands,
        .policy = policy,
        .ui = ui,
    };
}

/// `[a-z0-9-]+` — narrower than `isValidId`.
fn isValidCommandName(s: []const u8) bool {
    return isLowerDashWord(s);
}

/// `[a-z0-9-]+`, same charset as a command name.
fn isValidUiHost(s: []const u8) bool {
    return isLowerDashWord(s);
}

fn isLowerDashWord(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn isValidId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// A `std.Target.Os.Tag` name or `"default"`. A closed vocabulary, so a typo
/// (`"win"`) is refused rather than silently meaning "no entry on Windows".
fn isKnownOsKey(key: []const u8) bool {
    if (std.mem.eql(u8, key, PlatformValue.default_key)) return true;
    return std.meta.stringToEnum(std.Target.Os.Tag, key) != null;
}

/// A relative path that cannot escape the extension directory.
fn isSafeRelPath(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.fs.path.isAbsolute(s)) return false;
    var it = std.mem.splitAny(u8, s, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

fn dupRuntime(a: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!?Runtime {
    const value = obj.get("runtime") orelse return null;
    const runtime_obj = switch (value) {
        .object => |o| o,
        else => return error.WrongType,
    };
    const interpreter: ?PlatformValue = switch (runtime_obj.get("interpreter") orelse std.json.Value{ .null = {} }) {
        .null => null,
        else => |v| try dupPlatformValue(a, v),
    };
    return .{
        .entry = try dupPlatformValue(a, runtime_obj.get("entry") orelse return error.MissingField),
        .interpreter = interpreter,
        .runs_on = try optionalString(a, runtime_obj, "runs_on"),
    };
}

/// Neither a string nor an object is a `WrongType`: a mistyped entry must not
/// read as "absent".
fn dupPlatformValue(a: std.mem.Allocator, value: std.json.Value) ParseError!PlatformValue {
    switch (value) {
        .string => |s| {
            const one = try a.alloc(PlatformValue.Variant, 1);
            one[0] = .{ .os = "", .value = try a.dupe(u8, s) };
            return .{ .variants = one };
        },
        .object => |o| {
            const variants = try a.alloc(PlatformValue.Variant, o.count());
            var it = o.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                variants[i] = .{
                    .os = try a.dupe(u8, entry.key_ptr.*),
                    .value = switch (entry.value_ptr.*) {
                        .string => |s| try a.dupe(u8, s),
                        else => return error.WrongType,
                    },
                };
            }
            return .{ .variants = variants, .per_os = true };
        },
        else => return error.WrongType,
    }
}

fn dupTools(a: std.mem.Allocator, contributes: std.json.ObjectMap) ParseError![]const ToolSpec {
    const tools_val = switch (contributes.get("tools") orelse return a.alloc(ToolSpec, 0)) {
        .array => |arr| arr,
        else => return error.WrongType,
    };
    const tools = try a.alloc(ToolSpec, tools_val.items.len);
    for (tools_val.items, 0..) |tv, i| {
        const to = switch (tv) {
            .object => |o| o,
            else => return error.WrongType,
        };
        tools[i] = .{
            .name = try dupString(a, to, "name"),
            .description = try dupStringOr(a, to, "description", ""),
            .input_schema = if (to.get("input")) |iv| try compact(a, iv) else try a.dupe(u8, "{}"),
            .timeout_ms = try optionalU32(to, "timeout_ms"),
            .readonly = try optionalBool(to, "readonly"),
            .surface = try optionalString(a, to, "surface"),
            .ui = try dupToolUi(a, to),
        };
    }
    return tools;
}

/// A bare path, or an object with `path` plus optional `position`; anything
/// else is a `WrongType`.
fn dupSystemPrompts(a: std.mem.Allocator, contributes: std.json.ObjectMap) ParseError![]const SystemPromptSpec {
    const list = switch (contributes.get("system_prompts") orelse return a.alloc(SystemPromptSpec, 0)) {
        .array => |arr| arr,
        else => return error.WrongType,
    };
    const out = try a.alloc(SystemPromptSpec, list.items.len);
    for (list.items, 0..) |v, i| {
        out[i] = switch (v) {
            .string => |s| .{ .path = try a.dupe(u8, s) },
            .object => |o| .{
                .path = try dupString(a, o, "path"),
                .position = try optionalString(a, o, "position"),
            },
            else => return error.WrongType,
        };
    }
    return out;
}

fn dupToolUi(a: std.mem.Allocator, to: std.json.ObjectMap) ParseError!?ToolUi {
    const value = to.get("ui") orelse return null;
    const ui_obj = switch (value) {
        .object => |o| o,
        else => return error.WrongType,
    };
    return .{
        .render = try optionalString(a, ui_obj, "render"),
        .panel = try optionalBool(ui_obj, "panel"),
    };
}

fn dupCommands(a: std.mem.Allocator, contributes: std.json.ObjectMap) ParseError![]const Command {
    const commands_val = switch (contributes.get("commands") orelse return a.alloc(Command, 0)) {
        .array => |arr| arr,
        else => return error.WrongType,
    };
    const commands = try a.alloc(Command, commands_val.items.len);
    for (commands_val.items, 0..) |cv, i| {
        const co = switch (cv) {
            .object => |o| o,
            else => return error.WrongType,
        };
        commands[i] = .{
            .name = try dupString(a, co, "name"),
            .description = try dupStringOr(a, co, "description", ""),
            .action = try dupAction(a, co.get("action") orelse return error.MissingField),
        };
    }
    return commands;
}

/// One key whose value is a bare `true` or a string; anything else under it is
/// a `WrongType`. The key COUNT is `validate`'s to check.
fn dupAction(a: std.mem.Allocator, value: std.json.Value) ParseError!Action {
    switch (value) {
        .object => |o| {
            if (o.count() == 0) return .{ .verb = "", .keys = 0 };
            var it = o.iterator();
            const first = it.next().?;
            return .{
                .verb = try a.dupe(u8, first.key_ptr.*),
                .target = switch (first.value_ptr.*) {
                    .string => |s| try a.dupe(u8, s),
                    .bool => |b| if (b) null else return error.WrongType,
                    else => return error.WrongType,
                },
                .keys = o.count(),
            };
        },
        else => return error.WrongType,
    }
}

/// One optional bool: nothing to duplicate, so no allocator.
fn readPolicy(contributes: std.json.ObjectMap) ParseError!?Policy {
    const value = contributes.get("policy") orelse return null;
    const policy_obj = switch (value) {
        .object => |o| o,
        else => return error.WrongType,
    };
    return .{ .readonly = try optionalBool(policy_obj, "readonly") };
}

/// Keyed by host. A flat `{"entry": …, "api": …}` reads as a host named
/// `entry` whose value is a string, hence `WrongType` — the schema names no
/// concrete front end.
fn dupUi(a: std.mem.Allocator, contributes: std.json.ObjectMap) ParseError![]const UiHost {
    const value = contributes.get("ui") orelse return a.alloc(UiHost, 0);
    const ui_obj = switch (value) {
        .object => |o| o,
        else => return error.WrongType,
    };
    const hosts = try a.alloc(UiHost, ui_obj.count());
    var it = ui_obj.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        const host_obj = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.WrongType,
        };
        hosts[i] = .{
            .host = try a.dupe(u8, entry.key_ptr.*),
            .entry = try dupString(a, host_obj, "entry"),
            .api = try requiredU32(host_obj, "api"),
        };
    }
    return hosts;
}

/// A value that is not an integer, or does not fit, is a `WrongType` rather
/// than a silently ignored key — as in `optionalBool` / `optionalString`.
fn optionalU32(obj: std.json.ObjectMap, key: []const u8) ParseError!?u32 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| std.math.cast(u32, n) orelse error.WrongType,
        else => error.WrongType,
    };
}

fn requiredU32(obj: std.json.ObjectMap, key: []const u8) ParseError!u32 {
    return switch (obj.get(key) orelse return error.MissingField) {
        .integer => |n| std.math.cast(u32, n) orelse error.WrongType,
        else => error.WrongType,
    };
}

fn optionalBool(obj: std.json.ObjectMap, key: []const u8) ParseError!?bool {
    return switch (obj.get(key) orelse return null) {
        .bool => |b| b,
        else => error.WrongType,
    };
}

fn optionalString(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError!?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| try a.dupe(u8, s),
        else => error.WrongType,
    };
}

fn dupString(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![]const u8 {
    return switch (obj.get(key) orelse return error.MissingField) {
        .string => |s| try a.dupe(u8, s),
        else => error.WrongType,
    };
}

fn dupStringOr(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ParseError![]const u8 {
    return switch (obj.get(key) orelse return a.dupe(u8, default)) {
        .string => |s| try a.dupe(u8, s),
        else => error.WrongType,
    };
}

fn dupStringList(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![]const []const u8 {
    const list = switch (obj.get(key) orelse return a.alloc([]const u8, 0)) {
        .array => |arr| arr,
        else => return error.WrongType,
    };
    const out = try a.alloc([]const u8, list.items.len);
    for (list.items, 0..) |v, i| {
        out[i] = switch (v) {
            .string => |s| try a.dupe(u8, s),
            else => return error.WrongType,
        };
    }
    return out;
}

fn compact(a: std.mem.Allocator, value: std.json.Value) ParseError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const valid_manifest =
    \\{
    \\  "schema": "nulya.extension/v2",
    \\  "id": "web.search",
    \\  "runtime": { "entry": "bin/web-search" },
    \\  "contributes": {
    \\    "tools": [{
    \\      "name": "web_search",
    \\      "description": "Search the web.",
    \\      "input": { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] }
    \\    }],
    \\    "skills": ["skills/search-review"]
    \\  }
    \\}
;

test "parses and validates a well-formed manifest" {
    var m = try parse(std.testing.allocator, valid_manifest);
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqualStrings("web.search", m.id);
    try std.testing.expect(m.runtime != null);
    try std.testing.expectEqualStrings("bin/web-search", m.runtime.?.entry.forHost().?);
    try std.testing.expectEqual(@as(usize, 1), m.tools.len);
    try std.testing.expectEqualStrings("web_search", m.tools[0].name);
    try std.testing.expect(std.mem.indexOf(u8, m.tools[0].input_schema, "query") != null);
    try std.testing.expectEqual(@as(usize, 1), m.skills.len);
    try std.testing.expectEqualStrings("skills/search-review", m.skills[0]);
}

test "parses and validates a script runtime with an interpreter" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"greeter","runtime":{"entry":"src/run.ps1","interpreter":"powershell"},"contributes":{"tools":[{"name":"greet","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try m.validate();
    try std.testing.expect(m.runtime != null);
    try std.testing.expect(isScript(m.runtime.?));
    try std.testing.expectEqualStrings("powershell", m.runtime.?.interpreter.?.forHost().?);
}

test "a bin/ entry is a compiled runtime, not a script" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try m.validate();
    try std.testing.expect(!isScript(m.runtime.?));
    try std.testing.expect(m.runtime.?.interpreter == null);
}

test "a script entry must live under src/" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"run.sh","interpreter":"sh"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.InvalidEntry, m.validate());
}

test "rejects an empty interpreter" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"src/run.sh","interpreter":""},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.InvalidInterpreter, m.validate());
}

test "keys the schema has retired — activation, permissions, runtime.wire — are ordinary unknown keys" {
    const alloc = std.testing.allocator;
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","activation":"on_request","permissions":{"fs":"rw"},
        \\ "runtime":{"entry":"src/run.sh","interpreter":"sh","wire":"jsonrpc"},
        \\ "contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqual(Surface.auto, m.tools[0].surfaceOf());
}

test "entry and interpreter may be written per OS; the host picks, then `default`, then nothing" {
    const alloc = std.testing.allocator;
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{"windows":"src/run.ps1","default":"src/run.sh"},"interpreter":{"windows":"powershell","default":"sh"}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer m.deinit();
    try m.validate();
    const rt = m.runtime.?;
    try std.testing.expect(isScript(rt));
    try std.testing.expectEqual(ImplementationKind.script, implementationKind(m));
    try std.testing.expectEqualStrings("src/run.ps1", rt.entry.forOs("windows").?);
    try std.testing.expectEqualStrings("src/run.sh", rt.entry.forOs("linux").?);
    try std.testing.expectEqualStrings("powershell", rt.interpreter.?.forOs("windows").?);
    try std.testing.expectEqualStrings("sh", rt.interpreter.?.forOs("macos").?);

    // No `default`: the version still builds and installs, only running on a
    // host outside the list fails.
    var narrow = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{"linux":"src/run.sh"},"interpreter":{"linux":"sh"}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer narrow.deinit();
    try narrow.validate();
    try std.testing.expectEqualStrings("src/run.sh", narrow.runtime.?.entry.forOs("linux").?);
    try std.testing.expect(narrow.runtime.?.entry.forOs("windows") == null);

    var bare = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"src/run.sh"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer bare.deinit();
    try bare.validate();
    try std.testing.expectEqualStrings("src/run.sh", bare.runtime.?.entry.forOs("windows").?);
    try std.testing.expect(!bare.runtime.?.entry.per_os);
}

test "the per-OS entry form is scripts only, and its keys must be OS names" {
    const alloc = std.testing.allocator;

    // A `bin/` path inside the object: two implementation kinds under one id.
    var compiled = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{"windows":"bin/a","default":"src/run.sh"}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer compiled.deinit();
    try std.testing.expectError(error.InvalidEntry, compiled.validate());

    var all_compiled = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{"windows":"bin/a.exe","default":"bin/a"}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer all_compiled.deinit();
    try std.testing.expectError(error.InvalidEntry, all_compiled.validate());

    var typo = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{"win":"src/run.ps1"}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer typo.deinit();
    try std.testing.expectError(error.InvalidEntry, typo.validate());

    var typo_interp = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"src/run.sh","interpreter":{"linnux":"sh"}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer typo_interp.deinit();
    try std.testing.expectError(error.InvalidInterpreter, typo_interp.validate());

    var empty = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer empty.deinit();
    try std.testing.expectError(error.InvalidEntry, empty.validate());

    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{"windows":42}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ));
    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":["src/run.sh"]},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ));
}

test "a runtime lands beside the workspace or beside the session; silence means workspace and an unknown word is refused" {
    const alloc = std.testing.allocator;

    var beside_session = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a","runs_on":"session"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer beside_session.deinit();
    try beside_session.validate();
    try std.testing.expectEqual(RunsOn.session, runsOn(beside_session));

    // A script says it the same way: the landing side is orthogonal to how the
    // package is implemented.
    var script = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"src/run.sh","interpreter":"sh","runs_on":"session"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer script.deinit();
    try script.validate();
    try std.testing.expectEqual(RunsOn.session, runsOn(script));

    // Every manifest written before the key reads as `workspace`.
    var silent = try parse(alloc, valid_manifest);
    defer silent.deinit();
    try silent.validate();
    try std.testing.expect(silent.runtime.?.runs_on == null);
    try std.testing.expectEqual(RunsOn.workspace, runsOn(silent));

    var no_runtime = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"skills":["skills/demo"]}}
    );
    defer no_runtime.deinit();
    try no_runtime.validate();
    try std.testing.expectEqual(RunsOn.workspace, runsOn(no_runtime));

    var typo = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a","runs_on":"host"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer typo.deinit();
    try std.testing.expectError(error.InvalidRunsOn, typo.validate());

    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a","runs_on":true},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ));
}

test "validates a pure skill package without runtime" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"skills.finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try m.validate();
    try std.testing.expect(m.runtime == null);
    try std.testing.expectEqual(@as(usize, 0), m.tools.len);
    try std.testing.expectEqualStrings("skills/risk-parity", m.skills[0]);
}

test "rejects wrong schema" {
    const src =
        \\{"schema":"other/v9","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.UnsupportedSchema, m.validate());
}

test "rejects tool contribution without runtime" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.MissingRuntime, m.validate());
}

test "rejects manifest with no contributions" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.NoContributions, m.validate());
}

test "rejects the one reserved tool name, and only that one" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"shell","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.ReservedToolName, m.validate());

    // `edit` is an extension tool, so a package may claim that name.
    const editing =
        \\{"schema":"nulya.extension/v2","id":"b","runtime":{"entry":"bin/b"},"contributes":{"tools":[{"name":"edit","input":{}}]}}
    ;
    var e = try parse(std.testing.allocator, editing);
    defer e.deinit();
    try e.validate();
}

test "rejects duplicate tool names" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{}},{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.DuplicateToolName, m.validate());
}

test "a tool may declare its own timeout, within the host ceiling" {
    const alloc = std.testing.allocator;
    const with_timeout =
        \\{"schema":"nulya.extension/v2","id":"slow","runtime":{"entry":"bin/slow"},"contributes":{"tools":[{"name":"t","input":{},"timeout_ms":60000}]}}
    ;
    var ok = try parse(alloc, with_timeout);
    defer ok.deinit();
    try ok.validate();
    try std.testing.expectEqual(@as(?u32, 60000), ok.tools[0].timeout_ms);

    var plain = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer plain.deinit();
    try plain.validate();
    try std.testing.expect(plain.tools[0].timeout_ms == null);

    // Zero is not "no timeout", and no manifest may exceed the host ceiling.
    var zero = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"timeout_ms":0}]}}
    );
    defer zero.deinit();
    try std.testing.expectError(error.InvalidTimeout, zero.validate());

    var huge = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"timeout_ms":700000}]}}
    );
    defer huge.deinit();
    try std.testing.expectError(error.InvalidTimeout, huge.validate());
    try std.testing.expectEqual(@as(u32, 600_000), tool.Timeouts.extension_max_ms);

    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"timeout_ms":"60s"}]}}
    ));
}

test "a tool may declare itself readonly; the kernel records the claim and enforces nothing" {
    const alloc = std.testing.allocator;
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"r","runtime":{"entry":"bin/r"},"contributes":{"tools":[{"name":"look","input":{},"readonly":true},{"name":"touch","input":{},"readonly":false},{"name":"quiet","input":{}}]}}
    );
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqual(@as(?bool, true), m.tools[0].readonly);
    try std.testing.expectEqual(@as(?bool, false), m.tools[1].readonly);
    try std.testing.expect(m.tools[2].readonly == null);

    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"r","runtime":{"entry":"bin/r"},"contributes":{"tools":[{"name":"look","input":{},"readonly":"yes"}]}}
    ));
}

test "a tool's surface is auto, manual or internal; silence means auto and an unknown word is refused" {
    const alloc = std.testing.allocator;
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"ask","input":{},"surface":"auto"},{"name":"pinny","input":{},"surface":"manual"},{"name":"drive","input":{},"surface":"internal"},{"name":"quiet","input":{}}]}}
    );
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqual(Surface.auto, m.tools[0].surfaceOf());
    try std.testing.expectEqual(Surface.manual, m.tools[1].surfaceOf());
    try std.testing.expectEqual(Surface.internal, m.tools[2].surfaceOf());
    try std.testing.expect(m.tools[3].surface == null);
    try std.testing.expectEqual(Surface.auto, m.tools[3].surfaceOf());

    for ([_][]const u8{ "public", "pin", "with", "driver" }) |word| {
        const src = try std.fmt.allocPrint(alloc,
            \\{{"schema":"nulya.extension/v2","id":"a","runtime":{{"entry":"bin/a"}},"contributes":{{"tools":[{{"name":"t","input":{{}},"surface":"{s}"}}]}}}}
        , .{word});
        defer alloc.free(src);
        var typo = try parse(alloc, src);
        defer typo.deinit();
        try std.testing.expectError(error.InvalidSurface, typo.validate());
    }

    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"surface":true}]}}
    ));
}

// A leak only shows when an allocation needs a NEW chunk, so the sweep exists
// to cross a chunk boundary somewhere — no single size matters.
test "parse allocates nothing outside the arena it returns, at any size" {
    const alloc = std.testing.allocator;
    var len: usize = 1;
    while (len <= 96) : (len += 1) {
        const path = try alloc.alloc(u8, len);
        defer alloc.free(path);
        @memset(path, 'p');
        const text = try std.fmt.allocPrint(
            alloc,
            "{{\"schema\":\"nulya.extension/v2\",\"id\":\"a\",\"contributes\":{{\"system_prompts\":[\"{s}\"]}}}}",
            .{path},
        );
        defer alloc.free(text);
        var m = try parse(alloc, text);
        m.deinit();
    }
}

test "rejects entry that escapes the extension dir" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"../evil"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.InvalidEntry, m.validate());
}

test "rejects skill path that escapes the extension dir" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"skills":["../evil"]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.InvalidSkillPath, m.validate());
}

test "missing required field is a parse error" {
    const src =
        \\{"schema":"nulya.extension/v2","contributes":{}}
    ;
    try std.testing.expectError(error.MissingField, parse(std.testing.allocator, src));
}

test "validates a prompt-only package without runtime" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"prompts.finance","contributes":{"system_prompts":["prompts/finance.md"]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try m.validate();
    try std.testing.expect(m.runtime == null);
    try std.testing.expectEqual(@as(usize, 0), m.tools.len);
    try std.testing.expectEqual(@as(usize, 0), m.skills.len);
    try std.testing.expectEqualStrings("prompts/finance.md", m.system_prompts[0].path);
}

test "rejects invalid and duplicate system prompt paths" {
    const invalid =
        \\{"schema":"nulya.extension/v2","id":"prompts","contributes":{"system_prompts":["../evil.md"]}}
    ;
    var a = try parse(std.testing.allocator, invalid);
    defer a.deinit();
    try std.testing.expectError(error.InvalidSystemPromptPath, a.validate());

    const dup =
        \\{"schema":"nulya.extension/v2","id":"prompts","contributes":{"system_prompts":["prompts/a.md","prompts/a.md"]}}
    ;
    var b = try parse(std.testing.allocator, dup);
    defer b.deinit();
    try std.testing.expectError(error.DuplicateSystemPromptPath, b.validate());
}

test "a system prompt entry is a bare path or an object with a position; silence means normal and an unknown word is refused" {
    const alloc = std.testing.allocator;

    const mixed =
        \\{"schema":"nulya.extension/v2","id":"p","contributes":{"system_prompts":["a.md",{"path":"b.md","position":"early"},{"path":"c.md","position":"late"},{"path":"d.md"}]}}
    ;
    var m = try parse(alloc, mixed);
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqualStrings("a.md", m.system_prompts[0].path);
    try std.testing.expectEqual(PromptPosition.normal, m.system_prompts[0].positionOf());
    try std.testing.expectEqual(PromptPosition.early, m.system_prompts[1].positionOf());
    try std.testing.expectEqual(PromptPosition.late, m.system_prompts[2].positionOf());
    try std.testing.expect(m.system_prompts[3].position == null);
    try std.testing.expectEqual(PromptPosition.normal, m.system_prompts[3].positionOf());

    const typo =
        \\{"schema":"nulya.extension/v2","id":"p","contributes":{"system_prompts":[{"path":"a.md","position":"latte"}]}}
    ;
    var t = try parse(alloc, typo);
    defer t.deinit();
    try std.testing.expectError(error.InvalidPromptPosition, t.validate());

    const escape =
        \\{"schema":"nulya.extension/v2","id":"p","contributes":{"system_prompts":[{"path":"../evil.md","position":"late"}]}}
    ;
    var e = try parse(alloc, escape);
    defer e.deinit();
    try std.testing.expectError(error.InvalidSystemPromptPath, e.validate());

    const dup =
        \\{"schema":"nulya.extension/v2","id":"p","contributes":{"system_prompts":["a.md",{"path":"a.md","position":"late"}]}}
    ;
    var d = try parse(alloc, dup);
    defer d.deinit();
    try std.testing.expectError(error.DuplicateSystemPromptPath, d.validate());

    const wrong =
        \\{"schema":"nulya.extension/v2","id":"p","contributes":{"system_prompts":[42]}}
    ;
    try std.testing.expectError(error.WrongType, parse(alloc, wrong));
}

test "round-trips commands, policy and ui, and a tool's ui hints" {
    const alloc = std.testing.allocator;
    const src =
        \\{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "plan",
        \\  "runtime": { "entry": "bin/plan" },
        \\  "contributes": {
        \\    "tools": [
        \\      {"name": "propose", "input": {}, "ui": {"render": "checklist", "panel": true}},
        \\      {"name": "quiet", "input": {}}
        \\    ],
        \\    "commands": [
        \\      {"name": "plan", "description": "review a plan", "action": {"with": true}},
        \\      {"name": "review", "description": "run the propose tool", "action": {"run": "propose"}}
        \\    ],
        \\    "policy": {"readonly": true},
        \\    "ui": {"tui": {"entry": "tui/panel.ts", "api": 1}}
        \\  }
        \\}
    ;
    var m = try parse(alloc, src);
    defer m.deinit();
    try m.validate();

    try std.testing.expectEqualStrings("checklist", m.tools[0].ui.?.render.?);
    try std.testing.expectEqual(@as(?bool, true), m.tools[0].ui.?.panel);
    try std.testing.expect(m.tools[1].ui == null);

    try std.testing.expectEqual(@as(usize, 2), m.commands.len);
    try std.testing.expectEqualStrings("plan", m.commands[0].name);
    try std.testing.expectEqualStrings("with", m.commands[0].action.verb);
    try std.testing.expect(m.commands[0].action.target == null);
    try std.testing.expectEqualStrings("review", m.commands[1].name);
    try std.testing.expectEqualStrings("run", m.commands[1].action.verb);
    try std.testing.expectEqualStrings("propose", m.commands[1].action.runTarget().?);

    try std.testing.expectEqual(@as(?bool, true), m.policy.?.readonly);

    try std.testing.expectEqual(@as(usize, 1), m.ui.len);
    try std.testing.expectEqualStrings("tui", m.ui[0].host);
    try std.testing.expectEqualStrings("tui/panel.ts", m.ui[0].entry);
    try std.testing.expectEqual(@as(u32, 1), m.ui[0].api);
}

test "an action is one key: zero or two is a shape error, and its value is `true` or a string" {
    const alloc = std.testing.allocator;

    var empty = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{}}]}}
    );
    defer empty.deinit();
    try std.testing.expectError(error.InvalidCommandAction, empty.validate());

    // Two verbs is not "both": nothing could decide which one runs.
    var two = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"with":true,"skill":"s"}}]}}
    );
    defer two.deinit();
    try std.testing.expectError(error.InvalidCommandAction, two.validate());

    var unknown = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"review":"changes"}}]}}
    );
    defer unknown.deinit();
    try unknown.validate();
    try std.testing.expectEqualStrings("review", unknown.commands[0].action.verb);
    try std.testing.expectEqualStrings("changes", unknown.commands[0].action.target.?);

    for ([_][]const u8{
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"run":42}}]}}
        ,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"with":false}}]}}
        ,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":["with"]}]}}
        ,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":"run propose"}]}}
        ,
    }) |src| {
        try std.testing.expectError(error.WrongType, parse(alloc, src));
    }

    try std.testing.expectError(error.MissingField, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":""}]}}
    ));
}

test "`with`'s value may be a string — the default first message a bare command sends" {
    const alloc = std.testing.allocator;
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[
        \\  {"name": "evolve", "description": "", "action": {"with": "Review the recent sessions."}},
        \\  {"name": "plan", "description": "", "action": {"with": true}}
        \\]}}
    );
    defer m.deinit();
    try m.validate();

    try std.testing.expectEqualStrings("with", m.commands[0].action.verb);
    try std.testing.expectEqualStrings("Review the recent sessions.", m.commands[0].action.withPrompt().?);

    try std.testing.expect(m.commands[1].action.withPrompt() == null);
    try std.testing.expect(m.commands[1].action.runTarget() == null);
}

test "a command name is [a-z0-9-]+ and may not repeat within a package" {
    const alloc = std.testing.allocator;

    var upper = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"Plan","description":"","action":{"with":true}}]}}
    );
    defer upper.deinit();
    try std.testing.expectError(error.InvalidCommandName, upper.validate());

    var empty = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"","description":"","action":{"with":true}}]}}
    );
    defer empty.deinit();
    try std.testing.expectError(error.InvalidCommandName, empty.validate());

    var dup = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"plan","description":"","action":{"with":true}},{"name":"plan","description":"","action":{"skill":"x"}}]}}
    );
    defer dup.deinit();
    try std.testing.expectError(error.DuplicateCommandName, dup.validate());
}

test "a `run` command must name a tool this same manifest declares; other verbs are the reader's word" {
    const alloc = std.testing.allocator;

    var with_action = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"plan","description":"","action":{"with":true}}]}}
    );
    defer with_action.deinit();
    try with_action.validate();

    var skill = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"help","description":"","action":{"skill":"some/ref"}}]}}
    );
    defer skill.deinit();
    try skill.validate();

    // `{"run": …}` IS checked: the closed, in-package reference.
    var missing = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"other","input":{}}],"commands":[{"name":"review","description":"","action":{"run":"propose"}}]}}
    );
    defer missing.deinit();
    try std.testing.expectError(error.UnknownCommandTool, missing.validate());

    var present = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"propose","input":{}}],"commands":[{"name":"review","description":"","action":{"run":"propose"}}]}}
    );
    defer present.deinit();
    try present.validate();
}

test "policy is one optional bool, so nothing it can say has to be refused" {
    const alloc = std.testing.allocator;

    var allow = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{"allow":["shell"]}}}
    );
    defer allow.deinit();
    try std.testing.expectError(error.NoContributions, allow.validate());

    var alone = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{}}}
    );
    defer alone.deinit();
    try std.testing.expectError(error.NoContributions, alone.validate());

    // Present but empty is a different fact than never having written the key.
    var declared_empty = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"with":true}}],"policy":{}}}
    );
    defer declared_empty.deinit();
    try declared_empty.validate();
    try std.testing.expect(declared_empty.policy != null);
    try std.testing.expect(declared_empty.policy.?.readonly == null);

    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{"readonly":"yes"}}}
    ));
}

test "contributes.ui is keyed by host; each entry needs a safe path and a real api version" {
    const alloc = std.testing.allocator;

    var many = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"tui":{"entry":"tui/panel.ts","api":1},"web":{"entry":"web/panel.js","api":2}}}}
    );
    defer many.deinit();
    try many.validate();
    try std.testing.expectEqual(@as(usize, 2), many.ui.len);
    try std.testing.expectEqualStrings("tui", many.ui[0].host);
    try std.testing.expectEqualStrings("web", many.ui[1].host);
    try std.testing.expectEqual(@as(u32, 2), many.ui[1].api);

    // The charset is checked, the WORD never — no schema names a front end.
    var bad_host = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"TUI":{"entry":"tui/panel.ts","api":1}}}}
    );
    defer bad_host.deinit();
    try std.testing.expectError(error.InvalidUiHost, bad_host.validate());

    var escapes = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"tui":{"entry":"../evil.ts","api":1}}}}
    );
    defer escapes.deinit();
    try std.testing.expectError(error.InvalidUiEntry, escapes.validate());

    var zero = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"tui":{"entry":"tui/panel.ts","api":0}}}}
    );
    defer zero.deinit();
    try std.testing.expectError(error.InvalidUiApi, zero.validate());

    try std.testing.expectError(error.MissingField, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"tui":{"entry":"tui/panel.ts"}}}}
    ));

    var none = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{}}}
    );
    defer none.deinit();
    try std.testing.expectError(error.NoContributions, none.validate());
}

test "the pre-host flat ui block is not a second shape: it reads as a host whose entry is a string" {
    try std.testing.expectError(error.WrongType, parse(std.testing.allocator,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"entry":"tui/panel.ts","api":1}}}
    ));
}

test "a command, a policy with content, or a ui block each alone counts as a contribution" {
    const alloc = std.testing.allocator;

    var cmd = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"plan","description":"","action":{"with":true}}]}}
    );
    defer cmd.deinit();
    try cmd.validate();

    var pol = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{"readonly":true}}}
    );
    defer pol.deinit();
    try pol.validate();

    var ui = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"tui":{"entry":"tui/panel.ts","api":1}}}}
    );
    defer ui.deinit();
    try ui.validate();

    var none = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{}}
    );
    defer none.deinit();
    try std.testing.expectError(error.NoContributions, none.validate());
}

test "commands, policy and ui default to absent, and a manifest predating them still validates" {
    var m = try parse(std.testing.allocator, valid_manifest);
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqual(@as(usize, 0), m.commands.len);
    try std.testing.expect(m.policy == null);
    try std.testing.expectEqual(@as(usize, 0), m.ui.len);
    try std.testing.expect(m.tools[0].ui == null);
}
