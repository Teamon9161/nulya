//! `extension.json` — the manifest (DESIGN §7.2).
//!
//! The manifest is the SINGLE source of truth for an extension's identity and
//! model-facing schema. Nulya never starts a binary just to ask what tools it
//! has: that would split truth across source / manifest / runtime describe().
//! Runtime processes only ever handle calls declared by the manifest.
//!
//! `parse` loads the structure into arena-owned memory (so the caller may free
//! the source bytes); `validate` enforces the kernel's deterministic rules
//! (DESIGN §7.4, §12). Whether a tool is "good taste" is policy, not validation.

const std = @import("std");
const builtin = @import("builtin");
const tool = @import("../tool.zig");

pub const schema_id = "nulya.extension/v2";

/// The builtin name is permanently reserved; an extension may not shadow it
/// (DESIGN §5.2, §6). One name, because there is one builtin — `edit` left this
/// list when it became a tool of the bundled `std` extension (DESIGN §7.8).
pub const reserved_tool_names = [_][]const u8{"shell"};

/// A runtime string that may differ per host OS (DESIGN §7.1). Written either
/// as a bare string — one value everywhere — or as an object keyed by
/// `builtin.os.tag` names plus an optional `"default"`:
///
///     "entry": "src/run.sh"
///     "entry": { "windows": "src/run.ps1", "default": "src/run.sh" }
///
/// One package, one version id: the snapshot already collects the whole `src/`
/// tree, so every platform's variant is inside the same content-addressed
/// version. That is the point — `v-…` names the same package on every machine,
/// and only WHICH file runs differs.
///
/// Both forms are one representation, so every consumer iterates `variants`
/// without asking which shape was written; `per_os` records WHICH shape the
/// manifest used, because the two mean different things about the same list
/// (one value for every host, versus one value per named host).
pub const PlatformValue = struct {
    variants: []const Variant,
    /// The manifest wrote an object. False = a bare string, in which case
    /// `variants` holds exactly one entry whose `os` is empty.
    per_os: bool = false,

    pub const Variant = struct {
        /// A `std.Target.Os.Tag` name or `"default"` in the object form; empty
        /// in the bare-string form.
        os: []const u8,
        value: []const u8,
    };

    pub const default_key = "default";

    pub fn single(value: []const u8) PlatformValue {
        return .{ .variants = &.{.{ .os = "", .value = value }} };
    }

    /// The value this OS gets: an exact match first, then `"default"`, then
    /// null — "this version has no entry on that host", which is a real and
    /// nameable state, not a fault in the package.
    pub fn forOs(self: PlatformValue, os_name: []const u8) ?[]const u8 {
        if (!self.per_os) return if (self.variants.len == 0) null else self.variants[0].value;
        var fallback: ?[]const u8 = null;
        for (self.variants) |v| {
            if (std.mem.eql(u8, v.os, os_name)) return v.value;
            if (std.mem.eql(u8, v.os, default_key)) fallback = v.value;
        }
        return fallback;
    }

    /// `forOs` for the machine this binary runs on.
    pub fn forHost(self: PlatformValue) ?[]const u8 {
        return self.forOs(@tagName(builtin.os.tag));
    }
};

pub const Runtime = struct {
    /// Relative path to the runtime entry within the package, possibly per-OS
    /// (`PlatformValue`). A `bin/<name>` entry is a COMPILED Zig extension
    /// (built from `src/main.zig`); any other entry (e.g. `src/run.ps1`) is a
    /// SCRIPT extension frozen as-is — see `isScript`. The per-OS form is for
    /// scripts only: a compiled extension's cross-platform story is cross
    /// compilation, which this field is not.
    entry: PlatformValue,
    /// For a script extension, the executable used to run `entry` (e.g. `sh`,
    /// `powershell`, `python3`), possibly per-OS. Absent means the entry is
    /// directly executable (a `.cmd`/`.bat` on Windows, or a shebang script
    /// with the exec bit).
    interpreter: ?PlatformValue = null,
};

/// A script extension is frozen and run as-is (no compilation); a compiled Zig
/// extension outputs a binary under `bin/`. The `bin/` prefix is the sole,
/// purely-syntactic distinguisher, so every consumer decides identically without
/// probing the filesystem — and it is asked of EVERY declared variant, so a
/// per-OS entry cannot be one kind here and another kind there (`validate`
/// refuses the mixture outright).
pub fn isScript(rt: Runtime) bool {
    for (rt.entry.variants) |v| {
        if (std.mem.startsWith(u8, v.value, "bin/")) return false;
    }
    return true;
}

/// How an extension version is materialized — the one axis that decides what
/// belongs in its content-addressed identity (DESIGN §7.1, §7.4):
///   - `data`     : no runtime at all (pure skills / system prompts). Identity is
///                  the package snapshot alone; building needs no compiler.
///   - `script`   : a runtime entry frozen and run as-is (`src/…`). Same as data
///                  for identity purposes: no compilation, so no compiler/target.
///   - `compiled` : a Zig runtime built into `bin/…`. Its binary depends on the
///                  compiler and host target, so BOTH enter the version id.
/// Only `compiled` requires a toolchain; `data` and `script` never touch zig.
pub const ImplementationKind = enum { data, script, compiled };

