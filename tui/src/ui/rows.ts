/**
 * What every clickable row in this front end has in common (tui.md §11, T18).
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
 *    is here / the mouse is passing through) and they get two different
 *    backgrounds and two different gutter marks, so neither can be mistaken for
 *    the other when a colour is missing.
 *
 * Mouse handling itself stays in each component's own JSX: there is no global
 * dispatcher, and a row's click calls the very function its `Enter` calls.
 */
import { createSignal, type Accessor } from "solid-js"
import type { MouseEvent } from "@opentui/core"
import type { Style } from "../render/theme.ts"

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
 */
export function onClick(action: () => void, stop = false): {
  onMouseDown: (event: MouseEvent) => void
  onMouseUp: (event: MouseEvent) => void
} {
  let from: { x: number; y: number } | null = null
  return {
    onMouseDown: (event: MouseEvent) => {
      from = { x: event.x, y: event.y }
      if (stop) event.stopPropagation()
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

/** The row background: the cursor's, the pointer's fainter one, or none. */
export function rowBackground(style: Style, tone: RowTone): string | undefined {
  if (tone.selected) return style.theme.selection
  if (tone.hovered) return style.theme.hover
  return undefined
}

/**
 * The two-column gutter every list row starts with: the cursor's mark, the
 * pointer's, or nothing. Always two columns wide, so the columns beside it line
 * up whatever is in it.
 */
export function rowGutter(style: Style, tone: RowTone): { text: string; fg: string } {
  if (tone.selected) return { text: `${style.glyphs.foldOpen} `, fg: style.theme.fg }
  if (tone.hovered) return { text: `${style.glyphs.pointer} `, fg: style.theme.faint }
  return { text: "  ", fg: style.theme.faint }
}
