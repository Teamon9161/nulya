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
  pendingPlaceholder,
  placeholderBefore,
  placeholderFor,
  placeholderRanges,
  referenced,
  tokenAt,
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

// ── pending pastes: settling an async paste at its own spot, not the cursor ─

/**
 * `Composer.tsx`'s `settleToken`, modelled as a pure splice — the same
 * `text.slice(0, at) + replacement + text.slice(at + token.length)` the real
 * one does after finding `at` with `tokenAt`, minus the OpenTUI selection
 * calls that make it. This is what these tests exercise: `Composer.tsx`
 * calls `tokenAt`, computes the same range, and hands it to
 * `setSelection`/`deleteSelection`/`insertText`.
 */
function settle(text: string, token: string, replacement: string): string | null {
  const at = tokenAt(text, token)
  if (at < 0) return null
  return text.slice(0, at) + replacement + text.slice(at + token.length)
}

test("a pending marker is its own id space — it cannot collide with [Pasted text #N] / [Image #N]", () => {
  expect(pendingPlaceholder(1)).toBe("[Pasting… #1]")
  expect(nextAttachmentAfter([pendingPlaceholder(7)])).toBe(1) // not counted as a numbered attachment
})

test("settling replaces the marker wherever it sits, regardless of what else changed around it", () => {
  const token = pendingPlaceholder(3)
  // Typed before AND after the marker, same as a person keeps typing while
  // the paste is still in flight.
  const text = `see ${token} in this sentence`
  expect(settle(text, token, "[Image #1]")).toBe("see [Image #1] in this sentence")
  expect(settle(text, token, "")).toBe("see  in this sentence") // a refusal: the marker just disappears
})

test("two pending pastes in flight resolve independently, in either order", () => {
  const a = pendingPlaceholder(1)
  const b = pendingPlaceholder(2)
  const text = `first ${a}, second ${b}.`
  // Settle the SECOND one first — a slower first paste finishing later must
  // not disturb a token that already resolved.
  const afterB = settle(text, b, "[Image #2]")!
  expect(afterB).toBe(`first ${a}, second [Image #2].`)
  const afterA = settle(afterB, a, "[Image #1]")!
  expect(afterA).toBe("first [Image #1], second [Image #2].")
})

test("a marker deleted before the paste resolved is simply gone — nothing is put back", () => {
  const token = pendingPlaceholder(4)
  // The person backspaced the whole token away (or selected and deleted it)
  // before the async read returned.
  const textWithoutToken = "the token used to be here but is not now"
  expect(settle(textWithoutToken, token, "[Image #9]")).toBeNull()
})

test("text typed exactly where the marker was does not confuse the splice with an empty replacement", () => {
  const token = pendingPlaceholder(5)
  const text = `notes: ${token}`
  // A refused paste (vision not accepted, or the clipboard was empty):
  // settling with "" must leave the surrounding text untouched.
  expect(settle(text, token, "")).toBe("notes: ")
})

test("placeholders are accented by their shape, wherever they sit in the line", () => {
  const text = "before [Pasted text #1] middle [Pasted text #22] after [Pasted text #] [Image #3]"
  const lit = placeholderRanges(text).map((range) => text.slice(range.start, range.end))
  // A numberless bracket is not a placeholder, and images are not this
  // contract's business (D7) — neither lights up.
  expect(lit).toEqual(["[Pasted text #1]", "[Pasted text #22]"])
  expect(placeholderRanges("nothing here")).toEqual([])
})