pub fn implementationKind(m: Manifest) ImplementationKind {
    const rt = m.runtime orelse return .data;
    return if (isScript(rt)) .script else .compiled;
}

/// Where this tool belongs in a session's capability surface — three words
/// that answer one question: given that this package IS a member of a session,
/// does this tool reach the model, and how?
///
///   - `auto`     : it reaches the model as soon as the package is a member
///                  (`--with`, config `[extensions] with`, `apply: "auto"`, or
///                  a driver's equivalent). THE DEFAULT: a package a person
///                  composed in is a package whose tools they meant to use, and
///                  a scaffolded extension should work the moment it is named.
///                  Membership is membership: a package a pin brought in is a
///                  member like any other, so its `auto` tools reach the model
///                  too (DESIGN §5.1).
///   - `manual`   : membership is not enough; a person has to name this tool
///                  (`session new --pin ext:<id>/<tool>`, config
///                  `[registry] pinned_native_tools`). The only surface a pin
///                  accepts, so it is what a package writes for a tool that
///                  should take a native slot only when somebody says so —
///                  `extensions/std`, whose six tools are a face a person
///                  assembles, is the case that exists.
///   - `internal` : never on the model face at all; called by outside code
///                  through `nulya ext run`. A driver's tool.
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

/// What ACTIVATING this package means for the sessions that follow (DESIGN
/// §5.1) — the package author's DEFAULT on the membership axis, and the only
/// thing a manifest may say about reach:
///
///   - `manual` : the default. Activation says which version `<id>` means and
///                nothing more; the package joins the sessions that name it
///                (config `[extensions] with`, `session new --with`, or a pin
///                that implies membership).
///   - `auto`   : while this package has a `current`, it is a standing member of
///                every fresh, non-`--bare` session on this machine. What a
///                "mode" package wants — a system prompt that is the point of
///                installing it — and what a tool package that should always be
///                there wants.
///
/// It is a DEFAULT, never a ceiling: config's `[extensions] with` can always
/// add a package the author left at `manual`, and `nulya ext deactivate <id>`
/// is how a person turns `auto` off. Reach stays the person's decision
/// (physics #6); the author only gets to say what installing SHOULD mean.
pub const Apply = enum {
    auto,
    manual,

    pub fn fromString(s: []const u8) ?Apply {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "manual")) return .manual;
        return null;
    }
};

/// Where this package's system prompt block sits among the OTHER packages'
/// (DESIGN §5.6) — the one thing a manifest may say about system-prompt order,
/// and a closed three-word vocabulary like `surface` and `apply`:
///
///   - `early`  : before the packages that said nothing. Framing a later prompt
///                is meant to be read against.
///   - `normal` : THE DEFAULT. Member order decides, as it always did.
///   - `late`   : after the packages that said nothing. The closing word a mode
///                package wants when another package's prompt is the body.
///
/// Its scope is exactly the extension band of `PromptIR.system_blocks`: the
/// kernel block stays first, `--prompt` inline text stays after every extension,
/// and `skills:catalog` stays last (`composition.buildSystemPrompts`). Within one
/// position the existing member order is untouched, so this is a partition of the
/// band, not a sort key a package can use to jump the kernel.
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

/// One entry of `contributes.system_prompts`, written either as a bare path or
/// as an object that also carries a `position` (see `PromptPosition`):
///
///     "system_prompts": ["prompts/base.md", {"path": "prompts/tail.md", "position": "late"}]
///
/// The bare string stays legal and means `normal` — it is what every package in
/// this repository writes, and a field nobody needs should not have to be typed.
pub const SystemPromptSpec = struct {
    path: []const u8,
    /// This prompt's band, kept as WRITTEN. Read through `positionOf`, which
    /// supplies the default. Silence is a DEFAULT, not a "did not say" (the same
    /// reasoning as `ToolSpec.surface`): every block lands somewhere whether or
    /// not the manifest names a band.
    position: ?[]const u8 = null,

    pub fn positionOf(self: SystemPromptSpec) PromptPosition {
        if (self.position) |s| return PromptPosition.fromString(s).?;
        return .normal;
    }
};

