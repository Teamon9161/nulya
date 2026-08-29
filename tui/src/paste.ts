/**
 * Long pastes, folded (tui.md §11, T14).
 *
 * A thousand-line stack trace pasted into a three-row input box hides
 * everything else on screen and makes the draft impossible to edit. tcode's
 * answer is an attachment with an inline placeholder, and the thresholds and
 * the placeholder shape are copied from it exactly (`composer.rs`
 * `PASTE_FOLD_LINES` / `PASTE_FOLD_CHARS`, `input.rs` `[Pasted text #N]`) —
 * goals/tui-panel.md D6.
 *
 * Text only. Images are the vision track's business and are deliberately not
 * approximated here: the ledger has no image content block today, and building
 * a "cannot see images yet" placeholder now would be building something to
 * throw away (D7).
 */

/** tcode `PASTE_FOLD_LINES` / `PASTE_FOLD_CHARS`. */
export const paste_fold_lines = 15
export const paste_fold_chars = 1000

export function pasteShouldFold(chars: number, lines: number): boolean {
  return chars > paste_fold_chars || lines > paste_fold_lines
}

export interface PasteAttachment {
  /** Monotonic within a TUI process; the placeholder's number. */
  id: number
  text: string
  chars: number
  lines: number
}

export function placeholderFor(id: number): string {
  return `[Pasted text #${id}]`
}

/** The line under the composer, so a fold never hides how much it folded. */
export function describeAttachment(attachment: PasteAttachment): string {
  return `${placeholderFor(attachment.id)} · ${attachment.chars} chars · ${attachment.lines} lines`
}

/**
 * Characters and lines of a paste. Characters, not UTF-16 units, so a paste of
 * emoji is not counted double; lines the way Rust's `str::lines()` counts them
 * (tcode's measurement), so a trailing newline does not add a phantom line.
 */
export function measure(text: string): { chars: number; lines: number } {
  const body = text.replace(/\n$/, "")
  return { chars: [...text].length, lines: Math.max(1, body.length === 0 ? 0 : body.split("\n").length) }
}

/**
 * Put the pasted text back where its placeholder is, on submit.
 *
 * The fold is a display of the draft, never a change to it: what reaches the
 * ledger is exactly what was pasted, in the position it was pasted into. A
 * placeholder whose attachment is gone (backspaced away) is left alone — at
 * that point it is text somebody typed, and inventing content for it would be
 * worse than showing the brackets.
 */
export function expandPastes(text: string, attachments: readonly PasteAttachment[]): string {
  let out = text
  for (const attachment of attachments) {
    out = out.split(placeholderFor(attachment.id)).join(attachment.text)
  }
  return out
}

/** Which attachments the draft still refers to. Deleting the token drops it. */
export function referenced(text: string, attachments: readonly PasteAttachment[]): PasteAttachment[] {
  return attachments.filter((attachment) => text.includes(placeholderFor(attachment.id)))
}

/**
 * The character ranges of `[Pasted text #N]` tokens, for the accent in the
 * input box (tcode `input_token_ranges`). Shape-matched rather than
 * attachment-matched, exactly as there: the token is what the eye reads.
 */
export function placeholderRanges(text: string): { start: number; end: number }[] {
  const chars = [...text]
  const prefix = [..."[Pasted text #"]
  const ranges: { start: number; end: number }[] = []
  for (let at = 0; at < chars.length; at++) {
    if (!prefix.every((c, i) => chars[at + i] === c)) continue
    let end = at + prefix.length
    while (end < chars.length && chars[end]! >= "0" && chars[end]! <= "9") end += 1
    if (end === at + prefix.length || chars[end] !== "]") continue
    ranges.push({ start: at, end: end + 1 })
    at = end
  }
  return ranges
}

/**
 * If the cursor sits right after a placeholder, the token it names — so one
 * Backspace takes the whole thing rather than chewing a `]` off the end of
 * something that then means nothing.
 */
export function placeholderBefore(
  text: string,
  cursor: number,
  attachments: readonly PasteAttachment[],
): PasteAttachment | null {
  const before = [...text].slice(0, cursor).join("")
  return attachments.find((attachment) => before.endsWith(placeholderFor(attachment.id))) ?? null
}

/**
 * Every shape a paste in this composer can become, as the word between `#`
 * and the number: `[Pasted text #N]` here, `[Image #N]` in `Composer.tsx`.
 * Images are otherwise none of this file's business (D7 above), but the
 * counter that numbers both shapes has to recognise both, or a fresh image
 * could be handed the same number a still-recalled text placeholder means.
 */
const numbered_placeholder = /\[(?:Pasted text|Image) #(\d+)\]/g

/**
 * The number the composer's next placeholder should start from, given every
 * message it can still recall (`Up` walks `history`, tui.md §11 T14/T79).
 *
 * Counting up forever from process start is correct but reads badly:
 * `[Image #7]` looks like seven pictures are attached when there may be one,
 * because deleting an attachment never gave its number back — a recalled
 * draft might still be showing that number's brackets, and reusing it for a
 * fresh paste would silently swap what the old text meant (`expandPastes`'s
 * "placeholder whose attachment is gone" case is what a naive reuse would
 * produce). So the count cannot simply restart at 1 either.
 *
 * The answer is conditional: one past the highest number that appears
 * ANYWHERE in `history`, or 1 if there is none. That is safe to hand out
 * only once nothing is currently attached — `Composer.tsx` is the one that
 * knows when that is true; this function only answers what the floor is.
 */
export function nextAttachmentAfter(history: readonly string[]): number {
  let max = 0
  for (const entry of history) {
    for (const match of entry.matchAll(numbered_placeholder)) {
      const n = Number(match[1])
      if (n > max) max = n
    }
  }
  return max + 1
}

// ── pending pastes: where async content lands (tui.md §11 T103, review ③) ──

/**
 * `Ctrl+V`, `Alt+V`, a right-click and a bracketed paste that might be an
 * image path are all fire-and-forget in `Composer.tsx`: the read that
 * decides what a paste WAS (a file's bytes, the system clipboard) takes real
 * time, and the composer's cursor does not wait for it — a person keeps
 * typing, or moves the cursor, while it is in flight. Inserting "wherever
 * the cursor is when the promise settles" is therefore inserting in the
 * wrong place the moment either of those happens.
 *
 * The fix is the one every async UI needs: claim a spot with a token the
 * instant the gesture happens (synchronously, before anything is awaited),
 * and when the answer arrives, replace THAT token wherever it ended up —
 * never "the cursor", never "the first token of this shape". Editing before
 * or after the token, and more than one paste in flight at once, both fall
 * out of "find and replace this exact substring" for free, which is why the
 * seam below is as small as it is: `Composer.tsx` mints a fresh marker with
 * `pendingPlaceholder`, inserts it, and later looks it up with `tokenAt` to
 * know what selection to replace.
 */

/**
 * A fresh marker for a paste whose content is not known yet. Its own id
 * space, so it can never collide with `[Pasted text #N]` / `[Image #N]`
 * (`numbered_placeholder` above) and is never mistaken for a real attachment
 * on the rare path where it reaches a submitted message unresolved (nothing
 * here waits for a pending paste before letting Enter submit — a message
 * sent mid-paste keeps the marker as literal text, the same way an ordinary
 * typo would).
 */
export function pendingPlaceholder(id: number): string {
  return `[Pasting… #${id}]`
}

/** Where `token` sits in `text`, or -1 when it is no longer there (deleted before the paste resolved). */
export function tokenAt(text: string, token: string): number {
  return text.indexOf(token)
}
