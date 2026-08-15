//! Session-scoped capability composition.
//!
//! The composition freezes all session-scoped capability state at
//! `AgentSession.init()`, including pinned and usage-ranked extension
//! contributions and the model-facing tool set. Tool, Skill, and System Prompt
//! snapshots stay strongly typed and keep their own semantics.

const std = @import("std");
const registry = @import("registry.zig");
const ledger = @import("ledger.zig");
const prompt = @import("prompt.zig");
const skill = @import("skill.zig");
const tool = @import("tool.zig");
const environment = @import("environment.zig");
const ext_skills = @import("extension/skills.zig");
const ext_tools = @import("extension/tools.zig");
const manifest = @import("extension/manifest.zig");
const store = @import("extension/store.zig");
const integrity = @import("extension/integrity.zig");
const testkit = @import("extension/testkit.zig");

const kernel_system_prompt =
    "You are Nulya, a minimal self-evolving agent harness. " ++
    "shell and edit are permanent builtin tools. Some extension tools may also be exposed to you directly this session; every other extension capability is invoked through the nulya CLI. " ++
    "A directly-exposed extension tool is pinned to the version that was active when this session began. Activating a new version mid-session takes effect immediately through the CLI, but its directly-exposed form changes only in the next session.";

pub const PinnedExtension = struct {
    id: []const u8,
    version: []const u8,
};

/// Narrow, config-agnostic selection input. The composition knows only which
/// extension tools to promote to the model-facing set and the total tool budget;
/// it never learns where these came from (DESIGN §9.5 keeps config at the
/// session-setup boundary).
pub const Options = struct {
    /// Stable ids (`ext:<extension-id>/<tool-name>`) to expose natively this
    /// session. Each must resolve against an active extension; an unknown pin is
    /// a hard error, never a silent skip.
    pinned_native_tools: []const []const u8 = &.{},
    /// Extension stable ids ranked best-first by usage, produced at the
    /// session-setup boundary (DESIGN §5.1 rule 3). Best-effort: a candidate
    /// that cannot be bound against the frozen active extensions, or whose
    /// model-facing name is already taken, is skipped in rank order until the
    /// budget fills. Ranking decides membership only — the final model-facing
    /// order still comes from `registry.snapshotWith` (DESIGN §5.2).
    ranked_native_tools: []const []const u8 = &.{},
    /// Provider-facing total tool count, builtins included. shell + edit always
    /// occupy `registry.builtin_count` of it.
    max_tools: u32 = 8,
};

pub const CompositionError = error{
    /// `max_tools` cannot even seat the permanent builtins.
    ToolBudgetTooSmall,
    /// The explicit pins would push the tool set past `max_tools`.
    ToolBudgetExceeded,
    /// A pin is not `ext:<extension-id>/<tool-name>`.
    InvalidStableToolId,
    /// A pin names an extension with no active version this session.
    PinnedExtensionNotActive,
    /// The pinned extension is active but its frozen manifest declares no such tool.
    PinnedToolNotDeclared,
};

pub const SessionComposition = struct {
    pinned_extensions: []const PinnedExtension,
    /// Owned, address-stable bindings for the natively exposed extension tools.
    /// `tools` borrows these, so they must outlive it and are freed after it.
    extension_tool_bindings: []ext_tools.Binding,
    tools: registry.ToolSetSnapshot,
    skills: skill.SkillSetSnapshot,
    system_prompts: prompt.SystemPromptSnapshot,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        ext_root_rel: []const u8,
        opts: Options,
    ) !SessionComposition {
        try validateBudget(opts);
        const auto_slots = autoFillSlots(opts);

        var root = store.openRoot(io, cwd, ext_root_rel) catch |err| switch (err) {
            error.FileNotFound => {
                // No store at all: nothing can be active, so any explicit pin is
                // unresolvable — fail loudly rather than start a session missing
                // the tools the operator asked for.
                if (opts.pinned_native_tools.len != 0) return error.PinnedExtensionNotActive;
                return emptyComposition(alloc);
            },
            else => return err,
        };
        defer root.close(io);

        const resolved = try resolveActiveExtensions(alloc, io, root);
        defer freeResolved(alloc, resolved);
        sortResolved(resolved);

        return assemble(alloc, io, root, resolved, opts.pinned_native_tools, opts.ranked_native_tools, auto_slots);
    }

    /// Rebuild the composition frozen into a session header (DESIGN §3, §7.5):
    /// resolve exactly the pinned `active` versions (never the live `current`),
    /// and expose `native_tools` as the model-facing set. This is what every
    /// `session step` process calls, so all of them see the identical composition
    /// no matter what `activate` ran meanwhile.
    pub fn initFrozen(
        alloc: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        ext_root_rel: []const u8,
        frozen: ledger.FrozenComposition,
    ) !SessionComposition {
        if (frozen.active.len == 0) {
            if (frozen.native_tools.len != 0) return error.PinnedExtensionNotActive;
            return emptyComposition(alloc);
        }
        var root = try store.openRoot(io, cwd, ext_root_rel);
        defer root.close(io);

        const resolved = try resolveFrozenExtensions(alloc, io, root, frozen.active);
        defer freeResolved(alloc, resolved);
        sortResolved(resolved);

        // The frozen native tools are the exact, already-decided native set, so
        // they enter as pins (strict); no usage ranking or auto-fill on resume.
        return assemble(alloc, io, root, resolved, frozen.native_tools, &.{}, 0);
    }

    pub fn deinit(self: SessionComposition, alloc: std.mem.Allocator) void {
        // `tools` borrows the bindings, so it must go first.
        self.tools.deinit(alloc);
        freeBindings(alloc, self.extension_tool_bindings);
        self.skills.deinit(alloc);
        self.system_prompts.deinit(alloc);
        freePinned(alloc, self.pinned_extensions);
    }
};

/// The shared tail of `init` / `initFrozen`: given the resolved (sorted) active
/// extensions and an already-decided native-tool selection (`pins` strict,
/// `ranked` best-effort up to `auto_slots`), freeze the tool set, skills, and
/// system prompts. `resolved` and `root` stay owned by the caller.
fn assemble(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    resolved: []const ResolvedExtension,
    pins: []const []const u8,
    ranked: []const []const u8,
    auto_slots: usize,
) !SessionComposition {
    // Build every owned binding first, then freeze the slice: only after
    // `toOwnedSlice` are the binding addresses stable enough for `asTool` to
    // hand out `ToolExecutor.ptr` values into them.
    const bindings = try resolveBindings(alloc, io, root, resolved, pins, ranked, auto_slots);
    errdefer freeBindings(alloc, bindings);

    const tools = try snapshotFromBindings(alloc, bindings);
    errdefer tools.deinit(alloc);

    const pinned = try copyPinsFromResolved(alloc, resolved);
    errdefer freePinned(alloc, pinned);

    var descriptors: std.ArrayList(skill.SkillDescriptor) = .empty;
    errdefer skill.deinitDescriptorArrayList(alloc, &descriptors);
    for (resolved) |r| {
        try ext_skills.appendFromManifest(alloc, io, root, &descriptors, r.id, r.version, r.manifest);
    }
    skill.sortDescriptors(descriptors.items);
    const skills = skill.SkillSetSnapshot{ .skills = try descriptors.toOwnedSlice(alloc) };
    errdefer skills.deinit(alloc);

    const system_prompts = try buildSystemPrompts(alloc, .{ .io = io, .root = root }, resolved, skills);
    errdefer system_prompts.deinit(alloc);

    return .{
        .pinned_extensions = pinned,
        .extension_tool_bindings = bindings,
        .tools = tools,
        .skills = skills,
        .system_prompts = system_prompts,
    };
}