/// A tool's front-end rendering hints (DESIGN §7.2.1, tui-plugin D12) — the
/// FRONT-END tier of the manifest: an open vocabulary, never refused by
/// `validate`, and read by nobody but whoever draws a tool's calls on a
/// screen.
pub const ToolUi = struct {
    /// A rendering HINT for whoever draws this tool's calls — a word from an
    /// OPEN vocabulary (`"checklist"`, `"markdown"`, more later), kept as
    /// WRITTEN and NEVER refused by `validate`. Unlike `surface` (a closed
    /// three-word set the kernel can exhaustively check), this vocabulary is
    /// expected to grow, so an unrecognized word is the READER's decision —
    /// fall back to a plain card and move on — not a build-time refusal.
    /// Absent is null, not any particular word: the same "silence is not a
    /// claim" discipline as `readonly`.
    render: ?[]const u8 = null,
    /// The package's request that the LATEST call of this tool also be
    /// projected as a persistent, foldable widget above the input — the
    /// degraded display a front end with no plugin code can still give a
    /// progress indicator (tui-plugin D12). A DECLARATION like the rest of
    /// this struct: absent is null, not `false`, and the kernel does not act
    /// on it.
    panel: ?bool = null,
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON of the tool's `input` schema. Only fed to the model when the
    /// extension is promoted into `tools[]`; otherwise pure discoverability
    /// metadata (DESIGN §7.2 note).
    input_schema: []const u8,
    /// Wall-clock cap for one call of THIS tool, when it knows the host default
    /// (`tool.Timeouts.extension_ms`, 30s) is not enough — a driver tool that
    /// steps a real model is the case that exists (`extensions/compact`). Absent
    /// means the default; the ceiling is `tool.Timeouts.extension_max_ms`. The
    /// manifest is the one place this can be said, because the manifest is the
    /// single source of truth about a tool (DESIGN §7.2.1).
    timeout_ms: ?u32 = null,
    /// The package's claim that this tool only READS: it makes no change a
    /// person would want to approve first. A DECLARATION (DESIGN §9) — the
    /// kernel parses it, records it in the frozen manifest, and enforces
    /// nothing. What consumes it is a driver's
    /// approval policy (`loop.ToolGate`, DESIGN §4), which is free to ignore it;
    /// a real boundary needs OS enforcement (PLAN §3.8), not a boolean.
    ///
    /// Absent means the package did not say, which is not the same as `false`
    /// and must not be read as one.
    readonly: ?bool = null,
    /// This tool's placement (see `Surface`), kept as WRITTEN. Read through
    /// `surfaceOf`, which supplies the default.
    surface: ?[]const u8 = null,
    /// This tool's front-end rendering hints (see `ToolUi`), or null when the
    /// package made neither claim. Grouped under one FRONT-END key, distinct
    /// from `readonly` / `surface` above: those two are read by the kernel's
    /// gate and by `--pin`/`--with` composition, this one only by whoever
    /// draws a call on a screen.
    ui: ?ToolUi = null,

    /// This tool's placement, defaulting to `auto` — a tool in a package
    /// somebody composed in is a tool they meant to have. Silence is a DEFAULT
    /// here, not a "did not say" (unlike `readonly`): every tool has a
    /// placement whether or not the manifest names one, so there is nothing for
    /// a null to mean. `validate` refuses a word outside the three, so the
    /// unwrap is safe on any validated manifest.
    pub fn surfaceOf(self: ToolSpec) Surface {
        if (self.surface) |s| return Surface.fromString(s).?;
        return .auto;
    }
};

/// A slash command this package offers whoever DRIVES a session (DESIGN
/// §7.2.1, tui-plugin D1/D2/D8). Declared in the manifest — not in a sidecar
/// the front end alone reads — so any driver, headless or not, sees the same
/// commands a session's frozen composition actually carries.
pub const Command = struct {
    name: []const u8,
    description: []const u8,
    /// What typing this command does (see `Action`).
    action: Action,
};

/// A command's verb, written as an object with EXACTLY ONE key:
///
///     "action": { "with": true }
///     "action": { "run": "propose" }
///     "action": { "skill": "review/checklist" }
///
/// The key is the verb and the value is its argument — a bare `true` when the
/// verb takes none, a string when it does. That is the whole shape rule, and
/// it is verb-INDEPENDENT on purpose: the vocabulary is OPEN (`ToolUi.render`'s
/// discipline), so an unrecognized key is the READER's decision (warn and
/// skip), never a `validate` refusal. What `validate` does check is the shape
/// itself — one key, no more and no fewer (`InvalidCommandAction`) — and the
/// one closed reference inside it: a `run` command's `<tool>` must name a tool
/// this SAME manifest declares (`UnknownCommandTool`), which is a fact about
/// this file's own shape rather than a member of the vocabulary.
///
/// The object replaced a string mini-language (`"run propose"`), which had the
/// reader splitting on a space to find out what it was holding. That form is
/// gone: a string `action` is a `WrongType` like any other mistyped field.
pub const Action = struct {
    /// The single key. Empty only when the object had no keys at all, which
    /// `validate` refuses.
    verb: []const u8,
    /// The string under the key (`{"run": "propose"}` → `"propose"`). Null when
    /// the verb takes no argument (`{"with": true}`).
    target: ?[]const u8 = null,
    /// How many keys the object wrote — the one thing `validate` asks about an
    /// action's shape (exactly one).
    keys: usize = 1,

    /// The tool a `run` command names, or null for every other verb (including
    /// a `run` with no argument at all). The only reference `validate` follows.
    pub fn runTarget(self: Action) ?[]const u8 {
        if (!std.mem.eql(u8, self.verb, "run")) return null;
        return self.target;
    }
};

