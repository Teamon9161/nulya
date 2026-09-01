/**
 * What every clickable row in this front end has in common.
 *
 * Three things, and they are here so that a new list cannot invent a fourth
 * answer to any of them:
 *
 *  - WHAT A CLICK IS. Press and release in the same cell. A press that travels
 *    was a text selection (OpenTUI starts one on mouse-down over any selectable
 *    text), and folding a card or moving a cursor because somebody dragged
 *    across it is the mouse equivalent of a key that fires on the way down.
 *  - WHERE THE POINTER IS. One signal per list, set by the row it enters and
 *    cleared by the row it leaves. `onMouseOut` fires before the next row's
 *    `onMouseOver`, including between two cells of the SAME row, so clearing is
 *    conditional on still owning the slot — otherwise crossing a column
 *    boundary blinks the highlight off and on.
 *  - HOW A ROW LOOKS. Cursor and pointer are two different facts (the keyboard
 *    is here / the mouse is passing through), so they are said in two different
 *    ways and neither can be mistaken for the other: the cursor gets a band
 *    behind the row, the pointer LIFTS the row's own colours toward
 *    `theme.lift`. Both keep their own gutter mark, which is what survives a
 *    terminal with no colour at all.
 *
 *    A second band under the pointer, at nearly the cursor's own weight,
 *    would be a distinction nobody reads, and would be a slab
 *    of background drawn under text that had not been chosen — it would make a row
 *    look picked when the mouse had merely crossed it. A lift says the same
 *    thing without painting anything: the row brightens where its own colours
 *    are, so a warn-coloured cell stays warn (`theme.lift` is the token for
 *    exactly this —
 *    "brighter" is not a direction a colour has on a light background).
 *
 * Mouse handling itself stays in each component's own JSX: there is no global
 * dispatcher, and a row's click calls the very function its `Enter` calls.
 */
import { createSignal, type Accessor } from "solid-js"
import type { MouseEvent } from "@opentui/core"
import { mixHex, type Style } from "../render/theme.ts"

/** The pointer's row within one list. `-1` is "not over any of them". */
export interface Hover {
  at: Accessor<number>
  /** Props for the row box at `index`: enter sets, leave clears. */
  row(index: number): { onMouseOver: () => void; onMouseOut: () => void }
  clear(): void
}

export function createHover(): Hover {
  const [at, setAt] = createSignal(-1)
  return {
    at,
    row: (index: number) => ({
      onMouseOver: () => setAt(index),
      // Only if this row still owns the slot: moving from one cell of a row to
      // the next sends `out` for the old cell after `over` for the new one in
      // some paths, and an unconditional clear would drop a live highlight.
      onMouseOut: () => setAt((now) => (now === index ? -1 : now)),
    }),
    clear: () => setAt(-1),
  }
}

/**
 * A press-and-release-in-place handler pair, to spread onto a renderable.
 *
 * `stop` claims the event so an enclosing row does not also act on it — the
 * checkbox inside a pin row is the one place where two nested targets both want
 * the same click and mean different things.
 *
 * IT CLAIMS THE RELEASE, NOT THE PRESS. What `stop` protects against is
 * the enclosing row ACTING, and a row acts on the release — a click is press
 * and release in the same cell, and nothing above has decided anything yet on
 * the way down. Stopping the press as well used to cost nothing because the
 * only thing above a row was another row; with a second pane on screen, the
 * thing above is the pane, which focuses itself on mouse-down (`PaneHost`).
 * Clicking a checkbox in an unfocused pane would then tick the box without the
 * keyboard ever arriving — the one gesture that is unambiguously "I am working
 * here". The enclosing row still sees the press, sets its own start cell, and
 * never gets the release, so it still does not act.
 */
export function onClick(action: () => void, stop = false): {
  onMouseDown: (event: MouseEvent) => void
  onMouseUp: (event: MouseEvent) => void
} {
  let from: { x: number; y: number } | null = null
  return {
    onMouseDown: (event: MouseEvent) => {
      from = { x: event.x, y: event.y }
    },
    onMouseUp: (event: MouseEvent) => {
      const start = from
      from = null
      if (stop) event.stopPropagation()
      if (start && start.x === event.x && start.y === event.y) action()
    },
  }
}

export interface RowTone {
  selected: boolean
  hovered: boolean
}

/**
 * How far a pointed-at cell moves toward `theme.lift`.
 *
 * Enough to be unmistakable on `dim` furniture, little enough that `warn` is
 * still warn and `accent.user` is still that accent: the point of lifting a
 * colour rather than replacing it is that the row keeps saying what it said.
 */
const pointer_lift = 0.34

/**
 * A cell's colour while the pointer is on its row — `base` itself when it is
 * not. Every clickable thing in this front end goes through here, so "what
 * hover looks like" has one answer and one number.
 */
export function lifted(style: Style, on: boolean, base: string): string {
  return on ? mixHex(base, style.theme.lift, pointer_lift) : base
}

/** The same, for a row that already has a `RowTone`. */
export function rowText(style: Style, tone: RowTone, base: string): string {
  return lifted(style, tone.hovered, base)
}

/** The row background: the cursor's band, or none. The pointer lifts instead. */
export function rowBackground(style: Style, tone: RowTone): string | undefined {
  return tone.selected ? style.theme.selection : undefined
}

/**
 * The two-column gutter every list row starts with: the cursor's mark, the
 * pointer's, or nothing. Always two columns wide, so the columns beside it line
 * up whatever is in it.
 */
export function rowGutter(style: Style, tone: RowTone): { text: string; fg: string } {
  if (tone.selected) return { text: `${style.glyphs.foldOpen} `, fg: style.theme.fg }
  // Lifted like the rest of the row it marks: with no band behind it, the mark
  // and the lift are the whole of what the pointer says.
  if (tone.hovered) return { text: `${style.glyphs.pointer} `, fg: lifted(style, true, style.theme.faint) }
  return { text: "  ", fg: style.theme.faint }
}
