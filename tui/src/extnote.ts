/**
 * What a PLUGIN says to the model (`api.actions.appendNote`).
 *
 * A plugin changes the world only through verbs a person already has, and the
 * one that carries a machine fact to the model is `session note` — the same
 * deposit path, the same step boundary, a different event from the turns a
 * person types.
 *
 * Which is what it is: a block of quoted plan lines is not the person retyping
 * the model's own plan at it. The ledger says a package assembled this, on the
 * person's behalf, in response to what the model just did — `source` says a
 * package, `meta.pkg` says WHICH, and the host fills that in, so a plugin
 * cannot claim to be another package here any more than it can register
 * another package's card.
 *
 * Sessions written before this was a `note` carry a `<ext-note pkg=…>` sentinel
 * inside a user turn; `parseExtNote` still folds those, so an old transcript
 * draws the same card.
 */
import type { TranscriptItem } from "./state/session.ts"

const open_prefix = '<ext-note pkg="'
const kind_attr = '" kind="'
const open_suffix = '">'
const close = "</ext-note>"

/** The source label every plugin note carries. */
export const ext_note_source = "ext"

/** The contract, in the shape `approvalnote.ts` and `midtask.ts` use: once per turn. */
export const ext_note_contract =
  "The message above was assembled by the extension it names, from what the " +
  "user did on screen — it is the user speaking through that package, not the " +
  "package speaking for itself. Read it as guidance on the work in progress."

export interface ExtNote {
  pkg: string
  /** The package's own word for what sort of note this is; the card's badge. */
  kind: string
  text: string
}

/** The note's `meta` column: which package assembled it, and what it called it. */
export function extNoteMeta(pkg: string, kind: string): string {
  return JSON.stringify({ pkg, kind })
}

/** What the model reads: the assembled body, then the contract, once. */
export function extNoteText(text: string, withContract = true): string {
  return withContract ? `${text}\n${ext_note_contract}` : text
}

/**
 * The body without the contract the model needs and the person does not — the
 * screen shows what the package assembled, exactly as it did when the contract
 * sat outside the sentinel. A note written without one is returned untouched.
 */
function withoutContract(text: string): string {
  const at = text.lastIndexOf(`\n${ext_note_contract}`)
  return at < 0 ? text : text.slice(0, at)
}

/**
 * A legacy `<ext-note>` turn, unwrapped. Parse depends on the sentinel alone,
 * never on the contract's wording: a session written by an older TUI must fold
 * in a newer one.
 */
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
  if (item.kind === "user") return parseExtNote(item.text)
  if (item.kind !== "note" || item.source !== ext_note_source) return null
  const pkg = item.meta["pkg"]
  if (typeof pkg !== "string") return null
  const kind = item.meta["kind"]
  return { pkg, kind: typeof kind === "string" ? kind : "", text: withoutContract(item.text) }
}

/** How the badge reads: the package, then what it called this note. */
export function extNoteBadge(note: ExtNote): string {
  return note.kind.length > 0 ? `${note.pkg} · ${note.kind}` : note.pkg
}
