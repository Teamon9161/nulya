/**
 * Nulya on the agent side of ACP: an editor drives `nulya session *` over
 * JSON-RPC.
 *
 * A driver client over a process boundary, exactly as the TUI is — every method
 * below turns into `session new` / `append` / `step --gate` / `events` /
 * `cancel` and nothing else. The kernel gains nothing for this file's sake: an
 * ACP session IS a nulya session (its id is the one on disk), a `session/update`
 * is the step's own line protocol translated, and `session/request_permission`
 * is the gate's one question asked in the editor's words.
 *
 * The two things this adapter keeps for itself are the two the kernel has no
 * business knowing: the permission mode and what "always" means this session
 * (`permission.ts`), and which deliveries it has already echoed.
 */
import {
  PROTOCOL_VERSION,
  RequestError,
  agent as acpAgent,
  methods,
  type AgentApp,
  type AgentContext,
  type AvailableCommand,
  type ContentBlock,
  type SessionModeState,
  type SessionUpdate,
  type StopReason as AcpStopReason,
} from "@agentclientprotocol/sdk"
import { default_rules, isMode, type ApprovalRules, type PermissionMode } from "../approvals.ts"
import { openWorkspace, type Workspace } from "../nulya/bin.ts"
import {
  CliError,
  extList,
  sessionAppend,
  sessionCancel,
  sessionEvents,
  sessionNew,
  sessionStep,
  type StopReason,
} from "../nulya/cli.ts"
import { sessionExists } from "../nulya/files.ts"
import { readCatalog } from "./catalog.ts"
import { answerGate, type SessionPolicy } from "./permission.ts"
import { TurnTranslator, replayUpdates } from "./updates.ts"

/**
 * This adapter's own version, which is not the kernel's: the binary a session
 * runs on is found per workspace and may be any build.
 */
const adapter_version = "0.1.0"

/** The four endings the kernel reports, in ACP's words. */
const stop_reasons: Record<StopReason, AcpStopReason> = {
  end_turn: "end_turn",
  canceled: "cancelled",
  max_tokens: "max_tokens",
  budget: "max_turn_requests",
}

export interface AcpAgentOptions {
  /** `--profile` for every session this adapter creates; absent means the config's active one. */
  profile?: string
  /** `--model` within that profile; absent means the profile's default. */
  model?: string
  /** `--effort` for every step. */
  effort?: string
  /** The mode a new session starts in. */
  mode?: PermissionMode
  /**
   * The standing approval tables. Policy is the driver's, which is why it
   * arrives as a parameter and not as a file this module knows how to find.
   */
  rules?: ApprovalRules
  /** Extra environment for the `nulya` children (`NULYA_SCRIPTED_MODE` in tests). */
  env?: Record<string, string>
  /** Where diagnostics go. Never stdout: that carries JSON-RPC and nothing else. */
  log?: (line: string) => void
}

interface AcpSession {
  id: string
  ws: Workspace
  policy: SessionPolicy
  planTodo: boolean
  /**
   * Updates that belong to the session rather than to a turn — the command list
   * and any refusal from `session/new`. Held until there is somewhere to stream
   * them, because `session/new` has no such window: the client does not know
   * the session id until the response it is still waiting for arrives.
   */
  opening: SessionUpdate[]
  /** Delivery names appended here, so the drained `user_text` is not echoed twice. */
  echoed: Set<string>
  /**
   * Whether a prompt turn is under way. It covers the append as well as the
   * step, because the kernel's cancel is a marker consumed at a step boundary:
   * one that lands before the step starts still ends that turn, while one that
   * lands when nothing is running would be left for whatever runs next.
   */
  turn: boolean
}

function modeState(current: PermissionMode): SessionModeState {
  return {
    currentModeId: current,
    availableModes: [
      { id: "ask", name: "Ask", description: "Offer every call no standing rule settles." },
      {
        id: "unsafe",
        name: "Unsafe",
        description: "Run what the model wrote, with only the standing deny and ask tables in the way.",
      },
    ],
  }
}

/**
 * The text of one prompt. `text` and `resource_link` are the two blocks an
 * agent must support, and a link becomes its uri because what the model needs
 * is where to look — the same thing the TUI's composer puts in a turn. The
 * other block types are declined in `promptCapabilities`, so one that arrives
 * anyway contributes nothing rather than being trusted.
 */
function promptText(blocks: readonly ContentBlock[]): string {
  const parts: string[] = []
  for (const block of blocks) {
    if (block.type === "text") parts.push(block.text)
    else if (block.type === "resource_link") parts.push(block.uri)
  }
  return parts.join("\n").trim()
}

/**
 * Which of the client's MCP servers this machine can answer for.
 *
 * A server is honoured only as a package already built and activated here under
 * its name, and it joins as a MEMBER — so its tools freeze at `session new`
 * like every other member's. Mounting tools on a live session is the one thing
 * this mapping must never become: a session's tool face is decided when it is
 * created, and a client that could add to it afterwards would be editing that
 * decision from outside.
 */
