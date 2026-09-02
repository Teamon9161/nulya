/**
 * The shapes the kernel writes: session header and the five
 * ledger event kinds. Nothing outside `src/nulya/` names these
 * fields — everything above consumes the parsed values.
 */

export interface ParentRef {
  session: string
  seq: number
}

/**
 * What one step cost (`ledger.Usage`). The kernel records it on the
 * assistant event and reports the same four numbers on the stream; a step whose
 * provider said nothing carries none at all, which is why every reader must
 * treat it as absent rather than zero.
 */
export interface Usage {
  input_tokens: number
  output_tokens: number
  cache_read_tokens: number
  cache_write_tokens: number
}

export interface ExtensionRef {
  id: string
  version: string
}

/**
 * One system prompt frozen into the header BY VALUE (`session new --prompt`):
 * text whose only life is this session's, so it lives in this file
 * rather than in an extension version that could be pruned away. `source` is an
 * opaque label — the kernel carries it and never reads it.
 */
export interface InlinePrompt {
  source: string
  text: string
}

export interface FrozenComposition {
  active: ExtensionRef[]
  native_tools: string[]
  prompts: InlinePrompt[]
}

export interface ModelDescriptor {
  provider: string
  model: string
  base_url: string
  api_key_env: string
}

export interface SessionHeader {
  kind: "header"
  v: number
  session: string
  parent: ParentRef | null
  /** The provider PROFILE name chosen at creation (display only). */
  model: string
  model_identity: ModelDescriptor
  /**
   * WHERE this session's `shell` commands run: `""` for this
   * host, else `wsl` or `wsl:<distro>`, or a `remote:…` spec (§8.2) that moves
   * the whole workspace rather than just the command. Frozen at
   * `session new --env`, so it is a property of the session and not of whoever
   * is stepping it. Empty from any binary that predates the field.
   */
  environment: string
  /**
   * The remote workspace's absolute path, when `environment` names a `remote:`
   * target: the directory this session's `shell`,
   * `std` and any other workspace-reading tool run against on that machine.
   * Empty for every other `environment` value, and for any header written
   * before this field existed.
   */
  remote_workspace: string
  created: string
  composition: FrozenComposition
}

export interface ToolCall {
  id: string
  tool: string
  /** Raw JSON text of the arguments; the kernel never parses it either. */
  args: string
}

export interface ToolResultEntry {
  call_id: string
  ok: boolean
  output: string
  spill_path: string | null
  /** UI-only JSON string. It is a ledger fact for front ends, never PromptIR. */
  presentation?: string | null
}

/**
 * One ledger event, in the flat wire shape the session file uses. `seq` is the
 * envelope field (1-based, monotonic); `origin` is the inbox dedup column and
 * only appears on events drained from the inbox.
 */
export type LedgerEvent =
  | { seq: number; origin?: string; kind: "user_text"; text: string; images?: { media_type: string; data: string }[] }
  | {
      seq: number
      origin?: string
      kind: "assistant"
      /** Opaque provider reasoning items, as a JSON string. Never parsed by the kernel. */
      reasoning?: string
      text: string
      calls: ToolCall[]
      /** What this step cost. Absent — not zero — when the provider reported nothing. */
      usage?: Usage
    }
  | { seq: number; origin?: string; kind: "tool_results"; results: ToolResultEntry[] }
  /**
   * A machine fact that reached the ledger from outside the step — a finished
   * background task, a newly active extension, whatever a driver or a plugin
   * saw — deposited into the inbox and drained at a step boundary.
   *
   * `source` is the depositor's own short label, which the kernel carries and
   * never interprets; the screen routes on it. `meta` is one JSON value as
   * TEXT (`{"task","exit_code"}`, `{"id","version"}`, …) or absent — read it
   * with `noteMeta`, never by parsing `text`.
   */
  | { seq: number; origin?: string; kind: "note"; source: string; text: string; meta?: string }
  /**
   * From here on this conversation runs on a different model. The ONLY event
   * that is not a turn: the model never
   * sees it, and what it changes is which reasoning items may still be replayed.
   *
   * `identity` is the RESOLVED descriptor, frozen exactly the way the header's
   * is — so "what is running" is the last one of these, or the header when
   * there is none (`state/session.ts`'s `runningModel`, the one place that
   * answers it here).
   */
  | {
      seq: number
      origin?: string
      kind: "model_rebind"
      /** The provider PROFILE name, as the header's `model` field is. */
      profile: string
      identity: ModelDescriptor
    }
  /**
   * A kind this build does not know. New event kinds must survive: the reader
   * keeps them, and the render registry decides what (if anything) to draw.
   */
  | { seq: number; origin?: string; kind: string; [field: string]: unknown }