/// The narrowing this package asks an approval policy to apply while it is a
/// member of a session's frozen composition (DESIGN §7.2.1, tui-plugin
/// D2/D3). A DECLARATION exactly like `ToolSpec.readonly`
/// beside it: the kernel parses it, freezes it into the version, and
/// enforces nothing — the consumer is a driver's own approval policy (TUI's
/// `approvals.decide`).
///
/// One field, and it can only NARROW. There were three (`readonly` / `deny` /
/// `ask`, mirroring the tables an approval policy already reads), with an
/// `allow` key refused outright because a package that could add an entry to
/// an allow table would be authority growing implicitly through membership
/// alone (physics #6). The two list fields had no reader that a single
/// `readonly` did not already serve, and a shape that is one optional bool
/// CANNOT widen anything — so the rule that used to need a parse-time refusal
/// is now carried by the shape itself, and `allow` is just another unknown key.
pub const Policy = struct {
    /// Same three-state discipline as `ToolSpec.readonly`: absent is null,
    /// not `false` — the package said nothing, which is not the same as
    /// saying "not readonly".
    readonly: ?bool = null,
};

/// One front end's module declaration inside `contributes.ui` (DESIGN §7.2.1,
/// tui-plugin D1/D10) — the FRONT-END tier's own code layer. A DECLARATION
/// only: the kernel validates the SHAPE (a known-charset host name, a safe
/// relative path, a non-zero API version) and never loads or executes
/// anything — loading is a front end's job, not this layer's.
pub const UiHost = struct {
    /// WHICH front end this module is for — the object key in
    /// `"ui": {"tui": {…}}`. An OPEN vocabulary (`ToolUi.render`'s
    /// discipline): the kernel checks the charset (`[a-z0-9-]+`,
    /// `InvalidUiHost`) and never the word, because the kernel's schema must
    /// not name one concrete front end. A front end reads its own key and
    /// skips a package that has none — "this package has no plugin for me" is
    /// an ordinary answer, not a warning.
    host: []const u8,
    /// Package-relative path to the module that front end loads. Same
    /// path-safety rule as `system_prompts` (`isSafeRelPath`, checked in
    /// `validate`), and once a build actually collects the package snapshot,
    /// the same existence check `validateSystemPrompts` runs for a system
    /// prompt file (`extension/build/build_ext.zig`) — a declared entry that
    /// is not there is a fault in the draft, not something discovered at
    /// load time.
    entry: []const u8,
    /// The plugin-host API version this module was written against. Kept as
    /// a bare number rather than a word set, because API versions are
    /// linearly ordered and a front end's compatibility check is "is my
    /// major version at least this" (warn-and-skip on mismatch, a front-end
    /// policy) — not membership in a vocabulary. Zero can never be a real
    /// version, so it is the one value `validate` refuses (`InvalidUiApi`).
    api: u32,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    schema: []const u8,
    id: []const u8,
    runtime: ?Runtime,
    tools: []const ToolSpec,
    skills: []const []const u8,
    /// This package's static system prompt contributions (see
    /// `SystemPromptSpec`), in the order the manifest wrote them.
    system_prompts: []const SystemPromptSpec,
    /// This package's slash commands (see `Command`). Absent reads as empty —
    /// same convention as `skills` / `system_prompts`.
    commands: []const Command = &.{},
    /// This package's approval-policy narrowing (see `Policy`), or null when
    /// the package never wrote `contributes.policy` at all — so null and
    /// present-but-every-field-empty (`{}`) stay different VALUES a reader
    /// can still tell apart. `NoContributions` reads them the same, though
    /// (`policyContributes`): an empty `{}` narrows nothing, so it counts as
    /// having said nothing, exactly like never writing the key.
    policy: ?Policy = null,
    /// This package's front-end modules, one per host (see `UiHost`). Absent
    /// reads as empty — same convention as `skills` / `system_prompts`.
    ui: []const UiHost = &.{},
    /// What activating this package means for the sessions that follow (see
    /// `Apply`), kept as WRITTEN. Read through `applyOf`, which supplies the
    /// default. A TOP-LEVEL key rather than one under `contributes`: it is not
    /// a contribution, it is what the author thinks installing the whole
    /// package should mean.
    apply: ?[]const u8 = null,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// This package's membership default, `manual` unless it says otherwise —
    /// the conservative half, because the other one puts a system prompt in
    /// front of every model on this machine. `validate` refuses a word outside
    /// the two, so the unwrap is safe on any validated manifest.
    pub fn applyOf(self: Manifest) Apply {
        if (self.apply) |s| return Apply.fromString(s).?;
        return .manual;
    }

    /// Enforce the deterministic kernel rules (DESIGN §7.4, §12). Whether a tool
    /// is "good taste" is policy, checked elsewhere — not here.
    pub fn validate(self: Manifest) ValidateError!void {
        if (!std.mem.eql(u8, self.schema, schema_id)) return error.UnsupportedSchema;
        if (!isValidId(self.id)) return error.InvalidId;
        // A closed two-word vocabulary, so a typo is refused rather than read
        // as the default: `aply: "auot"` must not silently mean `manual` — the
        // author would install a mode package and never see it in a session.
        if (self.apply) |s| {
            if (Apply.fromString(s) == null) return error.InvalidApply;
        }
        if (self.tools.len == 0 and self.skills.len == 0 and self.system_prompts.len == 0 and
            self.commands.len == 0 and !policyContributes(self.policy) and self.ui.len == 0) return error.NoContributions;

        if (self.runtime) |rt| {
            if (rt.entry.variants.len == 0) return error.InvalidEntry;
            const per_os = rt.entry.per_os;
            for (rt.entry.variants) |v| {
                if (per_os and !isKnownOsKey(v.os)) return error.InvalidEntry;
                if (!isSafeRelPath(v.value)) return error.InvalidEntry;
                // A compiled entry lives under `bin/` (the build output); a
                // script entry lives under `src/` (frozen with the source tree).
                // Anything else is rejected so every consumer can locate the
                // entry the same way. In the per-OS form EVERY variant must be a
                // script: a package that is compiled on one platform and a
                // script on another is two implementation kinds under one
                // version id, and the version id would have to be two things at
                // once (DESIGN §7.4). Cross-platform compiled means cross
                // compilation, not this field.
                if (per_os or isScript(rt)) {
                    if (!std.mem.startsWith(u8, v.value, "src/")) return error.InvalidEntry;
                }
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
            // A word outside the three is refused rather than read as the
            // default: a package that meant `internal` and typed `internl`
            // would otherwise land its driver tool on the model's face, which
            // is the exact outcome the field exists to prevent. The words the
            // three used to be spelled with (`pin` / `with` / `driver`) are
            // refused by the same rule — a rename that silently kept reading
            // the old word would leave two vocabularies in the wild.
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
            // A closed vocabulary refused rather than read as the default, for
            // `surface`'s reason: a package that meant `late` and typed `latte`
            // would silently land in the middle of the band, and the author
            // would see a wrong prompt order with nothing to explain it.
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
            // The two things `validate` asks of an otherwise open verb
            // vocabulary (see `Action`): the object holds exactly one key, and
            // a `run` command names a tool THIS manifest itself declares — a
            // closed, in-package reference, not a member of a word list that
            // might grow.
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

        // `policy` needs no check at all: its one field is the same three-state
        // bool as `ToolSpec.readonly`, and a shape that is one optional bool
        // cannot say anything a `validate` rule would have to refuse.

        for (self.ui) |u| {
            if (!isValidUiHost(u.host)) return error.InvalidUiHost;
            if (!isSafeRelPath(u.entry)) return error.InvalidUiEntry;
            if (u.api == 0) return error.InvalidUiApi;
        }
    }
};

/// Whether a declared `policy` says anything at all (D3, D5) — `{}` does
/// not, and reads the same as `null` here even though the two stay
/// distinguishable VALUES on `Manifest.policy` itself. Used only by
/// `NoContributions`: a policy that narrows nothing is not a reason a
/// manifest with nothing else in it should be allowed to build.
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
    NoContributions,
    InvalidToolName,
    ReservedToolName,
    DuplicateToolName,
    /// A tool's `timeout_ms` is zero or above `tool.Timeouts.extension_max_ms`.
    InvalidTimeout,
    /// A tool's `surface` is a string, but not one of `auto` / `manual` /
    /// `internal`.
    InvalidSurface,
    /// The manifest's `apply` is a string, but not one of `auto` / `manual`.
    InvalidApply,
    InvalidSkillPath,
    DuplicateSkillPath,
    InvalidSystemPromptPath,
    DuplicateSystemPromptPath,
    /// A system prompt entry's `position` is a string, but not one of `early` /
    /// `normal` / `late`.
    InvalidPromptPosition,
    /// A command's `name` is empty or outside `[a-z0-9-]+`.
    InvalidCommandName,
    DuplicateCommandName,
    /// A command's `action` object does not hold exactly one key (see
    /// `Action`) — the only shape rule on an open verb vocabulary.
    InvalidCommandAction,
    /// A command's `action` is `{"run": "<tool>"}`, but no tool this SAME
    /// manifest declares is named `<tool>` (`Action`).
    UnknownCommandTool,
    /// A `contributes.ui` host key is empty or outside `[a-z0-9-]+`.
    InvalidUiHost,
    /// A `ui` entry's path escapes the package directory — `InvalidEntry` /
    /// `InvalidSystemPromptPath`'s rule, applied to the same field.
    InvalidUiEntry,
    /// A `ui` entry's `api` is zero, which can never be a real API version.
    InvalidUiApi,
};

/// Load `extension.json` into arena-owned memory. Structural only — call
/// `validate` for the kernel rules.
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
        .apply = try optionalString(a, obj, "apply"),
    };
}

