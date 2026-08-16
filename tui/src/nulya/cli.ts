/**
 * Every `nulya session *` call the TUI makes, and the typed parse of the
 * `session step --stream` line protocol (DESIGN §14). This is the ONLY module
 * that spawns the binary; nothing above it knows a flag name or a JSON field.
 */
import { parseEventLine, type LedgerEvent } from "./ledger.ts"
import type { Workspace } from "./bin.ts"

export type StopReason = "end_turn" | "budget" | "canceled"
export type StepStatus = "completed" | "canceled"

export interface StreamUsage {
  input_tokens: number
  output_tokens: number
  cache_read_tokens: number
  cache_write_tokens: number
}

export type StreamLine =
  | { stream: "model"; event: "started" }
  | { stream: "model"; event: "text_delta"; text: string }
  | { stream: "model"; event: "thinking_delta"; text: string }
  | { stream: "model"; event: "tool_use_start"; index: number; id: string; name: string }
  | { stream: "model"; event: "tool_use_input_delta"; index: number; fragment: string }
  | ({ stream: "model"; event: "usage" } & StreamUsage)
  | { stream: "model"; event: "done"; stop: string }
  | { stream: "tool"; event: "begin"; call_id: string; tool: string }
  | { stream: "tool"; event: "end"; call_id: string; ok: boolean }
  | { stream: "step"; event: "end"; status: StepStatus }
  | { stream: "run"; event: "done"; steps: number; stopped: StopReason }
  | { stream: "run"; event: "error"; message: string }
  /** Forward-compatibility: a stream/event pair this build does not know. */
  | { stream: string; event: string; [field: string]: unknown }

/**
 * One parsed stdout line. The split is exactly the kernel's: a `stream` field
 * means a transient observation, its absence means a ledger event in the same
 * shape `session events` prints. Never filter by `kind` — an event kind added
 * later must still reach the transcript (tui.md §11, T0 reminder 1).
 */
export type StepLine = { kind: "stream"; line: StreamLine } | { kind: "event"; event: LedgerEvent }

export function parseStepLine(line: string): StepLine | null {
  const trimmed = line.trim()
  if (trimmed.length === 0) return null
  let value: unknown
  try {
    value = JSON.parse(trimmed)
  } catch {
    return null
  }
  if (typeof value !== "object" || value === null) return null
  const record = value as Record<string, unknown>
  if (typeof record["stream"] === "string") return { kind: "stream", line: record as unknown as StreamLine }
  const event = parseEventLine(trimmed)
  return event ? { kind: "event", event } : null
}

async function* decodeLines(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffered = ""
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      buffered += decoder.decode(value, { stream: true })
      let at = buffered.indexOf("\n")
      while (at >= 0) {
        yield buffered.slice(0, at)
        buffered = buffered.slice(at + 1)
        at = buffered.indexOf("\n")
      }
    }
    buffered += decoder.decode()
    if (buffered.trim().length > 0) yield buffered
  } finally {
    reader.releaseLock()
  }
}

interface RunResult {
  code: number
  stdout: string
  stderr: string
}

async function run(ws: Workspace, args: string[], env?: Record<string, string>): Promise<RunResult> {
  const proc = Bun.spawn({
    cmd: [ws.bin, ...args],
    cwd: ws.dir,
    env: env ? { ...process.env, ...env } : process.env,
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])
  return { code, stdout, stderr }
}

