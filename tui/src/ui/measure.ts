/**
 * How wide a box actually came out, as a signal.
 *
 * WHY THIS EXISTS: a markdown TABLE cannot be sized by the layout.
 * `TextTableRenderable` (what OpenTUI's `markdown` primitive builds for a pipe
 * table) fits its columns once, through a yoga measure function, and caches the
 * result; when the space around it later NARROWS — which is exactly what
 * happens the moment a transcript grows past its viewport and the scrollbox's
 * vertical scrollbar claims its column — the table is never re-fitted. It keeps
 * the wider layout, so it is drawn one column wider than the box it sits in
 * (measured: `MarkdownRenderable w=75` holding `TextTableRenderable w=76`), and
 * its row count is the one that belonged to the other width. Because that row
 * count is what decides whether the scrollbar is needed at all, a table sitting
 * on that threshold flips the scrollbar on and off and the two column layouts
 * alternate forever — the flicker. A percentage width does not help: `100%`,
 * `auto`, `flexGrow` and `alignSelf: stretch` all fail the same way. Only a
 * width that is a NUMBER before layout starts is stable, and when that number
 * changes the table does follow it.
 *
 * So the number has to come from somewhere, and the honest source is the box
 * itself rather than the terminal's width — a card lives inside a pane, and the
 * sidebar takes a quarter of the screen away from it (`state/sidebar.ts`).
 * Every renderable emits `resize` when its laid-out size changes, so this is
 * one listener per markdown body and no second copy of the layout to drift
 * (the same reason `App`'s "rows below" reads the scrollbox instead of
 * computing it).
 *
 * The cost is one frame: on a resize the body draws at the previous width
 * before the new one arrives. That was already true — every table was stale at
 * every width until something forced a relayout — and now it corrects itself.
 */
import { createSignal, type Accessor } from "solid-js"

/** The subset of a renderable this needs: its width, and word that it changed. */
interface Sized {
  readonly width: number
  on(event: "resize", listener: () => void): unknown
}

/**
 * `[width, attach]` — put `attach` on the box's `ref` and read `width` where
 * the number is needed. Before the first layout the fallback stands in; it is
 * never `0`, so a body that is measured late still wraps at something sane.
 */
export function boxWidth(fallback: number): [Accessor<number>, (box: Sized) => void] {
  const [width, setWidth] = createSignal(fallback)
  const attach = (box: Sized) => {
    const read = () => setWidth(Math.max(1, box.width))
    read()
    box.on("resize", read)
  }
  return [width, attach]
}