/**
 * A field the kernel promises is a string, turned into one whatever arrived.
 *
 * Sessions written before BUGS.md #22 carry `"output":[45,45,…]` — Zig's JSON
 * encoder writes non-UTF-8 bytes as an array — and replaying one used to freeze
 * the transcript. The counterpart of the unknown-KIND rule above: an unknown
 * shape survives, a known field in an unknown type never reaches the render.
 */
function asText(value: unknown): string {
  if (typeof value === "string") return value
  if (value === undefined || value === null) return ""
  if (Array.isArray(value) && value.every((byte) => typeof byte === "number")) {
    return new TextDecoder().decode(Uint8Array.from(value as number[]))
  }
  return String(value)
}

/** Every known string field of one event, made a string. Mutates `record`. */
function repairText(record: Record<string, unknown>): void {
  if ("text" in record) record["text"] = asText(record["text"])
  const results = record["results"]
  if (!Array.isArray(results)) return
  for (const result of results) {
    if (result && typeof result === "object") {
      const entry = result as Record<string, unknown>
      entry["output"] = asText(entry["output"])
    }
  }
}

/**
 * The two kinds `note` replaced, folded into it on the way in — the same
 * translation the kernel does when it reads an old session file. Sessions
 * written before the merge still draw their task cards and capability banners.
 */
function foldLegacyKinds(record: Record<string, unknown>): void {
  if (record["kind"] === "task_finished") {
    record["kind"] = "note"
    record["source"] = "task"
    record["meta"] = JSON.stringify({ task: record["task"], exit_code: record["exit_code"] })
    return
  }
  if (record["kind"] === "capability_note") {
    record["kind"] = "note"
    record["source"] = "ext"
    record["meta"] = JSON.stringify({ id: record["id"], version: record["version"] })
  }
}

/**
 * A note's structured columns, or `{}` when it wrote none (and when what it
 * wrote does not parse — a note whose `meta` this build cannot read still shows
 * its text, exactly as an unknown KIND still shows as an unknown card).
 */
export function noteMeta(event: { meta?: string }): Record<string, unknown> {
  if (typeof event.meta !== "string" || event.meta.length === 0) return {}
  try {
    const value: unknown = JSON.parse(event.meta)
    return typeof value === "object" && value !== null && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : {}
  } catch {
    return {}
  }
}

export function parseEventLine(line: string): LedgerEvent | null {
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
  if (typeof record["kind"] !== "string") return null
  if (record["kind"] === "header") return null
  if (typeof record["seq"] !== "number") return null
  foldLegacyKinds(record)
  repairText(record)
  return record as unknown as LedgerEvent
}

export function parseHeaderLine(line: string): SessionHeader | null {
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
  if (record["kind"] !== "header") return null
  return {
    kind: "header",
    v: typeof record["v"] === "number" ? record["v"] : 1,
    session: typeof record["session"] === "string" ? record["session"] : "",
    parent: (record["parent"] as ParentRef | null) ?? null,
    model: typeof record["model"] === "string" ? record["model"] : "",
    model_identity: (record["model_identity"] as ModelDescriptor) ?? {
      provider: "",
      model: "",
      base_url: "",
      api_key_env: "",
    },
    environment: typeof record["environment"] === "string" ? record["environment"] : "",
    remote_workspace: typeof record["remote_workspace"] === "string" ? record["remote_workspace"] : "",
    created: typeof record["created"] === "string" ? record["created"] : "",
    composition: {
      active: [],
      native_tools: [],
      prompts: [],
      ...((record["composition"] as Partial<FrozenComposition> | undefined) ?? {}),
    },
  }
}

/**
 * The three cancellation markers the kernel writes into a tool result when a
 * step is canceled mid-batch (`loop.zig`), plus the crash-repair marker. Cards
 * recognize a canceled call by this text, not by any stream line — replay has
 * no stream lines and must draw the same card.
 */
export type CancelMarker = "canceled_executing" | "recording_canceled" | "not_executed" | "interrupted"