/// A slash command name: `[a-z0-9-]+`. Deliberately narrower than
/// `isValidId` (lowercase only, no `.` / `_`) — a command name is typed by a
/// person after `/`, not carried as an opaque id, so the charset matches
/// what a driver's slash dispatcher already expects everywhere else (DESIGN
/// §7.2.1, tui-plugin §3 U1).
fn isValidCommandName(s: []const u8) bool {
    return isLowerDashWord(s);
}

/// A `contributes.ui` host key: `[a-z0-9-]+`, the same charset a command name
/// uses and for the same reason — it is a short word a person writes and a
/// front end matches, never an opaque id.
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

/// An OS key in a per-OS `entry` / `interpreter` object: a `std.Target.Os.Tag`
/// name, or `"default"`. A CLOSED vocabulary the kernel can enumerate, so a typo
/// (`"win"`) is refused here rather than silently meaning "no entry on Windows"
/// — the same reason `surface` refuses a word it cannot read, and the failure
/// this catches would otherwise surface a session away, at `session new`.
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
    };
}

/// A runtime string written either bare or keyed by OS (`PlatformValue`).
/// Anything that is neither a string nor an object is a `WrongType`, the same
/// strictness every other manifest field applies — a mistyped entry must not
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

/// `contributes.system_prompts` (see `SystemPromptSpec`): each entry is a bare
/// path or an object carrying `path` plus an optional `position`. Anything else
/// is a `WrongType` — a mistyped entry must not read as "absent", the strictness
/// every other manifest field applies.
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

