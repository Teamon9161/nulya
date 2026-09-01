/**
 * The note a person attaches to an approval.
 *
 * tcode's approval dialog lets any option carry a free-text comment: "yes, but
 * use the other flag" reaches the model without making it redo the work, and
 * "no, because…" tells it why. The kernel's gate has a channel for exactly half
 * of that — `deny <note>` becomes the marker result of that call —
 * and there is deliberately no `allow <note>`: an allowed call runs, and what
 * the model then reads is the tool's own output. Growing a second payload on
 * `allow` would mean the kernel deciding where a person's words belong in a
 * transcript, which is a prompt decision (physics #8).
 *
 * So an approval note on a YES goes where every other thing a person says goes:
 * `session append`. It lands in the inbox and the kernel drains it at the next
 * step boundary — right after the tool_results of the batch it was about — so
 * the model reads the call's output and the guidance together, in that order.
 *
 * The framing is the mid-task sentinel's twin (midtask.ts), and for the same
 * reason: a bare sentence arriving after tool results reads like a fresh
 * instruction, and this one is not — it is a footnote on a call the model
 * already made. The sentinel is what a card folds back on, so a live turn and
 * its replay show the person's own words identically.
 */
import type { TranscriptItem } from "./state/session.ts"

const open_prefix = '<user-approval-note tool="'
const open_suffix = '">'
const close = "</user-approval-note>"

/** The contract, in the shape midtask.ts uses: once per run, then the tag alone. */
export const approval_note_contract =
  "The message above is what the user said while approving the tool call it " +
  "names — the call was allowed and its result is in this same batch. Treat it " +
  "as guidance on that call and on what follows from it, not as a new task and " +
  "not as a reason to start over."

export function wrapApprovalNote(tool: string, text: string, withContract = true): string {
  // The tool name is an attribute rather than a line of the body, so the body
  // is exactly what was typed and a card needs no rules to fold it back.
  const wrapped = `${open_prefix}${tool}${open_suffix}\n${text}\n${close}`
  return withContract ? `${wrapped}\n${approval_note_contract}` : wrapped
}

export interface ApprovalNote {
  tool: string
  text: string
}

/**
 * Parse depends on the sentinel alone, never on the contract's wording: a
 * session written by an older TUI must fold in a newer one.
 */
export function parseApprovalNote(text: string): ApprovalNote | null {
  if (!text.startsWith(open_prefix)) return null
  const end = text.indexOf(`${open_suffix}\n`)
  if (end < 0) return null
  const tool = text.slice(open_prefix.length, end)
  const from = end + open_suffix.length + 1
  // The LAST close is the real one, so a body quoting the sentinel round-trips.
  const at = text.lastIndexOf(`\n${close}`)
  if (at < from) return null
  return { tool, text: text.slice(from, at) }
}

/** Whether an item is an approval note, for the card router. */
export function approvalNoteOf(item: TranscriptItem): ApprovalNote | null {
  return item.kind === "user" ? parseApprovalNote(item.text) : null
}