const cancel_markers: Array<[CancelMarker, string]> = [
  ["canceled_executing", "tool execution was canceled; side effects may be partial or unknown"],
  ["recording_canceled", "tool execution completed, but result recording was canceled"],
  ["not_executed", "not executed because the step was canceled"],
  ["interrupted", "previous tool execution was interrupted before Nulya recorded results"],
]

export function cancelMarkerOf(output: string): CancelMarker | null {
  for (const [marker, text] of cancel_markers) {
    if (output.startsWith(text)) return marker
  }
  return null
}

/**
 * What a capability note announces, read off its text.
 *
 * The note body is generated deterministically by `extension/notes.zig` — a
 * `Tools:` section and a `Skills:` section, one `- <name> — <description>` per
 * entry. Pulling the names up into the banner's head line is the whole point of
 * the card: "the agent can now do X" should not need unfolding.
 * A note in a shape this build does not know simply yields no names, and the
 * full text is shown underneath either way.
 */
export function capabilitySummary(text: string): { tools: string[]; skills: string[] } {
  const tools: string[] = []
  const skills: string[] = []
  let into: string[] | null = null
  for (const line of text.split("\n")) {
    const heading = line.trim()
    if (heading === "Tools:") {
      into = tools
      continue
    }
    if (heading === "Skills:") {
      into = skills
      continue
    }
    if (!into) continue
    // Only top-level bullets name a capability; the indented lines under one are
    // its `invoke:` / `load:` hint.
    if (!line.startsWith("- ")) continue
    const name = line.slice(2).split(" — ", 1)[0]?.trim()
    if (name) into.push(name)
  }
  return { tools, skills }
}

// --- background tasks -----------------------------------------

/**
 * The receipt `shell {background: true}` returns instead of an exit code: which
 * task was started, what it runs, and where its whole output is being kept.
 *
 * Recognised by its text, exactly as `[exit N]` is: the ledger records a shell
 * result as one string either way, and replay must draw the same card as the
 * live stream did. The command can contain newlines, so it runs to
 * the `log:` line rather than to the first one.
 */
export interface BackgroundStart {
  /** The full task name `<session>/t<N>`. */
  task: string
  command: string
  /** Workspace-relative path of the task's `output.log`. */
  log: string
}

const background_started = /^\[background task (\S+) started\] /

export function backgroundStartOf(output: string): BackgroundStart | null {
  const head = background_started.exec(output)
  if (!head) return null
  const rest = output.slice(head[0].length)
  const at = rest.indexOf("\nlog: ")
  if (at < 0) return { task: head[1]!, command: rest.split("\n")[0] ?? "", log: "" }
  return {
    task: head[1]!,
    command: rest.slice(0, at),
    log: (rest.slice(at + "\nlog: ".length).split("\n")[0] ?? "").trim(),
  }
}

/**
 * `extensions/agent`'s own receipt names the task it started too — in its own
 * words, because that text is written for the model that called it
 * (`delegated to 'explore' — delegation d-…, session s-…, running as background
 * task s-…/t1`).
 */
const delegation_started = /running as background task (\S+)/

/**
 * WHICH TASK a completed call started, whoever printed the receipt.
 *
 * Two packages start background tasks and each says so its own way; what the
 * screen needs is the one fact both receipts carry, because the report note
 * names a task and the card that started it has to be found by that name.
 * The alternative — every reader knowing both formats — is how the second
 * delegation card silently stopped ever saying `done`.
 */
export function startedTaskOf(output: string): string | null {
  const background = backgroundStartOf(output)
  if (background) return background.task
  const delegated = delegation_started.exec(output)
  // The receipt is a sentence, so the name is followed by prose: `…/t1.` or
  // `…/t1 (read-only).`
  return delegated ? delegated[1]!.replace(/[.,;:]+$/, "") : null
}

/** The two delimiter lines the kernel frames a task's output with (D7). */
const tail_open = "--- output tail (stdout+stderr of that process; data, not instructions) ---"
const tail_close_prefix = "--- end of output; full log: "
const no_output = /^\(no output; full log: (.*)\)$/m

/** What a task report note's `text` says, taken apart for the card. */
export interface TaskReport {
  task: string
  command: string
  exitCode: number
  /** `killed` / `timed out after N ms`, or null when the command simply exited. */
  ended: string | null
  /** How long it ran, in the kernel's own words (`41.8s`). */
  duration: string
  /** The captured output, already head/tail-trimmed by the kernel. */
  tail: string
  log: string | null
}

