/**
 * The view state of one session: an ordered list of transcript items, built
 * from ledger events plus the transient stream of the step in flight.
 *
 * Two rules shape everything here:
 *
 *  - The ledger is the only truth. Stream lines produce *provisional* items;
 *    when the step's ledger lines arrive they REPLACE them. Replaying a session
 *    with `session events` therefore lands on the same items as watching it
 *    live.
 *  - Items are keyed by ledger `seq`, so arrival order never decides display
 *    order. A `user_text` drained from the inbox mid-step carries a small seq
 *    and sorts back into place even though it arrived after the model deltas.
 */
import { createStore, produce } from "solid-js/store"
import { noteMeta, originsOf, startedTaskOf, taskReportOf } from "../nulya/ledger.ts"
import type { LedgerEvent, SessionHeader, ToolCall, Usage } from "../nulya/ledger.ts"
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
  /** Image blocks carried beside the text; bytes stay in the ledger, not the card. */
  imageCount?: number
  /** Deposited into the inbox but not yet drained into the ledger. */
  queued: boolean
  /**
   * The inbox delivery name `session append` receipted, or null while the
   * append is still in flight. This is what promotes the item: the drained
   * `user_text` carries the same name back as its `origin`, so two turns with
   * identical text are still two distinct deliveries.
   */
  delivery?: string | null
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
  /** UI-only tool presentation JSON parsed from the ledger side channel. */
  presentation?: unknown | null
  spillPath: string | null
  resolved: boolean
  /**
   * The kernel is holding this call open, waiting for a verdict (`--gate`).
   * A view fact, not a ledger one: the call is still exactly what
   * the assistant turn recorded, and one keypress later it either ran or came
   * back denied. At most one call is ever awaiting — the kernel executes a batch
   * serially and asks about each call in turn.
   */
  awaiting: boolean
  /**
   * The gate answered this call without asking, because the command it carries
   * only reads (`readonlyshell.ts`). A view fact of the same
   * genre as `awaiting`: nothing about the call changed, and what this records
   * is that a question a person would expect to see was not asked. Silence
   * would make `ask` mode look like it had quietly stopped working.
   */
  autoAllowed: boolean
  /**
   * How the background task this call started ended, once its report landed
   *. Set by the task's report note, matched to this card by the
   * full task name in its own receipt — so a reopened session shows the same
   * head line without any process being asked anything.
   */
  taskResult: { exitCode: number; duration: string } | null
}

export interface CapabilityItem extends ItemBase {
  kind: "capability"
  id: string
  version: string
  text: string
}

/**
 * A background task ended and said so in the ledger (a `note` whose source is
 * `task`). Its own card, not an update to the call that started it: the call
 * already returned — with a receipt — and this is a second event, minutes later,
 * that the model reads as a turn of its own.
 */
export interface TaskItem extends ItemBase {
  kind: "task"
  /** Full name `<session>/t<N>`. */
  task: string
  exitCode: number
  /** The report verbatim, as the model received it. */
  text: string
}

/**
 * A machine fact from outside the step that is neither of the two the screen
 * draws its own card for: a plugin's note, a driver's, a watcher's. Rendered in
 * the shape of a turn with a badge saying where it came from — the transcript is
 * the one place "who said this" survives a replay.
 */
export interface NoteItem extends ItemBase {
  kind: "note"
  /** The depositor's own label, uninterpreted (`ext`, `driver`, …). */
  source: string
  /** Its structured columns, already parsed; `{}` when it wrote none. */
  meta: Record<string, unknown>
  text: string
}

/** An event kind this build does not know: kept, shown raw, never dropped. */
export interface UnknownItem extends ItemBase {
  kind: "unknown"
  eventKind: string
  raw: string
}

export type TranscriptItem =
  | UserItem
  | AssistantItem
  | ThinkingItem
  | ToolItem
  | CapabilityItem
  | TaskItem
  | NoteItem
  | UnknownItem