/// A composition with only the two builtins — no active extensions.
fn emptyComposition(alloc: std.mem.Allocator) !SessionComposition {
    const bindings = try alloc.alloc(ext_tools.Binding, 0);
    errdefer alloc.free(bindings);
    const tools = try registry.snapshotWith(alloc, &.{});
    errdefer tools.deinit(alloc);
    const pinned = try alloc.alloc(PinnedExtension, 0);
    errdefer freePinned(alloc, pinned);
    const skills = skill.SkillSetSnapshot{ .skills = try alloc.alloc(skill.SkillDescriptor, 0) };
    errdefer skills.deinit(alloc);
    const system_prompts = try buildSystemPrompts(alloc, null, &.{}, skills);
    return .{
        .pinned_extensions = pinned,
        .extension_tool_bindings = bindings,
        .tools = tools,
        .skills = skills,
        .system_prompts = system_prompts,
    };
}

/// The tool budget is provider-facing and counts the permanent builtins. Reject
/// impossible budgets up front, before any filesystem work.
fn validateBudget(opts: Options) CompositionError!void {
    if (opts.max_tools < registry.builtin_count) return error.ToolBudgetTooSmall;
    const room_for_extensions = opts.max_tools - registry.builtin_count;
    if (opts.pinned_native_tools.len > room_for_extensions) return error.ToolBudgetExceeded;
}

/// Extension slots left after the explicit pins. Ranked candidates are
/// best-effort: exceeding the budget truncates by rank order and is never an
/// error (unlike pins, which fail loudly).
fn autoFillSlots(opts: Options) usize {
    const room: usize = @intCast(opts.max_tools - @as(u32, @intCast(registry.builtin_count)));
    return room - opts.pinned_native_tools.len;
}

/// Freeze the builtin table plus the bindings' tools. The extras array is
/// transient — `snapshotWith` copies it — but each `Tool.executor.ptr` keeps
/// pointing at the caller-owned, address-stable `bindings`.
fn snapshotFromBindings(alloc: std.mem.Allocator, bindings: []ext_tools.Binding) !registry.ToolSetSnapshot {
    const extras = try alloc.alloc(tool.Tool, bindings.len);
    defer alloc.free(extras);
    for (bindings, 0..) |*b, i| extras[i] = b.asTool();
    return registry.snapshotWith(alloc, extras);
}

/// Resolve the session's extension-tool bindings: explicit pins first (strict —
/// an unresolvable pin fails the session), then usage-ranked candidates fill the
/// remaining slots best-effort (an unresolvable or colliding candidate is
/// skipped, never fatal). The store root is resolved to an absolute path once:
/// the frozen `entry_path` must be absolute so it survives being spawned with
/// the workspace as cwd, regardless of the host process's own working directory.
/// The returned slice is address-stable; on any error every binding built so far
/// is released and nothing leaks.
fn resolveBindings(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    resolved: []const ResolvedExtension,
    pins: []const []const u8,
    ranked: []const []const u8,
    auto_slots: usize,
) ![]ext_tools.Binding {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_real_len = try root.realPath(io, &root_buf);
    const root_real = root_buf[0..root_real_len];
    const st = store.Store.init(io, root);

    var list: std.ArrayList(ext_tools.Binding) = .empty;
    errdefer freeBindingsList(alloc, &list);

    for (pins) |pin| {
        const binding = try resolvePinnedBinding(alloc, st, root_real, resolved, pin);
        list.append(alloc, binding) catch |err| {
            binding.deinit(alloc);
            return err;
        };
    }

    try appendRankedBindings(alloc, st, root_real, resolved, pins, ranked, auto_slots, &list);
    return list.toOwnedSlice(alloc);
}

/// Best-effort automatic fill (DESIGN §5.1 rule 3). Walk ranked stable ids in
/// rank order and add a binding when the candidate is available, not already
/// pinned, and its model-facing name is still free, stopping at `auto_slots`.
/// A historical candidate that can no longer be bound (extension deactivated or
/// deleted, tool removed from the active version, malformed id) is skipped, as
/// is a candidate whose model-facing name is already taken by a builtin, a pin,
/// or an earlier-ranked automatic candidate — a lower-priority automatic
/// candidate never fails the session. Host faults (OOM, real filesystem errors)
/// propagate: they are never "candidate unavailable".
fn appendRankedBindings(
    alloc: std.mem.Allocator,
    st: store.Store,
    root_real: []const u8,
    resolved: []const ResolvedExtension,
    pins: []const []const u8,
    ranked: []const []const u8,
    auto_slots: usize,
    list: *std.ArrayList(ext_tools.Binding),
) !void {
    if (auto_slots == 0) return;

    // Taken names: builtins first, then the pins already bound. A valid manifest
    // can never declare a reserved name (manifest.validate rejects it), so the
    // builtin entries are defensive — the automatic walk still refuses such a
    // candidate rather than let the snapshot collision checks fail the session.
    var taken: std.ArrayList([]const u8) = .empty;
    defer taken.deinit(alloc);
    for (manifest.reserved_tool_names) |name| try taken.append(alloc, name);
    for (list.items) |b| try taken.append(alloc, b.definition.name);

    var selected: usize = 0;
    for (ranked) |id| {
        if (selected == auto_slots) break;
        // A pinned id is already bound; pins always win over ranking.
        if (sliceHas(pins, id)) continue;
        // rank() rejects duplicate candidates, so a repeat inside the ranked
        // list is a caller contract violation, not a case to dedupe.
        std.debug.assert(!bindingSliceHas(list.items, id));

        const binding = try resolveRankedBinding(alloc, st, root_real, resolved, id) orelse continue;
        if (sliceHas(taken.items, binding.definition.name)) {
            binding.deinit(alloc);
            continue;
        }
        list.append(alloc, binding) catch |err| {
            binding.deinit(alloc);
            return err;
        };
        try taken.append(alloc, binding.definition.name);
        selected += 1;
    }
}

/// Best-effort single-candidate resolution against the frozen active extensions.
/// Returns null for a historical id that can no longer be bound: malformed
/// stable id, extension no longer active, or tool removed from the active
/// version. Host faults propagate unchanged.
fn resolveRankedBinding(
    alloc: std.mem.Allocator,
    st: store.Store,
    root_real: []const u8,
    resolved: []const ResolvedExtension,
    id: []const u8,
) !?ext_tools.Binding {
    const parsed = parseStableToolId(id) catch return null;
    const r = findResolved(resolved, parsed.ext_id) orelse return null;
    const spec = findToolSpec(r.manifest, parsed.tool_name) orelse return null;
    // Same guarantee as the pinned path: `resolved` only holds extensions whose
    // manifest passed validation during discovery (a tool-declaring manifest with
    // no runtime fails as MissingRuntime, an isExtensionFault skipped there), so a
    // found tool spec proves the runtime exists. No runtime-less state to defend.
    const rt = r.manifest.runtime.?;

    // Exact, frozen entry path (a compiled binary or a frozen script, per the
    // runtime kind). Built from the version frozen at composition time — never
    // `current`, never a second `activeVersion` lookup — so mid-session
    // activation cannot move it.
    const entry_rel = try st.versionRuntimeEntryPath(alloc, r.id, r.version, rt);
    defer alloc.free(entry_rel);
    const entry_abs = try std.fs.path.join(alloc, &.{ root_real, entry_rel });
    defer alloc.free(entry_abs);

    // `id` already passed parseStableToolId, whose two segments reformat back
    // to exactly `id`, so initOwned dupes it directly.
    const binding = try ext_tools.Binding.initOwned(alloc, .{
        .id = id,
        .name = spec.name,
        .description = spec.description,
        .input_schema = spec.input_schema,
    }, entry_abs, rt.interpreter);
    return binding;
}

