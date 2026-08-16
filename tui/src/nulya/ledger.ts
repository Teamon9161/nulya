/**
 * The shapes the kernel writes: session header (DESIGN §3.4) and the four
 * ledger event kinds (DESIGN §3.1). Nothing outside `src/nulya/` names these
 * fields — everything above consumes the parsed values.
 */

export interface ParentRef {
  session: string
  seq: number
}

/**
 * What one step cost (`ledger.Usage`, DESIGN §3.1). The kernel records it on the
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

export interface PinnedExtensionRef {
  id: string
  version: string
}

export interface FrozenComposition {
  active: PinnedExtensionRef[]
  native_tools: string[]
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
}

/**
 * One ledger event, in the flat wire shape the session file uses. `seq` is the
 * envelope field (1-based, monotonic); `origin` is the inbox dedup column and
 * only appears on events drained from the inbox.
 */
export type LedgerEvent =
  | { seq: number; origin?: string; kind: "user_text"; text: string }
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
  | { seq: number; origin?: string; kind: "capability_note"; id: string; version: string; text: string }
  /**
   * A kind this build does not know. New event kinds must survive: the reader
   * keeps them, and the render registry decides what (if anything) to draw.
   */
  | { seq: number; origin?: string; kind: string; [field: string]: unknown }

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
    created: typeof record["created"] === "string" ? record["created"] : "",
    composition: (record["composition"] as FrozenComposition) ?? { active: [], native_tools: [] },
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
 * What a `capability_note` announces, read off its text.
 *
 * The note body is generated deterministically by `extension/notes.zig` — a
 * `Tools:` section and a `Skills:` section, one `- <name> — <description>` per
 * entry. Pulling the names up into the banner's head line is the whole point of
 * the card (tui.md §4.2): "the agent can now do X" should not need unfolding.
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
