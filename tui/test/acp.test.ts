/**
 * The ACP adapter against the REAL `nulya` binary in scripted mode: no API key,
 * no network, no mocked line protocol. The client on the other side is the
 * official SDK's own, so what these assert is the protocol as a client sees it
 * and not this adapter talking to itself.
 *
 * Four of the five run the agent app in this process (the SDK connects an agent
 * app straight to a client app); `session/load` runs the entry point as a
 * separate process over real stdio, because "a new process can pick a session
 * up" is the whole claim being made.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { join } from "node:path"
import {
  PROTOCOL_VERSION,
  client,
  ndJsonStream,
  type ClientContext,
  type ContentBlock,
  type PermissionOptionId,
  type RequestPermissionRequest,
  type SessionUpdate,
} from "@agentclientprotocol/sdk"
import { createAcpAgent, type AcpAgentOptions } from "../src/acp/agent.ts"
import { default_rules } from "../src/approvals.ts"
import { sessionEvents, sessionList } from "../src/nulya/cli.ts"
import {
  scripted_batch_env,
  scripted_env,
  scripted_loop_env,
  tempWorkspace,
  until,
  type TempWorkspace,
} from "./support.ts"

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

/** What the client saw, and how it answers when asked. */
interface Seen {
  updates: SessionUpdate[]
  asked: RequestPermissionRequest[]
  /** The option id for the n-th request (1-based). */
  answer: (nth: number) => PermissionOptionId
}

function chunkText(update: SessionUpdate): string {
  return ((update as { content?: ContentBlock }).content as { text?: string } | undefined)?.text ?? ""
}

function kinds(seen: Seen, kind: SessionUpdate["sessionUpdate"]): SessionUpdate[] {
  return seen.updates.filter((update) => update.sessionUpdate === kind)
}

async function withAgent<T>(
  options: AcpAgentOptions,
  op: (cx: ClientContext, seen: Seen) => Promise<T>,
): Promise<T> {
  const seen: Seen = { updates: [], asked: [], answer: () => "reject_once" }
  return client({ name: "acp-test" })
    .onNotification("session/update", (ctx) => {
      seen.updates.push(ctx.params.update)
    })
    .onRequest("session/request_permission", (ctx) => {
      seen.asked.push(ctx.params)
      return { outcome: { outcome: "selected", optionId: seen.answer(seen.asked.length) } }
    })
    .connectWith(createAcpAgent({ log: () => {}, ...options }), (cx) => op(cx, seen))
}

async function newSession(cx: ClientContext): Promise<string> {
  await cx.request("initialize", { protocolVersion: PROTOCOL_VERSION })
  const created = await cx.request("session/new", { cwd: ws.dir, mcpServers: [] })
  return created.sessionId
}

test("initialize → session/new → session/prompt streams a turn and ends it", async () => {
  await withAgent({ profile: "scripted", env: scripted_env, mode: "unsafe" }, async (cx, seen) => {
    const init = await cx.request("initialize", { protocolVersion: PROTOCOL_VERSION })
    expect(init.protocolVersion).toBe(PROTOCOL_VERSION)
    expect(init.agentCapabilities?.loadSession).toBe(true)
    expect(init.authMethods).toEqual([])

    const created = await cx.request("session/new", { cwd: ws.dir, mcpServers: [] })
    expect(created.sessionId.startsWith("s-")).toBe(true)
    expect(created.modes?.currentModeId).toBe("unsafe")

    const turn = await cx.request("session/prompt", {
      sessionId: created.sessionId,
      prompt: [{ type: "text", text: "read the kernel" }],
    })
    expect(turn.stopReason).toBe("end_turn")

    // The user's own turn is echoed exactly once: the adapter says it while the
    // append is still in the inbox, and recognises the drained event by the
    // delivery name rather than by its text.
    const echoes = kinds(seen, "user_message_chunk")
    expect(echoes.map(chunkText)).toEqual(["read the kernel"])

    expect(kinds(seen, "agent_message_chunk").length).toBeGreaterThan(0)

    const calls = kinds(seen, "tool_call") as { toolCallId: string; name?: string | null }[]
    expect(calls.length).toBe(1)
    expect(calls[0]!.name).toBe("shell")

    const updates = kinds(seen, "tool_call_update") as { toolCallId: string; status?: string | null }[]
    const mine = updates.filter((update) => update.toolCallId === calls[0]!.toolCallId)
    expect(mine.some((update) => update.status === "completed")).toBe(true)
  })
}, 120_000)

test("a rejected call comes back denied, and always-allow stops the asking", async () => {
  await withAgent(
    {
      profile: "scripted",
      env: scripted_batch_env,
      mode: "ask",
      // `echo` is a command the read-only classifier waves through, so the
      // table that says "stop for this anyway" is what keeps these three calls
      // being questions at all.
      rules: { ...default_rules, ask: ["shell:echo"] },
    },
    async (cx, seen) => {
      seen.answer = (nth) => (nth === 1 ? "reject_once" : "allow_always")
      const id = await newSession(cx)
      const turn = await cx.request("session/prompt", {
        sessionId: id,
        prompt: [{ type: "text", text: "look around" }],
      })
      expect(turn.stopReason).toBe("end_turn")

      // Three calls in one turn; the second answer remembers `shell echo`, so
      // the third is never put to anybody.
      expect(seen.asked.length).toBe(2)

      const results = kinds(seen, "tool_call_update") as {
        toolCallId: string
        status?: string | null
        content?: { content?: { text?: string } }[] | null
      }[]
      const denied = results.filter((update) => update.toolCallId === seen.asked[0]!.toolCall.toolCallId)
      expect(denied.some((update) => update.status === "failed")).toBe(true)
      const said = denied.flatMap((update) => (update.content ?? []).map((part) => part.content?.text ?? ""))
      expect(said.join("\n")).toContain("denied by the user")

      // The two that were allowed did run.
      const allowed = results.filter((update) => update.status === "completed")
      expect(allowed.length).toBeGreaterThanOrEqual(2)
    },
  )
}, 120_000)