fn sliceHas(slice: []const []const u8, needle: []const u8) bool {
    for (slice) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn bindingSliceHas(list: []const ext_tools.Binding, id: []const u8) bool {
    for (list) |b| {
        if (std.mem.eql(u8, b.definition.id, id)) return true;
    }
    return false;
}

const StableToolId = struct { ext_id: []const u8, tool_name: []const u8 };

/// Parse `ext:<extension-id>/<tool-name>`. Pure — no filesystem, easy to unit
/// test. Both segments must be valid ids, so splitting on the first `/` is
/// unambiguous (ids never contain `/`).
fn parseStableToolId(pin: []const u8) CompositionError!StableToolId {
    const prefix = "ext:";
    if (!std.mem.startsWith(u8, pin, prefix)) return error.InvalidStableToolId;
    const rest = pin[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidStableToolId;
    const ext_id = rest[0..slash];
    const tool_name = rest[slash + 1 ..];
    if (!manifest.isValidId(ext_id) or !manifest.isValidId(tool_name)) return error.InvalidStableToolId;
    return .{ .ext_id = ext_id, .tool_name = tool_name };
}

fn resolvePinnedBinding(
    alloc: std.mem.Allocator,
    st: store.Store,
    root_real: []const u8,
    resolved: []const ResolvedExtension,
    pin: []const u8,
) !ext_tools.Binding {
    const parsed = try parseStableToolId(pin);

    const r = findResolved(resolved, parsed.ext_id) orelse return error.PinnedExtensionNotActive;
    const spec = findToolSpec(r.manifest, parsed.tool_name) orelse return error.PinnedToolNotDeclared;
    // A validated manifest requires `runtime` whenever it declares tools
    // (manifest.validate -> MissingRuntime), so a found tool spec guarantees an
    // executable; there is no runtime-less tool state to defend against.
    const rt = r.manifest.runtime.?;

    // Exact, frozen entry path (a compiled binary or a frozen script, per the
    // runtime kind). Built from the version pinned at composition time — never
    // `current`, never a second `activeVersion` lookup — so mid-session
    // activation cannot move it.
    const entry_rel = try st.versionRuntimeEntryPath(alloc, r.id, r.version, rt);
    defer alloc.free(entry_rel);
    const entry_abs = try std.fs.path.join(alloc, &.{ root_real, entry_rel });
    defer alloc.free(entry_abs);

    // `pin` already passed parseStableToolId, whose two segments reformat back
    // to exactly `pin` (ids never contain `/`), so initOwned dupes it directly.
    return ext_tools.Binding.initOwned(alloc, .{
        .id = pin,
        .name = spec.name,
        .description = spec.description,
        .input_schema = spec.input_schema,
    }, entry_abs, rt.interpreter);
}

fn findResolved(resolved: []const ResolvedExtension, id: []const u8) ?ResolvedExtension {
    for (resolved) |r| {
        if (std.mem.eql(u8, r.id, id)) return r;
    }
    return null;
}

fn findToolSpec(m: manifest.Manifest, name: []const u8) ?manifest.ToolSpec {
    for (m.tools) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

fn freeBindings(alloc: std.mem.Allocator, bindings: []ext_tools.Binding) void {
    for (bindings) |b| b.deinit(alloc);
    alloc.free(bindings);
}

fn freeBindingsList(alloc: std.mem.Allocator, list: *std.ArrayList(ext_tools.Binding)) void {
    for (list.items) |b| b.deinit(alloc);
    list.deinit(alloc);
}

const OpenRoot = struct { io: std.Io, root: std.Io.Dir };

const ResolvedExtension = struct {
    id: []const u8,
    version: []const u8,
    manifest: manifest.Manifest,
};

/// Store/manifest faults that mean "this directory is not a usable extension"
/// and are safe to skip during discovery. Anything else — host cancellation,
/// `OutOfMemory`, real I/O failures — is a host fault and must propagate: an
/// OOM must never masquerade as "extension skipped" or `PinnedExtensionNotActive`.
fn isExtensionFault(err: anyerror) bool {
    return switch (err) {
        // Invalid extension identity.
        error.InvalidId,
        error.InvalidVersion,
        // Bad `current` pointer or a frozen version failing integrity.
        error.VersionNotFound,
        error.VersionSealInvalid,
        error.VersionManifestIdMismatch,
        error.VersionPackageMissing,
        error.VersionEntryNotFound,
        // Unparseable or invalid manifest.
        error.InvalidJson,
        error.NotAnObject,
        error.MissingField,
        error.WrongType,
        error.UnsupportedSchema,
        error.MissingRuntime,
        error.InvalidEntry,
        error.InvalidInterpreter,
        error.NoContributions,
        error.InvalidToolName,
        error.ReservedToolName,
        error.DuplicateToolName,
        error.InvalidSkillPath,
        error.InvalidSystemPromptPath,
        error.DuplicateSystemPromptPath,
        => true,
        else => false,
    };
}

fn resolveActiveExtensions(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]ResolvedExtension {
    const st = store.Store.init(io, root);
    var resolved: std.ArrayList(ResolvedExtension) = .empty;
    errdefer freeResolved(alloc, resolved.items);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // A malformed extension is skipped, but a host fault — cancellation,
        // OOM, a real I/O failure — must propagate, never be mistaken for a
        // broken extension (see isExtensionFault).
        const active = (st.activeVersion(alloc, entry.name) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => if (isExtensionFault(err)) continue else return err,
        }) orelse continue;
        defer alloc.free(active);
        var m = st.readManifest(alloc, entry.name, active) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => if (isExtensionFault(err)) continue else return err,
        };
        errdefer m.deinit();

        const id = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(id);
        const version = try alloc.dupe(u8, active);
        errdefer alloc.free(version);
        try resolved.append(alloc, .{ .id = id, .version = version, .manifest = m });
    }
    return resolved.toOwnedSlice(alloc);
}

/// Resolve exactly the frozen (id, version) pairs from a session header. Unlike
/// discovery, this never scans `current` and never skips: a pinned version that
/// no longer validates is a hard error, because resume must reconstruct the same
/// cache scope or not at all.
fn resolveFrozenExtensions(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, active: []const ledger.PinnedExtensionRef) ![]ResolvedExtension {
    const st = store.Store.init(io, root);
    var resolved: std.ArrayList(ResolvedExtension) = .empty;
    errdefer freeResolved(alloc, resolved.items);
    for (active) |ext| {
        var m = try st.readManifest(alloc, ext.id, ext.version);
        errdefer m.deinit();
        const id = try alloc.dupe(u8, ext.id);
        errdefer alloc.free(id);
        const version = try alloc.dupe(u8, ext.version);
        errdefer alloc.free(version);
        try resolved.append(alloc, .{ .id = id, .version = version, .manifest = m });
    }
    return resolved.toOwnedSlice(alloc);
}

