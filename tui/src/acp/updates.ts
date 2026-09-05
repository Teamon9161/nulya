/**
 * The kernel's step line protocol and its ledger events, translated into ACP
 * `session/update` payloads.
 *
 * Pure: nothing here spawns, notifies or waits. Lines go in, updates come out,
 * and all of a turn's bookkeeping — which `tool_use_start` index carries which
 * call id, which delivery this side already echoed — lives in the instance.
 *
 * Two invariants the callers rely on:
 *   - a gate line never reaches this file. `sessionStep` answers it before the
 *     line generator yields again, so a call is offered for approval only after
 *     every update that precedes it has been sent.
 *   - ids are the kernel's. `toolCallId` is its `call_id`, `messageId` is a
 *     replayed event's `seq`; nothing here mints an identifier of its own.
 */
import type {
  PlanEntry,
  PlanEntryStatus,
  SessionUpdate,
  ToolCallContent,
  ToolCallStatus,
  ToolKind,
} from "@agentclientprotocol/sdk"
import { shellCommand, summarize } from "../approvals.ts"
import type { StepLine, StreamLine } from "../nulya/cli.ts"
import { originsOf, type LedgerEvent, type ToolCall, type ToolResultEntry } from "../nulya/ledger.ts"

/**
 * ACP's icon hint for a call. `shell` is the only name this adapter can be sure
 * of; the rest is what the bundled `std` and `plan` call their tools, and a
 * package may name a tool anything at all — so `other` is the honest answer for
 * everything else rather than a guess from the spelling.
 */
const tool_kinds: Record<string, ToolKind> = {
  shell: "execute",
  read: "read",
  glob: "search",
  grep: "search",
  edit: "edit",
  write: "edit",
  append: "edit",
  todo: "think",
  propose: "think",
}

/** `extensions/plan`'s checklist states, in ACP's words. */
const plan_states: Record<string, PlanEntryStatus> = {
  todo: "pending",
  doing: "in_progress",
  done: "completed",
}

function str(value: unknown): string {
  return typeof value === "string" ? value : ""
}

function fields(value: unknown): Record<string, unknown> {
  return value as Record<string, unknown>
}

type ChunkKind = "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk"

function textChunk(kind: ChunkKind, text: string, seq?: number): SessionUpdate {
  const content = { type: "text" as const, text }
  return seq === undefined
    ? { sessionUpdate: kind, content }
    : { sessionUpdate: kind, content, messageId: String(seq) }
}

/**
 * What a call is DOING, for the one line a client puts beside the icon. A
 * `shell` call is its command; anything else is the tool's name and its
 * arguments as the model wrote them, because this side does not know what a
 * package's fields mean (`approvals.summarize`).
 */
function toolTitle(tool: string, args: string): string {
  const request = { call_id: "", tool, tool_id: null, readonly: null, args }
  const command = shellCommand(request)
  if (command !== null) return command
  const summary = summarize(request)
  return summary.length > 0 ? `${tool} ${summary}` : tool
}

/** The arguments as a value, or undefined when they are not JSON — a reply cut off by `max_tokens`. */
function rawInput(args: string): unknown {
  try {
    return JSON.parse(args)
  } catch {
    return undefined
  }
}

/**
 * `extensions/plan`'s `todo` arguments as an ACP plan, or null when they are
 * not that shape.
 *
 * Every entry reads `medium`: ACP requires a priority, a checklist has no such
 * column, and the neutral value is the only one that is not a claim about the
 * item.
 */
export function planOf(args: string): SessionUpdate | null {
  const items = fields(rawInput(args) ?? {})["items"]
  if (!Array.isArray(items)) return null
  const entries: PlanEntry[] = []
  for (const item of items) {
    const text = str(fields(item ?? {})["text"])
    if (text.length === 0) continue
    const state = str(fields(item ?? {})["state"])
    entries.push({ content: text, priority: "medium", status: plan_states[state] ?? "pending" })
  }
  return entries.length > 0 ? { sessionUpdate: "plan", entries } : null
}

function toolCallStart(id: string, tool: string): SessionUpdate {
  return {
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: tool,
    name: tool,
    kind: tool_kinds[tool] ?? "other",
    status: "pending",
  }
}

function inputUpdate(id: string, tool: string, args: string): SessionUpdate {
  return {
    sessionUpdate: "tool_call_update",
    toolCallId: id,
    title: toolTitle(tool, args),
    rawInput: rawInput(args),
  }
}

/**
 * One recorded result as an update. The status is the ledger's `ok`, which is
 * the only source covering every ending: a call the gate refused is never
 * dispatched, so it has no `tool` begin/end pair at all and this line is the
 * first and last thing said about it.
 */
function toolResultUpdate(entry: ToolResultEntry): SessionUpdate {
  const output = str(entry.output)
  const content: ToolCallContent[] =
    output.length > 0 ? [{ type: "content", content: { type: "text", text: output } }] : []
  return {
    sessionUpdate: "tool_call_update",
    toolCallId: entry.call_id,
    status: entry.ok ? "completed" : "failed",
    content,
  }
}

function statusUpdate(id: string, status: ToolCallStatus): SessionUpdate {
  return { sessionUpdate: "tool_call_update", toolCallId: id, status }
}

