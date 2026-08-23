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

/// How the host talks to a runtime for one call (DESIGN §7.1, §7.3). A closed
/// two-word vocabulary the kernel ENFORCES: it decides what is written to the
/// child's stdin and how its stdout is read, so an unrecognized word cannot be
/// left to a reader.
///
///   - `jsonrpc` : one JSON-RPC 2.0 `tool/call` request in, one response out
///                 (`protocol.zig`). The default, so every manifest written
///                 before this field means exactly what it meant.
///   - `plain`   : the arguments JSON on stdin, `NULYA_TOOL` / `NULYA_ARG_<k>`
///                 in the environment, stdout verbatim as the tool's text,
///                 exit code as ok/failed. Five lines of `sh` can serve it.
///
/// Independent of `ImplementationKind`: a compiled Zig runtime may declare
/// `plain` too. What the wire says is how to TALK to a process, not what kind
/// of process it is.
pub const Wire = enum {
    jsonrpc,
    plain,

    pub fn fromString(s: []const u8) ?Wire {
        if (std.mem.eql(u8, s, "jsonrpc")) return .jsonrpc;
        if (std.mem.eql(u8, s, "plain")) return .plain;
        return null;
    }
};

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
    /// How to talk to this runtime, kept as WRITTEN — the `audience`
    /// discipline, for its reason: a wrong TYPE is a parse error, an
    /// unrecognized WORD is a named `validate` refusal (`InvalidWire`), and the
    /// reading of ABSENT is decided once, here (`wireOf` → `.jsonrpc`), because
    /// it is a fact about the file format rather than a judgement.
    wire: ?[]const u8 = null,

    /// How to talk to this runtime. Absent means `.jsonrpc` (see the field),
    /// and so does a word `validate` would refuse — on a validated manifest
    /// that case cannot occur.
    pub fn wireOf(self: Runtime) Wire {
        const written = self.wire orelse return .jsonrpc;
        return Wire.fromString(written) orelse .jsonrpc;
    }
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

/// Who a tool is FOR — the only question about a tool that only its own package
/// can answer (DESIGN §7.2.1).
///
///   - `model`  : it belongs on the model's tool face; pinning it is the point.
///   - `driver` : it is an interface for whoever DRIVES a session (`nulya ext
///                run`, a front end, a script). Putting it on the model's face
///                would at best waste a slot and at worst deadlock — `compact`
///                appends to and steps the very session it is called about.
pub const Audience = enum {
    model,
    driver,

    pub fn fromString(s: []const u8) ?Audience {
        if (std.mem.eql(u8, s, "model")) return .model;
        if (std.mem.eql(u8, s, "driver")) return .driver;
        return null;
    }
};