test("session/cancel ends the turn as cancelled and leaves the ledger legal", async () => {
  const id = await withAgent({ profile: "scripted", env: scripted_loop_env, mode: "unsafe" }, async (cx, seen) => {
    const id = await newSession(cx)
    const turn = cx.request("session/prompt", { sessionId: id, prompt: [{ type: "text", text: "loop forever" }] })
    // `loop` never ends its own turn, so only the cancel can end this one.
    await until(() =>
      seen.updates.some(
        (update) => update.sessionUpdate === "tool_call_update" && (update as { status?: string }).status === "completed",
      ),
    )
    await cx.notify("session/cancel", { sessionId: id })
    expect((await turn).stopReason).toBe("cancelled")
    return id
  })

  // Physics #7 is the kernel's, and the point of asserting it here is that this
  // adapter did not find a way around it: every assistant turn that asked for
  // tools has the batch of results that answers it, call for call.
  const events = await sessionEvents(ws, id)
  for (let at = 0; at < events.length; at++) {
    const event = events[at]!
    if (event.kind !== "assistant") continue
    const calls = (event as { calls?: { id: string }[] }).calls ?? []
    if (calls.length === 0) continue
    const next = events[at + 1]
    expect(next?.kind).toBe("tool_results")
    const results = (next as { results?: { call_id: string }[] } | undefined)?.results ?? []
    expect(results.map((entry) => entry.call_id)).toEqual(calls.map((call) => call.id))
  }
}, 180_000)

test("session/load in a separate process replays what the session file says", async () => {
  const id = await withAgent({ profile: "scripted", env: scripted_env, mode: "unsafe" }, async (cx) => {
    const id = await newSession(cx)
    await cx.request("session/prompt", { sessionId: id, prompt: [{ type: "text", text: "read the kernel" }] })
    return id
  })

  const entry = join(import.meta.dir, "..", "src", "acp", "main.ts")
  const proc = Bun.spawn({
    cmd: [process.execPath, "run", entry, "--profile", "scripted", "--mode", "unsafe"],
    cwd: ws.dir,
    // Explicit: a child spawned without one does not see the NULYA_HOME this
    // test set after the process started.
    env: { ...process.env, NULYA_BIN: ws.bin },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  })
  const sink = proc.stdin
  const toChild = new WritableStream<Uint8Array>({
    write(chunk) {
      sink.write(chunk)
      return Promise.resolve(sink.flush()).then(() => undefined)
    },
    close() {
      sink.end()
    },
  })
  void new Response(proc.stderr).text()

  const replayed: SessionUpdate[] = []
  try {
    await client({ name: "acp-loader" })
      .onNotification("session/update", (ctx) => {
        replayed.push(ctx.params.update)
      })
      .connectWith(ndJsonStream(toChild, proc.stdout), async (cx) => {
        await cx.request("initialize", { protocolVersion: PROTOCOL_VERSION })
        await cx.request("session/load", { sessionId: id, cwd: ws.dir, mcpServers: [] })
      })
  } finally {
    proc.kill()
    await proc.exited
  }

  const events = await sessionEvents(ws, id)
  const expected = events.flatMap((event) => {
    if (event.kind === "user_text" || event.kind === "note") return [["user", (event as { text: string }).text]]
    const text = (event as { text?: string }).text ?? ""
    return event.kind === "assistant" && text.length > 0 ? [["agent", text]] : []
  })
  const actual = replayed
    .filter((update) => update.sessionUpdate === "user_message_chunk" || update.sessionUpdate === "agent_message_chunk")
    .map((update) => [update.sessionUpdate === "user_message_chunk" ? "user" : "agent", chunkText(update)])
  expect(actual).toEqual(expected)
  expect(actual.length).toBeGreaterThan(1)
}, 180_000)

test("an MCP server this machine has no package for is refused out loud", async () => {
  await withAgent({ profile: "scripted", env: scripted_env, mode: "unsafe" }, async (cx, seen) => {
    await cx.request("initialize", { protocolVersion: PROTOCOL_VERSION })
    const created = await cx.request("session/new", {
      cwd: ws.dir,
      mcpServers: [{ type: "http", name: "github", url: "https://example.invalid/mcp", headers: [] }],
    })

    await cx.request("session/prompt", {
      sessionId: created.sessionId,
      prompt: [{ type: "text", text: "hello" }],
    })

    const notice = kinds(seen, "agent_message_chunk").map(chunkText).join("\n")
    expect(notice).toContain("github")
    expect(notice).toContain("Not connected")

    // And it was refused rather than mounted: the session composed with nothing
    // in it, which is what keeps a frozen tool face frozen.
    const row = (await sessionList(ws)).find((entry) => entry.id === created.sessionId)!
    expect(row.composition.active).toEqual([])
  })
}, 120_000)
