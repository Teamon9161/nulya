/**
 * What a PLUGIN says to the model (`api.actions.appendNote`, tui-plugin D5).
 *
 * A plugin changes the world only through verbs a person already has, and the
 * one that reaches the model is `session append` (tui.md §5.7's note, T17's
 * mid-task message, T15's skill echo — this is the fourth of the same family).
 * Which is exactly right: a plan review's comments, an `ask` panel's answer and
 * a person typing the same words by hand are the same kind of thing, and they
 * should land in the ledger as the same kind of turn.
 *
 * What is different is WHO wrote it, and that has to be legible from the turn
 * itself. A block of quoted plan lines arriving as a bare user turn reads like
 * the person retyping the model's own plan at it; the sentinel says a package
 * assembled it, on the person's behalf, in response to what the model just did.
 * The `pkg` attribute is the frozen package id, which the host fills in — a
 * plugin cannot claim to be another package here any more than it can register
 * another package's card (D11).
 *
 * Parse depends on the sentinel alone, never on the contract's wording: a
 * session written by an older TUI must fold in a newer one.
 */
import type { TranscriptItem } from "./state/session.ts"

const open_prefix = '<ext-note pkg="'
const kind_attr = '" kind="'
const open_suffix = '">'
const close = "</ext-note>"

/** The contract, in the shape `approvalnote.ts` and `midtask.ts` use: once per turn. */
export const ext_note_contract =
  "The message above was assembled by the extension it names, from what the " +
  "user did on screen — it is the user speaking through that package, not the " +
  "package speaking for itself. Read it as guidance on the work in progress."

export function wrapExtNote(pkg: string, kind: string, text: string, withContract = true): string {
  // Both attributes rather than lines of the body, so the body is exactly what
  // was assembled and a card needs no rules to fold it back.
  const wrapped = `${open_prefix}${pkg}${kind_attr}${kind}${open_suffix}\n${text}\n${close}`
  return withContract ? `${wrapped}\n${ext_note_contract}` : wrapped
}

export interface ExtNote {
  pkg: string
  /** The package's own word for what sort of note this is; the card's badge. */
  kind: string
  text: string
}

export function parseExtNote(text: string): ExtNote | null {
  if (!text.startsWith(open_prefix)) return null
  const kindAt = text.indexOf(kind_attr, open_prefix.length)
  if (kindAt < 0) return null
  const end = text.indexOf(`${open_suffix}\n`, kindAt)
  if (end < 0) return null
  const pkg = text.slice(open_prefix.length, kindAt)
  const kind = text.slice(kindAt + kind_attr.length, end)
  const from = end + open_suffix.length + 1
  // The LAST close is the real one, so a body quoting the sentinel round-trips.
  const at = text.lastIndexOf(`\n${close}`)
  if (at < from) return null
  return { pkg, kind, text: text.slice(from, at) }
}

/** Whether an item is a plugin note, for the card router. */
export function extNoteOf(item: TranscriptItem): ExtNote | null {
  return item.kind === "user" ? parseExtNote(item.text) : null
}

/** How the badge reads: the package, then what it called this note. */
export function extNoteBadge(note: ExtNote): string {
  return note.kind.length > 0 ? `${note.pkg} · ${note.kind}` : note.pkg
}