/// A tool's front-end rendering hints (DESIGN §7.2.1, tui-plugin D12) — the
/// FRONT-END tier of the manifest: an open vocabulary, never refused by
/// `validate`, and read by nobody but whoever draws a tool's calls on a
/// screen.
pub const ToolUi = struct {
    /// A rendering HINT for whoever draws this tool's calls — a word from an
    /// OPEN vocabulary (`"checklist"`, `"markdown"`, more later), kept as
    /// WRITTEN and NEVER refused by `validate`. Unlike `audience` (a closed
    /// two-word set the kernel can exhaustively check), this vocabulary is
    /// expected to grow, so an unrecognized word is the READER's decision —
    /// fall back to a plain card and move on — not a build-time refusal.
    /// Absent is null, not any particular word: the same "silence is not a
    /// claim" discipline as `readonly` and `audience`.
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
    /// person would want to approve first. A DECLARATION, exactly like
    /// `permissions` (DESIGN §9) — the kernel parses it, records it in the
    /// frozen manifest, and enforces nothing. What consumes it is a driver's
    /// approval policy (`loop.ToolGate`, DESIGN §4), which is free to ignore it;
    /// a real boundary needs OS enforcement (PLAN §3.8), not a boolean.
    ///
    /// Absent means the package did not say, which is not the same as `false`
    /// and must not be read as one.
    readonly: ?bool = null,
    /// The package's statement of who this tool is for — kept as WRITTEN, so
    /// that an unrecognized word is a named `validate` refusal rather than a
    /// silent default (`audienceOf`, `InvalidAudience`). Exactly the discipline
    /// `timeout_ms` follows: a wrong TYPE is a parse error, a wrong VALUE is a
    /// validate error.
    ///
    /// A DECLARATION, like `readonly` and `permissions` beside it: the kernel
    /// parses it, freezes it into the version's manifest, and enforces nothing.
    /// Nothing here filters a tool face or refuses a pin — pinning a `driver`
    /// tool stays legal, it is simply not what a driver would do by default.
    /// The consumers are a driver's own policies: which tools a standing pin
    /// list holds, which ones a panel lists, which ones an approval rule is about.
    ///
    /// Absent is null, NOT `.model`. "The package did not say" and "the package
    /// said model" are different facts; a reader is free to treat silence as
    /// model (every manifest written before this field existed declares model
    /// tools), but that reading is the reader's, made where it is used.
    audience: ?[]const u8 = null,
    /// This tool's front-end rendering hints (see `ToolUi`), or null when the
    /// package made neither claim. Grouped under one FRONT-END key, distinct
    /// from `readonly` / `audience` above: those two are read by the kernel's
    /// gate and by `--pin`/`--with` composition, this one only by whoever
    /// draws a call on a screen.
    ui: ?ToolUi = null,

    /// The declared audience, decoded. Null when absent — and also when the
    /// word is not one of the two, which `validate` refuses, so on a validated
    /// manifest null means only "did not say".
    pub fn audienceOf(self: ToolSpec) ?Audience {
        return Audience.fromString(self.audience orelse return null);
    }
};

/// A package's claimed filesystem/network/process footprint — a declaration, zero readers today, waiting for M7's sandbox.
pub const Permissions = struct {
    fs: []const []const u8 = &.{},
    network: []const []const u8 = &.{},
    process: []const []const u8 = &.{},
};

/// A slash command this package offers whoever DRIVES a session (DESIGN
/// §7.2.1, tui-plugin D1/D2/D8). Declared in the manifest — not in a sidecar
/// the front end alone reads — so any driver, headless or not, sees the same
/// commands a session's frozen composition actually carries.
pub const Command = struct {
    name: []const u8,
    description: []const u8,
    /// The verb this command performs, kept as WRITTEN — the same "silence is
    /// not a claim, a wrong TYPE is a parse error" discipline as `audience`,
    /// but NOT the same discipline for a wrong VALUE: this vocabulary
    /// (`"with"` / `"run <tool>"` / `"skill <ref>"` today) is expected to
    /// grow, so an unrecognized verb is the READER's decision (warn and
    /// skip), never a `validate` refusal (tui-plugin D1 / DESIGN §7.2.1
    /// `ToolUi.render` precedent). The one shape `validate` DOES check is the
    /// `"run <tool>"` case: `<tool>` must name a tool this SAME manifest
    /// declares (`commandRunTarget` + `UnknownCommandTool`) — that is a
    /// closed, in-package reference, a fact about this file's own shape, not
    /// a member of the open verb vocabulary.
    action: []const u8,
};

/// The narrowing this package asks an approval policy to apply while it is a
/// member of a session's frozen composition (DESIGN §7.2.1, tui-plugin
/// D2/D3). A DECLARATION exactly like `ToolSpec.readonly` / `.audience`
/// beside it: the kernel parses it, freezes it into the version, and
/// enforces nothing — the consumer is a driver's own approval policy (TUI's
/// `approvals.decide`).
///
/// The shape is deliberately narrow-ONLY: `readonly` / `deny` / `ask` mirror
/// the tables an approval policy already reads (`[approvals]`), and there is
/// no `allow`. A package that could ADD an entry to an allow table would be
/// authority growing implicitly through membership alone (physics #6) — the
/// same reasoning `mergeProject`'s "only ever narrows" already rests on. That
/// is why an `allow` key is refused in `dupPolicy`, at PARSE time: its
/// presence alone is the violation, no value under it could make the shape
/// acceptable, so there is nothing left for `validate` to check.
pub const Policy = struct {
    /// Same three-state discipline as `ToolSpec.readonly`: absent is null,
    /// not `false` — the package said nothing, which is not the same as
    /// saying "not readonly".
    readonly: ?bool = null,
    /// Tool ids / names / `shell:<prefix>` entries an approval policy should
    /// treat as denied while this package is a composition member. Absent
    /// reads as empty, the same convention `skills` / `system_prompts` /
    /// `Permissions` fields already use.
    deny: []const []const u8 = &.{},
    /// Same shape as `deny`, for the table an approval policy asks about
    /// before running.
    ask: []const []const u8 = &.{},
};