function fail(what: string, result: RunResult): never {
  const detail = (result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`).split("\n")[0]
  throw new Error(`${what}: ${detail}`)
}

export interface NewSessionOptions {
  /** Provider profile name; omitted means the config's active profile. */
  model?: string
  parent?: { session: string; seq: number }
}

/** `nulya session new` — stdout is the session id. */
export async function sessionNew(ws: Workspace, options: NewSessionOptions = {}): Promise<string> {
  const args = ["session", "new"]
  if (options.model) args.push("--model", options.model)
  if (options.parent) args.push("--parent", `${options.parent.session}:${options.parent.seq}`)
  const result = await run(ws, args)
  const id = result.stdout.trim()
  if (result.code !== 0 || !id.startsWith("s-")) fail("session new failed", result)
  return id
}

/**
 * Appends in flight, per session. Two `session append` processes running at
 * once have no defined order in the inbox — the one that happens to finish
 * first is drained first — so turns typed as "first, second" could land as
 * "second, first". Serialising them here keeps the ledger's order the user's.
 */
const appends = new Map<string, Promise<void>>()

/**
 * `nulya session append` — the text goes through a scratch file rather than
 * argv: multi-line input and Windows quoting both stop being our problem. The
 * turn lands in the inbox and only enters the ledger at the next step boundary,
 * so the caller must treat it as queued until the matching `user_text` arrives.
 * Calls for the same session run one after another, in call order.
 */
export function sessionAppend(ws: Workspace, id: string, text: string): Promise<void> {
  // The id first: it has a fixed alphabet (`s-[A-Za-z0-9._-]+`), so `@` cannot
  // be part of it and the key is unambiguous whatever the directory contains.
  const key = `${id}@${ws.dir}`
  const previous = appends.get(key) ?? Promise.resolve()
  const mine = previous.then(
    () => appendNow(ws, id, text),
    () => appendNow(ws, id, text),
  )
  // The chain must never break on one failure; the caller sees its own.
  const settled = mine.then(
    () => undefined,
    () => undefined,
  )
  appends.set(key, settled)
  void settled.then(() => {
    if (appends.get(key) === settled) appends.delete(key)
  })
  return mine
}

async function appendNow(ws: Workspace, id: string, text: string): Promise<void> {
  const nonce = Math.random().toString(36).slice(2, 10)
  const rel = `.nulya/scratch/tui-${Date.now().toString(36)}-${nonce}.txt`
  await Bun.write(`${ws.dir}/${rel}`, text)
  const result = await run(ws, ["session", "append", id, "--file", rel])
  if (result.code !== 0) fail("session append failed", result)
}

/** `nulya session events` — the whole tail, already parsed, for open/resume. */
export async function sessionEvents(ws: Workspace, id: string, since = 0): Promise<LedgerEvent[]> {
  const args = ["session", "events", id]
  if (since > 0) args.push("--since", String(since))
  const result = await run(ws, args)
  if (result.code !== 0) fail("session events failed", result)
  const events: LedgerEvent[] = []
  for (const line of result.stdout.split("\n")) {
    const event = parseEventLine(line)
    if (event) events.push(event)
  }
  return events
}

/** `nulya session cancel` — the kernel consumes the marker at a step boundary. */
export async function sessionCancel(ws: Workspace, id: string): Promise<void> {
  const result = await run(ws, ["session", "cancel", id])
  if (result.code !== 0) fail("session cancel failed", result)
}

export interface FollowHandle {
  /** Ledger events as they are appended by whoever holds the writer lease. */
  events: AsyncGenerator<LedgerEvent>
  stop(): void
}

/**
 * `nulya session events <id> --since N --follow` — the observer's source.
 *
 * A session has exactly one writer (DESIGN §3.4). When that writer is somebody
 * else — a driver script, another TUI, a parent session's shell — this is how we
 * watch: a read-only tail that never opens a write handle and never blocks the
 * writer. The granularity is a ledger event, not a delta: deltas exist only on
 * the driver's own stdout (tui.md §5.6).
 */
export function sessionFollow(ws: Workspace, id: string, since = 0): FollowHandle {
  const args = ["session", "events", id, "--follow"]
  if (since > 0) args.push("--since", String(since))
  const proc = Bun.spawn({ cmd: [ws.bin, ...args], cwd: ws.dir, stdout: "pipe", stderr: "pipe" })

  async function* events(): AsyncGenerator<LedgerEvent> {
    for await (const raw of decodeLines(proc.stdout)) {
      const event = parseEventLine(raw)
      if (event) yield event
    }
  }

  return {
    events: events(),
    stop: () => {
      try {
        proc.kill()
      } catch {
        // Already gone.
      }
    },
  }
}

/**
 * `nulya ext activate|rollback` — a CLI action, not a session event. It moves
 * the store's `current` pointer (physics #5) and therefore changes nothing about
 * the session in front of us: composition froze at `session new` (DESIGN §7.5).
 */
export async function extSetCurrent(
  ws: Workspace,
  verb: "activate" | "rollback",
  id: string,
  version: string,
): Promise<string> {
  const result = await run(ws, ["ext", verb, id, version])
  const detail = (result.stdout.trim() || result.stderr.trim() || `exit ${result.code}`).split("\n")[0] ?? ""
  if (result.code !== 0) throw new Error(`ext ${verb} failed: ${detail}`)
  return detail
}

export interface StepHandle {
  /** Parsed stdout lines, in arrival order. Ends when the process exits. */
  lines: AsyncGenerator<StepLine>
  /** Exit code; 0 unless the kernel reported a `run error`. */
  exited: Promise<number>
  /** Anything the step wrote to stderr (a stream write failure, say). */
  stderr: Promise<string>
  /** Ctrl+C's second press: kill the step process (tui.md §1.2 D6). */
  kill(): void
}

export interface StepOptions {
  maxSteps?: number
  /** Extra environment for the child, e.g. NULYA_SCRIPTED_MODE in tests. */
  env?: Record<string, string>
}

/**
 * `nulya session step <id> --stream`. The TUI owns this subprocess, so its
 * stdout is the live source for the whole step (tui.md §1.2 D2); the session
 * file stays the durable truth and both agree by construction — the ledger
 * lines in this stream are the very lines the kernel appended.
 */
export function sessionStep(ws: Workspace, id: string, options: StepOptions = {}): StepHandle {
  const args = ["session", "step", id, "--stream"]
  if (options.maxSteps !== undefined) args.push("--max-steps", String(options.maxSteps))
  const proc = Bun.spawn({
    cmd: [ws.bin, ...args],
    cwd: ws.dir,
    env: options.env ? { ...process.env, ...options.env } : process.env,
    stdout: "pipe",
    stderr: "pipe",
  })
  const stderr = new Response(proc.stderr).text()

  async function* lines(): AsyncGenerator<StepLine> {
    for await (const raw of decodeLines(proc.stdout)) {
      const parsed = parseStepLine(raw)
      if (parsed) yield parsed
    }
  }

  return {
    lines: lines(),
    exited: proc.exited,
    stderr,
    kill: () => killTree(proc),
  }
}

/**
 * Kill a step and whatever it spawned. `Bun.spawn().kill()` stops only the
 * process itself; on Windows the `shell` tool's child (a `zig build test`, say)
 * would outlive it, still working in the workspace after the user asked for
 * everything to stop. `taskkill /T` takes the whole tree; POSIX shells put the
 * child in the same process group, so the plain kill already reaches it there.
 * The ledger is safe either way: the next open repairs the interrupted batch
 * (`completeInterruptedToolBatch`).
 */
function killTree(proc: ReturnType<typeof Bun.spawn>): void {
  const plain = () => {
    try {
      proc.kill()
    } catch {
      // Already gone; nothing to stop.
    }
  }
  if (process.platform === "win32" && proc.pid) {
    try {
      // Tree first, then the plain kill as a backstop once taskkill has had its
      // look: killing the parent first would orphan the children before
      // taskkill could enumerate them.
      const sweep = Bun.spawn({
        cmd: ["taskkill", "/pid", String(proc.pid), "/t", "/f"],
        stdout: "ignore",
        stderr: "ignore",
      })
      void sweep.exited.then(plain, plain)
      return
    } catch {
      // taskkill unavailable; fall through to the plain kill.
    }
  }
  plain()
}