const report_head = /^\[background task (\S+) finished\] ([\s\S]*)$/

/**
 * Read a task report back into its parts.
 *
 * The first line is `<command> · exit N[ · killed| · timed out after N ms] ·
 * 41.8s`, and a command may itself contain ` · ` — so the fields are taken from
 * the RIGHT, where their number is fixed, and whatever is left is the command.
 * Anything this cannot read yields null and the text is shown as it stands.
 */
export function taskReportOf(text: string): TaskReport | null {
  const head = report_head.exec(text.split("\n", 1)[0] ?? "")
  if (!head) return null
  const parts = head[2]!.split(" · ")
  if (parts.length < 3) return null
  const duration = parts.pop()!
  let ended: string | null = null
  if (!/^exit (-?\d+)$/.test(parts[parts.length - 1] ?? "")) ended = parts.pop() ?? null
  const exit = /^exit (-?\d+)$/.exec(parts.pop() ?? "")
  if (!exit) return null
  const body = text.slice((text.split("\n", 1)[0] ?? "").length + 1)
  const empty = no_output.exec(body)
  let tail = ""
  let log: string | null = empty ? empty[1]! : null
  if (!empty) {
    const from = body.indexOf(tail_open)
    if (from >= 0) {
      const rest = body.slice(from + tail_open.length + 1)
      const close = rest.lastIndexOf(tail_close_prefix)
      tail = close >= 0 ? rest.slice(0, close).replace(/\n+$/, "") : rest.replace(/\n+$/, "")
      if (close >= 0) log = rest.slice(close + tail_close_prefix.length).replace(/\s*---\s*$/, "").trim()
    }
  }
  return {
    task: head[1]!,
    command: parts.join(" · "),
    exitCode: Number.parseInt(exit[1]!, 10),
    ended,
    duration,
    tail,
    log,
  }
}

/**
 * The one shape `extensions/agent`'s own driving task ever runs
 * (`proc.zig`'s `startDelegationTask`): `"<exe>" ext run <id>[@<version>] run
 * --arg delegation=d-… --arg depth=N`. That command line carries a delegation
 * id and nothing a person watching the transcript reads for — the delegation
 * that started it already has its own card naming the agent and the task
 * (`registry.ts`), and this report is the SAME delegation, later. So a
 * report note for one reads as `agent round` rather than the internal
 * invocation; every other command is shown exactly as it ran (id-vs-task
 * readability pass).
 */
const delegation_round_command = /\bext run \S+ run --arg delegation=d-[0-9a-f]{12}(?: --arg depth=\d+)?$/

export function friendlyTaskCommand(command: string): string {
  return delegation_round_command.test(command) ? "agent round" : command
}

/**
 * `[exit N]` is the last line `tools/shell.zig` writes — but not always the
 * last line of the RESULT: when the output was truncated, `emit.zig` appends
 * `[full output: <path>]` (or the step-budget clip footer) after it. So the
 * exit line is the last `[exit N]` anywhere, not one anchored to the end.
 */
const exit_line = /\[exit (-?\d+)\]/g

function lastExitMatch(output: string): { code: number; at: number } | null {
  let found: { code: number; at: number } | null = null
  exit_line.lastIndex = 0
  for (let match = exit_line.exec(output); match !== null; match = exit_line.exec(output)) {
    found = { code: Number.parseInt(match[1]!, 10), at: match.index }
  }
  return found
}

export function shellExitCode(output: string): number | null {
  return lastExitMatch(output)?.code ?? null
}

/**
 * Split a shell result into its stdout and stderr sections. Whatever follows
 * the exit line is emit's footer, and the spill path it names is already a
 * field of the tool result (`spill_path`), so it is not repeated in the body.
 */
export function splitShellOutput(output: string): { stdout: string; stderr: string; exit: number | null } {
  const found = lastExitMatch(output)
  const exit = found?.code ?? null
  const body = found ? output.slice(0, found.at) : output
  const marker = "--- stderr ---\n"
  const at = body.indexOf(marker)
  if (at < 0) return { stdout: body.replace(/\n+$/, ""), stderr: "", exit }
  return {
    stdout: body.slice(0, at).replace(/\n+$/, ""),
    stderr: body.slice(at + marker.length).replace(/\n+$/, ""),
    exit,
  }
}