/// The package's own front-end module, if it has one (DESIGN §7.2.1,
/// tui-plugin D1/D10) — the FRONT-END tier's own code layer, `contributes.ui`
/// in the manifest. A DECLARATION only: the kernel validates the SHAPE (a
/// safe relative path, a non-zero API version) and never loads or executes
/// it — loading is a front end's job, not this layer's, and is out of scope
/// until U3.
pub const Ui = struct {
    /// Package-relative path to the module a front end loads. Same
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
    /// policy for U3) — not membership in a vocabulary. Zero can never be a
    /// real version, so it is the one value `validate` refuses
    /// (`InvalidUiApi`); there is no "absent" case because `Ui` itself is
    /// optional on `Manifest` — a package with no `ui` block simply has no
    /// `Ui` value.
    api: u32,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    schema: []const u8,
    id: []const u8,
    runtime: ?Runtime,
    tools: []const ToolSpec,
    skills: []const []const u8,
    system_prompts: []const []const u8,
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
    /// This package's front-end module (see `Ui`), or null when it has
    /// none.
    ui: ?Ui = null,
    /// See `Permissions` — a declaration, zero readers today, waiting for M7.
    permissions: Permissions,
    /// True when this manifest still writes the removed `activation` key.
    ///
    /// The key is an UNKNOWN key now, so parsing ignores it like any other and
    /// nothing about the package changes. But a draft still carrying it was
    /// written to mean something ("only the sessions that name me"), and that
    /// meaning now lives in one place a package cannot reach: config's
    /// `[extensions] with` (DESIGN §5.1) — reach is the person's decision, not
    /// the author's. Silently ignoring the word would leave the author believing
    /// their package still opts out, so `ext build` / `ext sync` say one line
    /// about it. The only reader is that note; nothing in a session ever asks.
    legacy_activation: bool = false,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Enforce the deterministic kernel rules (DESIGN §7.4, §12). Whether a tool
    /// is "good taste" is policy, checked elsewhere — not here.
    pub fn validate(self: Manifest) ValidateError!void {
        if (!std.mem.eql(u8, self.schema, schema_id)) return error.UnsupportedSchema;
        if (!isValidId(self.id)) return error.InvalidId;
        if (self.tools.len == 0 and self.skills.len == 0 and self.system_prompts.len == 0 and
            self.commands.len == 0 and !policyContributes(self.policy) and self.ui == null) return error.NoContributions;

        if (self.runtime) |rt| {
            if (rt.wire) |w| {
                if (Wire.fromString(w) == null) return error.InvalidWire;
            }
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
            // A word outside the two is refused rather than read as the
            // default: a package that meant `driver` and typed `drivers` would
            // otherwise land its tool on the model's face, which is the exact
            // outcome the field exists to prevent.
            if (t.audience) |a| {
                if (Audience.fromString(a) == null) return error.InvalidAudience;
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

        for (self.system_prompts, 0..) |prompt_path, i| {
            if (!isSafeRelPath(prompt_path)) return error.InvalidSystemPromptPath;
            for (self.system_prompts[i + 1 ..]) |other| {
                if (std.mem.eql(u8, prompt_path, other)) return error.DuplicateSystemPromptPath;
            }
        }

        for (self.commands, 0..) |c, i| {
            if (!isValidCommandName(c.name)) return error.InvalidCommandName;
            for (self.commands[i + 1 ..]) |other| {
                if (std.mem.eql(u8, c.name, other.name)) return error.DuplicateCommandName;
            }
            // The one shape check on an otherwise open verb vocabulary (see
            // `Command.action`): a `"run <tool>"` command must name a tool
            // THIS manifest itself declares — a closed, in-package reference,
            // not a member of a word list that might grow.
            if (commandRunTarget(c.action)) |target| {
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

        // `readonly` needs no check (same three-state bool as `ToolSpec`); the
        // shape violation `Policy` refuses (an `allow` key) is caught earlier,
        // at parse time, in `dupPolicy` — by the time `validate` runs it
        // cannot occur. All that is left here is entries with nothing in them.
        if (self.policy) |p| {
            for (p.deny) |entry| if (entry.len == 0) return error.InvalidPolicyEntry;
            for (p.ask) |entry| if (entry.len == 0) return error.InvalidPolicyEntry;
        }

        if (self.ui) |u| {
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
    return policy.readonly != null or policy.deny.len != 0 or policy.ask.len != 0;
}

pub const ParseError = error{
    InvalidJson,
    NotAnObject,
    MissingField,
    WrongType,
    /// `contributes.policy` contains an `allow` key. Refused here rather than
    /// in `validate`, because the violation is the key's mere PRESENCE — no
    /// value under it could make the shape acceptable (see `Policy`).
    PolicyAllowNotPermitted,
} || std.mem.Allocator.Error;

pub const ValidateError = error{
    UnsupportedSchema,
    InvalidId,
    MissingRuntime,
    InvalidEntry,
    InvalidInterpreter,
    /// `runtime.wire` is a string, but not one of `jsonrpc` / `plain`.
    InvalidWire,
    NoContributions,
    InvalidToolName,
    ReservedToolName,
    DuplicateToolName,
    /// A tool's `timeout_ms` is zero or above `tool.Timeouts.extension_max_ms`.
    InvalidTimeout,
    /// A tool's `audience` is a string, but not one of `model` / `driver`.
    InvalidAudience,
    InvalidSkillPath,
    DuplicateSkillPath,
    InvalidSystemPromptPath,
    DuplicateSystemPromptPath,
    /// A command's `name` is empty or outside `[a-z0-9-]+`.
    InvalidCommandName,
    DuplicateCommandName,
    /// A command's `action` is `"run <tool>"`, but no tool this SAME manifest
    /// declares is named `<tool>` (`Command.action`).
    UnknownCommandTool,
    /// A `policy.deny` / `policy.ask` entry is the empty string.
    InvalidPolicyEntry,
    /// `ui.entry` escapes the package directory — `InvalidEntry` /
    /// `InvalidSystemPromptPath`'s rule, applied to the same field.
    InvalidUiEntry,
    /// `ui.api` is zero, which can never be a real API version.
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
    const system_prompts = try dupStringList(a, contributes, "system_prompts");
    const commands = try dupCommands(a, contributes);
    const policy = try dupPolicy(a, contributes);
    const ui = try dupUi(a, contributes);
    const permissions: Permissions = .{
        .fs = try dupPermissionList(a, obj, "fs"),
        .network = try dupPermissionList(a, obj, "network"),
        .process = try dupPermissionList(a, obj, "process"),
    };
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
        .permissions = permissions,
        // An unknown key, read for one purpose: `ext build` says a line about it
        // (see the field). Nothing composed from this manifest is affected.
        .legacy_activation = obj.get("activation") != null,
    };
}

/// A slash command name: `[a-z0-9-]+`. Deliberately narrower than
/// `isValidId` (lowercase only, no `.` / `_`) — a command name is typed by a
/// person after `/`, not carried as an opaque id, so the charset matches
/// what a driver's slash dispatcher already expects everywhere else (DESIGN
/// §7.2.1, tui-plugin §3 U1).
fn isValidCommandName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// `action`'s one checked shape: `"run <tool>"`. Returns the tool name when
/// `action` has that prefix, null for every other verb (including a bare
/// `"run"` with nothing after it) — those are left to the open vocabulary
/// `Command.action` describes, not checked here.
fn commandRunTarget(action: []const u8) ?[]const u8 {
    const prefix = "run ";
    if (!std.mem.startsWith(u8, action, prefix)) return null;
    return action[prefix.len..];
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
/// — the same reason `audience` refuses a word it cannot read, and the failure
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
        .wire = try optionalString(a, runtime_obj, "wire"),
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
            .audience = try optionalString(a, to, "audience"),
            .ui = try dupToolUi(a, to),
        };
    }
    return tools;
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
            .action = try dupString(a, co, "action"),
        };
    }
    return commands;
}

fn dupPolicy(a: std.mem.Allocator, contributes: std.json.ObjectMap) ParseError!?Policy {
    const value = contributes.get("policy") orelse return null;
    const policy_obj = switch (value) {
        .object => |o| o,
        else => return error.WrongType,
    };
    // D3 (physics #6, no implicit authority growth): a package's policy may
    // only NARROW the tables an approval policy already reads — never place
    // authority INTO them. An `allow` key's mere PRESENCE is the violation,
    // so it is refused here rather than left for `validate` to reject a value
    // that could never have been acceptable in the first place.
    if (policy_obj.get("allow") != null) return error.PolicyAllowNotPermitted;
    return .{
        .readonly = try optionalBool(policy_obj, "readonly"),
        .deny = try dupStringList(a, policy_obj, "deny"),
        .ask = try dupStringList(a, policy_obj, "ask"),
    };
}

fn dupUi(a: std.mem.Allocator, contributes: std.json.ObjectMap) ParseError!?Ui {
    const value = contributes.get("ui") orelse return null;
    const ui_obj = switch (value) {
        .object => |o| o,
        else => return error.WrongType,
    };
    return .{
        .entry = try dupString(a, ui_obj, "entry"),
        .api = try requiredU32(ui_obj, "api"),
    };
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

/// Read a string list out of the nested `permissions` object; absent -> empty.
fn dupPermissionList(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![]const []const u8 {
    const perms = switch (obj.get("permissions") orelse return a.alloc([]const u8, 0)) {
        .object => |o| o,
        else => return error.WrongType,
    };
    return dupStringList(a, perms, key);
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
    \\  },
    \\  "permissions": { "fs": [], "network": ["https"], "process": [] }
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
    try std.testing.expectEqual(@as(usize, 1), m.permissions.network.len);
    try std.testing.expectEqualStrings("https", m.permissions.network[0]);
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
    // Saying nothing about the wire means what it has always meant.
    try std.testing.expectEqual(@as(Wire, .jsonrpc), m.runtime.?.wireOf());
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

test "a runtime says how to talk to it; silence is jsonrpc and an unknown word is refused" {
    const alloc = std.testing.allocator;

    var plain = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"src/run.sh","interpreter":"sh","wire":"plain"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer plain.deinit();
    try plain.validate();
    try std.testing.expectEqual(@as(Wire, .plain), plain.runtime.?.wireOf());

    // Both kinds may declare either wire: what it says is how to TALK to a
    // process, not what kind of process it is.
    var compiled_plain = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a","wire":"plain"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer compiled_plain.deinit();
    try compiled_plain.validate();
    try std.testing.expectEqual(@as(Wire, .plain), compiled_plain.runtime.?.wireOf());

    // A word outside the two is a named refusal, not a default: the wire decides
    // what is written to stdin, so a typo cannot be left to a reader.
    var typo = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"src/run.sh","wire":"json-rpc"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer typo.deinit();
    try std.testing.expectError(error.InvalidWire, typo.validate());

    // And a wrong TYPE is a parse error — `audience`'s split, for its reason.
    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"src/run.sh","wire":true},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ));
}

