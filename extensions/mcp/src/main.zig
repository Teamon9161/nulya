//! `mcp` — one MCP server becomes one generated extension package.
//!
//! Two jobs, one binary, told apart by whether a `server.json` was frozen beside
//! this executable:
//!
//!   no spec  → this is the generator. `mcp_add` connects to a server once and
//!              freezes the tool list it is given into a new package; `mcp_list`
//!              says which packages this machine holds.
//!   a spec   → this IS one of those packages. `NULYA_TOOL` names one of its
//!              tools and this call is that tool's `tools/call`.
//!
//! A generated package carries this same source, so the runtime that answers a
//! call is the runtime that was built here — there is no second implementation
//! to keep in step, and the difference between the two jobs is one file.

const std = @import("std");
const client = @import("client.zig");
const gen = @import("gen.zig");
const rpc = @import("rpc.zig");
const spec_mod = @import("server.zig");

/// How much of a failing server's own stderr is quoted back. Enough to carry a
/// stack-less error line, short enough that a chatty server cannot bury the
/// sentence this package wrote around it.
const quoted_stderr_bytes: usize = 600;

/// `std.process.Init` rather than a bare `main()` for the io it hands over: the
/// MCP server started below inherits this process's real environment, and a
/// hand-rolled io would hand it an empty one — no PATH, no HOME.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: this process talks to one server and prints
    // one answer, so individual frees would be noise.
    const alloc = init.arena.allocator();

    const name = init.environ_map.get("NULYA_TOOL") orelse "";
    const raw = rpc.readRaw(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try rpc.answer(io, .{ .failed = "mcp expects this call's arguments as one JSON object on stdin" }),
    };

    const ctx: gen.Ctx = .{
        .alloc = alloc,
        .io = io,
        .env = init.environ_map,
        .exe = init.environ_map.get("NULYA_EXE") orelse "",
    };

    // Host faults are folded into a refusal, so every path ends in one answer.
    const outcome = dispatch(ctx, name, raw) catch |err| rpc.Outcome{
        .failed = try std.fmt.allocPrint(alloc, "{s} could not run: {s}", .{
            if (name.len == 0) "mcp" else name,
            @errorName(err),
        }),
    };
    try rpc.answer(io, outcome);
}

fn dispatch(ctx: gen.Ctx, name: []const u8, raw: []const u8) !rpc.Outcome {
    if (try spec_mod.besideExe(ctx.alloc, ctx.io)) |spec| return serve(ctx, spec, name, raw);

    if (ctx.exe.len == 0) {
        return rpc.refuse(ctx.alloc, "mcp cannot find the nulya that spawned it (NULYA_EXE is not set)", .{});
    }
    if (std.mem.eql(u8, name, "mcp_list")) return gen.list(ctx);
    if (std.mem.eql(u8, name, "mcp_add")) {
        const arguments = rpc.asObject(ctx.alloc, raw) catch
            return rpc.refuse(ctx.alloc, "mcp_add expects this call's arguments as one JSON object on stdin", .{});
        return gen.add(ctx, arguments);
    }
    return rpc.refuse(ctx.alloc, "mcp has no tool '{s}'; it offers mcp_add and mcp_list", .{name});
}

/// One tool call against this package's own server.
///
/// The arguments go over untouched and the answer comes back as the model reads
/// it. A server that reports its own failure (`isError`) is a FAILED CALL, not a
/// broken package: the model asked for something the server could not do, which
/// is a thing to read and retry, not a thing to fix.
fn serve(ctx: gen.Ctx, spec: spec_mod.Spec, name: []const u8, arguments: []const u8) !rpc.Outcome {
    const remote_name = spec.serverTool(name) orelse return rpc.refuse(
        ctx.alloc,
        "mcp.{s} does not expose a tool called '{s}'",
        .{ spec.name, name },
    );

    const config = spec_mod.load(ctx.alloc, ctx.io, ctx.env, spec.name) catch
        return rpc.refuse(
            ctx.alloc,
            "mcp.{s}: a configuration file for this server exists but is not {{\"env\": {{…}}}}; one of {s}",
            .{ spec.name, try joinPaths(ctx, spec.name) },
        );
    const absent = try spec_mod.missing(ctx.alloc, spec, config);
    if (absent.len != 0) {
        return .{ .failed = try spec_mod.notConfiguredMessage(ctx.alloc, ctx.env, spec, config, absent) };
    }

    var values: std.ArrayList(client.Pair) = .empty;
    for (spec.env) |key| try values.append(ctx.alloc, .{ .key = key, .value = config.?.get(key).? });

    var server: client.Server = .{ .alloc = ctx.alloc, .io = ctx.io };
    defer server.stop();
    server.start(ctx.env, .{
        .command = spec.command,
        .args = spec.args,
        .env = values.items,
        .timeout_ms = gen.client_timeout_ms,
    }) catch return rpc.refuse(
        ctx.alloc,
        "mcp.{s}: '{s}' did not start (check it is installed and on PATH)",
        .{ spec.name, spec.command },
    );

    server.initialize() catch |err| return failure(ctx, &server, spec, "the handshake", err);
    const answer = server.callTool(remote_name, arguments) catch |err|
        return failure(ctx, &server, spec, remote_name, err);

    if (answer.is_error) {
        return .{ .failed = try std.fmt.allocPrint(ctx.alloc, "{s} failed: {s}", .{ name, answer.text }) };
    }
    return .{ .text = answer.text };
}

/// A refusal that carries the server's own words. Which words depends on how it
/// failed: a JSON-RPC error is what it MEANT to say, and anything else leaves
/// only what it happened to print.
fn failure(
    ctx: gen.Ctx,
    server: *client.Server,
    spec: spec_mod.Spec,
    during: []const u8,
    err: client.Error,
) !rpc.Outcome {
    const said = if (err == error.ServerError) server.fault else server.stderrTail(quoted_stderr_bytes);
    return rpc.refuse(
        ctx.alloc,
        "mcp.{s}: '{s}' did not complete {s} ({s}){s}{s}",
        .{ spec.name, spec.command, during, @errorName(err), if (said.len == 0) "" else ": ", said },
    );
}

fn joinPaths(ctx: gen.Ctx, name: []const u8) ![]const u8 {
    return std.mem.join(ctx.alloc, ", ", try spec_mod.candidates(ctx.alloc, ctx.env, name));
}
