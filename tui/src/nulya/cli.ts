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
 * `nulya session append` — the text goes through a scratch file rather than
 * argv: multi-line input and Windows quoting both stop being our problem. The
 * turn lands in the inbox and only enters the ledger at the next step boundary,
 * so the caller must treat it as queued until the matching `user_text` arrives.
 */
export async function sessionAppend(ws: Workspace, id: string, text: string): Promise<void> {
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
    kill: () => {
      try {
        proc.kill()
      } catch {
        // Already gone; nothing to stop.
      }
    },
  }
}