fn copyPinsFromResolved(alloc: std.mem.Allocator, resolved: []const ResolvedExtension) ![]PinnedExtension {
    var pins: std.ArrayList(PinnedExtension) = .empty;
    errdefer freePinned(alloc, pins.items);
    for (resolved) |r| {
        const id = try alloc.dupe(u8, r.id);
        errdefer alloc.free(id);
        const version = try alloc.dupe(u8, r.version);
        errdefer alloc.free(version);
        try pins.append(alloc, .{ .id = id, .version = version });
    }
    return pins.toOwnedSlice(alloc);
}

fn buildSystemPrompts(
    alloc: std.mem.Allocator,
    open_root: ?OpenRoot,
    resolved: []const ResolvedExtension,
    skills: skill.SkillSetSnapshot,
) !prompt.SystemPromptSnapshot {
    var blocks: std.ArrayList(prompt.SystemBlock) = .empty;
    errdefer (prompt.SystemPromptSnapshot{ .blocks = blocks.items }).deinit(alloc);

    try appendSystemBlock(alloc, &blocks, "kernel", kernel_system_prompt);

    if (open_root) |opened| {
        for (resolved) |r| {
            for (r.manifest.system_prompts) |prompt_path| {
                const source = try std.fmt.allocPrint(alloc, "ext:{s}@{s}/{s}", .{ r.id, r.version, prompt_path });
                defer alloc.free(source);
                const rel = try std.fs.path.join(alloc, &.{ r.id, "versions", r.version, integrity.package_dir, prompt_path });
                defer alloc.free(rel);
                const bytes = try opened.root.readFileAlloc(opened.io, rel, alloc, .limited(prompt.max_system_prompt_bytes));
                defer alloc.free(bytes);
                try appendSystemBlock(alloc, &blocks, source, bytes);
            }
        }
    }

    if (try skills.catalogText(alloc)) |catalog| {
        defer alloc.free(catalog);
        try appendSystemBlock(alloc, &blocks, "skills:catalog", catalog);
    }

    return .{ .blocks = try blocks.toOwnedSlice(alloc) };
}

fn appendSystemBlock(alloc: std.mem.Allocator, blocks: *std.ArrayList(prompt.SystemBlock), source: []const u8, bytes: []const u8) !void {
    const owned_source = try alloc.dupe(u8, source);
    errdefer alloc.free(owned_source);
    const owned_bytes = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned_bytes);
    try blocks.append(alloc, .{ .source = owned_source, .bytes = owned_bytes });
}

fn sortResolved(resolved: []ResolvedExtension) void {
    std.mem.sort(ResolvedExtension, resolved, {}, struct {
        fn lessThan(_: void, a: ResolvedExtension, b: ResolvedExtension) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
}

fn freeResolved(alloc: std.mem.Allocator, resolved: []const ResolvedExtension) void {
    for (resolved) |*r| {
        alloc.free(r.id);
        alloc.free(r.version);
        var m = r.manifest;
        m.deinit();
    }
    alloc.free(resolved);
}

fn freePinned(alloc: std.mem.Allocator, pins: []const PinnedExtension) void {
    for (pins) |pin| {
        alloc.free(pin.id);
        alloc.free(pin.version);
    }
    alloc.free(pins);
}

pub fn testingKernelPrompt() []const u8 {
    return kernel_system_prompt;
}

fn tmpPath(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    return try alloc.dupe(u8, buf[0..len]);
}

test "session composition pins active extension versions for the session" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_v1 =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    const manifest_v2 =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    const skill_v1 = "---\nname: risk-parity\ndescription: v1 skill\n---\nv1 body\n";
    const skill_v2 = "---\nname: risk-parity\ndescription: v2 skill\n---\nv2 body\n";
    const v1 = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "finance", manifest_v1, &.{.{ .rel = "skills/risk-parity/SKILL.md", .bytes = skill_v1 }});
    defer alloc.free(v1);
    const v2 = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "finance", manifest_v2, &.{.{ .rel = "skills/risk-parity/SKILL.md", .bytes = skill_v2 }});
    defer alloc.free(v2);

    try testkit.activate(alloc, io, tmp.dir, "finance", v1);
    var first = try SessionComposition.init(alloc, io, cwd, ".", .{});
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), first.pinned_extensions.len);
    try std.testing.expectEqualStrings(v1, first.pinned_extensions[0].version);
    try std.testing.expectEqualStrings("v1 skill", first.skills.skills[0].description);
    try std.testing.expectEqual(@as(usize, 2), first.system_prompts.blocks.len);
    try std.testing.expectEqualStrings("skills:catalog", first.system_prompts.blocks[1].source);
    try std.testing.expect(std.mem.indexOf(u8, first.system_prompts.blocks[1].bytes, first.skills.skills[0].ref) != null);

    try testkit.activate(alloc, io, tmp.dir, "finance", v2);
    try std.testing.expectEqualStrings(v1, first.pinned_extensions[0].version);
    try std.testing.expectEqualStrings("v1 skill", first.skills.skills[0].description);

    var second = try SessionComposition.init(alloc, io, cwd, ".", .{});
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings(v2, second.pinned_extensions[0].version);
    try std.testing.expectEqualStrings("v2 skill", second.skills.skills[0].description);
}

test "pinned skill load survives current changes and absent draft source" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    const v1 = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "finance", manifest_bytes, &.{.{ .rel = "skills/risk-parity/SKILL.md", .bytes = "---\nname: risk-parity\ndescription: v1 skill\n---\nv1 body\n" }});
    defer alloc.free(v1);
    const v2 = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "finance", manifest_bytes, &.{.{ .rel = "skills/risk-parity/SKILL.md", .bytes = "---\nname: risk-parity\ndescription: v2 skill\n---\nv2 body\n" }});
    defer alloc.free(v2);
    try testkit.activate(alloc, io, tmp.dir, "finance", v1);

    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{});
    defer comp.deinit(alloc);
    const ref = try alloc.dupe(u8, comp.skills.skills[0].ref);
    defer alloc.free(ref);

    try testkit.activate(alloc, io, tmp.dir, "finance", v2);
    var root = try tmp.dir.openDir(io, ".", .{});
    defer root.close(io);
    const body = try ext_skills.loadPinned(alloc, io, root, ref);
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "v1 body") != null);
}

test "skill frontmatter name must match the skill directory" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    const version = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "finance", manifest_bytes, &.{.{ .rel = "skills/risk-parity/SKILL.md", .bytes = "---\nname: other\ndescription: wrong name\n---\nbody\n" }});
    defer alloc.free(version);
    try testkit.activate(alloc, io, tmp.dir, "finance", version);

    try std.testing.expectError(error.SkillNameDoesNotMatchDirectory, SessionComposition.init(alloc, io, cwd, ".", .{}));
}

test "duplicate skill names in one extension are rejected" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/a/foo","skills/b/foo"]}}
    ;
    const version = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "finance", manifest_bytes, &.{
        .{ .rel = "skills/a/foo/SKILL.md", .bytes = "---\nname: foo\ndescription: first\n---\nbody\n" },
        .{ .rel = "skills/b/foo/SKILL.md", .bytes = "---\nname: foo\ndescription: second\n---\nbody\n" },
    });
    defer alloc.free(version);
    try testkit.activate(alloc, io, tmp.dir, "finance", version);

    try std.testing.expectError(error.DuplicateSkillName, SessionComposition.init(alloc, io, cwd, ".", .{}));
}

