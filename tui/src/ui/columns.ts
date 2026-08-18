/**
 * Cell and line discipline for the overlays: nothing a list draws may wrap.
 *
 * Not for neatness — for correctness. A `<text>` paints the cells its glyphs
 * land on and leaves the ones its blanks cover as they were, so a line whose
 * wrapping changes between two frames keeps the previous frame's characters in
 * every position where the new text has a space. That is what turned the
 * `/model` notice into `openai·hasino APIvkeyr·athisssessionsisnthe offline
 * stand-in`: the title line above it showing through the notice's spaces, one
 * character per blank. A cell that overflows its column wraps, so it reflows,
 * so it garbles — and it costs a second row on top of that, which makes the
 * whole table ragged.
 *
 * The rule, then: a table cell is cut to its column (`fit`), a sentence is
 * broken by us at a joint we choose (`wrapWords`) into one `<text>` per line,
 * and column widths come from the content (`columnWidth`, `squeeze`) rather
 * than from a number typed once and outgrown by the next provider name.
 *
 * Everything here counts DISPLAY WIDTH, not characters and not bytes: `·` is
 * two bytes and one column, CJK is one character and two columns, and getting
 * that wrong is how a cell that "fits" still overflows by a column.
 */

/** Terminal columns one code point takes: 0 combining, 2 wide, 1 otherwise. */
export function charWidth(cp: number): number {
  if (cp === 0) return 0
  // Combining marks, zero-width spaces/joiners, variation selectors.
  if (
    (cp >= 0x0300 && cp <= 0x036f) ||
    (cp >= 0x1ab0 && cp <= 0x1aff) ||
    (cp >= 0x20d0 && cp <= 0x20ff) ||
    (cp >= 0xfe20 && cp <= 0xfe2f) ||
    (cp >= 0x200b && cp <= 0x200f) ||
    (cp >= 0xfe00 && cp <= 0xfe0f)
  )
    return 0
  // Symbols that are emoji by default and therefore two columns wide, even
  // though the block around them is one. `⚡` (the capability glyph) is the one
  // this project draws, and it was one column short of what the renderer gave
  // it — a cell that "fits" by our count and overflows by the terminal's.
  if (
    cp === 0x231a ||
    cp === 0x231b ||
    (cp >= 0x23e9 && cp <= 0x23ec) ||
    cp === 0x23f0 ||
    cp === 0x23f3 ||
    cp === 0x25fd ||
    cp === 0x25fe ||
    cp === 0x2614 ||
    cp === 0x2615 ||
    (cp >= 0x2648 && cp <= 0x2653) ||
    cp === 0x267f ||
    cp === 0x2693 ||
    cp === 0x26a1 ||
    cp === 0x26aa ||
    cp === 0x26ab ||
    cp === 0x26bd ||
    cp === 0x26be ||
    cp === 0x26c4 ||
    cp === 0x26c5 ||
    cp === 0x26ce ||
    cp === 0x26d4 ||
    cp === 0x26ea ||
    cp === 0x26f2 ||
    cp === 0x26f3 ||
    cp === 0x26f5 ||
    cp === 0x26fa ||
    cp === 0x26fd ||
    cp === 0x2705 ||
    cp === 0x270a ||
    cp === 0x270b ||
    cp === 0x2728 ||
    cp === 0x274c ||
    cp === 0x274e ||
    (cp >= 0x2753 && cp <= 0x2755) ||
    cp === 0x2757 ||
    (cp >= 0x2795 && cp <= 0x2797) ||
    cp === 0x27b0 ||
    cp === 0x27bf ||
    cp === 0x2b1b ||
    cp === 0x2b1c ||
    cp === 0x2b50 ||
    cp === 0x2b55
  )
    return 2
  // The East Asian Wide / Fullwidth blocks, plus the emoji planes.
  if (
    (cp >= 0x1100 && cp <= 0x115f) ||
    (cp >= 0x2e80 && cp <= 0x303e) ||
    (cp >= 0x3041 && cp <= 0x33ff) ||
    (cp >= 0x3400 && cp <= 0x4dbf) ||
    (cp >= 0x4e00 && cp <= 0x9fff) ||
    (cp >= 0xa000 && cp <= 0xa4cf) ||
    (cp >= 0xac00 && cp <= 0xd7a3) ||
    (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xfe30 && cp <= 0xfe6f) ||
    (cp >= 0xff00 && cp <= 0xff60) ||
    (cp >= 0xffe0 && cp <= 0xffe6) ||
    (cp >= 0x1f300 && cp <= 0x1f64f) ||
    (cp >= 0x1f900 && cp <= 0x1f9ff) ||
    (cp >= 0x20000 && cp <= 0x3fffd)
  )
    return 2
  return 1
}

