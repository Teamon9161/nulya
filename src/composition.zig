//! Session-scoped capability composition.
//!
//! The composition freezes all session-scoped capability state at
//! `AgentSession.init()`: the active extension versions, the pinned
//! model-facing tool set, skills and system prompts. Tool, Skill, and System
//! Prompt snapshots stay strongly typed and keep their own semantics.
//!
//! Two phases, one intermediate value. `resolve` answers the request — a fresh
//! session's discovery plus `--with`, or a session header's frozen versions —
//! and resolves the pins into bindings; `assemble` builds the frozen session
//! state out of that answer alone. Everything about WHY an extension or a tool
//! is here is decided in the first phase and unrepresentable in the second, so
//! `init` and `initFrozen` differ only in what they hand to `resolve`.

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
const roots_mod = @import("extension/roots.zig");
const integrity = @import("extension/integrity.zig");
const testkit = @import("extension/testkit.zig");

const kernel_system_prompt =
    "You are Nulya, a minimal self-evolving agent harness. " ++
    "shell and edit are permanent builtin tools. Some extension tools may also be exposed to you directly this session; every other extension capability is invoked through the nulya CLI. " ++
    "A directly-exposed extension tool is pinned to the version that was active when this session began. Activating a new version mid-session takes effect immediately through the CLI, but its directly-exposed form changes only in the next session.";

/// A digest over everything the KERNEL ITSELF puts into a session's frozen
/// model-visible state: the kernel system prompt, then each builtin's id, name,
/// description and input schema in registry order. Stamped into the session
/// header at creation (`ledger.Stamp`, DESIGN §3.4) so a resume can SEE that
/// these compile-time constants moved under an existing session instead of
/// silently sending it a different system prompt. Deterministic and cheap:
/// a couple of KB through Blake3, once per `session new` / `session step`.
pub fn kernelHash(alloc: std.mem.Allocator) ![]u8 {
    const snap = try registry.snapshot(alloc);
    defer snap.deinit(alloc);
    const defs = try snap.definitions(alloc);
    defer alloc.free(defs);
    return hashKernel(alloc, kernel_system_prompt, defs);
}

/// The hash itself, over a canonical concatenation: every part is length-
/// prefixed, so no two different inputs can produce the same byte stream (a
/// description ending where the next schema begins cannot masquerade as a
/// different split). Takes its inputs as parameters so the property is testable.
fn hashKernel(alloc: std.mem.Allocator, system_prompt: []const u8, defs: []const tool.ToolDefinition) ![]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    hashPart(&h, system_prompt);
    for (defs) |d| {
        hashPart(&h, d.id);
        hashPart(&h, d.name);
        hashPart(&h, d.description);
        hashPart(&h, d.input_schema);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const out = try alloc.alloc(u8, digest.len * 2);
    _ = std.fmt.bufPrint(out, "{x}", .{digest[0..]}) catch unreachable;
    return out;
}

fn hashPart(h: *std.crypto.hash.Blake3, part: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, part.len, .little);
    h.update(&len);
    h.update(part);
}

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
    /// session — `registry.pinned_native_tools` plus `session new --pin`
    /// (DESIGN §5.1). The ONLY way an extension tool reaches the model's tool
    /// face: usage facts never fill a slot by themselves. Each must resolve
    /// against an active extension; an unknown pin is a hard error, never a
    /// silent skip.
    pinned_native_tools: []const []const u8 = &.{},
    /// Provider-facing total tool count, builtins included. shell + edit always
    /// occupy `registry.builtin_count` of it.
    max_tools: u32 = 8,
    /// Extensions to bring into THIS session's composition whether or not they
    /// are activated (`nulya session new --with`, DESIGN §14). Membership only:
    /// their skills enter the catalog, their system prompts enter the system
    /// blocks, and their tools become invocable through the CLI — whether a tool
    /// takes a native slot is still `pinned_native_tools`. Same id as an active
    /// extension overrides it for this session; a later `--with` of the same id
    /// overrides an earlier one.
    with: []const WithRef = &.{},
};