test "inactive extension contributions do not enter composition" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"inactive","contributes":{"skills":["skills/demo"],"system_prompts":["prompts/base.md"]}}
    ;
    const version = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "inactive", manifest_bytes, &.{
        .{ .rel = "skills/demo/SKILL.md", .bytes = "---\nname: demo\ndescription: demo skill\n---\nbody\n" },
        .{ .rel = "prompts/base.md", .bytes = "inactive prompt\n" },
    });
    defer alloc.free(version);

    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{});
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), comp.pinned_extensions.len);
    try std.testing.expectEqual(@as(usize, 0), comp.skills.skills.len);
    try std.testing.expectEqual(@as(usize, 1), comp.system_prompts.blocks.len); // kernel only
}

test "system prompt ordering is deterministic by pinned extension id and manifest order" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_b =
        \\{"schema":"nulya.extension/v2","id":"b","contributes":{"system_prompts":["prompts/b1.md"]}}
    ;
    const manifest_a =
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"system_prompts":["prompts/a1.md","prompts/a2.md"]}}
    ;
    const vb = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "b", manifest_b, &.{.{ .rel = "prompts/b1.md", .bytes = "B1" }});
    defer alloc.free(vb);
    const va = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "a", manifest_a, &.{
        .{ .rel = "prompts/a1.md", .bytes = "A1" },
        .{ .rel = "prompts/a2.md", .bytes = "A2" },
    });
    defer alloc.free(va);
    try testkit.activate(alloc, io, tmp.dir, "b", vb);
    try testkit.activate(alloc, io, tmp.dir, "a", va);

    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{});
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), comp.system_prompts.blocks.len);
    try std.testing.expectEqualStrings("kernel", comp.system_prompts.blocks[0].source);
    try std.testing.expectEqualStrings("A1", comp.system_prompts.blocks[1].bytes);
    try std.testing.expectEqualStrings("A2", comp.system_prompts.blocks[2].bytes);
    try std.testing.expectEqualStrings("B1", comp.system_prompts.blocks[3].bytes);
}

test "parseStableToolId splits ext:<id>/<tool>, rejecting malformed pins" {
    const ok = try parseStableToolId("ext:web.search/web_search");
    try std.testing.expectEqualStrings("web.search", ok.ext_id);
    try std.testing.expectEqualStrings("web_search", ok.tool_name);

    try std.testing.expectError(error.InvalidStableToolId, parseStableToolId("web_search"));
    try std.testing.expectError(error.InvalidStableToolId, parseStableToolId("ext:web.search"));
    try std.testing.expectError(error.InvalidStableToolId, parseStableToolId("ext:/web_search"));
    try std.testing.expectError(error.InvalidStableToolId, parseStableToolId("ext:web.search/"));
    // A second slash lands in the tool-name segment, which is not a valid id.
    try std.testing.expectError(error.InvalidStableToolId, parseStableToolId("ext:web.search/a/b"));
}

test "isExtensionFault classifies extension faults vs host faults" {
    // Extension faults: skipped during discovery.
    try std.testing.expect(isExtensionFault(error.InvalidId));
    try std.testing.expect(isExtensionFault(error.InvalidVersion));
    try std.testing.expect(isExtensionFault(error.VersionNotFound));
    try std.testing.expect(isExtensionFault(error.VersionSealInvalid));
    try std.testing.expect(isExtensionFault(error.VersionManifestIdMismatch));
    try std.testing.expect(isExtensionFault(error.VersionPackageMissing));
    try std.testing.expect(isExtensionFault(error.VersionEntryNotFound));
    try std.testing.expect(isExtensionFault(error.InvalidJson));
    try std.testing.expect(isExtensionFault(error.MissingRuntime));
    try std.testing.expect(isExtensionFault(error.DuplicateToolName));
    // Host faults: must propagate, never be read as "broken extension".
    try std.testing.expect(!isExtensionFault(error.Canceled));
    try std.testing.expect(!isExtensionFault(error.OutOfMemory));
    try std.testing.expect(!isExtensionFault(error.AccessDenied));
    try std.testing.expect(!isExtensionFault(error.FileSystem));
    try std.testing.expect(!isExtensionFault(error.FileNotFound));
}

test "budget rejects an impossible tool count before any filesystem work" {
    // Below the permanent builtins.
    try std.testing.expectError(error.ToolBudgetTooSmall, validateBudget(.{ .max_tools = 1 }));
    // Room for zero extensions, but one pin requested.
    try std.testing.expectError(error.ToolBudgetExceeded, validateBudget(.{
        .max_tools = registry.builtin_count,
        .pinned_native_tools = &.{"ext:web.search/web_search"},
    }));
    // Exactly enough room.
    try validateBudget(.{ .max_tools = registry.builtin_count + 1, .pinned_native_tools = &.{"ext:web.search/web_search"} });
}

/// A runtime extension exposing one tool, `id`/`tool` configurable so tests can
/// stand up name collisions. `marker` differentiates otherwise-identical
/// versions so their content addresses differ.
fn writeToolExtension(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    id: []const u8,
    tool_name: []const u8,
    marker: []const u8,
) ![]u8 {
    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","runtime":{{"entry":"bin/run"}},"contributes":{{"tools":[{{"name":"{s}","description":"a tool","input":{{"type":"object"}}}}]}}}}
    , .{ id, tool_name });
    defer alloc.free(manifest_bytes);
    const main_src = try std.fmt.allocPrint(alloc, "pub fn main() void {{}} // {s}\n", .{marker});
    defer alloc.free(main_src);
    return testkit.writeFrozenVersion(alloc, io, root, id, manifest_bytes, &.{.{ .rel = "src/main.zig", .bytes = main_src }});
}

/// Scripted environment for the executor-chain test: records the frozen entry
/// path each `runExtension` call receives and returns a canned success, so the
/// full Composition -> Binding -> ToolExecutor -> invoke -> Environment chain is
/// exercised without spawning a real process.
const FakeEnv = struct {
    io: std.Io,
    response: []const u8 = "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"result\":{\"results\":[]}}",
    saw_entry_path: []const u8 = "",

    fn runExtension(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.ExtensionRequest) anyerror!environment.ExtensionOutcome {
        const self: *FakeEnv = @ptrCast(@alignCast(ptr));
        // Free the previous observation before allocating the next: the test
        // calls the same env several times, and deinit frees only the latest.
        if (self.saw_entry_path.len != 0) alloc.free(self.saw_entry_path);
        self.saw_entry_path = "";
        // Allocate everything before publishing to `self` so a mid-way failure
        // (errdefer) can never leave a dangling `saw_entry_path`.
        const saw = try alloc.dupe(u8, req.entry_path);
        errdefer alloc.free(saw);
        const stdout = try alloc.dupe(u8, self.response);
        errdefer alloc.free(stdout);
        const stderr = try alloc.dupe(u8, "");
        self.saw_entry_path = saw;
        return .{ .stdout = stdout, .stderr = stderr, .exit_code = 0, .timed_out = false };
    }

    fn dialect(ptr: *anyopaque) environment.Dialect {
        _ = ptr;
        return .bash;
    }

    fn runShell(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.ShellRequest) anyerror!environment.ShellOutcome {
        _ = ptr;
        _ = alloc;
        _ = req;
        return error.NotSupported;
    }

    fn handle(self: *FakeEnv) environment.Environment {
        return .{
            .io = self.io,
            .ptr = self,
            .vtable = &.{
                .dialect = dialect,
                .runShell = runShell,
                .runExtension = runExtension,
            },
        };
    }

    fn deinit(self: *FakeEnv, alloc: std.mem.Allocator) void {
        if (self.saw_entry_path.len != 0) alloc.free(self.saw_entry_path);
    }
};