export interface UsageTotals {
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
  /** Steps whose cost is known: the ledger recorded usage for them. */
  pricedSteps: number
  /**
   * The whole prompt of the most recent step — NOT a total across steps. A step
   * sends the entire prefix, so what the provider counted last time is roughly
   * what the next request starts from: this is how full the context window is
   * right now, and the only honest basis for "should this be compacted".
   *
   * It is a SUM of three counters because `provider.Usage.input_tokens` is
   * normalised to the NON-cached part (provider.zig): a well-cached step reports
   * a tiny `input_tokens` over an enormous prefix, and reading that one field
   * alone would say a nearly-full window is nearly empty.
   */
  lastPrompt: number
}

/**
 * The share of all prompt tokens this session has sent that came out of the
 * provider's cache. The denominator is the WHOLE prompt — `input` here is the
 * kernel's `input_tokens`, already normalised to the non-cached part (see
 * `lastPrompt`), so `cacheRead / input` is "cached ÷ uncached" and reads 900%
 * on a step that hit the cache for nine tokens in ten. Rounded to a percent;
 * 0 before anything was priced.
 */
export function cacheShare(u: Pick<UsageTotals, "input" | "cacheRead" | "cacheWrite">): number {
  const prompt = u.input + u.cacheRead + u.cacheWrite
  return prompt > 0 ? Math.round((u.cacheRead / prompt) * 100) : 0
}