/// One `--with` request: an extension id, optionally at an exact version.
/// Without a version, the id's `current` is used — but unlike discovery, an id
/// that resolves to nothing is a hard error, because the caller named it.
pub const WithRef = struct {
    id: []const u8,
    version: ?[]const u8 = null,
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
    /// A `--with` extension has no built version to use: either no `current` at
    /// all, or the named version is in none of the store roots.
    WithVersionNotFound,
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
        ext_roots: []const []const u8,
        opts: Options,
    ) !SessionComposition {
        try validateBudget(opts);

        // No store root existing anywhere needs no special case: discovery finds
        // nothing, so a pin fails as `PinnedExtensionNotActive` and a `--with`
        // as `WithVersionNotFound` on the ordinary path — the same errors, from
        // the same two places, as when the roots exist but the extension does not.
        var roots = try roots_mod.Roots.open(alloc, io, cwd, ext_roots);
        defer roots.deinit();

        const resolved = try resolve(alloc, &roots, .{ .fresh = opts });
        defer freeResolved(alloc, resolved.extensions);

        return assemble(alloc, io, &roots, resolved);
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
        ext_roots: []const []const u8,
        frozen: ledger.FrozenComposition,
    ) !SessionComposition {
        var roots = try roots_mod.Roots.open(alloc, io, cwd, ext_roots);
        defer roots.deinit();

        const resolved = try resolve(alloc, &roots, .{ .frozen = frozen });
        defer freeResolved(alloc, resolved.extensions);

        return assemble(alloc, io, &roots, resolved);
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

/// What a session's composition was ASKED for, in the only two shapes that
/// exist: a fresh session (whatever is active, plus `--with`, with pins named
/// by config / `--pin`) or the frozen record in a session header. The
/// difference lives here and dies here — `resolve` turns either into the same
/// `Resolved`.
const Request = union(enum) {
    fresh: Options,
    frozen: ledger.FrozenComposition,
};

/// A composition request, answered: which extension versions are in this
/// session (sorted by id) and the bindings for the tools that take a native
/// slot. Everything about WHY — active, `--with`, frozen header; pinned by
/// config or by the header — has been decided by the time this exists.
const Resolved = struct {
    extensions: []roots_mod.Roots.Resolved,
    /// Owned by whoever holds this value until `assemble` takes them.
    bindings: []ext_tools.Binding,
};

/// Phase one: decide membership. Discovery (best effort) and `--with` /
/// frozen versions (named, so strict) differ only in how the extension list is
/// obtained; pin resolution is the same for both, and is strict either way —
/// an unresolvable pin fails the session rather than quietly starting without
/// the tool that was asked for. `roots` stays the caller's; on any error
/// everything built here is released.
fn resolve(alloc: std.mem.Allocator, roots: *const roots_mod.Roots, request: Request) !Resolved {
    const extensions = switch (request) {
        .fresh => |opts| try unionWith(alloc, roots, try resolveActiveExtensions(alloc, roots), opts.with),
        .frozen => |frozen| try resolveFrozenExtensions(alloc, roots, frozen.active),
    };
    errdefer freeResolved(alloc, extensions);
    sortResolved(extensions);

    const pins = switch (request) {
        .fresh => |opts| opts.pinned_native_tools,
        .frozen => |frozen| frozen.native_tools,
    };
    return .{ .extensions = extensions, .bindings = try resolveBindings(alloc, roots, extensions, pins) };
}

/// Phase two: build the frozen session state out of what phase one decided —
/// the tool set, the skill catalog, the system blocks, the pinned versions —
/// and nothing else. It cannot tell an active extension from a `--with` one, or
/// a config pin from a header's: by the time anything reaches here those
/// questions have no representation left. Each resolved extension names the
/// root index it was found in, so the search order is never re-derived either.
///
/// Takes ownership of `resolved.bindings` (released on any failure here);
/// `resolved.extensions` and `roots` stay the caller's.
fn assemble(
    alloc: std.mem.Allocator,
    io: std.Io,
    roots: *const roots_mod.Roots,
    resolved: Resolved,
) !SessionComposition {
    // The bindings arrived as one frozen slice, so their addresses are stable
    // enough for `asTool` to hand out `ToolExecutor.ptr` values into them.
    const bindings = resolved.bindings;
    errdefer freeBindings(alloc, bindings);

    const tools = try snapshotFromBindings(alloc, bindings);
    errdefer tools.deinit(alloc);

    const pinned = try copyPinsFromResolved(alloc, resolved.extensions);
    errdefer freePinned(alloc, pinned);

    var descriptors: std.ArrayList(skill.SkillDescriptor) = .empty;
    errdefer skill.deinitDescriptorArrayList(alloc, &descriptors);
    for (resolved.extensions) |r| {
        try ext_skills.appendFromManifest(alloc, io, roots.entries[r.root].dir, &descriptors, r.id, r.version, r.manifest);
    }
    skill.sortDescriptors(descriptors.items);
    const skills = skill.SkillSetSnapshot{ .skills = try descriptors.toOwnedSlice(alloc) };
    errdefer skills.deinit(alloc);

    const system_prompts = try buildSystemPrompts(alloc, io, roots, resolved.extensions, skills);
    errdefer system_prompts.deinit(alloc);

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

/// Freeze the builtin table plus the bindings' tools. The extras array is
/// transient — `snapshotWith` copies it — but each `Tool.executor.ptr` keeps
/// pointing at the caller-owned, address-stable `bindings`.
fn snapshotFromBindings(alloc: std.mem.Allocator, bindings: []ext_tools.Binding) !registry.ToolSetSnapshot {
    const extras = try alloc.alloc(tool.Tool, bindings.len);
    defer alloc.free(extras);
    for (bindings, 0..) |*b, i| extras[i] = b.asTool();
    return registry.snapshotWith(alloc, extras);
}

/// Resolve the session's extension-tool bindings from the explicit pins — the
/// whole native selection, and strict: an unresolvable pin fails the session
/// rather than quietly starting without the tool the operator asked for. The
/// frozen entry path comes from `Roots.Resolved.entryPathAbs`: absolute,
/// so it survives being spawned with the workspace as cwd, and built from the
/// version frozen at composition time, so mid-session activation cannot move it.
/// The returned slice is address-stable; on any error every binding built so far
/// is released and nothing leaks.
fn resolveBindings(
    alloc: std.mem.Allocator,
    roots: *const roots_mod.Roots,
    resolved: []const roots_mod.Roots.Resolved,
    pins: []const []const u8,
) ![]ext_tools.Binding {
    var list: std.ArrayList(ext_tools.Binding) = .empty;
    errdefer freeBindingsList(alloc, &list);

    for (pins) |pin| {
        const binding = try resolvePinnedBinding(alloc, roots, resolved, pin);
        list.append(alloc, binding) catch |err| {
            binding.deinit(alloc);
            return err;
        };
    }
    return list.toOwnedSlice(alloc);
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
    roots: *const roots_mod.Roots,
    resolved: []const roots_mod.Roots.Resolved,
    pin: []const u8,
) !ext_tools.Binding {
    const parsed = try parseStableToolId(pin);

    const r = findResolved(resolved, parsed.ext_id) orelse return error.PinnedExtensionNotActive;
    const spec = findToolSpec(r.manifest, parsed.tool_name) orelse return error.PinnedToolNotDeclared;
    // A validated manifest requires `runtime` whenever it declares tools
    // (manifest.validate -> MissingRuntime), so a found tool spec guarantees an
    // executable; there is no runtime-less tool state to defend against.
    const rt = r.manifest.runtime.?;

    const entry_abs = try r.entryPathAbs(alloc, roots);
    defer alloc.free(entry_abs);

    // `pin` already passed parseStableToolId, whose two segments reformat back
    // to exactly `pin` (ids never contain `/`), so initOwned dupes it directly.
    return ext_tools.Binding.initOwned(alloc, .{
        .id = pin,
        .name = spec.name,
        .description = spec.description,
        .input_schema = spec.input_schema,
    }, entry_abs, rt.interpreter, spec.timeout_ms);
}

fn findResolved(resolved: []const roots_mod.Roots.Resolved, id: []const u8) ?roots_mod.Roots.Resolved {
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

/// Store/manifest faults that mean "this directory is not a usable extension".
/// Lives in `store.zig` (it classifies store / integrity / manifest errors);
/// discovery skips them, and anything else — host cancellation, `OutOfMemory`,
/// real I/O failures — propagates.
const isExtensionFault = store.isExtensionFault;

/// Discover the active extensions across every store root, in search order:
/// `Roots.listActive` already applied first-root-wins, so each entry only has
/// to be turned into a validated `Resolved` — `resolveEntry` takes the root and
/// version the listing decided rather than asking `current` again.
fn resolveActiveExtensions(alloc: std.mem.Allocator, roots: *const roots_mod.Roots) ![]roots_mod.Roots.Resolved {
    var resolved: std.ArrayList(roots_mod.Roots.Resolved) = .empty;
    errdefer freeResolved(alloc, resolved.items);

    const active = try roots.listActive(alloc);
    defer roots_mod.Roots.freeActive(alloc, active);

    for (active) |entry| {
        // A malformed extension is skipped, but a host fault — cancellation,
        // OOM, a real I/O failure — must propagate, never be mistaken for a
        // broken extension (see isExtensionFault).
        const r = roots.resolveEntry(alloc, entry) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => if (isExtensionFault(err)) continue else return err,
        };
        errdefer r.deinit(alloc);
        try resolved.append(alloc, r);
    }
    return resolved.toOwnedSlice(alloc);
}

/// Union the `--with` extensions into the discovered set (DESIGN §14): each one
/// enters this session's composition whether or not it is activated, at the
/// named version or at its `current`. Same id as a discovered extension REPLACES
/// it (this session says which version it means), and a repeated `--with` of one
/// id keeps the last — the request is an override, so the last override wins.
///
/// Unlike discovery, nothing here is best-effort: the caller named these, so an
/// id with no built version, or a version no root holds, fails the session.
/// Takes ownership of `base`; on any error it and everything built so far is
/// released.
fn unionWith(
    alloc: std.mem.Allocator,
    roots: *const roots_mod.Roots,
    base: []roots_mod.Roots.Resolved,
    with: []const WithRef,
) ![]roots_mod.Roots.Resolved {
    if (with.len == 0) return base;
    var list: std.ArrayList(roots_mod.Roots.Resolved) = .{ .items = base, .capacity = base.len };
    errdefer freeResolved(alloc, list.items);

    for (with) |ref| {
        const r = if (ref.version) |v|
            roots.resolveVersion(alloc, ref.id, v) catch |err| switch (err) {
                error.VersionNotFound => return error.WithVersionNotFound,
                else => return err,
            }
        else
            (try roots.resolveActive(alloc, ref.id)) orelse return error.WithVersionNotFound;
        errdefer r.deinit(alloc);

        // Replace an entry for the same id rather than shadowing it: two
        // manifests of one id in one composition would collide on tool names.
        for (list.items, 0..) |existing, i| {
            if (!std.mem.eql(u8, existing.id, ref.id)) continue;
            list.swapRemove(i).deinit(alloc);
            break;
        }
        try list.append(alloc, r);
    }
    return list.toOwnedSlice(alloc);
}

/// Resolve exactly the frozen (id, version) pairs from a session header. Unlike
/// discovery, this never scans `current` and never skips: a pinned version that
/// no longer validates is a hard error, because resume must reconstruct the same
/// cache scope or not at all. A version is looked up in root order and taken
/// from whichever root holds it — versions are content-addressed, so every
/// root's copy is the same bytes and integrity is checked either way; the search
/// order only decides where it is found, never what runs.
fn resolveFrozenExtensions(alloc: std.mem.Allocator, roots: *const roots_mod.Roots, active: []const ledger.PinnedExtensionRef) ![]roots_mod.Roots.Resolved {
    var resolved: std.ArrayList(roots_mod.Roots.Resolved) = .empty;
    errdefer freeResolved(alloc, resolved.items);
    for (active) |ext| {
        const r = try roots.resolveVersion(alloc, ext.id, ext.version);
        errdefer r.deinit(alloc);
        try resolved.append(alloc, r);
    }
    return resolved.toOwnedSlice(alloc);
}

fn copyPinsFromResolved(alloc: std.mem.Allocator, resolved: []const roots_mod.Roots.Resolved) ![]PinnedExtension {
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
    io: std.Io,
    roots: *const roots_mod.Roots,
    resolved: []const roots_mod.Roots.Resolved,
    skills: skill.SkillSetSnapshot,
) !prompt.SystemPromptSnapshot {
    var blocks: std.ArrayList(prompt.SystemBlock) = .empty;
    errdefer (prompt.SystemPromptSnapshot{ .blocks = blocks.items }).deinit(alloc);

    try appendSystemBlock(alloc, &blocks, "kernel", kernel_system_prompt);

    for (resolved) |r| {
        for (r.manifest.system_prompts) |prompt_path| {
            const source = try std.fmt.allocPrint(alloc, "ext:{s}@{s}/{s}", .{ r.id, r.version, prompt_path });
            defer alloc.free(source);
            const rel = try std.fs.path.join(alloc, &.{ r.id, "versions", r.version, integrity.package_dir, prompt_path });
            defer alloc.free(rel);
            const bytes = try roots.entries[r.root].dir.readFileAlloc(io, rel, alloc, .limited(prompt.max_system_prompt_bytes));
            defer alloc.free(bytes);
            try appendSystemBlock(alloc, &blocks, source, bytes);
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

fn sortResolved(resolved: []roots_mod.Roots.Resolved) void {
    std.mem.sort(roots_mod.Roots.Resolved, resolved, {}, struct {
        fn lessThan(_: void, a: roots_mod.Roots.Resolved, b: roots_mod.Roots.Resolved) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
}

fn freeResolved(alloc: std.mem.Allocator, resolved: []const roots_mod.Roots.Resolved) void {
    for (resolved) |r| r.deinit(alloc);
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

test "kernelHash is stable across calls and moves when any kernel constant does" {
    const alloc = std.testing.allocator;

    const a = try kernelHash(alloc);
    defer alloc.free(a);
    const b = try kernelHash(alloc);
    defer alloc.free(b);
    // Deterministic: the header stamp is only worth anything if two runs of the
    // same binary agree (DESIGN §3.4).
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqual(@as(usize, 64), a.len);

    // …and sensitive: a changed system prompt, or a changed builtin definition,
    // is exactly the drift the stamp exists to reveal.
    const defs = [_]tool.ToolDefinition{
        .{ .id = "builtin.shell", .name = "shell", .description = "d", .input_schema = "{}" },
    };
    const base = try hashKernel(alloc, kernel_system_prompt, &defs);
    defer alloc.free(base);
    const other_prompt = try hashKernel(alloc, "You are someone else.", &defs);
    defer alloc.free(other_prompt);
    try std.testing.expect(!std.mem.eql(u8, base, other_prompt));

    const other_defs = [_]tool.ToolDefinition{
        .{ .id = "builtin.shell", .name = "shell", .description = "d", .input_schema = "{\"x\":1}" },
    };
    const other_schema = try hashKernel(alloc, kernel_system_prompt, &other_defs);
    defer alloc.free(other_schema);
    try std.testing.expect(!std.mem.eql(u8, base, other_schema));

    // Length-prefixing, not concatenation: moving a byte across a field boundary
    // must not collide with the original.
    const shifted = [_]tool.ToolDefinition{
        .{ .id = "builtin.shel", .name = "lshell", .description = "d", .input_schema = "{}" },
    };
    const shifted_hash = try hashKernel(alloc, kernel_system_prompt, &shifted);
    defer alloc.free(shifted_hash);
    try std.testing.expect(!std.mem.eql(u8, base, shifted_hash));
}

/// Most tests below stand a single store root up in a tmp dir and pass it as
/// the whole search order.
const one_root: []const []const u8 = &.{"."};

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
    var first = try SessionComposition.init(alloc, io, cwd, one_root, .{});
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

    var second = try SessionComposition.init(alloc, io, cwd, one_root, .{});
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

    var comp = try SessionComposition.init(alloc, io, cwd, one_root, .{});
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

    try std.testing.expectError(error.SkillNameDoesNotMatchDirectory, SessionComposition.init(alloc, io, cwd, one_root, .{}));
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

    try std.testing.expectError(error.DuplicateSkillName, SessionComposition.init(alloc, io, cwd, one_root, .{}));
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

    var comp = try SessionComposition.init(alloc, io, cwd, one_root, .{});
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), comp.pinned_extensions.len);
    try std.testing.expectEqual(@as(usize, 0), comp.skills.skills.len);
    try std.testing.expectEqual(@as(usize, 1), comp.system_prompts.blocks.len); // kernel only
}

test "--with brings a built-but-inactive version into one session, overrides an active one, and refuses what does not exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"mode","contributes":{"system_prompts":["prompts/base.md"]}}
    ;
    const v1 = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "mode", manifest_bytes, &.{.{ .rel = "prompts/base.md", .bytes = "V1" }});
    defer alloc.free(v1);
    const v2 = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "mode", manifest_bytes, &.{.{ .rel = "prompts/base.md", .bytes = "V2" }});
    defer alloc.free(v2);

    // Nothing is activated: a plain session sees only the kernel prompt…
    {
        var plain = try SessionComposition.init(alloc, io, cwd, one_root, .{});
        defer plain.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), plain.system_prompts.blocks.len);
    }
    // …while `--with mode@v2` composes that exact version into this session.
    {
        var with = try SessionComposition.init(alloc, io, cwd, one_root, .{ .with = &.{.{ .id = "mode", .version = v2 }} });
        defer with.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), with.system_prompts.blocks.len);
        try std.testing.expectEqualStrings("V2", with.system_prompts.blocks[1].bytes);
        // It is in the frozen set, so the header records it and a resume rebuilds it.
        try std.testing.expectEqual(@as(usize, 1), with.pinned_extensions.len);
        try std.testing.expectEqualStrings(v2, with.pinned_extensions[0].version);
    }

    // With v1 activated, a bare `--with mode` takes `current`…
    try testkit.activate(alloc, io, tmp.dir, "mode", v1);
    {
        var current = try SessionComposition.init(alloc, io, cwd, one_root, .{ .with = &.{.{ .id = "mode" }} });
        defer current.deinit(alloc);
        try std.testing.expectEqualStrings("V1", current.system_prompts.blocks[1].bytes);
    }
    // …and naming a version OVERRIDES the active one for this session only,
    // exactly once — the same id is replaced, never composed twice.
    {
        var override = try SessionComposition.init(alloc, io, cwd, one_root, .{ .with = &.{
            .{ .id = "mode", .version = v2 },
            .{ .id = "mode", .version = v1 },
            .{ .id = "mode", .version = v2 },
        } });
        defer override.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), override.pinned_extensions.len);
        try std.testing.expectEqual(@as(usize, 2), override.system_prompts.blocks.len);
        try std.testing.expectEqualStrings("V2", override.system_prompts.blocks[1].bytes); // the last --with wins
    }

    // The caller named these, so an unknown id or version fails the session.
    try std.testing.expectError(error.WithVersionNotFound, SessionComposition.init(alloc, io, cwd, one_root, .{ .with = &.{.{ .id = "absent" }} }));
    try std.testing.expectError(error.WithVersionNotFound, SessionComposition.init(alloc, io, cwd, one_root, .{ .with = &.{.{ .id = "mode", .version = "v-000000000000000000000000" }} }));
    try std.testing.expectError(error.WithVersionNotFound, SessionComposition.init(alloc, io, cwd, &.{"nulya-absent-root"}, .{ .with = &.{.{ .id = "mode" }} }));
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

    var comp = try SessionComposition.init(alloc, io, cwd, one_root, .{});
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
    var comp = try SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &pins });
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
    var comp2 = try SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &pins });
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

    var comp = try SessionComposition.initFrozen(alloc, io, cwd, one_root, frozen);
    defer comp.deinit(alloc);
    const t = comp.tools.lookup("web_search") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), comp.extension_tool_bindings.len);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&comp.extension_tool_bindings[0])), t.executor.ptr);
    try std.testing.expect(std.mem.indexOf(u8, comp.extension_tool_bindings[0].entry_path, v1) != null);

    // Activate v2 live; a fresh initFrozen on the SAME header still rebuilds v1 —
    // resume is bound to the header, not to `current`.
    try testkit.activate(alloc, io, tmp.dir, "web.search", v2);
    var comp2 = try SessionComposition.initFrozen(alloc, io, cwd, one_root, frozen);
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

    var comp = try SessionComposition.initFrozen(alloc, io, cwd, one_root, .{});
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
    var session_a = try SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &pins });
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
    var session_b = try SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &pins });
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
    var comp = try SessionComposition.init(alloc, io, cwd, one_root, .{});
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
    var comp = try SessionComposition.init(alloc, io, cwd, one_root, .{});
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
    try std.testing.expectError(error.DuplicateToolName, SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &pins }));
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
    try std.testing.expectError(error.DuplicateToolId, SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &pins }));
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
    try std.testing.expectError(error.PinnedExtensionNotActive, SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &[_][]const u8{"ext:absent/tool"} }));
    // Active extension, but no such tool in its frozen manifest.
    try std.testing.expectError(error.PinnedToolNotDeclared, SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &[_][]const u8{"ext:web.search/nope"} }));
    // Malformed stable id.
    try std.testing.expectError(error.InvalidStableToolId, SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &[_][]const u8{"web_search"} }));
    // A resolvable pin with no slot left is refused too: the budget is the cap
    // on the whole face, and a pin never silently loses to it.
    try std.testing.expectError(error.ToolBudgetExceeded, SessionComposition.init(alloc, io, cwd, one_root, .{
        .pinned_native_tools = &[_][]const u8{"ext:web.search/web_search"},
        .max_tools = registry.builtin_count,
    }));
}