test "entry and interpreter may be written per OS; the host picks, then `default`, then nothing" {
    const alloc = std.testing.allocator;
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":{"windows":"src/run.ps1","default":"src/run.sh"},"interpreter":{"windows":"powershell","default":"sh"},"wire":"plain"},"contributes":{"tools":[{"name":"t","input":{}}]}}
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
    // as one that lies in `permissions` (DESIGN §9).
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

test "a tool may declare who it is for; silence is not a claim and an unknown word is refused" {
    const alloc = std.testing.allocator;
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"ask","input":{},"audience":"model"},{"name":"drive","input":{},"audience":"driver"},{"name":"quiet","input":{}}]}}
    );
    defer m.deinit();
    // Nothing in `validate` acts on it beyond refusing a word it cannot read:
    // like `readonly`, the claim is recorded for a driver's policy to consult,
    // and the kernel neither filters the tool face nor refuses a pin over it.
    try m.validate();
    try std.testing.expectEqual(@as(?Audience, .model), m.tools[0].audienceOf());
    try std.testing.expectEqual(@as(?Audience, .driver), m.tools[1].audienceOf());
    // Absent is NOT `model`: the reading of silence belongs to whoever uses it.
    try std.testing.expect(m.tools[2].audience == null);
    try std.testing.expect(m.tools[2].audienceOf() == null);

    // A word outside the two is a named refusal, not a default.
    var typo = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"audience":"drivers"}]}}
    );
    defer typo.deinit();
    try std.testing.expectError(error.InvalidAudience, typo.validate());

    // And a wrong TYPE is a parse error, the same split `timeout_ms` makes.
    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"audience":true}]}}
    ));
}