/// The executor never touches `req.ctx.fs`; a stub keeps the `ToolContext`
/// well-formed without reaching the real filesystem.
const DummyFs = struct {
    fn readFileAlloc(ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) anyerror![]u8 {
        _ = ptr;
        _ = alloc;
        _ = path;
        _ = max_bytes;
        return error.NotSupported;
    }

    fn atomicWriteFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        _ = ptr;
        _ = path;
        _ = data;
        return error.NotSupported;
    }

    fn handle(self: *DummyFs) environment.WorkspaceFs {
        return .{ .ptr = self, .vtable = &.{ .readFileAlloc = readFileAlloc, .atomicWriteFile = atomicWriteFile } };
    }
};

test "a selected extension tool is provider-visible and freezes to the composition-time version" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    const v2 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v2");
    defer alloc.free(v2);
    try std.testing.expect(!std.mem.eql(u8, v1, v2));

    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    const pins = [_][]const u8{"ext:web.search/web_search"};
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &pins });
    defer comp.deinit(alloc);

    // Provider-visible under its model-facing name, and the snapshot's Tool
    // borrows the exact owned binding (no copy of the executor target).
    const t = comp.tools.lookup("web_search") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), comp.extension_tool_bindings.len);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&comp.extension_tool_bindings[0])), t.executor.ptr);

    // The frozen entry path is absolute and names v1.
    const entry = comp.extension_tool_bindings[0].entry_path;
    try std.testing.expect(std.fs.path.isAbsolute(entry));
    try std.testing.expect(std.mem.indexOf(u8, entry, v1) != null);

    // Activate v2 mid-session: the pinned executable stays on v1 (no `current`
    // re-read, no second activeVersion lookup).
    try testkit.activate(alloc, io, tmp.dir, "web.search", v2);
    try std.testing.expect(std.mem.indexOf(u8, comp.extension_tool_bindings[0].entry_path, v1) != null);
    try std.testing.expect(std.mem.indexOf(u8, comp.extension_tool_bindings[0].entry_path, v2) == null);

    // A fresh session opened after the switch sees v2.
    var comp2 = try SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &pins });
    defer comp2.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, comp2.extension_tool_bindings[0].entry_path, v2) != null);
}

test "initFrozen rebuilds a composition from a header and ignores later activation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    const v2 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v2");
    defer alloc.free(v2);
    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    // A header frozen at v1 with the tool selected as native.
    const frozen: ledger.FrozenComposition = .{
        .active = &.{.{ .id = "web.search", .version = v1 }},
        .native_tools = &.{"ext:web.search/web_search"},
    };

    var comp = try SessionComposition.initFrozen(alloc, io, cwd, ".", frozen);
    defer comp.deinit(alloc);
    const t = comp.tools.lookup("web_search") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), comp.extension_tool_bindings.len);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&comp.extension_tool_bindings[0])), t.executor.ptr);
    try std.testing.expect(std.mem.indexOf(u8, comp.extension_tool_bindings[0].entry_path, v1) != null);

    // Activate v2 live; a fresh initFrozen on the SAME header still rebuilds v1 —
    // resume is bound to the header, not to `current`.
    try testkit.activate(alloc, io, tmp.dir, "web.search", v2);
    var comp2 = try SessionComposition.initFrozen(alloc, io, cwd, ".", frozen);
    defer comp2.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, comp2.extension_tool_bindings[0].entry_path, v1) != null);
    try std.testing.expect(std.mem.indexOf(u8, comp2.extension_tool_bindings[0].entry_path, v2) == null);
}

test "initFrozen with no active extensions yields the two builtins only" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    var comp = try SessionComposition.initFrozen(alloc, io, cwd, ".", .{});
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), comp.extension_tool_bindings.len);
    try std.testing.expectEqual(registry.builtin_count, comp.tools.tools.len);
}

test "executor calls reach the composition-time frozen entry path" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    const v2 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v2");
    defer alloc.free(v2);
    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    const pins = [_][]const u8{"ext:web.search/web_search"};
    var session_a = try SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &pins });
    defer session_a.deinit(alloc);
    const tool_a = session_a.tools.lookup("web_search") orelse return error.TestUnexpectedResult;
    var env_a = FakeEnv{ .io = io };
    defer env_a.deinit(alloc);
    var fs = DummyFs{};
    const req_a: tool.ToolRequest = .{ .args_json = "{}", .ctx = .{ .environment = env_a.handle(), .fs = fs.handle(), .cwd = "ws" } };

    // Session A's executor hands the environment the v1 executable.
    {
        const result = try tool_a.executor.call(alloc, req_a);
        defer alloc.free(result.output);
        try std.testing.expect(std.mem.indexOf(u8, env_a.saw_entry_path, v1) != null);
        try std.testing.expect(std.mem.indexOf(u8, env_a.saw_entry_path, v2) == null);
    }

    // Activate v2 mid-session: A's executor still reaches v1...
    try testkit.activate(alloc, io, tmp.dir, "web.search", v2);
    {
        const result = try tool_a.executor.call(alloc, req_a);
        defer alloc.free(result.output);
        try std.testing.expect(std.mem.indexOf(u8, env_a.saw_entry_path, v1) != null);
        try std.testing.expect(std.mem.indexOf(u8, env_a.saw_entry_path, v2) == null);
    }

    // ...while a fresh session's executor reaches v2.
    var session_b = try SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &pins });
    defer session_b.deinit(alloc);
    const tool_b = session_b.tools.lookup("web_search") orelse return error.TestUnexpectedResult;
    var env_b = FakeEnv{ .io = io };
    defer env_b.deinit(alloc);
    const req_b: tool.ToolRequest = .{ .args_json = "{}", .ctx = .{ .environment = env_b.handle(), .fs = fs.handle(), .cwd = "ws" } };
    {
        const result = try tool_b.executor.call(alloc, req_b);
        defer alloc.free(result.output);
        try std.testing.expect(std.mem.indexOf(u8, env_b.saw_entry_path, v2) != null);
        try std.testing.expect(std.mem.indexOf(u8, env_b.saw_entry_path, v1) == null);
    }
}

test "a corrupted frozen version is skipped during discovery, not fatal" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    // Break the seal so integrity validation fails for the active version.
    const seal_sub = try std.fs.path.join(alloc, &.{ "web.search", "versions", v1, integrity.seal_file });
    defer alloc.free(seal_sub);
    try tmp.dir.writeFile(io, .{ .sub_path = seal_sub, .data = "{}" });

    // Discovery skips the broken extension rather than aborting the session.
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{});
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), comp.pinned_extensions.len);
    try std.testing.expectEqual(@as(usize, 0), comp.extension_tool_bindings.len);
}

test "an active but unpinned extension tool is not natively visible" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    // No pins: the extension is still active (composition pins its version), but
    // its tool is reachable only through the CLI, never the model-facing set.
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{});
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), comp.extension_tool_bindings.len);
    try std.testing.expect(comp.tools.lookup("web_search") == null);
    try std.testing.expectEqual(@as(usize, 1), comp.pinned_extensions.len);
}

