//! Session-scoped capability composition.
//!
//! The composition freezes all session-scoped capability state at
//! `AgentSession.init()`, including pinned extension contributions and the
//! model-facing tool set. Tool, Skill, and System Prompt snapshots stay strongly
//! typed and keep their own semantics.

const std = @import("std");
const registry = @import("registry.zig");
const prompt = @import("prompt.zig");
const skill = @import("skill.zig");
const tool = @import("tool.zig");
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
    /// The pinned tool's extension declares no runtime, so it has no executable.
    PinnedToolHasNoRuntime,
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

        var root = store.openRoot(io, cwd, ext_root_rel) catch |err| switch (err) {
            error.FileNotFound => {
                // No store at all: nothing can be active, so any explicit pin is
                // unresolvable — fail loudly rather than start a session missing
                // the tools the operator asked for.
                if (opts.pinned_native_tools.len != 0) return error.PinnedExtensionNotActive;

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
            },
            else => return err,
        };
        defer root.close(io);

        const resolved = try resolveActiveExtensions(alloc, io, root);
        defer freeResolved(alloc, resolved);
        sortResolved(resolved);

        // Build every owned binding first, then freeze the slice: only after
        // `toOwnedSlice` are the binding addresses stable enough for `asTool` to
        // hand out `ToolExecutor.ptr` values into them.
        const bindings = try resolvePinnedBindings(alloc, io, root, resolved, opts.pinned_native_tools);
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

    pub fn deinit(self: SessionComposition, alloc: std.mem.Allocator) void {
        // `tools` borrows the bindings, so it must go first.
        self.tools.deinit(alloc);
        freeBindings(alloc, self.extension_tool_bindings);
        self.skills.deinit(alloc);
        self.system_prompts.deinit(alloc);
        freePinned(alloc, self.pinned_extensions);
    }
};

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

/// Resolve each explicit pin into an owned binding, in caller order. The
/// returned slice is address-stable; on any error every binding built so far is
/// released and nothing leaks.
fn resolvePinnedBindings(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    resolved: []const ResolvedExtension,
    pins: []const []const u8,
) ![]ext_tools.Binding {
    // Resolve the store root to an absolute path once: the frozen `entry_path`
    // must be absolute so it survives being spawned with the workspace as cwd,
    // regardless of the host process's own working directory.
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
    st: store.Store,
    root_real: []const u8,
    resolved: []const ResolvedExtension,
    pin: []const u8,
) !ext_tools.Binding {
    const parsed = try parseStableToolId(pin);

    const r = findResolved(resolved, parsed.ext_id) orelse return error.PinnedExtensionNotActive;
    const spec = findToolSpec(r.manifest, parsed.tool_name) orelse return error.PinnedToolNotDeclared;
    const rt = r.manifest.runtime orelse return error.PinnedToolHasNoRuntime;

    // Exact, frozen executable path: <root>/<id>/versions/<r.version>/<entry>.
    // Built from the version pinned at composition time — never `current`, never
    // a second `activeVersion` lookup — so mid-session activation cannot move it.
    const entry_rel = try st.versionEntryPath(alloc, r.id, r.version, rt.entry);
    defer alloc.free(entry_rel);
    const entry_abs = try std.fs.path.join(alloc, &.{ root_real, entry_rel });
    defer alloc.free(entry_abs);

    const stable_id = try std.fmt.allocPrint(alloc, "ext:{s}/{s}", .{ parsed.ext_id, parsed.tool_name });
    defer alloc.free(stable_id);

    return ext_tools.Binding.initOwned(alloc, .{
        .id = stable_id,
        .name = spec.name,
        .description = spec.description,
        .input_schema = spec.input_schema,
    }, entry_abs);
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

fn resolveActiveExtensions(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]ResolvedExtension {
    const st = store.Store.init(io, root);
    var resolved: std.ArrayList(ResolvedExtension) = .empty;
    errdefer freeResolved(alloc, resolved.items);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // A malformed extension is skipped, but a cancellation is host execution
        // control — it must propagate, never be mistaken for a broken extension.
        const active = (st.activeVersion(alloc, entry.name) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        }) orelse continue;
        defer alloc.free(active);
        var m = st.readManifest(alloc, entry.name, active) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
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