test "the removed `activation` key is ignored, whatever it says, and only flagged for a build note" {
    const alloc = std.testing.allocator;

    // A package that still writes it parses and validates exactly like one that
    // does not. Which sessions it joins is not its decision any more: config's
    // `[extensions] with` names the members, `--with` names them for one session
    // (DESIGN §5.1), and both read the same `current` this key used to qualify.
    var mode = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"evolution","activation":"on_request","contributes":{"system_prompts":["p.md"]}}
    );
    defer mode.deinit();
    try mode.validate();
    try std.testing.expect(mode.legacy_activation);

    // Including a word the old enum would have refused: an unknown key has no
    // vocabulary to be outside of, so `onrequest` is no more an error than
    // `on_request` is — and neither is a wrong TYPE, which used to be one.
    for ([_][]const u8{
        \\{"schema":"nulya.extension/v2","id":"a","activation":"onrequest","contributes":{"skills":["s"]}}
        ,
        \\{"schema":"nulya.extension/v2","id":"a","activation":false,"contributes":{"skills":["s"]}}
        ,
    }) |src| {
        var m = try parse(alloc, src);
        defer m.deinit();
        try m.validate();
        try std.testing.expect(m.legacy_activation);
    }

    // Silence is the ordinary case and says nothing at all — no default to
    // infer from the package's shape, because there is no longer a question
    // here for a shape to answer.
    var quiet = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"b","contributes":{"system_prompts":["p.md"]}}
    );
    defer quiet.deinit();
    try quiet.validate();
    try std.testing.expect(!quiet.legacy_activation);
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
    try std.testing.expectEqualStrings("prompts/finance.md", m.system_prompts[0]);
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
        \\      {"name": "plan", "description": "review a plan", "action": "with"},
        \\      {"name": "review", "description": "run the propose tool", "action": "run propose"}
        \\    ],
        \\    "policy": {"readonly": true, "deny": ["shell"], "ask": ["propose"]},
        \\    "ui": {"entry": "tui/panel.ts", "api": 1}
        \\  }
        \\}
    ;
    var m = try parse(alloc, src);
    defer m.deinit();
    try m.validate();

    try std.testing.expectEqualStrings("checklist", m.tools[0].ui.?.render.?);
    try std.testing.expectEqual(@as(?bool, true), m.tools[0].ui.?.panel);
    // Absent is null, not any particular word — same as `audience`/`readonly`.
    try std.testing.expect(m.tools[1].ui == null);

    try std.testing.expectEqual(@as(usize, 2), m.commands.len);
    try std.testing.expectEqualStrings("plan", m.commands[0].name);
    try std.testing.expectEqualStrings("with", m.commands[0].action);
    try std.testing.expectEqualStrings("review", m.commands[1].name);
    try std.testing.expectEqualStrings("run propose", m.commands[1].action);

    const p = m.policy.?;
    try std.testing.expectEqual(@as(?bool, true), p.readonly);
    try std.testing.expectEqual(@as(usize, 1), p.deny.len);
    try std.testing.expectEqualStrings("shell", p.deny[0]);
    try std.testing.expectEqual(@as(usize, 1), p.ask.len);
    try std.testing.expectEqualStrings("propose", p.ask[0]);

    const u = m.ui.?;
    try std.testing.expectEqualStrings("tui/panel.ts", u.entry);
    try std.testing.expectEqual(@as(u32, 1), u.api);
}

