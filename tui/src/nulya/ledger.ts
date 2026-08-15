/**
 * The shapes the kernel writes: session header (DESIGN §3.4) and the four
 * ledger event kinds (DESIGN §3.1). Nothing outside `src/nulya/` names these
 * fields — everything above consumes the parsed values.
 */

export interface ParentRef {
  session: string
  seq: number
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

/** `[exit N]` is the last line of every `shell` result (`tools/shell.zig`). */
export function shellExitCode(output: string): number | null {
  const match = /\[exit (-?\d+)\]\s*$/.exec(output)
  if (!match || match[1] === undefined) return null
  return Number.parseInt(match[1], 10)
}

/** Split a shell result into its stdout and stderr sections. */
export function splitShellOutput(output: string): { stdout: string; stderr: string; exit: number | null } {
  const exit = shellExitCode(output)
  let body = output
  const exit_at = body.lastIndexOf("[exit ")
  if (exit !== null && exit_at >= 0) body = body.slice(0, exit_at)
  const marker = "--- stderr ---\n"
  const at = body.indexOf(marker)
  if (at < 0) return { stdout: body.replace(/\n+$/, ""), stderr: "", exit }
  return {
    stdout: body.slice(0, at).replace(/\n+$/, ""),
    stderr: body.slice(at + marker.length).replace(/\n+$/, ""),
    exit,
  }
}