/** How many terminal columns `text` occupies. */
export function displayWidth(text: string): number {
  let width = 0
  for (const ch of text) width += charWidth(ch.codePointAt(0) ?? 0)
  return width
}

/**
 * `text` cut to at most `width` columns, with `…` standing for what was cut.
 * Cutting before a wide character can leave one column unused — a cell one
 * short of its column is invisible, a cell one over it reflows.
 */
export function fit(text: string, width: number): string {
  if (width <= 0) return ""
  if (displayWidth(text) <= width) return text
  if (width === 1) return "…"
  const budget = width - 1
  let used = 0
  let kept = ""
  for (const ch of text) {
    const w = charWidth(ch.codePointAt(0) ?? 0)
    if (used + w > budget) break
    used += w
    kept += ch
  }
  return `${kept}…`
}

/** The joint these sentences are written with: ` · ` between whole phrases. */
const joint = " · "

/**
 * `text` broken into lines of at most `width` columns, at the ` · ` joints
 * first and at spaces only when a phrase is too long to stand on its own. The
 * separator is dropped at a break: a line never starts with a lonely `·`.
 *
 * A word longer than the whole width (a URL, a model id) is cut rather than
 * hyphenated — it is metadata, and the alternative is a wrapped line.
 */
export function wrapWords(text: string, width: number): string[] {
  const source = text.trim()
  if (source.length === 0) return []
  if (width <= 0) return []
  const lines: string[] = []
  let line = ""
  const flush = () => {
    if (line.length > 0) lines.push(line)
    line = ""
  }
  for (const phrase of source.split(joint)) {
    const piece = phrase.trim()
    if (piece.length === 0) continue
    const joined = line.length > 0 ? `${line}${joint}${piece}` : piece
    if (displayWidth(joined) <= width) {
      line = joined
      continue
    }
    flush()
    if (displayWidth(piece) <= width) {
      line = piece
      continue
    }
    // One phrase wider than the screen: fall back to spaces, then to the knife.
    for (const word of piece.split(/\s+/)) {
      const next = line.length > 0 ? `${line} ${word}` : word
      if (displayWidth(next) <= width) {
        line = next
        continue
      }
      flush()
      line = displayWidth(word) <= width ? word : fit(word, width)
    }
  }
  flush()
  return lines
}

/**
 * A column wide enough for every one of `values`, plus `gutter` blank columns
 * after it, and never wider than `cap` — the widest value is content, the cap
 * is a promise to the columns on its right. A column with nothing in it takes
 * no room at all, gutter included.
 */
export function columnWidth(values: readonly string[], gutter = 2, cap = 24): number {
  let widest = 0
  for (const value of values) widest = Math.max(widest, displayWidth(value))
  if (widest === 0) return 0
  return Math.min(cap, widest + gutter)
}

/**
 * `want` columns squeezed into `total`: if they fit they keep what they asked
 * for (a table is left-aligned, trailing space is not a problem), and if they
 * do not, the widest column gives up a cell at a time — never below `min` —
 * until they do. Widest-first because that is the column with the most to
 * spare; a fixed order would starve the same column on every screen.
 */
export function squeeze(want: readonly number[], min: readonly number[], total: number): number[] {
  const out = want.map((w, i) => Math.max(w, min[i] ?? 0))
  let over = out.reduce((sum, w) => sum + w, 0) - total
  while (over > 0) {
    let at = -1
    for (let i = 0; i < out.length; i++) {
      if (out[i]! <= (min[i] ?? 0)) continue
      if (at < 0 || out[i]! > out[at]!) at = i
    }
    if (at < 0) break
    out[at]! -= 1
    over -= 1
  }
  return out
}
