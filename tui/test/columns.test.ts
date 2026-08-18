/**
 * `ui/columns.ts`: the arithmetic that keeps a list from wrapping.
 *
 * These are pure functions over display width, so they are tested as such —
 * the frame tests in `model.test.tsx` then check that the overlay actually
 * uses them.
 */
import { expect, test } from "bun:test"
import { charWidth, columnWidth, displayWidth, fit, squeeze, wrapWords } from "../src/ui/columns.ts"

test("displayWidth counts columns, not characters and not bytes", () => {
  // `·` is two bytes and one column — measuring it wrong is what shifts a
  // whole line by one and leaves the line under it showing through.
  expect("·".length).toBe(1)
  expect(Buffer.byteLength("·")).toBe(2)
  expect(displayWidth("a · b")).toBe(5)
  expect(displayWidth("")).toBe(0)
  // Wide, combining, and the glyphs this UI actually draws.
  expect(displayWidth("模型")).toBe(4)
  expect(displayWidth("é")).toBe(1)
  expect(displayWidth("▾ ‹ auto › ✓ …")).toBe(14)
  expect(charWidth("a".codePointAt(0)!)).toBe(1)
  expect(charWidth("中".codePointAt(0)!)).toBe(2)
  expect(charWidth(0x0301)).toBe(0)
})

test("fit cuts to the column and never one past it", () => {
  expect(fit("openai", 18)).toBe("openai")
  expect(fit("deepseek-anthropic", 18)).toBe("deepseek-anthropic")
  expect(fit("anthropic wire · api.deepseek.com", 20)).toBe("anthropic wire · ap…")
  expect(displayWidth(fit("anthropic wire · api.deepseek.com", 20))).toBe(20)
  expect(fit("abc", 1)).toBe("…")
  expect(fit("abc", 0)).toBe("")
  expect(fit("", 4)).toBe("")
  // A cut that lands inside a wide character leaves the column short rather
  // than half a glyph over: one blank column is invisible, one over reflows.
  expect(fit("模型选择", 4)).toBe("模…")
  expect(displayWidth(fit("模型选择", 4))).toBe(3)
  expect(displayWidth(fit("模型选择", 5))).toBe(5)
  for (const width of [1, 2, 3, 4, 5, 6, 7]) {
    expect(displayWidth(fit("a模b模c", width))).toBeLessThanOrEqual(width)
  }
})

test("wrapWords breaks at the ` · ` joints, and drops the separator at the break", () => {
  const notice = "openai has no API key · this session is the offline stand-in · pick a ready row, or press s on one to paste a key"
  expect(wrapWords(notice, 78)).toEqual([
    "openai has no API key · this session is the offline stand-in",
    "pick a ready row, or press s on one to paste a key",
  ])
  // Everything fits: one line, untouched.
  expect(wrapWords(notice, 200)).toEqual([notice])
  // The hint line: `· Esc close` is never left on a line of its own, because
  // the break happens at a joint that has content after it.
  const hint = "j/k move · Enter its models · s paste a key · a add a provider · r reload · Esc close"
  const lines = wrapWords(hint, 70)
  expect(lines).toEqual([
    "j/k move · Enter its models · s paste a key · a add a provider",
    "r reload · Esc close",
  ])
  for (const line of lines) expect(displayWidth(line)).toBeLessThanOrEqual(70)
  // A phrase wider than the line falls back to spaces, and a word wider than
  // the line is cut — anything else is a wrapped line.
  expect(wrapWords("a phrase with no joints at all in it", 12)).toEqual(["a phrase", "with no", "joints at", "all in it"])
  expect(wrapWords("short · https://an.example.invalid/very/long/path", 10)).toEqual(["short", "https://a…"])
  expect(wrapWords("", 40)).toEqual([])
  expect(wrapWords("   ", 40)).toEqual([])
  expect(wrapWords("anything", 0)).toEqual([])
})

test("columnWidth is content plus gutter, capped, and nothing at all when empty", () => {
  const names = ["openai", "deepseek", "deepseek-anthropic", "codex"]
  expect(columnWidth(names)).toBe(20)
  expect(columnWidth(names, 2, 12)).toBe(12)
  expect(columnWidth(names, 0)).toBe(18)
  // A column whose every value is empty (the model-id column when each label
  // IS its id) takes no room, gutter included.
  expect(columnWidth(["", ""])).toBe(0)
  expect(columnWidth([])).toBe(0)
  expect(columnWidth(["模型"], 2)).toBe(6)
})

test("squeeze: columns keep what they asked for, or the widest gives up cells first", () => {
  expect(squeeze([20, 30, 11, 26], [8, 6, 4, 8], 120)).toEqual([20, 30, 11, 26])
  // 87 wanted into 60: the wide ones come down towards each other, the narrow
  // one is left alone.
  const tight = squeeze([20, 30, 11, 26], [8, 6, 4, 8], 60)
  expect(tight.reduce((a, b) => a + b, 0)).toBe(60)
  expect(tight).toEqual([16, 16, 11, 17])
  // Past every minimum it stops rather than going negative: the row overflows
  // the screen, but no column is asked to draw in less than nothing.
  const floor = squeeze([20, 30, 11, 26], [8, 6, 4, 8], 10)
  expect(floor).toEqual([8, 6, 4, 8])
  // A column below its minimum is raised to it, not left where it was.
  expect(squeeze([2, 2], [8, 6], 100)).toEqual([8, 6])
})
