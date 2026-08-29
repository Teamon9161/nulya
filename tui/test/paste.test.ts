/**
 * Folding a long paste (tui.md §11, T14).
 *
 * The threshold test is tcode's `long_or_multiline_pastes_fold_into_attachments`
 * boundary for boundary — the constants are ported, so the edges should be
 * checked the same way. The rest is what nulya does with the fold: a placeholder
 * that stands for the text, and an expansion on the way out, so what reaches the
 * ledger is exactly what was pasted.
 */
import { expect, test } from "bun:test"
import {
  describeAttachment,
  expandPastes,
  measure,
  nextAttachmentAfter,
  paste_fold_chars,
  paste_fold_lines,
  pasteShouldFold,
  placeholderBefore,
  placeholderFor,
  placeholderRanges,
  referenced,
  type PasteAttachment,
} from "../src/paste.ts"

const attachment = (id: number, text: string): PasteAttachment => ({ id, text, ...measure(text) })

test("long or multi-line pastes fold; a paste exactly at the threshold does not", () => {
  expect(paste_fold_chars).toBe(1000)
  expect(paste_fold_lines).toBe(15)
  expect(pasteShouldFold(paste_fold_chars, 1)).toBe(false)
  expect(pasteShouldFold(paste_fold_chars + 1, 1)).toBe(true)
  expect(pasteShouldFold(1, paste_fold_lines)).toBe(false)
  expect(pasteShouldFold(1, paste_fold_lines + 1)).toBe(true)

  // The measurement is characters and lines of the pasted text itself.
  expect(measure("a\nb\nc")).toEqual({ chars: 5, lines: 3 })
  expect(measure("")).toEqual({ chars: 0, lines: 1 })
  // Characters, not UTF-16 units: a paste of emoji must not fold on a
  // surrogate-pair count.
  expect(measure("🙂🙂").chars).toBe(2)
})

test("the placeholder stands for the text, and submitting puts it back", () => {
  const one = attachment(1, "line\n".repeat(40))
  const two = attachment(2, "x".repeat(2000))
  expect(placeholderFor(1)).toBe("[Pasted text #1]")
  expect(describeAttachment(one)).toBe("[Pasted text #1] · 200 chars · 40 lines")

  const draft = "look at [Pasted text #1] and then [Pasted text #2] please"
  const sent = expandPastes(draft, [one, two])
  expect(sent).toBe(`look at ${one.text} and then ${two.text} please`)
  // Idempotent on a draft that names nothing.
  expect(expandPastes("plain words", [one])).toBe("plain words")
  // A placeholder whose attachment is gone stays literal: at that point it is
  // text somebody typed, and inventing content for it would be worse.
  expect(expandPastes(draft, [two])).toContain("[Pasted text #1]")
})

test("deleting the token drops the attachment, and one Backspace takes the whole token", () => {
  const one = attachment(1, "a".repeat(1200))
  const two = attachment(2, "b".repeat(1200))
  expect(referenced("keep [Pasted text #2] only", [one, two])).toEqual([two])
  expect(referenced("nothing", [one, two])).toEqual([])

  // The cursor right after the token: that whole token is what Backspace takes.
  const draft = "see [Pasted text #1] here"
  expect(placeholderBefore(draft, 20, [one])?.id).toBe(1)
  // One character further in, or short of the end: not a whole token, so the
  // normal Backspace applies.
  expect(placeholderBefore(draft, 19, [one])).toBeNull()
  expect(placeholderBefore(draft, 25, [one])).toBeNull()
})

test("the next attachment id resumes just past the highest one history can still recall", () => {
  // No history at all: nothing to collide with, so start at 1.
  expect(nextAttachmentAfter([])).toBe(1)
  expect(nextAttachmentAfter(["plain message, no placeholders"])).toBe(1)

  // Ordinary ascending use: the highest number seen, plus one — not the COUNT
  // of placeholders, in case some were deleted along the way.
  expect(nextAttachmentAfter(["look at [Pasted text #1] and [Pasted text #3]"])).toBe(4)

  // Both shapes count, and the highest wins regardless of which shape it is —
  // a fresh image must not reuse a number a recalled text placeholder means,
  // and vice versa.
  expect(nextAttachmentAfter(["see [Image #5]", "then [Pasted text #2]"])).toBe(6)
  expect(nextAttachmentAfter(["[Pasted text #9]", "[Image #2]"])).toBe(10)

  // Spread across several messages, not just the most recent one — Up walks
  // the whole history, not only the last entry.
  expect(nextAttachmentAfter(["one [Pasted text #1]", "two [Image #4]", "three [Pasted text #2]"])).toBe(5)
})

test("placeholders are accented by their shape, wherever they sit in the line", () => {
  const text = "before [Pasted text #1] middle [Pasted text #22] after [Pasted text #] [Image #3]"
  const lit = placeholderRanges(text).map((range) => text.slice(range.start, range.end))
  // A numberless bracket is not a placeholder, and images are not this
  // contract's business (D7) — neither lights up.
  expect(lit).toEqual(["[Pasted text #1]", "[Pasted text #22]"])
  expect(placeholderRanges("nothing here")).toEqual([])
})
