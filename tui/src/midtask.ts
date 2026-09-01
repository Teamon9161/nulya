/**
 * Mid-task messages.
 *
 * The kernel already delivers a turn appended while a run is in flight:
 * `session append` never takes the writer lease, the deposit lands in the
 * inbox, and the kernel drains it at its next step boundary.
 * What the model cannot know is HOW the turn arrived — a user message right
 * after tool results reads exactly like a fresh instruction at rest, and
 * models routinely treat one as a signal to drop what they were doing.
 *
 * tcode answers this with a machine-authored ledger entry (`Entry::Note`)
 * appended after the delivered messages. nulya's ledger has no such kind and
 * should not grow one for this: the interrupt contract is prompt text, and
 * prompts live above the kernel (physics #8). So the framing rides inside the
 * turn itself, the same shape a skill echo uses (skills.ts): a sentinel this
 * module both writes and parses, so a live turn and its replay fold back to
 * the user's own words identically.
 *
 * The note is tcode's, adapted only from "the message(s) above" to the one
 * message it now rides under. Its key property survives the trip: it speaks of
 * when the message was TYPED, so it stays true even when the append races the
 * end of the run and is only drained at the next run's first boundary.
 */
import type { TranscriptItem } from "./state/session.ts"

export const mid_task_open = "<user-mid-task-message>"
const mid_task_close = "</user-mid-task-message>"

/** tcode's interrupt contract (`agent/mod.rs`), singular. */
export const mid_task_note =
  "The message above was typed while you were working — the user did not " +
  "interrupt or end your turn. Read what they said and decide the right " +
  "response: if they asked a question or added a requirement, address it and " +
  "continue your original task (updating your plan if you have one); if they " +
  "asked you to stop, change direction, or said your approach is wrong, follow " +
  "their new instruction instead. Do not treat a mid-turn message as an " +
  "implicit signal to stop working."

/**
 * The note explains the sentinel, so it rides once per run (tcode appends one
 * note per delivered batch, for the same reason): the first mid-task message a
 * run receives carries the contract, later ones in the same run carry the tag
 * alone and inherit its meaning.
 */
export function wrapMidTask(text: string, withNote = true): string {
  const wrapped = `${mid_task_open}\n${text}\n${mid_task_close}`
  return withNote ? `${wrapped}\n${mid_task_note}` : wrapped
}

/** The user's own words, folded back out of the sentinel. */
export interface MidTask {
  text: string
}

/**
 * Parse depends on the sentinel alone, never on the note's wording: a session
 * written by an older TUI must fold in a newer one, so the note can be reworded
 * without stranding the turns already in ledgers.
 */
export function parseMidTask(text: string): MidTask | null {
  const opening = `${mid_task_open}\n`
  if (!text.startsWith(opening)) return null
  const close = `\n${mid_task_close}`
  const nextOpening = `\n\n${opening}`
  const messages: string[] = []
  let from = opening.length

  // One inbox drain may merge several framed messages into one user turn. The
  // text between a close and the next opening is the once-per-batch contract;
  // fold each frame independently and preserve their FIFO order for display.
  for (;;) {
    const next = text.indexOf(nextOpening, from)
    if (next < 0) {
      const at = text.lastIndexOf(close)
      if (at < from) return null
      messages.push(text.slice(from, at))
      return { text: messages.join("\n\n") }
    }
    const at = text.lastIndexOf(close, next)
    if (at < from) return null
    messages.push(text.slice(from, at))
    from = next + nextOpening.length
  }
}

/** Whether an item is a mid-task message, for the card router. */
export function midTaskOf(item: TranscriptItem): MidTask | null {
  return item.kind === "user" ? parseMidTask(item.text) : null
}