test "two pinned tools sharing a model-facing name are rejected" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const va = try writeToolExtension(alloc, io, tmp.dir, "a.pkg", "search", "a");
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "search", "b");
    defer alloc.free(vb);
    try testkit.activate(alloc, io, tmp.dir, "a.pkg", va);
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);

    const pins = [_][]const u8{ "ext:a.pkg/search", "ext:b.pkg/search" };
    try std.testing.expectError(error.DuplicateToolName, SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &pins }));
}

test "the same pin listed twice is rejected as a duplicate stable id" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    const pins = [_][]const u8{ "ext:web.search/web_search", "ext:web.search/web_search" };
    try std.testing.expectError(error.DuplicateToolId, SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &pins }));
}

test "a pin to an inactive extension or undeclared tool is a hard error" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    // Unknown extension.
    try std.testing.expectError(error.PinnedExtensionNotActive, SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &[_][]const u8{"ext:absent/tool"} }));
    // Active extension, but no such tool in its frozen manifest.
    try std.testing.expectError(error.PinnedToolNotDeclared, SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &[_][]const u8{"ext:web.search/nope"} }));
    // Malformed stable id.
    try std.testing.expectError(error.InvalidStableToolId, SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &[_][]const u8{"web_search"} }));
}

test "a pin without any extension store is a hard error, not a silent empty set" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    // No extensions root exists at all.
    try std.testing.expectError(error.PinnedExtensionNotActive, SessionComposition.init(alloc, io, cwd, "nulya-absent-root", .{ .pinned_native_tools = &[_][]const u8{"ext:web.search/web_search"} }));

    // With no pins, an absent store yields a clean builtin-only composition.
    var comp = try SessionComposition.init(alloc, io, cwd, "nulya-absent-root", .{});
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), comp.extension_tool_bindings.len);
    try std.testing.expect(comp.tools.lookup("shell") != null);
}

test "an active extension with no usage history is not auto-promoted" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    // No ranked candidates (a missing journal is an empty ranking at the
    // boundary): the extension stays CLI-only; an empty slot is never filled
    // with a zero-use tool.
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &.{} });
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), comp.extension_tool_bindings.len);
    try std.testing.expect(comp.tools.lookup("web_search") == null);
    try std.testing.expectEqual(@as(usize, 1), comp.pinned_extensions.len);
}

test "a used active extension is auto-promoted into the frozen tool set" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    const ranked = [_][]const u8{"ext:web.search/web_search"};
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked });
    defer comp.deinit(alloc);

    const t = comp.tools.lookup("web_search") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ext:web.search/web_search", t.definition.id);
    try std.testing.expectEqual(@as(usize, 1), comp.extension_tool_bindings.len);
    // Same owned-binding ownership as a pin: the Tool borrows the binding.
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&comp.extension_tool_bindings[0])), t.executor.ptr);
    // Final order is builtins then extras sorted by stable id: shell, edit, web_search.
    try std.testing.expectEqual(@as(usize, 3), comp.tools.tools.len);
    try std.testing.expectEqualStrings("shell", comp.tools.tools[0].definition.name);
    try std.testing.expectEqualStrings("edit", comp.tools.tools[1].definition.name);
    try std.testing.expectEqualStrings("web_search", comp.tools.tools[2].definition.name);
}

test "ranking decides membership, not the final tool order" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const va = try writeToolExtension(alloc, io, tmp.dir, "a.pkg", "alpha", "a");
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "beta", "b");
    defer alloc.free(vb);
    try testkit.activate(alloc, io, tmp.dir, "a.pkg", va);
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);

    // Both fit (max_tools=4), b ranked first: both selected, but the frozen
    // snapshot is sorted by stable id, so a comes before b in tools[].
    const ranked = [_][]const u8{ "ext:b.pkg/beta", "ext:a.pkg/alpha" };
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked, .max_tools = 4 });
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), comp.extension_tool_bindings.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", comp.tools.tools[2].definition.id);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", comp.tools.tools[3].definition.id);
    try std.testing.expect(comp.tools.lookup("alpha") != null);
    try std.testing.expect(comp.tools.lookup("beta") != null);
}

test "higher-ranked candidate wins the limited slot" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const va = try writeToolExtension(alloc, io, tmp.dir, "a.pkg", "alpha", "a");
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "beta", "b");
    defer alloc.free(vb);
    try testkit.activate(alloc, io, tmp.dir, "a.pkg", va);
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);

    // max_tools=3 leaves exactly one extension slot; ranking B > A selects B.
    const ranked = [_][]const u8{ "ext:b.pkg/beta", "ext:a.pkg/alpha" };
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked, .max_tools = 3 });
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), comp.extension_tool_bindings.len);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", comp.extension_tool_bindings[0].definition.id);
    try std.testing.expect(comp.tools.lookup("beta") != null);
    try std.testing.expect(comp.tools.lookup("alpha") == null);
}

test "an explicit pin wins the budget over a higher-ranked candidate" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const va = try writeToolExtension(alloc, io, tmp.dir, "a.pkg", "alpha", "a");
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "beta", "b");
    defer alloc.free(vb);
    try testkit.activate(alloc, io, tmp.dir, "a.pkg", va);
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);

    // max_tools=3: 2 builtins + pin A fill the budget; ranking B > A cannot
    // squeeze in.
    const pins = [_][]const u8{"ext:a.pkg/alpha"};
    const ranked = [_][]const u8{ "ext:b.pkg/beta", "ext:a.pkg/alpha" };
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &pins, .ranked_native_tools = &ranked, .max_tools = 3 });
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), comp.extension_tool_bindings.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", comp.extension_tool_bindings[0].definition.id);
    try std.testing.expect(comp.tools.lookup("alpha") != null);
    try std.testing.expect(comp.tools.lookup("beta") == null);
}

test "pins and ranking fill the budget together without duplicating a pinned id" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const va = try writeToolExtension(alloc, io, tmp.dir, "a.pkg", "alpha", "a");
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "beta", "b");
    defer alloc.free(vb);
    const vc = try writeToolExtension(alloc, io, tmp.dir, "c.pkg", "gamma", "c");
    defer alloc.free(vc);
    try testkit.activate(alloc, io, tmp.dir, "a.pkg", va);
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);
    try testkit.activate(alloc, io, tmp.dir, "c.pkg", vc);

    // max_tools=4: pin A plus one auto slot; ranked [A, B, C] -> A skipped as
    // already pinned, B fills the auto slot, C is beyond the budget.
    const pins = [_][]const u8{"ext:a.pkg/alpha"};
    const ranked = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta", "ext:c.pkg/gamma" };
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .pinned_native_tools = &pins, .ranked_native_tools = &ranked, .max_tools = 4 });
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), comp.extension_tool_bindings.len);
    try std.testing.expect(comp.tools.lookup("alpha") != null);
    try std.testing.expect(comp.tools.lookup("beta") != null);
    try std.testing.expect(comp.tools.lookup("gamma") == null);
    var alpha_count: usize = 0;
    for (comp.extension_tool_bindings) |b| {
        if (std.mem.eql(u8, b.definition.id, "ext:a.pkg/alpha")) alpha_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alpha_count);
}

