/**
 * The view state of one session: an ordered list of transcript items, built
 * from ledger events plus the transient stream of the step in flight.
 *
 * Two rules shape everything here (tui.md §0.2, §3):
 *
 *  - The ledger is the only truth. Stream lines produce *provisional* items;
 *    when the step's ledger lines arrive they REPLACE them. Replaying a session
 *    with `session events` therefore lands on the same items as watching it
 *    live — the property T1's tests pin down.
 *  - Items are keyed by ledger `seq`, so arrival order never decides display
 *    order. A `user_text` drained from the inbox mid-step carries a small seq
 *    and sorts back into place even though it arrived after the model deltas.
 */
import { createStore, produce } from "solid-js/store"
import type { LedgerEvent, SessionHeader, ToolCall } from "../nulya/ledger.ts"
import type { StreamLine, StepStatus, StopReason } from "../nulya/cli.ts"

export type ToolRunState = "pending" | "running" | "done"

interface ItemBase {
  /** Stable identity for keyed rendering. */
  key: string
  /** Ledger seq, or null while the item is still provisional. */
  seq: number | null
}

export interface UserItem extends ItemBase {
  kind: "user"
  text: string
  /** Deposited into the inbox but not yet drained into the ledger. */
  queued: boolean
}

export interface AssistantItem extends ItemBase {
  kind: "assistant"
  text: string
  streaming: boolean
}

export interface ThinkingItem extends ItemBase {
  kind: "thinking"
  text: string
  /** True when the text could not be recovered from the opaque reasoning blob. */
  opaque: boolean
}

export interface ToolItem extends ItemBase {
  kind: "tool"
  callId: string
  tool: string
  /** Raw JSON arguments; still growing while `state` is "pending" during a stream. */
  args: string
  state: ToolRunState
  ok: boolean | null
  output: string
  spillPath: string | null
  resolved: boolean
}

export interface CapabilityItem extends ItemBase {
  kind: "capability"
  id: string
  version: string
  text: string
}

/** An event kind this build does not know: kept, shown raw, never dropped. */
export interface UnknownItem extends ItemBase {
  kind: "unknown"
  eventKind: string
  raw: string
}

export type TranscriptItem = UserItem | AssistantItem | ThinkingItem | ToolItem | CapabilityItem | UnknownItem

export interface UsageTotals {
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
}

export interface SessionSnapshot {
  id: string
  header: SessionHeader | null
  items: TranscriptItem[]
  usage: UsageTotals
  /** Steps observed by this process (status bar; history before attach is unknown). */
  steps: number
  lastStepStatus: StepStatus | null
  lastStopped: StopReason | null
  /** The tool currently executing, for the status bar spinner. */
  activeTool: string | null
  error: string | null
}

export interface SessionState {
  readonly snapshot: SessionSnapshot
  setHeader(header: SessionHeader | null): void
  /** Replay a whole tail (open / resume). */
  applyEvents(events: LedgerEvent[]): void
  applyEvent(event: LedgerEvent): void
  applyStream(line: StreamLine): void
  /** Highest ledger seq applied so far — where a follower must resume from. */
  lastSeq(): number
  /** Optimistic echo of a just-sent turn; promoted when its `user_text` lands. */
  enqueueUser(text: string): void
  pendingCount(): number
  setError(message: string | null): void
}

function firstProvisionalIndex(items: TranscriptItem[]): number {
  for (let i = 0; i < items.length; i++) {
    if (items[i]!.seq === null) return i
  }
  return items.length
}