test "a command name is [a-z0-9-]+ and may not repeat within a package" {
    const alloc = std.testing.allocator;

    var upper = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"Plan","description":"","action":"with"}]}}
    );
    defer upper.deinit();
    try std.testing.expectError(error.InvalidCommandName, upper.validate());

    var empty = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"","description":"","action":"with"}]}}
    );
    defer empty.deinit();
    try std.testing.expectError(error.InvalidCommandName, empty.validate());

    var dup = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"plan","description":"","action":"with"},{"name":"plan","description":"","action":"skill x"}]}}
    );
    defer dup.deinit();
    try std.testing.expectError(error.DuplicateCommandName, dup.validate());
}

test "a `run <tool>` command must name a tool this same manifest declares; other verbs are the reader's word" {
    const alloc = std.testing.allocator;

    // The open vocabulary: `validate` never refuses a verb it does not know.
    var with_action = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"plan","description":"","action":"with"}]}}
    );
    defer with_action.deinit();
    try with_action.validate();

    var skill = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"help","description":"","action":"skill some/ref"}]}}
    );
    defer skill.deinit();
    try skill.validate();

    // `"run <tool>"` IS checked: the closed, in-package reference.
    var missing = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"other","input":{}}],"commands":[{"name":"review","description":"","action":"run propose"}]}}
    );
    defer missing.deinit();
    try std.testing.expectError(error.UnknownCommandTool, missing.validate());

    var present = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"propose","input":{}}],"commands":[{"name":"review","description":"","action":"run propose"}]}}
    );
    defer present.deinit();
    try present.validate();
}

