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