export function createSessionState(id: string): SessionState {
  const [snapshot, setSnapshot] = createStore<SessionSnapshot>({
    id,
    header: null,
    items: [],
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    steps: 0,
    lastStepStatus: null,
    lastStopped: null,
    activeTool: null,
    error: null,
  })

  // Bumped at every step boundary so provisional keys of one step never collide
  // with the next step's.
  let turn = 0

  const edit = (fn: (draft: SessionSnapshot) => void) => setSnapshot(produce(fn))

  function insertCommitted(draft: SessionSnapshot, made: TranscriptItem[]) {
    if (made.length === 0) return
    draft.items.splice(firstProvisionalIndex(draft.items), 0, ...made)
  }

  /**
   * Discard the provisional items of the step in flight. Queued user turns are
   * kept: they are waiting for their own `user_text` event, not for this one.
   */
  function dropInFlight(draft: SessionSnapshot) {
    for (let i = draft.items.length - 1; i >= 0; i--) {
      const item = draft.items[i]!
      if (item.seq === null && item.kind !== "user") draft.items.splice(i, 1)
    }
  }

  function toolItemsOf(seq: number, calls: ToolCall[]): ToolItem[] {
    return calls.map((call) => ({
      key: `e${seq}:${call.id}`,
      seq,
      kind: "tool" as const,
      callId: call.id,
      tool: call.tool,
      args: call.args,
      state: "pending" as ToolRunState,
      ok: null,
      output: "",
      spillPath: null,
      resolved: false,
    }))
  }

  // The highest seq already in `items`. A session can be fed from two mouths at
  // once — the step subprocess we own, and a `session events --follow` tail when
  // somebody else drives (tui.md §5.6) — and both replay the same lines. Since
  // seq is monotonic and an event is immutable, "already seen" is exactly
  // "seq <= applied", so idempotence costs one comparison.
  let applied = 0

  function applyEvent(event: LedgerEvent) {
    if (event.seq <= applied) return
    applied = event.seq
    edit((draft) => {
      const seq = event.seq
      switch (event.kind) {
        case "user_text": {
          const text = (event as Extract<LedgerEvent, { kind: "user_text" }>).text
          const at = draft.items.findIndex(
            (item) => item.kind === "user" && item.seq === null && item.queued && item.text === text,
          )
          if (at >= 0) {
            const [promoted] = draft.items.splice(at, 1) as [UserItem]
            promoted.seq = seq
            promoted.key = `e${seq}`
            promoted.queued = false
            insertCommitted(draft, [promoted])
          } else {
            insertCommitted(draft, [{ key: `e${seq}`, seq, kind: "user", text, queued: false }])
          }
          break
        }
        case "assistant": {
          const assistant = event as Extract<LedgerEvent, { kind: "assistant" }>
          dropInFlight(draft)
          const made: TranscriptItem[] = []
          const thinking = readableThinking(assistant.reasoning)
          if (thinking !== null) {
            made.push({
              key: `e${seq}:thinking`,
              seq,
              kind: "thinking",
              text: thinking.text,
              opaque: thinking.opaque,
            })
          }
          if (assistant.text.length > 0) {
            made.push({ key: `e${seq}`, seq, kind: "assistant", text: assistant.text, streaming: false })
          }
          made.push(...toolItemsOf(seq, assistant.calls))
          insertCommitted(draft, made)
          break
        }
        case "tool_results": {
          const results = (event as Extract<LedgerEvent, { kind: "tool_results" }>).results
          for (const result of results) {
            let target: ToolItem | null = null
            for (let i = draft.items.length - 1; i >= 0; i--) {
              const item = draft.items[i]!
              if (item.kind === "tool" && item.callId === result.call_id && !item.resolved) {
                target = item
                break
              }
            }
            if (target) {
              target.state = "done"
              target.ok = result.ok
              target.output = result.output
              target.spillPath = result.spill_path
              target.resolved = true
            } else {
              insertCommitted(draft, [
                {
                  key: `e${seq}:${result.call_id}`,
                  seq,
                  kind: "tool",
                  callId: result.call_id,
                  tool: "",
                  args: "",
                  state: "done",
                  ok: result.ok,
                  output: result.output,
                  spillPath: result.spill_path,
                  resolved: true,
                },
              ])
            }
          }
          break
        }
        case "capability_note": {
          const note = event as Extract<LedgerEvent, { kind: "capability_note" }>
          insertCommitted(draft, [
            { key: `e${seq}`, seq, kind: "capability", id: note.id, version: note.version, text: note.text },
          ])
          break
        }
        default: {
          insertCommitted(draft, [
            { key: `e${seq}`, seq, kind: "unknown", eventKind: event.kind, raw: JSON.stringify(event) },
          ])
        }
      }
    })
  }

  function provisional<T extends TranscriptItem>(draft: SessionSnapshot, key: string): T | null {
    for (let i = draft.items.length - 1; i >= 0; i--) {
      const item = draft.items[i]!
      if (item.key === key) return item as T
    }
    return null
  }

  function applyStream(line: StreamLine) {
    edit((draft) => {
      if (line.stream === "model") {
        switch (line.event) {
          case "started":
            draft.activeTool = null
            break
          case "text_delta": {
            const key = `p${turn}:assistant`
            const existing = provisional<AssistantItem>(draft, key)
            if (existing) existing.text += (line as { text: string }).text
            else
              draft.items.push({
                key,
                seq: null,
                kind: "assistant",
                text: (line as { text: string }).text,
                streaming: true,
              })
            break
          }
          case "thinking_delta": {
            const key = `p${turn}:thinking`
            const existing = provisional<ThinkingItem>(draft, key)
            if (existing) existing.text += (line as { text: string }).text
            else
              draft.items.push({
                key,
                seq: null,
                kind: "thinking",
                text: (line as { text: string }).text,
                opaque: false,
              })
            break
          }
          case "tool_use_start": {
            const start = line as unknown as { index: number; id: string; name: string }
            draft.items.push({
              key: `p${turn}:tool:${start.index}`,
              seq: null,
              kind: "tool",
              callId: start.id,
              tool: start.name,
              args: "",
              state: "pending",
              ok: null,
              output: "",
              spillPath: null,
              resolved: false,
            })
            break
          }
          case "tool_use_input_delta": {
            const delta = line as unknown as { index: number; fragment: string }
            const item = provisional<ToolItem>(draft, `p${turn}:tool:${delta.index}`)
            if (item) item.args += delta.fragment
            break
          }
          case "usage": {
            const usage = line as unknown as {
              input_tokens: number
              output_tokens: number
              cache_read_tokens: number
              cache_write_tokens: number
            }
            // Per-step counts, not cumulative (tui.md §11, T0 reminder 2).
            draft.usage.input += usage.input_tokens
            draft.usage.output += usage.output_tokens
            draft.usage.cacheRead += usage.cache_read_tokens
            draft.usage.cacheWrite += usage.cache_write_tokens
            break
          }
          case "done": {
            const item = provisional<AssistantItem>(draft, `p${turn}:assistant`)
            if (item) item.streaming = false
            break
          }
        }
        return
      }
      if (line.stream === "tool") {
        const call_id = (line as { call_id?: string }).call_id
        if (typeof call_id !== "string") return
        for (let i = draft.items.length - 1; i >= 0; i--) {
          const item = draft.items[i]!
          if (item.kind !== "tool" || item.callId !== call_id || item.resolved) continue
          if (line.event === "begin") {
            item.state = "running"
            draft.activeTool = item.tool
          } else if (line.event === "end") {
            item.state = "done"
            item.ok = (line as { ok?: boolean }).ok ?? null
            draft.activeTool = null
          }
          break
        }
        return
      }
      if (line.stream === "step" && line.event === "end") {
        // This step's ledger lines were flushed before this marker (DESIGN §14),
        // so anything still provisional never made it into the ledger — a turn
        // canceled in the provider phase, for instance. Drop it rather than
        // leave a card the session file does not back.
        dropInFlight(draft)
        draft.steps += 1
        draft.lastStepStatus = ((line as { status?: StepStatus }).status ?? "completed") as StepStatus
        draft.activeTool = null
        turn += 1
        return
      }
      if (line.stream === "run") {
        if (line.event === "done") {
          draft.lastStopped = ((line as { stopped?: StopReason }).stopped ?? "end_turn") as StopReason
          draft.activeTool = null
        } else if (line.event === "error") {
          draft.error = (line as { message?: string }).message ?? "step failed"
          draft.activeTool = null
        }
      }
    })
  }

  return {
    get snapshot() {
      return snapshot
    },
    setHeader(header) {
      edit((draft) => {
        draft.header = header
      })
    },
    applyEvents(events) {
      for (const event of events) applyEvent(event)
    },
    applyEvent,
    applyStream,
    lastSeq: () => applied,
    enqueueUser(text) {
      edit((draft) => {
        draft.items.push({ key: `q:${Date.now()}:${draft.items.length}`, seq: null, kind: "user", text, queued: true })
      })
    },
    pendingCount() {
      return snapshot.items.filter((item) => item.kind === "user" && item.queued).length
    },
    setError(message) {
      edit((draft) => {
        draft.error = message
      })
    },
  }
}

/**
 * A best-effort readable projection of `assistant.reasoning`. The kernel keeps
 * it opaque on purpose (DESIGN §3.1) — it is a provider-shaped array kept for
 * replay — so we try the one shape that carries plain text (Anthropic's
 * `thinking` blocks) and otherwise say so instead of guessing.
 */
export function readableThinking(reasoning: string | undefined): { text: string; opaque: boolean } | null {
  if (!reasoning || reasoning.length === 0) return null
  try {
    const items = JSON.parse(reasoning)
    if (Array.isArray(items)) {
      const parts: string[] = []
      for (const item of items) {
        if (item && typeof item === "object" && typeof (item as { thinking?: unknown }).thinking === "string") {
          parts.push((item as { thinking: string }).thinking)
        }
      }
      if (parts.length > 0) return { text: parts.join("\n"), opaque: false }
    }
  } catch {
    // Not JSON we understand; fall through to the opaque marker.
  }
  return { text: "", opaque: true }
}
