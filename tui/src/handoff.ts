/**
 * The model's own proposal to hand over (DESIGN §11, tui.md §5.8).
 *
 * The bundled `handoff` package contributes one tool, and that tool does exactly
 * one thing: it checks the four sections and tells the model to stop. **The CALL
 * is the proposal** — its arguments are the brief, and the kernel froze them
 * into the ledger before the tool ever ran. So there is nothing to watch on
 * disk: this front end already parses every ledger event, and a handover is one
 * of the tool cards it has been holding all along.
 *
 * It used to be a file. `.nulya/handoffs/<session>-<n>.md` made every driver
 * learn a directory convention no machine enforced, and it stopped working the
 * moment a workspace could live on another machine — the package runs there, the
 * driver does not (goals/remote-env.md §3.2). Reading the ledger costs this
 * module a JSON.parse and buys both drivers the same signal from the same
 * source.
 *
 * Forking is a separate act, and it belongs to whoever is driving:
 * `drivers/goal.*` does it without asking, this front end asks first (in `ask`
 * mode) because there is a person right there. The fork itself is `/compact`'s
 * ledger branch (`compact.ts`) — the same fork `/compact` always did, with the
 * brief taken from the call instead of asked for.
 */
import type { ToolItem, TranscriptItem } from "./state/session.ts"

/**
 * The model-facing name of the bundled package's one tool. A NAME because that
 * is all a ledger event records about a call — there is no tool id on the wire —
 * and `extensions/compact` matches on exactly the same string.
 */
export const handoff_tool = "handoff"

/** The four sections, as the model wrote them. `drop` is optional. */
export interface HandoffBrief {
  done: string
  next_task: string
  keep: string
  drop: string
}

export class HandoffRunBoundary {
  private readonly running = new Set<string>()

  /** True exactly once when a session observed running returns to idle. */
  observe(session: string, active: boolean): boolean {
    if (active) {
      this.running.add(session)
      return false
    }
    return this.running.delete(session)
  }
}

export interface HandoffProposal {
  /** The call's id — the identity this process remembers having answered. */
  callId: string
  /** Ledger seq of the assistant turn that made the call, for `brief_seq`. */
  seq: number | null
  brief: HandoffBrief
}

/**
 * Every handover this session's transcript holds, oldest first.
 *
 * Only calls the kernel ACCEPTED (`ok === true`) count: a `handoff` the tool
 * refused is an incomplete brief the model was told to redo, and one a gate
 * denied never happened at all — offering either would be offering to fork on a
 * brief somebody already said no to. Unparseable arguments are not a proposal
 * either (a reply cut by `max_tokens` records the fragment verbatim).
 */
export function handoffsIn(items: readonly TranscriptItem[]): HandoffProposal[] {
  const found: HandoffProposal[] = []
  for (const item of items) {
    if (item.kind !== "tool") continue
    const call = item as ToolItem
    if (call.tool !== handoff_tool || call.ok !== true) continue
    const brief = readBrief(call.args)
    if (!brief) continue
    found.push({ callId: call.callId, seq: call.seq, brief })
  }
  return found
}

/** The newest handover this process has not dealt with yet, or null. */
export function nextHandoff(
  items: readonly TranscriptItem[],
  seen: ReadonlySet<string>,
): HandoffProposal | null {
  const found = handoffsIn(items).filter((one) => !seen.has(one.callId))
  return found.length > 0 ? found[found.length - 1]! : null
}

/**
 * The brief's sections, or null when the arguments are not a complete brief.
 * The same three-section rule the package enforces at the moment of the call —
 * asked again here because what reaches this module is the ledger's bytes, not
 * the tool's verdict.
 */
function readBrief(args: string): HandoffBrief | null {
  let value: unknown
  try {
    value = JSON.parse(args)
  } catch {
    return null
  }
  if (typeof value !== "object" || value === null) return null
  const obj = value as Record<string, unknown>
  const brief: HandoffBrief = {
    done: section(obj["done"]),
    next_task: section(obj["next_task"]),
    keep: section(obj["keep"]),
    drop: section(obj["drop"]),
  }
  if (!brief.done && !brief.next_task && !brief.keep) return null
  return brief
}

function section(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

/**
 * The one line worth putting in a notice: what the next phase is for. "What
 * happens if I say yes" is the decision, and `next_task` is the answer to it.
 */
export function headline(brief: HandoffBrief): string {
  const source = brief.next_task || brief.done || brief.keep
  for (const raw of source.split("\n")) {
    const line = raw.replace(/^#+\s*/, "").trim()
    if (line.length > 0) return line.length > 80 ? `${line.slice(0, 77)}…` : line
  }
  return "a handover brief"
}

/**
 * The brief as lines to show while it is being decided on. A PREVIEW, labelled
 * by section — the markdown that will actually be carried over is rendered by
 * `extensions/compact`, which is the one place that renders it, so nothing here
 * has to agree with it byte for byte.
 */
export function briefPreview(brief: HandoffBrief): string[] {
  const out: string[] = []
  const sections: readonly (readonly [string, string])[] = [
    ["next", brief.next_task],
    ["done", brief.done],
    ["keep", brief.keep],
    ["drop", brief.drop],
  ]
  for (const [label, text] of sections) {
    if (text.length === 0) continue
    const lines = text.split("\n")
    out.push(`${label}: ${lines[0]}`)
    for (const rest of lines.slice(1)) out.push(`      ${rest}`)
  }
  return out
}