test "a deactivated historical candidate is skipped, the next candidate fills" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const va = try writeToolExtension(alloc, io, tmp.dir, "a.pkg", "alpha", "a");
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "beta", "b");
    defer alloc.free(vb);
    // Only B is active; A was used historically but is now deactivated.
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);

    const ranked = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta" };
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked, .max_tools = 3 });
    defer comp.deinit(alloc);
    // A is an automatic candidate, not a pin: it is skipped, never an error.
    try std.testing.expectEqual(@as(usize, 1), comp.extension_tool_bindings.len);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", comp.extension_tool_bindings[0].definition.id);
    try std.testing.expect(comp.tools.lookup("beta") != null);
    try std.testing.expect(comp.tools.lookup("alpha") == null);
}

test "a tool removed from the active version is skipped, the next candidate fills" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    // Extension `a` is active but its current manifest only declares `new_tool`;
    // the journal still ranks the historical `ext:a/old_tool` first.
    const manifest_a =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/run"},"contributes":{"tools":[{"name":"new_tool","description":"a tool","input":{"type":"object"}}]}}
    ;
    const va = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "a", manifest_a, &.{.{ .rel = "src/main.zig", .bytes = "pub fn main() void {}\n" }});
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "beta", "b");
    defer alloc.free(vb);
    try testkit.activate(alloc, io, tmp.dir, "a", va);
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);

    const ranked = [_][]const u8{ "ext:a/old_tool", "ext:b.pkg/beta" };
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked, .max_tools = 3 });
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), comp.extension_tool_bindings.len);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", comp.extension_tool_bindings[0].definition.id);
    try std.testing.expect(comp.tools.lookup("beta") != null);
    try std.testing.expect(comp.tools.lookup("new_tool") == null); // never ranked
}

test "an auto candidate whose model-facing name is a reserved builtin is skipped" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A hand-parsed, unvalidated manifest lets the walk see a tool named
    // `shell`; production can never reach this state (manifest.validate rejects
    // reserved names), so the walk's defensive builtin-name check is exercised
    // directly.
    var m = try manifest.parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/run"},"contributes":{"tools":[{"name":"shell","description":"x","input":{"type":"object"}}]}}
    );
    defer m.deinit();
    const resolved = [_]ResolvedExtension{.{ .id = "a", .version = "v-aaaaaaaaaaaaaaaaaaaaaaaa", .manifest = m }};
    const pins = [_][]const u8{};
    const ranked = [_][]const u8{"ext:a/shell"};
    const st = store.Store.init(io, tmp.dir);

    var list: std.ArrayList(ext_tools.Binding) = .empty;
    defer freeBindingsList(alloc, &list);
    try appendRankedBindings(alloc, st, ".", &resolved, &pins, &ranked, 1, &list);
    // The candidate was resolved but refused: no alias/rename, no binding.
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "an auto candidate colliding with an earlier-ranked auto candidate is skipped" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    // A and B both expose model-facing `search`; A ranks higher. A is selected,
    // B is skipped, and C (ranked after B) fills the remaining slot.
    const va = try writeToolExtension(alloc, io, tmp.dir, "a.pkg", "search", "a");
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "search", "b");
    defer alloc.free(vb);
    const vc = try writeToolExtension(alloc, io, tmp.dir, "c.pkg", "fetch", "c");
    defer alloc.free(vc);
    try testkit.activate(alloc, io, tmp.dir, "a.pkg", va);
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);
    try testkit.activate(alloc, io, tmp.dir, "c.pkg", vc);

    const ranked = [_][]const u8{ "ext:a.pkg/search", "ext:b.pkg/search", "ext:c.pkg/fetch" };
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked, .max_tools = 4 });
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), comp.extension_tool_bindings.len);
    const t = comp.tools.lookup("search") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ext:a.pkg/search", t.definition.id);
    try std.testing.expect(comp.tools.lookup("fetch") != null);
}

test "auto candidates beyond the budget are truncated by rank, never an error" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const va = try writeToolExtension(alloc, io, tmp.dir, "a.pkg", "alpha", "a");
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "beta", "b");
    defer alloc.free(vb);
    const vc = try writeToolExtension(alloc, io, tmp.dir, "c.pkg", "gamma", "c");
    defer alloc.free(vc);
    const vd = try writeToolExtension(alloc, io, tmp.dir, "d.pkg", "delta", "d");
    defer alloc.free(vd);
    try testkit.activate(alloc, io, tmp.dir, "a.pkg", va);
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);
    try testkit.activate(alloc, io, tmp.dir, "c.pkg", vc);
    try testkit.activate(alloc, io, tmp.dir, "d.pkg", vd);

    // max_tools=3 leaves one extension slot; four used candidates => only the
    // highest-ranked is selected, no error, no alphabetical filler.
    const ranked = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta", "ext:c.pkg/gamma", "ext:d.pkg/delta" };
    var comp = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked, .max_tools = 3 });
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), comp.extension_tool_bindings.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", comp.extension_tool_bindings[0].definition.id);
}

test "the tool set freezes at session creation; a later ranking change needs a new session" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const va = try writeToolExtension(alloc, io, tmp.dir, "a.pkg", "alpha", "a");
    defer alloc.free(va);
    const vb = try writeToolExtension(alloc, io, tmp.dir, "b.pkg", "beta", "b");
    defer alloc.free(vb);
    try testkit.activate(alloc, io, tmp.dir, "a.pkg", va);
    try testkit.activate(alloc, io, tmp.dir, "b.pkg", vb);

    const ranked_first = [_][]const u8{ "ext:a.pkg/alpha", "ext:b.pkg/beta" };
    var first = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked_first, .max_tools = 3 });
    defer first.deinit(alloc);
    try std.testing.expect(first.tools.lookup("alpha") != null);
    try std.testing.expect(first.tools.lookup("beta") == null);

    // A later session (new journal => new ranking) selects B instead. The first
    // composition is untouched: no mid-session mutation, no re-read.
    const ranked_second = [_][]const u8{ "ext:b.pkg/beta", "ext:a.pkg/alpha" };
    var second = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked_second, .max_tools = 3 });
    defer second.deinit(alloc);
    try std.testing.expect(second.tools.lookup("beta") != null);
    try std.testing.expect(second.tools.lookup("alpha") == null);

    try std.testing.expect(first.tools.lookup("alpha") != null);
    try std.testing.expect(first.tools.lookup("beta") == null);
}

test "an auto-promoted tool freezes to the composition-time version" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const v1 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v1");
    defer alloc.free(v1);
    const v2 = try writeToolExtension(alloc, io, tmp.dir, "web.search", "web_search", "v2");
    defer alloc.free(v2);
    try testkit.activate(alloc, io, tmp.dir, "web.search", v1);

    const ranked = [_][]const u8{"ext:web.search/web_search"};
    var first = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked });
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, first.extension_tool_bindings[0].entry_path, v1) != null);

    // Activate v2 mid-session: the auto-promoted executable stays on v1.
    try testkit.activate(alloc, io, tmp.dir, "web.search", v2);
    try std.testing.expect(std.mem.indexOf(u8, first.extension_tool_bindings[0].entry_path, v1) != null);
    try std.testing.expect(std.mem.indexOf(u8, first.extension_tool_bindings[0].entry_path, v2) == null);

    // A fresh session opened after the switch sees v2.
    var second = try SessionComposition.init(alloc, io, cwd, ".", .{ .ranked_native_tools = &ranked });
    defer second.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, second.extension_tool_bindings[0].entry_path, v2) != null);
}