test "a pin without any extension store is a hard error, not a silent empty set" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    // No extensions root exists at all.
    try std.testing.expectError(error.PinnedExtensionNotActive, SessionComposition.init(alloc, io, cwd, &.{"nulya-absent-root"}, .{ .pinned_native_tools = &[_][]const u8{"ext:web.search/web_search"} }));

    // With no pins, an absent store yields a clean builtin-only composition.
    var comp = try SessionComposition.init(alloc, io, cwd, &.{"nulya-absent-root"}, .{});
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), comp.extension_tool_bindings.len);
    try std.testing.expect(comp.tools.lookup("shell") != null);
}

test "pins decide membership, not the final tool order" {
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

    // Pinned b first, a second: both are exposed, but the frozen snapshot is
    // builtins then extras sorted by stable id, so a precedes b regardless of
    // how the pins were listed (DESIGN §5.2).
    const pins = [_][]const u8{ "ext:b.pkg/beta", "ext:a.pkg/alpha" };
    var comp = try SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &pins, .max_tools = 4 });
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), comp.extension_tool_bindings.len);
    try std.testing.expectEqual(@as(usize, 4), comp.tools.tools.len);
    try std.testing.expectEqualStrings("shell", comp.tools.tools[0].definition.name);
    try std.testing.expectEqualStrings("edit", comp.tools.tools[1].definition.name);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", comp.tools.tools[2].definition.id);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", comp.tools.tools[3].definition.id);
}

test "the tool set freezes at session creation; a changed pin only reaches the next session" {
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

    var first = try SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &[_][]const u8{"ext:a.pkg/alpha"}, .max_tools = 3 });
    defer first.deinit(alloc);
    try std.testing.expect(first.tools.lookup("alpha") != null);
    try std.testing.expect(first.tools.lookup("beta") == null);

    // A later session with a different pin gets a different face; the first
    // composition is untouched — a pin takes effect at a session boundary and
    // nowhere else (physics #2).
    var second = try SessionComposition.init(alloc, io, cwd, one_root, .{ .pinned_native_tools = &[_][]const u8{"ext:b.pkg/beta"}, .max_tools = 3 });
    defer second.deinit(alloc);
    try std.testing.expect(second.tools.lookup("beta") != null);
    try std.testing.expect(second.tools.lookup("alpha") == null);

    try std.testing.expect(first.tools.lookup("alpha") != null);
    try std.testing.expect(first.tools.lookup("beta") == null);
}