async function matchMcpServers(
  ws: Workspace,
  servers: readonly { name: string }[],
): Promise<{ members: string[]; unmatched: string[] }> {
  const members: string[] = []
  const unmatched: string[] = []
  if (servers.length === 0) return { members, unmatched }
  const held = new Map((await extList(ws)).map((entry) => [entry.id, entry.current]))
  for (const server of servers) {
    const id = `mcp.${server.name}`
    if (held.get(id)) members.push(id)
    else unmatched.push(server.name)
  }
  return { members, unmatched }
}

function mcpNotice(unmatched: readonly string[]): string {
  const names = unmatched.map((name) => `\`${name}\``).join(", ")
  return (
    `Not connected to ${names}: nulya reaches an MCP server through a package built and activated on this ` +
    `machine (\`mcp.<name>\`), and there is none by that name here. This session was composed without it, ` +
    `and nothing is mounted after a session starts — its tool face is decided when it is created.`
  )
}

/** A refused CLI call, with the kernel's own sentence kept intact for the client. */
function refuse(error: unknown): RequestError {
  if (error instanceof CliError) return RequestError.internalError(error.detail, error.message)
  return RequestError.internalError(String(error), error instanceof Error ? error.message : "nulya refused")
}

export function createAcpAgent(options: AcpAgentOptions = {}): AgentApp {
  const sessions = new Map<string, AcpSession>()
  const rules = options.rules ?? default_rules
  const startMode = options.mode ?? "ask"
  const log = options.log ?? ((line: string) => process.stderr.write(`${line}\n`))

  function open(sessionId: string): AcpSession {
    const session = sessions.get(sessionId)
    if (!session) throw RequestError.invalidParams(sessionId, `no session ${sessionId} on this connection`)
    return session
  }

  function track(id: string, ws: Workspace, planTodo: boolean, opening: SessionUpdate[]): AcpSession {
    const session: AcpSession = {
      id,
      ws,
      policy: { mode: startMode, rules, always: new Set(), never: new Set() },
      planTodo,
      opening,
      echoed: new Set(),
      turn: false,
    }
    sessions.set(id, session)
    return session
  }

  async function send(cx: AgentContext, sessionId: string, updates: readonly SessionUpdate[]): Promise<void> {
    for (const update of updates) {
      await cx.notify(methods.client.session.update, { sessionId, update })
    }
  }

  function commandsUpdate(commands: AvailableCommand[]): SessionUpdate[] {
    return commands.length > 0 ? [{ sessionUpdate: "available_commands_update", availableCommands: commands }] : []
  }

  /**
   * One prompt turn: append it, step, translate the step's own line protocol on
   * the way past. The gate answer travels back into that same subprocess, whose
   * connection to the model is already closed while it waits — so a person may
   * take as long as they like over a permission.
   */
  async function runTurn(cx: AgentContext, session: AcpSession, text: string): Promise<{ stopReason: AcpStopReason }> {
    await send(cx, session.id, session.opening)
    session.opening = []

    // Appended, then echoed: the turn sits in the inbox and only enters the
    // ledger at the step boundary, so this is the one update the adapter has to
    // say itself. The delivery name is what stops it being said twice — the
    // drained event carries that name back as its `origin`.
    let delivery: string
    try {
      delivery = await sessionAppend(session.ws, session.id, text)
    } catch (error) {
      throw refuse(error)
    }
    session.echoed.add(delivery)
    await send(cx, session.id, [{ sessionUpdate: "user_message_chunk", content: { type: "text", text } }])

    const translator = new TurnTranslator({ echoed: session.echoed, planTodo: session.planTodo })
    const step = sessionStep(session.ws, session.id, {
      effort: options.effort,
      env: options.env,
      gate: (request) =>
        answerGate(request, session.id, session.policy, (params) =>
          cx.request(methods.client.session.requestPermission, params),
        ),
    })

    let stopped: StopReason | null = null
    let failure: string | null = null
    const cost = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
    try {
      for await (const line of step.lines) {
        if (line.kind === "stream" && line.line.stream === "run") {
          const row = line.line as unknown as Record<string, unknown>
          if (line.line.event === "done") stopped = row["stopped"] as StopReason
          // A diagnostic is a line of the protocol like any other, so there is
          // nothing to guess at: this line plus a non-zero exit is the only way
          // a step says it failed, and stdout carries no other kind of line.
          if (line.line.event === "error") failure = String(row["message"] ?? "step failed")
        }
        if (line.kind === "stream" && line.line.stream === "model" && line.line.event === "usage") {
          const row = line.line as unknown as Record<string, number>
          cost.input += row["input_tokens"] ?? 0
          cost.output += row["output_tokens"] ?? 0
          cost.cacheRead += row["cache_read_tokens"] ?? 0
          cost.cacheWrite += row["cache_write_tokens"] ?? 0
        }
        await send(cx, session.id, translator.line(line))
      }
    } catch (error) {
      // Only on the way out through an exception: on the ordinary path the
      // stream ends because the step is already finishing, and a kill there
      // would land between its last line and its own cleanup.
      step.kill()
      throw error
    }
    const code = await step.exited
    const said = (await step.stderr).trim()
    if (cost.input + cost.output > 0) {
      // ACP v1 has no update for what a turn cost and this adapter does not
      // invent one; the number still has to land somewhere it can be read.
      log(
        `usage ${session.id} in=${cost.input} out=${cost.output} cache_read=${cost.cacheRead} cache_write=${cost.cacheWrite}`,
      )
    }
    if (said.length > 0) log(`step ${session.id}: ${said}`)
    if (failure !== null || code !== 0) {
      const message = failure ?? `nulya session step exited ${code}`
      throw RequestError.internalError(said.length > 0 ? said : message, message)
    }
    return { stopReason: stopped ? stop_reasons[stopped] : "end_turn" }
  }

  return acpAgent({ name: "nulya" })
    .onRequest(methods.agent.initialize, () => ({
      protocolVersion: PROTOCOL_VERSION,
      agentCapabilities: {
        // The history is the session file, so replaying it costs nothing this
        // adapter is not doing anyway.
        loadSession: true,
        // Text and resource links only. The client's file system and terminal
        // are left alone for the same reason: `extensions/std` reads and writes
        // here, and a background command is the kernel's own supervisor.
        promptCapabilities: { image: false, audio: false, embeddedContext: false },
      },
      authMethods: [],
      agentInfo: { name: "nulya", version: adapter_version },
    }))
    .onRequest(methods.agent.authenticate, () => {
      throw RequestError.invalidParams(
        undefined,
        "nulya has no authentication methods: a provider credential is config or environment, and " +
          "`session/new` reports in the kernel's own words when one is missing",
      )
    })
    .onRequest(methods.agent.session.new, async (ctx) => {
      const ws = openWorkspace(ctx.params.cwd)
      const { members, unmatched } = await matchMcpServers(ws, ctx.params.mcpServers ?? [])
      let id: string
      try {
        id = await sessionNew(ws, { profile: options.profile, model: options.model, with: members }, options.env)
      } catch (error) {
        throw refuse(error)
      }
      const catalog = await readCatalog(ws, id)
      const opening = commandsUpdate(catalog.commands)
      if (unmatched.length > 0) {
        opening.push({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: mcpNotice(unmatched) } })
      }
      track(id, ws, catalog.planTodo, opening)
      return { sessionId: id, modes: modeState(startMode) }
    })
    .onRequest(methods.agent.session.load, async (ctx) => {
      const ws = openWorkspace(ctx.params.cwd)
      const id = ctx.params.sessionId
      if (!sessionExists(ws, id)) throw RequestError.resourceNotFound(id)
      const catalog = await readCatalog(ws, id)
      const session = sessions.get(id) ?? track(id, ws, catalog.planTodo, commandsUpdate(catalog.commands))
      const events = await sessionEvents(ws, id)
      // A load HAS a window to stream in, so whatever was waiting for a first
      // prompt is said here instead.
      await send(ctx.client, id, session.opening)
      session.opening = []
      await send(ctx.client, id, replayUpdates(events, { planTodo: catalog.planTodo }))
      return { modes: modeState(session.policy.mode) }
    })
    .onRequest(methods.agent.session.setMode, (ctx) => {
      const session = open(ctx.params.sessionId)
      if (!isMode(ctx.params.modeId)) {
        throw RequestError.invalidParams(ctx.params.modeId, `no mode ${ctx.params.modeId}`)
      }
      session.policy.mode = ctx.params.modeId
      return {}
    })
    .onNotification(methods.agent.session.cancel, async (ctx) => {
      const session = sessions.get(ctx.params.sessionId)
      // Outside a turn there is nothing to cancel, and writing the marker
      // anyway would leave it lying there for whatever runs next.
      if (!session?.turn) return
      // The kernel's own cancellation: a marker consumed at a step boundary, so
      // the batch under way keeps its shape and the ledger is never left with
      // an assistant turn nobody answered.
      await sessionCancel(session.ws, session.id).catch((error: unknown) => {
        log(`cancel ${session.id}: ${error instanceof Error ? error.message : String(error)}`)
      })
    })
    .onRequest(methods.agent.session.prompt, async (ctx) => {
      const session = open(ctx.params.sessionId)
      // One turn at a time: a session has one writer, so a second step would be
      // refused by a lock rather than by anything here.
      if (session.turn) {
        throw RequestError.invalidRequest(undefined, `a prompt is already running for ${session.id}`)
      }
      const text = promptText(ctx.params.prompt)
      if (text.length === 0) throw RequestError.invalidParams(undefined, "the prompt carries no text")
      session.turn = true
      try {
        return await runTurn(ctx.client, session, text)
      } finally {
        session.turn = false
      }
    })
}