/// A tool's `ui` block (see `ToolUi`), or null when the tool wrote none.
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

/// A command's `action` (see `Action`): one key, whose value is a bare `true`
/// (the verb takes no argument) or a string (it does). Anything else under the
/// key is a `WrongType` rather than a silently argument-less verb — the
/// strictness `optionalU32` / `optionalBool` already apply, for their reason.
/// The COUNT of keys is not checked here: `validate` owns that, so a caller
/// that only parses still gets the object it was given.
///
/// A string is a `WrongType` like any other mistyped field. It used to be a
/// mini-language (`"run propose"`) folded by splitting at the first space.
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

/// `contributes.policy` — one optional bool, so there is nothing to duplicate
/// into the arena and no allocator to take.
fn readPolicy(contributes: std.json.ObjectMap) ParseError!?Policy {
    const value = contributes.get("policy") orelse return null;
    const policy_obj = switch (value) {
        .object => |o| o,
        else => return error.WrongType,
    };
    return .{ .readonly = try optionalBool(policy_obj, "readonly") };
}

/// `contributes.ui`, keyed by host (see `UiHost`). There is one shape: a FLAT
/// `{"entry": …, "api": …}` (the pre-M6 spelling, before a second front end was
/// conceivable) now reads as a host named `entry` whose value is a string, so
/// `WrongType` — the schema does not name one concrete front end.
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

/// Read an optional non-negative integer field. A value that is not an integer,
/// or does not fit, is a WrongType — never a silently dropped field, because
/// a mistyped timeout would otherwise read as "use the default".
fn optionalU32(obj: std.json.ObjectMap, key: []const u8) ParseError!?u32 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| std.math.cast(u32, n) orelse error.WrongType,
        else => error.WrongType,
    };
}

/// Read a required non-negative integer field. Missing is a `MissingField`,
/// the same split `dupString` makes for a required string; a value that is
/// not an integer, or does not fit, is a `WrongType` — `optionalU32`'s
/// strictness, minus the "absent is fine" case.
fn requiredU32(obj: std.json.ObjectMap, key: []const u8) ParseError!u32 {
    return switch (obj.get(key) orelse return error.MissingField) {
        .integer => |n| std.math.cast(u32, n) orelse error.WrongType,
        else => error.WrongType,
    };
}

/// Read an optional boolean field. Absent stays absent — "the package did not
/// say" is its own answer — and a non-boolean is a WrongType rather than a
/// silently ignored key, for the same reason `optionalU32` is strict.
fn optionalBool(obj: std.json.ObjectMap, key: []const u8) ParseError!?bool {
    return switch (obj.get(key) orelse return null) {
        .bool => |b| b,
        else => error.WrongType,
    };
}

