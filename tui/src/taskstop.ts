/**
 * The note that says a background task was stopped BY THE USER, from the TUI
 * (tasks panel).
 *
 * The kernel already says a background task was killed: the supervisor writes
 * `· killed` into that task's `task_finished` text (`cli/task.zig`, DESIGN
 * §6.1). What it cannot say is who asked for it — `nulya task kill` looks the
 * same whether the model ran it through `shell` or a person clicked a button
 * on screen, and only the screen knows which one just happened.
 *
 * So this is the same family as an approval note (`approvalnote.ts`) and a
 * plugin note (`extnote.ts`): a fact the TUI itself is attesting, landed
 * through `session append` — never a new ledger event, because a fact this
 * shaped is prompt text, not kernel state (physics #8). It carries no free
 * text of the user's; there is nothing to type before pressing "stop", only
 * the fact of having pressed it.
 *
 * `nulya task kill` run by the model itself, through `shell`, never goes
 * through this module — only a stop initiated from the TUI's own UI (the
 * panel or `/tasks`) is attributed, because only that stop is a fact the TUI
 * actually witnessed.
 *
 * Parse depends on the sentinel alone, never on the contract's wording: a
 * session written by an older TUI must fold in a newer one.
 */
import type { TranscriptItem } from "./state/session.ts"

const open_prefix = '<task-stopped task="'
const open_suffix = '">'
const close = "</task-stopped>"

/** The contract, in the shape `approvalnote.ts` and `extnote.ts` use. */
export const task_stopped_contract =
  "The message above records that the user stopped this background task from " +
  "the TUI. Its task_finished report, if one has arrived or still arrives, is " +
  "the process's own exit; this note says who asked for it."

export function wrapTaskStoppedNote(task: string, withContract = true): string {
  // The task name is an attribute, not a line of the body, so the body reads
  // as a plain sentence and a card needs no rules to fold it back.
  const wrapped = `${open_prefix}${task}${open_suffix}\n${task} was stopped by the user\n${close}`
  return withContract ? `${wrapped}\n${task_stopped_contract}` : wrapped
}

export interface TaskStoppedNote {
  task: string
  text: string
}

export function parseTaskStoppedNote(text: string): TaskStoppedNote | null {
  if (!text.startsWith(open_prefix)) return null
  const end = text.indexOf(`${open_suffix}\n`)
  if (end < 0) return null
  const task = text.slice(open_prefix.length, end)
  const from = end + open_suffix.length + 1
  // The LAST close is the real one, so a body quoting the sentinel round-trips.
  const at = text.lastIndexOf(`\n${close}`)
  if (at < from) return null
  return { task, text: text.slice(from, at) }
}

/** Whether an item is a task-stopped note, for the card router. */
export function taskStoppedNoteOf(item: TranscriptItem): TaskStoppedNote | null {
  return item.kind === "user" ? parseTaskStoppedNote(item.text) : null
}