export interface TurnOptions {
  /**
   * Delivery names this adapter appended and has already echoed as a
   * `user_message_chunk`. The drained `user_text` carries the name back in its
   * `origin`, which is how the echo is suppressed by IDENTITY: two turns with
   * the same text are two deliveries, and another driver's turn on this session
   * is not ours to swallow.
   */
  echoed: ReadonlySet<string>
  /**
   * The tools whose package asked for a checklist rendering (`catalog.ts`). An
   * ACP `plan` is a checklist, so calls to these become plan updates — asked of
   * the manifest, never of the tool's name.
   */
  checklistTools: ReadonlySet<string>
}

/** One prompt turn's worth of translation state. */
export class TurnTranslator {
  /** By `tool_use_start` index: the call it opened and the argument text so far. */
  private readonly open = new Map<number, { id: string; tool: string; args: string }>()

  constructor(private readonly options: TurnOptions) {}

  line(line: StepLine): SessionUpdate[] {
    return line.kind === "stream" ? this.stream(line.line) : this.event(line.event)
  }

  private stream(line: StreamLine): SessionUpdate[] {
    const row = fields(line)
    if (line.stream === "model") {
      switch (line.event) {
        case "text_delta":
          return [textChunk("agent_message_chunk", str(row["text"]))]
        case "thinking_delta":
          return [textChunk("agent_thought_chunk", str(row["text"]))]
        case "tool_use_start": {
          const id = str(row["id"])
          const tool = str(row["name"])
          this.open.set(typeof row["index"] === "number" ? row["index"] : 0, { id, tool, args: "" })
          return [toolCallStart(id, tool)]
        }
        case "tool_use_input_delta": {
          const open = this.open.get(typeof row["index"] === "number" ? row["index"] : 0)
          if (open) open.args += str(row["fragment"])
          return []
        }
        case "done":
          return this.closeInputs()
        default:
          return []
      }
    }
    if (line.stream === "tool") {
      const id = str(row["call_id"])
      if (line.event === "begin") return [statusUpdate(id, "in_progress")]
      // The recorded `tool_results` says this again, and says it durably; this
      // one exists so a batch's third call is not drawn as still running while
      // its first two have already finished.
      if (line.event === "end") return [statusUpdate(id, row["ok"] === true ? "completed" : "failed")]
    }
    return []
  }

  /**
   * The arguments are complete once the model's reply is done, so this is where
   * a call gets its real title and `rawInput` — and where a checklist becomes a
   * plan, since such a tool's arguments ARE the checklist.
   */
  private closeInputs(): SessionUpdate[] {
    const updates: SessionUpdate[] = []
    for (const call of this.open.values()) {
      updates.push(inputUpdate(call.id, call.tool, call.args))
      if (this.options.checklistTools.has(call.tool)) {
        const plan = planOf(call.args)
        if (plan) updates.push(plan)
      }
    }
    this.open.clear()
    return updates
  }

  private event(event: LedgerEvent): SessionUpdate[] {
    switch (event.kind) {
      case "user_text": {
        const mine = originsOf(event).some((name) => this.options.echoed.has(name))
        return mine ? [] : [textChunk("user_message_chunk", str(fields(event)["text"]), event.seq)]
      }
      case "note":
        return [textChunk("user_message_chunk", str(fields(event)["text"]), event.seq)]
      case "tool_results":
        return resultsOf(event).map(toolResultUpdate)
      // The assistant's own text and calls already streamed as deltas; this
      // event is that same turn recorded, not a second one.
      default:
        return []
    }
  }
}

function resultsOf(event: LedgerEvent): ToolResultEntry[] {
  const results = fields(event)["results"]
  return Array.isArray(results) ? (results as ToolResultEntry[]) : []
}

function callsOf(event: LedgerEvent): ToolCall[] {
  const calls = fields(event)["calls"]
  return Array.isArray(calls) ? (calls as ToolCall[]) : []
}

/**
 * A session's recorded events as the updates that replay it — `session/load`.
 *
 * The history is already on disk (a generation is a file), which is the whole
 * of what other agents have to keep a store for. `reasoning` is not replayed:
 * it is opaque provider state kept for the model, and nobody read it the first
 * time either.
 */
export function replayUpdates(
  events: readonly LedgerEvent[],
  options: { checklistTools: ReadonlySet<string> },
): SessionUpdate[] {
  const updates: SessionUpdate[] = []
  for (const event of events) {
    switch (event.kind) {
      case "user_text":
      case "note":
        updates.push(textChunk("user_message_chunk", str(fields(event)["text"]), event.seq))
        break
      case "assistant": {
        const text = str(fields(event)["text"])
        if (text.length > 0) updates.push(textChunk("agent_message_chunk", text, event.seq))
        for (const call of callsOf(event)) {
          updates.push(toolCallStart(call.id, call.tool))
          updates.push(inputUpdate(call.id, call.tool, call.args))
          if (options.checklistTools.has(call.tool)) {
            const plan = planOf(call.args)
            if (plan) updates.push(plan)
          }
        }
        break
      }
      case "tool_results":
        for (const entry of resultsOf(event)) updates.push(toolResultUpdate(entry))
        break
      default:
        break
    }
  }
  return updates
}