/// Read an optional string field. Absent stays absent, and a non-string is a
/// WrongType rather than a silently ignored key — the same strictness as
/// `optionalU32` / `optionalBool`, for the same reason.
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
    // Each of the three was once parsed, frozen and read by something. Nothing
    // reads them now, and nothing about a package carrying one changes: they
    // are unknown keys, exactly like a key nobody has ever defined.
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","activation":"on_request","permissions":{"fs":"rw"},
        \\ "runtime":{"entry":"src/run.sh","interpreter":"sh","wire":"jsonrpc"},
        \\ "contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqual(Apply.manual, m.applyOf());
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
    // Every variant is a script, so the package is one implementation kind.
    try std.testing.expect(isScript(rt));
    try std.testing.expectEqual(ImplementationKind.script, implementationKind(m));
    try std.testing.expectEqualStrings("src/run.ps1", rt.entry.forOs("windows").?);
    try std.testing.expectEqualStrings("src/run.sh", rt.entry.forOs("linux").?);
    try std.testing.expectEqualStrings("powershell", rt.interpreter.?.forOs("windows").?);
    try std.testing.expectEqualStrings("sh", rt.interpreter.?.forOs("macos").?);

    // No `default`: a host outside the list simply has no entry here. That is a
    // nameable state, not a broken package — the version stays buildable and
    // installable, and only running it on that host fails.
    var narrow = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{"linux":"src/run.sh"},"interpreter":{"linux":"sh"}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer narrow.deinit();
    try narrow.validate();
    try std.testing.expectEqualStrings("src/run.sh", narrow.runtime.?.entry.forOs("linux").?);
    try std.testing.expect(narrow.runtime.?.entry.forOs("windows") == null);

    // A bare string still answers for every host — the shape most manifests use.
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

    // A `bin/` path inside the object: two implementation kinds under one
    // version id, which the id cannot be.
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

    // A typo'd OS key would otherwise mean "no entry on Windows", and say so a
    // session later. Refused where the file is read instead.
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

    // An empty object declares nothing at all.
    var empty = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer empty.deinit();
    try std.testing.expectError(error.InvalidEntry, empty.validate());

    // A non-string variant is a parse error, like every other mistyped field.
    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{"windows":42}},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ));
    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":["src/run.sh"]},"contributes":{"tools":[{"name":"t","input":{}}]}}
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

    // `edit` is an extension tool now (the bundled `std` package declares it),
    // so the manifest layer must let a package claim that name.
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

    // Absent means the host default; the field is optional and nothing else changes.
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

    // A mistyped timeout is a parse error, not a silently defaulted one.
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
    // Nothing in `validate` looks at it: the claim is for a driver's approval
    // policy to read, and a package that lies about it is exactly as dangerous
    // as one that lies about anything else it declares (DESIGN §9).
    try m.validate();
    try std.testing.expectEqual(@as(?bool, true), m.tools[0].readonly);
    try std.testing.expectEqual(@as(?bool, false), m.tools[1].readonly);
    // Absent is NOT false: the package said nothing, and a reader that turns
    // silence into a claim would be inventing the one thing this field is for.
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
    // Silence is the DEFAULT, not "did not say": a scaffolded tool reaches the
    // model as soon as its package is composed in, with nothing else to write.
    try std.testing.expect(m.tools[3].surface == null);
    try std.testing.expectEqual(Surface.auto, m.tools[3].surfaceOf());

    // A word outside the three is a named refusal, not a default — including
    // the three words this vocabulary used to be spelled with.
    for ([_][]const u8{ "public", "pin", "with", "driver" }) |word| {
        const src = try std.fmt.allocPrint(alloc,
            \\{{"schema":"nulya.extension/v2","id":"a","runtime":{{"entry":"bin/a"}},"contributes":{{"tools":[{{"name":"t","input":{{}},"surface":"{s}"}}]}}}}
        , .{word});
        defer alloc.free(src);
        var typo = try parse(alloc, src);
        defer typo.deinit();
        try std.testing.expectError(error.InvalidSurface, typo.validate());
    }

    // And a wrong TYPE is a parse error, the same split `timeout_ms` makes.
    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"surface":true}]}}
    ));
}

test "apply says what activating this package means; silence means manual and an unknown word is refused" {
    const alloc = std.testing.allocator;

    var auto = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"kong","apply":"auto","contributes":{"system_prompts":["p.md"]}}
    );
    defer auto.deinit();
    try auto.validate();
    try std.testing.expectEqual(Apply.auto, auto.applyOf());

    var manual = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"kong","apply":"manual","contributes":{"system_prompts":["p.md"]}}
    );
    defer manual.deinit();
    try manual.validate();
    try std.testing.expectEqual(Apply.manual, manual.applyOf());

    // Silence is the conservative half: a package nobody named is in no
    // session, which is what every package written before this key assumed.
    var quiet = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"b","contributes":{"system_prompts":["p.md"]}}
    );
    defer quiet.deinit();
    try quiet.validate();
    try std.testing.expect(quiet.apply == null);
    try std.testing.expectEqual(Apply.manual, quiet.applyOf());

    // A typo must not read as `manual`: the author would install a mode and
    // never see it in a session, with nothing anywhere saying why.
    var typo = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"b","apply":"always","contributes":{"system_prompts":["p.md"]}}
    );
    defer typo.deinit();
    try std.testing.expectError(error.InvalidApply, typo.validate());

    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"b","apply":true,"contributes":{"system_prompts":["p.md"]}}
    ));
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
    // The object form without the key is silent, exactly like the bare string.
    try std.testing.expect(m.system_prompts[3].position == null);
    try std.testing.expectEqual(PromptPosition.normal, m.system_prompts[3].positionOf());

    // A word outside the three is a refusal, not a silent `normal`.
    const typo =
        \\{"schema":"nulya.extension/v2","id":"p","contributes":{"system_prompts":[{"path":"a.md","position":"latte"}]}}
    ;
    var t = try parse(alloc, typo);
    defer t.deinit();
    try std.testing.expectError(error.InvalidPromptPosition, t.validate());

    // The path rules still apply through the object form.
    const escape =
        \\{"schema":"nulya.extension/v2","id":"p","contributes":{"system_prompts":[{"path":"../evil.md","position":"late"}]}}
    ;
    var e = try parse(alloc, escape);
    defer e.deinit();
    try std.testing.expectError(error.InvalidSystemPromptPath, e.validate());

    // Duplicates are duplicates whichever form each was written in.
    const dup =
        \\{"schema":"nulya.extension/v2","id":"p","contributes":{"system_prompts":["a.md",{"path":"a.md","position":"late"}]}}
    ;
    var d = try parse(alloc, dup);
    defer d.deinit();
    try std.testing.expectError(error.DuplicateSystemPromptPath, d.validate());

    // A mistyped entry is a WrongType, never "absent".
    const wrong =
        \\{"schema":"nulya.extension/v2","id":"p","contributes":{"system_prompts":[42]}}
    ;
    try std.testing.expectError(error.WrongType, parse(alloc, wrong));
}