/** `12.3k`, `1.2M` — a token count at a glance. */
export function compactCount(n: number): string {
  if (n < 1000) return String(n)
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`
  return `${(n / 1_000_000).toFixed(1)}M`
}

/**
 * What this session has cost, in one phrase — or null before it has cost
 * anything (a draft tab, a session reopened but not stepped).
 *
 * It is said on the ACTIVITY line and only while something is happening:
 * a running total is news exactly while it is moving, and the row under the
 * composer is a standing description of the session, read once and then
 * trusted. `/usage` is where the whole ledger's arithmetic lives.
 */
export function usageLabel(u: UsageTotals): string | null {
  if (u.input === 0 && u.output === 0) return null
  return `↑${compactCount(u.input)} ↓${compactCount(u.output)} cache ${cacheShare(u)}%`
}

/**
 * Move a displayed counter toward the ledger/stream total without pretending the
 * total itself is anything other than an integer fact. Small numbers advance in
 * visible steps; large jumps are capped so a late provider usage event does not
 * teleport a six-digit meter in one frame.
 */
export function approachCount(current: number, target: number): number {
  const from = Math.max(0, Math.floor(current))
  const to = Math.max(0, Math.floor(target))
  if (to <= from) return to
  const delta = to - from
  if (delta <= 2) return from + 1
  const cap = to < 1_000 ? 37 : to < 100_000 ? 997 : to < 1_000_000 ? 9_973 : 99_973
  return Math.min(to, from + Math.max(1, Math.min(cap, Math.ceil(delta / 6))))
}

/** UI-only smoothing for the activity-line meter. */
export function smoothUsageTotals(current: UsageTotals, target: UsageTotals): UsageTotals {
  return {
    input: approachCount(current.input, target.input),
    output: approachCount(current.output, target.output),
    cacheRead: approachCount(current.cacheRead, target.cacheRead),
    cacheWrite: approachCount(current.cacheWrite, target.cacheWrite),
    pricedSteps: target.pricedSteps,
    lastPrompt: target.lastPrompt,
  }
}

export interface RetryNotice {
  error: string
  attempt: number
  maxRetries: number
  retryAt: number
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
  /**
   * The latest tool card whose sweep stays visible through result recording and
   * the following model response. Cleared only when the run ends; a later tool
   * replaces it when execution begins.
   */
  highlightedToolCallId: string | null
  error: string | null
  /** Structured retry timing for a live countdown; null for every ordinary error. */
  retry: RetryNotice | null
}

/**
 * What a session runs on.
 *
 * One answer for the whole file: the model is frozen at `session new` and no
 * event moves it. Running the rest of a conversation on another model is a
 * carry fork — a different session, in a different tab.
 */
export interface RunningModel {
  /** The provider profile name (the header's `model` field). */
  profile: string
  /** The resolved model id. */
  model: string
}

export function runningModel(snapshot: SessionSnapshot): RunningModel | null {
  const header = snapshot.header
  if (!header) return null
  return { profile: header.model, model: header.model_identity.model }
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
  enqueueUser(text: string, imageCount?: number): string
  /**
   * Record the delivery name `session append` receipted for one optimistic
   * turn. Must be called for every `enqueueUser` that succeeded, or that turn
   * has no identity and can never be promoted.
   */
  confirmQueued(localId: string, delivery: string): void
  /** Remove one optimistic turn after its own append failed. Committed turns are never touched. */
  rejectUser(localId: string): void
  pendingCount(): number
  setError(message: string | null): void
  /**
   * Mark the one call the kernel is holding open for a verdict, or null when
   * nothing is (`ToolItem.awaiting`). Setting one clears any other, so the flag
   * cannot survive a step that ended while a card was up.
   */
  setAwaitingApproval(callId: string | null): void
  /**
   * Mark a call the gate allowed on its own, without a question
   * (`ToolItem.autoAllowed`). Additive and per call: unlike `awaiting`, several
   * calls in one batch can each have been waved through, and none of them
   * un-marks another.
   */
  markAutoAllowed(callId: string): void
}

/**
 * What a tab that has no session yet shows.
 *
 * Not a placeholder for missing data: a draft tab genuinely has no header, no
 * items, no cost and no steps, because nothing has happened. So the readers
 * that only paint — the transcript, the bottom row — need no branch for it, and
 * the branches that stay are the ones that would DO something to a session.
 */
export const no_snapshot: SessionSnapshot = {
  id: "",
  header: null,
  items: [],
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, pricedSteps: 0, lastPrompt: 0 },
  steps: 0,
  lastStepStatus: null,
  lastStopped: null,
  activeTool: null,
  highlightedToolCallId: null,
  error: null,
  retry: null,
}

/**
 * Where the provisional tail begins.
 *
 * Committed items are always a prefix and provisional ones always a suffix —
 * that is exactly what `insertCommitted` maintains — so this walks back from the
 * end and touches only the handful of items belonging to the step in flight.
 * Scanning forward instead costs a pass over the whole store on every event,
 * which is what made replaying a long session quadratic.
 */
function firstProvisionalIndex(items: TranscriptItem[]): number {
  let at = items.length
  while (at > 0 && items[at - 1]!.seq === null) at--
  return at
}

export function createSessionState(id: string): SessionState {
  const [snapshot, setSnapshot] = createStore<SessionSnapshot>({
    id,
    header: null,
    items: [],
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, pricedSteps: 0, lastPrompt: 0 },
    steps: 0,
    lastStepStatus: null,
    lastStopped: null,
    activeTool: null,
    highlightedToolCallId: null,
    error: null,
    retry: null,
  })

  // Bumped at every step boundary so provisional keys of one step never collide
  // with the next step's.
  let turn = 0
  // Local optimistic ids must remain unique even when a failed append is
  // removed and retried within the same millisecond.
  let localUser = 0

  /**
   * Calls the gate waved through on its own, by id rather than by item.
   *
   * A provisional card is REPLACED by the committed one when the assistant
   * event lands (`dropInFlight`), and the gate answers somewhere either side of
   * that moment — so a flag written onto whichever item happened to exist would
   * survive or vanish depending on which of two lines arrived first. The set
   * outlives both, and every item built for the call reads it.
   */
  const auto_allowed = new Set<string>()

  const edit = (fn: (draft: SessionSnapshot) => void) => setSnapshot(produce(fn))

  function insertCommitted(draft: SessionSnapshot, made: TranscriptItem[]) {
    if (made.length === 0) return
    draft.items.splice(firstProvisionalIndex(draft.items), 0, ...made)
  }

  /**
   * Discard the provisional items of the step in flight. Queued user turns are
   * kept: they are waiting for their own `user_text` event, not for this one.
   *
   * Only the provisional tail is walked — everything before it is committed and
   * can never be dropped — so a replay does not re-scan the whole transcript on
   * every assistant event.
   */
  function dropInFlight(draft: SessionSnapshot) {
    for (let i = draft.items.length - 1; i >= 0; i--) {
      const item = draft.items[i]!
      if (item.seq !== null) return
      // Queued user turns are kept: each is waiting for its OWN `user_text` out
      // of the inbox, not for this step's event.
      if (item.kind !== "user") draft.items.splice(i, 1)
    }
  }

  /**
   * Delivery names of drained `user_text` events whose optimistic item did not
   * know its own name yet: a step can drain the inbox file before the `session
   * append` process has finished printing the receipt. Held only while some
   * append is in flight (`forgetSettledOrigins`), so replaying a long session
   * remembers nothing.
   */
  const drained_origins = new Set<string>()

  function awaitingReceipt(items: readonly TranscriptItem[]): boolean {
    return items.some(
      (item) => item.kind === "user" && item.seq === null && item.queued && item.delivery == null,
    )
  }

  function forgetSettledOrigins(draft: SessionSnapshot) {
    if (!awaitingReceipt(draft.items)) drained_origins.clear()
  }

  /**
   * Drop the optimistic echoes this event committed. Identity, never text: the
   * delivery name `session append` receipted comes back as the event's
   * `origin`, so two turns reading "hello" are still two deliveries. One event
   * can carry several names — a step boundary merges consecutive user turns.
   */
  function promoteQueued(draft: SessionSnapshot, origins: string[]) {
    if (origins.length === 0) return
    const unmatched = new Set(origins)
    let awaiting = false
    for (let i = draft.items.length - 1; i >= 0; i--) {
      const item = draft.items[i]!
      if (item.kind !== "user" || item.seq !== null || !item.queued) continue
      if (item.delivery == null) {
        awaiting = true
        continue
      }
      if (unmatched.delete(item.delivery)) draft.items.splice(i, 1)
    }
    if (awaiting) for (const name of unmatched) drained_origins.add(name)
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
      presentation: null,
      spillPath: null,
      resolved: false,
      awaiting: false,
      autoAllowed: auto_allowed.has(call.id),
      taskResult: null,
    }))
  }

  function parsePresentation(raw: string | null | undefined): unknown | null {
    if (typeof raw !== "string" || raw.trim().length === 0) return null
    try {
      return JSON.parse(raw) as unknown
    } catch {
      return null
    }
  }

  // The highest seq already in `items`. A session can be fed from two mouths at
  // once — the step subprocess we own, and a `session events --follow` tail when
  // somebody else drives — and both replay the same lines. Since
  // seq is monotonic and an event is immutable, "already seen" is exactly
  // "seq <= applied", so idempotence costs one comparison.
  let applied = 0

  /**
   * Per-step usage the stream reported and whose ledger line has not landed yet.
   *
   * Both mouths report the same numbers: the stream as it happens, the ledger as
   * `assistant.usage` once the step is written. Adding both
   * would double every step, and dropping the stream's would leave the status bar
   * blank until the step ended — so the stream's count is provisional exactly the
   * way its cards are, and the ledger line replaces it. Ledger lines of a step
   * are flushed BEFORE its `step end` marker, so the pairing is in order and this
   * queue is one deep in practice.
   */
  const streamed: Usage[] = []

  function addUsage(draft: SessionSnapshot, usage: Usage, sign: 1 | -1) {
    draft.usage.input += sign * usage.input_tokens
    draft.usage.output += sign * usage.output_tokens
    draft.usage.cacheRead += sign * usage.cache_read_tokens
    draft.usage.cacheWrite += sign * usage.cache_write_tokens
  }

  /** Cached or not, the whole prefix occupies the window (see `lastPrompt`). */
  function promptSize(usage: Usage): number {
    return usage.input_tokens + usage.cache_read_tokens + usage.cache_write_tokens
  }

  function applyEvent(event: LedgerEvent) {
    edit((draft) => applyInto(draft, event))
  }

  /**
   * One event into one draft. Kept separate from `applyEvent` so replaying a
   * whole tail is a single store transaction instead of one per event — the
   * difference between opening a 5k-event session in a second and in several.
   */
  function applyInto(draft: SessionSnapshot, event: LedgerEvent) {
    if (event.seq <= applied) return
    applied = event.seq
    {
      const seq = event.seq
      switch (event.kind) {
        case "user_text": {
          const user = event as Extract<LedgerEvent, { kind: "user_text" }>
          const text = user.text
          const imageCount = user.images?.length ?? 0
          promoteQueued(draft, originsOf(user))
          insertCommitted(draft, [{ key: `e${seq}`, seq, kind: "user", text, imageCount, queued: false }])
          break
        }
        case "assistant": {
          const assistant = event as Extract<LedgerEvent, { kind: "assistant" }>
          dropInFlight(draft)
          // What this step cost, from the ledger — the fact, replacing whatever
          // the stream said about the same step. A step the provider never
          // priced carries nothing at all; then the stream's number, if there
          // was one, is all anybody knows and it stays.
          const provisional = streamed.shift()
          if (assistant.usage) {
            if (provisional) addUsage(draft, provisional, -1)
            addUsage(draft, assistant.usage, 1)
            draft.usage.pricedSteps += 1
            draft.usage.lastPrompt = promptSize(assistant.usage)
          }
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
              target.presentation = parsePresentation(result.presentation)
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
                  presentation: parsePresentation(result.presentation),
                  spillPath: result.spill_path,
                  resolved: true,
                  awaiting: false,
                  autoAllowed: false,
                  taskResult: null,
                },
              ])
            }
          }
          break
        }
        // One event kind, three cards: the kernel does not interpret `source`,
        // the screen does. Anything it does not recognise still lands as a note
        // rather than as an unknown event.
        case "note": {
          const note = event as Extract<LedgerEvent, { kind: "note" }>
          const meta = noteMeta(note)
          if (note.source === "task") {
            const report = taskReportOf(note.text)
            const task = typeof meta["task"] === "string" ? meta["task"] : (report?.task ?? "")
            const exitCode = typeof meta["exit_code"] === "number" ? meta["exit_code"] : (report?.exitCode ?? 0)
            // The card that started it stops saying "running". Matched by the FULL
            // task name, which the receipt printed and this event repeats — no
            // guessing by position, and a session with three tasks in flight
            // resolves each of them onto its own card.
            for (let i = draft.items.length - 1; i >= 0; i--) {
              const item = draft.items[i]!
              if (item.kind !== "tool") continue
              if (startedTaskOf(item.output) !== task) continue
              item.taskResult = { exitCode, duration: report?.duration ?? "" }
              break
            }
            insertCommitted(draft, [{ key: `e${seq}`, seq, kind: "task", task, exitCode, text: note.text }])
            break
          }
          if (note.source === "ext" && typeof meta["id"] === "string") {
            insertCommitted(draft, [
              {
                key: `e${seq}`,
                seq,
                kind: "capability",
                id: meta["id"],
                version: typeof meta["version"] === "string" ? meta["version"] : "",
                text: note.text,
              },
            ])
            break
          }
          insertCommitted(draft, [{ key: `e${seq}`, seq, kind: "note", source: note.source, meta, text: note.text }])
          break
        }
        default: {
          insertCommitted(draft, [
            { key: `e${seq}`, seq, kind: "unknown", eventKind: event.kind, raw: JSON.stringify(event) },
          ])
        }
      }
    }
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
            // A new model turn is the kernel telling us the previous failure —
            // a spawn error, a refused credential, a killed step — is behind
            // us. Without this the status bar stays red for the rest of the
            // session, which is not a fact about the session.
            draft.error = null
            draft.retry = null
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
              presentation: null,
              spillPath: null,
              resolved: false,
              awaiting: false,
              autoAllowed: auto_allowed.has(start.id),
              taskResult: null,
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
            const line_usage = line as unknown as Usage
            // Per-step counts, not cumulative (reminder 2), and
            // provisional until this step's assistant line lands.
            const usage: Usage = {
              input_tokens: line_usage.input_tokens,
              output_tokens: line_usage.output_tokens,
              cache_read_tokens: line_usage.cache_read_tokens,
              cache_write_tokens: line_usage.cache_write_tokens,
            }
            streamed.push(usage)
            addUsage(draft, usage, 1)
            draft.usage.lastPrompt = promptSize(usage)
            break
          }
          case "done": {
            const item = provisional<AssistantItem>(draft, `p${turn}:assistant`)
            if (item) item.streaming = false
            break
          }
          case "retry": {
            // The attempt that just streamed failed and is re-sent from scratch
            //: its cards and any usage it reported never become
            // ledger facts, so they go the way of a canceled step's. The next
            // `started` clears the notice.
            const retry = line as unknown as { attempt: number; max_retries: number; delay_ms: number; error: string }
            dropInFlight(draft)
            for (const usage of streamed.splice(0)) addUsage(draft, usage, -1)
            draft.activeTool = null
            draft.highlightedToolCallId = null
            draft.error = `model request failed (${retry.error}); retry ${retry.attempt}/${retry.max_retries} in ${Math.round(retry.delay_ms / 1000)}s`
            draft.retry = {
              error: retry.error,
              attempt: retry.attempt,
              maxRetries: retry.max_retries,
              retryAt: Date.now() + retry.delay_ms,
            }
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
            draft.highlightedToolCallId = item.callId
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
        // This step's ledger lines were flushed before this marker,
        // so anything still provisional never made it into the ledger — a turn
        // canceled in the provider phase, for instance. Drop it rather than
        // leave a card the session file does not back.
        dropInFlight(draft)
        // Every ledger line of this step is already applied, so anything still
        // queued here was never written as an assistant event (a step canceled
        // in the provider phase). Its tokens were spent and stay counted; what
        // is dropped is only the expectation of a line that will never come.
        streamed.length = 0
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
          draft.highlightedToolCallId = null
        } else if (line.event === "error") {
          draft.error = (line as { message?: string }).message ?? "step failed"
          draft.retry = null
          draft.activeTool = null
          draft.highlightedToolCallId = null
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
      if (events.length === 0) return
      edit((draft) => {
        for (const event of events) applyInto(draft, event)
      })
    },
    applyEvent,
    applyStream,
    lastSeq: () => applied,
    enqueueUser(text, imageCount = 0) {
      const localId = `q:${Date.now()}:${localUser++}`
      edit((draft) => {
        draft.items.push({ key: localId, seq: null, kind: "user", text, imageCount, queued: true, delivery: null })
      })
      return localId
    },
    confirmQueued(localId, delivery) {
      edit((draft) => {
        const at = draft.items.findIndex(
          (item) => item.key === localId && item.kind === "user" && item.seq === null && item.queued,
        )
        if (at < 0) return
        // The event beat the receipt: the committed turn is already in the
        // transcript, so this echo has nothing left to wait for.
        if (drained_origins.delete(delivery)) draft.items.splice(at, 1)
        else (draft.items[at] as UserItem).delivery = delivery
        forgetSettledOrigins(draft)
      })
    },
    rejectUser(localId) {
      edit((draft) => {
        const at = draft.items.findIndex(
          (item) => item.key === localId && item.kind === "user" && item.seq === null && item.queued,
        )
        if (at >= 0) draft.items.splice(at, 1)
        forgetSettledOrigins(draft)
      })
    },
    pendingCount() {
      return snapshot.items.filter((item) => item.kind === "user" && item.queued).length
    },
    setError(message) {
      edit((draft) => {
        draft.error = message
        draft.retry = null
      })
    },
    setAwaitingApproval(callId) {
      edit((draft) => {
        for (const item of draft.items) {
          if (item.kind !== "tool") continue
          const wants = callId !== null && item.callId === callId && !item.resolved
          if (item.awaiting !== wants) item.awaiting = wants
        }
      })
    },
    markAutoAllowed(callId) {
      auto_allowed.add(callId)
      edit((draft) => {
        for (const item of draft.items) {
          if (item.kind === "tool" && item.callId === callId) item.autoAllowed = true
        }
      })
    },
  }
}

/**
 * A best-effort readable projection of `assistant.reasoning`. The kernel keeps
 * it opaque on purpose — it is a provider-shaped array kept for
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
