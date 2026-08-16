/**
 * Compaction: the same conversation, continued in a new file.
 *
 * Nulya has no "replace the history" verb and will not grow one — a ledger only
 * appends (physics #1) and nothing may rewrite what the model has seen
 * (physics #3). So compaction is not an edit, it is a **fork**: summarise, open
 * a new session file pointing back at the old one, and carry the summary over as
 * its first turn. The old file stays on disk, whole, and `/sessions` still opens
 * it (PLAN §3.4).
 *
 * Two consequences shape everything here:
 *
 *  1. **The summary is produced INSIDE the old session.** Compaction fires
 *     exactly when the cached prefix is at its largest, so asking the old
 *     session to summarise itself costs one nearly-free cache-hit request. A
 *     fresh sub-session would re-send the entire transcript as uncached input —
 *     paying full price for the very thing we are compacting. The cost of doing
 *     it this way is that the request and its summary become two real events in
 *     the old ledger, which is honest: that file now records why it ended.
 *
 *  2. **Nothing here is a kernel concept.** `session append` + `session step` +
 *     `session new --parent` already exist; this file is a driver procedure over
 *     them (PLAN §3.6), and the kernel neither knows nor cares that a
 *     compaction happened. When it should happen is policy, what to keep is the
 *     model's judgement — neither belongs in the kernel.
 *
 * The two markers below are a convention between this front end and itself: the
 * kernel stores them as ordinary `user_text`. They exist so the transcript can
 * fold two turns that are machinery rather than conversation, and so a summary
 * carried into a new session is visibly not something the user typed.
 */
import { sessionAppend, sessionNew } from "./nulya/cli.ts"
import type { Workspace } from "./nulya/bin.ts"
import type { TranscriptItem } from "./state/session.ts"

export const compact_request_marker = "<nulya:compact-request>"
export const compact_summary_marker = "<nulya:context-summary>"

/**
 * What the old session is asked to write before it is retired. Adapted from the
 * continuation-brief shape that tcode's `/compact` uses, with one difference
 * that matters: in nulya the summary does not replace anything in place, it is
 * the FIRST thing a new session sees — so the brief has to stand entirely on its
 * own, with no earlier context behind it to lean on.
 *
 * `focus` is the rest of the `/compact` line, when the user typed one. It
 * supplements the required sections; it never replaces them, or a person asking
 * to "focus on the API design" would quietly lose the file list.
 */
export function compactPrompt(focus?: string): string {
  const trimmed = focus?.trim()
  const extra =
    trimmed && trimmed.length > 0
      ? `\nAdditional focus the user asked for (this supplements, and never replaces, the sections above):\n${trimmed}\n`
      : ""
  return `${compact_request_marker}
# Context compaction

This conversation is about to continue in a NEW session that will see nothing
but your summary. Write a concise, standalone, actionable continuation brief for
the agent picking it up — it cannot go back and read any of this.

Use these sections where they hold something:

1. **Task and success criteria** — what was asked, what "done" means, explicit constraints and preferences.
2. **Current state** — work completed; files read, created, modified or deleted; commands run and what they showed.
3. **Decisions and discoveries** — design decisions and their reasons, technical constraints, relevant APIs, errors hit, approaches already rejected and why.
4. **Next steps** — the specific remaining actions, blockers, and open questions.
5. **Continuation details** — exact paths, symbols, commands, identifiers, config values and test results needed to carry on without guessing.

Be concise but keep every fact that prevents duplicate work, a repeated mistake,
or a guess. Prefer concrete evidence over narrative. Do not reproduce tool output
or the conversation verbatim. Do not claim work that was not done. If the task is
finished, say so and give the validation you actually ran.
${extra}
Answer with the summary text and nothing else — do not call any tool.`
}

/** How a carried-over summary enters the new session. */
export function summaryTurn(summary: string): string {
  return `${compact_summary_marker}\n${summary.trim()}`
}

/** Whether an item is one of the two machinery turns, for folded rendering. */
export function compactionMarker(item: TranscriptItem): "request" | "summary" | null {
  if (item.kind !== "user") return null
  if (item.text.startsWith(compact_request_marker)) return "request"
  if (item.text.startsWith(compact_summary_marker)) return "summary"
  return null
}

/** The marker line stripped off, for display. */
export function withoutMarker(text: string): string {
  const at = text.indexOf("\n")
  return at < 0 ? "" : text.slice(at + 1).trim()
}

/**
 * The summary the compaction request produced, or null if it did not produce
 * one. Null is a legitimate outcome the caller must handle rather than paper
 * over: a cancelled step, or a model that answered with tool calls instead of
 * text, leaves the window exactly as full as it was — and compacting to nothing
 * would throw the conversation away.
 */
export function summaryFrom(items: readonly TranscriptItem[]): string | null {
  let at = -1
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i]!
    if (item.kind === "user" && item.text.startsWith(compact_request_marker)) {
      at = i
      break
    }
  }
  if (at < 0) return null
  const parts: string[] = []
  for (const item of items.slice(at + 1)) {
    if (item.kind === "assistant" && item.text.trim().length > 0) parts.push(item.text.trim())
  }
  const summary = parts.join("\n").trim()
  return summary.length > 0 ? summary : null
}

/**
 * Open the session that continues `parentId` from `seq`, carrying `summary` as
 * its first turn. The new session inherits the parent's frozen model identity
 * from the kernel (`session new --parent`, DESIGN §14) — a compaction must not
 * change who the conversation is with — while its composition is resolved fresh,
 * because a new session is exactly where promotion and newly activated versions
 * are meant to take hold.
 *
 * The summary is deposited, not stepped: it sits in the new session's inbox
 * until its first step, the same as any turn typed before a step runs.
 */
export async function openCompacted(
  ws: Workspace,
  parentId: string,
  seq: number,
  summary: string,
): Promise<string> {
  const id = await sessionNew(ws, { parent: { session: parentId, seq } })
  await sessionAppend(ws, id, summaryTurn(summary))
  return id
}