// --- tui-plugin U1: `commands` / `policy` / a tool's `ui` / the package `ui` -----

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
    // Absent is null, not any particular word — same as `readonly`.
    try std.testing.expect(m.tools[1].ui == null);

    try std.testing.expectEqual(@as(usize, 2), m.commands.len);
    try std.testing.expectEqualStrings("plan", m.commands[0].name);
    try std.testing.expectEqualStrings("with", m.commands[0].action.verb);
    // A verb that takes no argument carries none: `true` is the key's presence
    // said out loud, not a value a reader has to interpret.
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

    // Two verbs is not "both": nothing could decide which one typing the
    // command does, so the file is wrong rather than the reader guessing.
    var two = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"with":true,"skill":"s"}}]}}
    );
    defer two.deinit();
    try std.testing.expectError(error.InvalidCommandAction, two.validate());

    // A verb the kernel has never heard of is fine — the vocabulary is open,
    // and skipping it is the reader's move.
    var unknown = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"review":"changes"}}]}}
    );
    defer unknown.deinit();
    try unknown.validate();
    try std.testing.expectEqualStrings("review", unknown.commands[0].action.verb);
    try std.testing.expectEqualStrings("changes", unknown.commands[0].action.target.?);

    // Anything but `true` or a string under the key is a parse error, not a
    // verb that quietly lost its argument.
    for ([_][]const u8{
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"run":42}}]}}
        ,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"with":false}}]}}
        ,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":["with"]}]}}
        ,
        // The string mini-language (`"run propose"`) is gone with the rest of
        // the folded shapes: a reader that had to split on a space to find out
        // what it was holding is one shape too many.
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":"run propose"}]}}
        ,
    }) |src| {
        try std.testing.expectError(error.WrongType, parse(alloc, src));
    }

    // And an action is required the moment a command is written at all.
    try std.testing.expectError(error.MissingField, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":""}]}}
    ));
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

    // The open vocabulary: `validate` never refuses a verb it does not know.
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

    // `allow` used to be a parse-time refusal — a package placing authority
    // INTO an approval table (physics #6). With one narrow-only field left,
    // that rule is carried by the SHAPE: `allow` is simply an unknown key, and
    // a policy that says nothing this build reads contributes nothing.
    var allow = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{"allow":["shell"]}}}
    );
    defer allow.deinit();
    try std.testing.expectError(error.NoContributions, allow.validate());

    // A `{}` is present but says nothing, and reads the same as never having
    // written `contributes.policy` at all for `NoContributions`'s purposes.
    var alone = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{}}}
    );
    defer alone.deinit();
    try std.testing.expectError(error.NoContributions, alone.validate());

    // Beside another contribution, the parsed VALUE is still there to read —
    // present but empty, a different fact than never having written the key.
    var declared_empty = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":{"with":true}}],"policy":{}}}
    );
    defer declared_empty.deinit();
    try declared_empty.validate();
    try std.testing.expect(declared_empty.policy != null);
    try std.testing.expect(declared_empty.policy.?.readonly == null);

    // A mistyped `readonly` is a parse error, like every other bool field.
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

    // The host key's charset is checked; the WORD never is — the kernel's
    // schema must not name one front end.
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

    // `api` is required the moment a host entry is written at all.
    try std.testing.expectError(error.MissingField, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"tui":{"entry":"tui/panel.ts"}}}}
    ));

    // An empty object declares no front-end module, which alone is no
    // contribution at all.
    var none = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{}}}
    );
    defer none.deinit();
    try std.testing.expectError(error.NoContributions, none.validate());
}

test "the pre-host flat ui block is not a second shape: it reads as a host whose entry is a string" {
    // `{"entry": …, "api": …}` was the spelling before a second front end was
    // conceivable. There is one shape now, so the flat form is simply a host
    // named `entry` whose value is not an object — a `WrongType`, like any
    // other mistyped field. Nothing folds it, because the kernel's schema must
    // not name one concrete front end (`UiHost`).
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

    // `readonly: true` is content; an empty `{}` would not be (see the
    // "policy is one optional bool" test above).
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
    // `valid_manifest` (top of file) has none of these three — the fixture
    // that already stood for "the format before this field existed".
    var m = try parse(std.testing.allocator, valid_manifest);
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqual(@as(usize, 0), m.commands.len);
    try std.testing.expect(m.policy == null);
    try std.testing.expectEqual(@as(usize, 0), m.ui.len);
    try std.testing.expect(m.tools[0].ui == null);
}