test "policy may only narrow: an `allow` key is refused at parse time; an empty entry at validate time" {
    const alloc = std.testing.allocator;

    // The key's mere presence is the violation — no value under it could pass.
    try std.testing.expectError(error.PolicyAllowNotPermitted, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{"allow":["shell"]}}}
    ));

    var empty_deny = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{"deny":[""]}}}
    );
    defer empty_deny.deinit();
    try std.testing.expectError(error.InvalidPolicyEntry, empty_deny.validate());

    var empty_ask = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{"ask":[""]}}}
    );
    defer empty_ask.deinit();
    try std.testing.expectError(error.InvalidPolicyEntry, empty_ask.validate());

    // A `{}` is present but says nothing — it narrows nothing, so it reads
    // the same as never having written `contributes.policy` at all for
    // `NoContributions`'s purposes (D3/D5). Alone, that IS no contribution.
    var alone = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{}}}
    );
    defer alone.deinit();
    try std.testing.expectError(error.NoContributions, alone.validate());

    // Beside another contribution, the parsed VALUE is still there to read —
    // present but empty, a different fact than never having written the key
    // at all, even though the two count the same toward `NoContributions`.
    var declared_empty = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"x","description":"","action":"with"}],"policy":{}}}
    );
    defer declared_empty.deinit();
    try declared_empty.validate();
    try std.testing.expect(declared_empty.policy != null);
    try std.testing.expect(declared_empty.policy.?.readonly == null);
    try std.testing.expectEqual(@as(usize, 0), declared_empty.policy.?.deny.len);
}

test "ui.entry cannot escape the package directory, and ui.api must be at least 1" {
    const alloc = std.testing.allocator;

    var escapes = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"entry":"../evil.ts","api":1}}}
    );
    defer escapes.deinit();
    try std.testing.expectError(error.InvalidUiEntry, escapes.validate());

    var zero = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"entry":"tui/panel.ts","api":0}}}
    );
    defer zero.deinit();
    try std.testing.expectError(error.InvalidUiApi, zero.validate());

    // `api` is required the moment `ui` is written at all — a missing one is
    // a parse error, the same split every other required field makes.
    try std.testing.expectError(error.MissingField, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"entry":"tui/panel.ts"}}}
    ));
}

test "a command, a policy with content, or a ui block each alone counts as a contribution" {
    const alloc = std.testing.allocator;

    var cmd = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"commands":[{"name":"plan","description":"","action":"with"}]}}
    );
    defer cmd.deinit();
    try cmd.validate();

    // `readonly: true` is content; an empty `{}` would not be (see the
    // "policy may only narrow" test above).
    var pol = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"policy":{"readonly":true}}}
    );
    defer pol.deinit();
    try pol.validate();

    var ui = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"ui":{"entry":"tui/panel.ts","api":1}}}
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
    try std.testing.expect(m.ui == null);
    try std.testing.expect(m.tools[0].ui == null);
}
