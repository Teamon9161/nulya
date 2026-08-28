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
 *
 * HOW THE NUMBER IS KEPT TRUE: two triggers, one read.
 *
 * The box's own `resize` event is the fast path — it fires during the frame
 * that laid the box out, so the correction lands as early as it can. But it
 * CANNOT be the only path, because OpenTUI drops it: `onLayoutResize` emits
 * only `if (this._visible)`, while a scrollbox's viewport culling still runs
 * `updateFromLayout()` on culled children — their `_widthValue` is updated
 * silently, and when the node scrolls into view its width already matches the
 * layout, so `sizeChanged` is false and the event never comes at all. A card
 * whose first layout happened off-viewport (streaming appends do this all the
 * time) would keep the pre-layout width forever — an answer wrapped at the
 * 12-cell floor was this bug on screen (BUGS.md #17).
 *
 * So the safety net is the renderer's `frame` event: after every painted frame,
 * re-read `box.width`. The read is a property access and an equality-compared
 * signal set — nothing downstream moves unless the number actually changed —
 * and a frame is the one trigger that cannot be missed, because a layout that
 * changed anything is only ever seen through the frame that painted it. One
 * renderer-level listener walks all live readers (`Set`), not one listener per
 * card: EventEmitter warns at ten.
 *
 * The cost is one frame: on a resize the body draws at the previous width
 * before the new one arrives. That was already true — every table was stale at
 * every width until something forced a relayout — and now it corrects itself.
 */
import { createSignal, onCleanup, type Accessor } from "solid-js"
import { useRenderer } from "@opentui/solid"

/** The subset of a renderable this needs: its width, and word that it changed. */
interface Sized {
  readonly width: number
  on(event: "resize", listener: () => void): unknown
}

/** The subset of the renderer: frames land, and each one is announced. */
interface Frames {
  on(event: "frame", listener: () => void): unknown
}

/** One "frame" listener per renderer, however many bodies are measuring. */
const readers = new WeakMap<Frames, Set<() => void>>()

function onFrame(renderer: Frames, read: () => void): () => void {
  let set = readers.get(renderer)
  if (!set) {
    const live = new Set<() => void>()
    set = live
    readers.set(renderer, live)
    renderer.on("frame", () => {
      for (const fn of live) fn()
    })
  }
  set.add(read)
  return () => set.delete(read)
}

/**
 * `[width, attach]` — put `attach` on the box's `ref` and read `width` where
 * the number is needed. The fallback stands only until the ref lands: from
 * `attach` on, the box is the answer, pre-layout narrowness included (the
 * comment inside `read` says why that is deliberate).
 */
export function boxWidth(fallback: number): [Accessor<number>, (box: Sized) => void] {
  const [width, setWidth] = createSignal(fallback)
  const renderer = useRenderer()
  let tracked: Sized | null = null
  const read = () => {
    // Pre-layout the box reports `0` and this reads it as 1 — ON PURPOSE.
    // Every body then starts from the same narrowest width no matter what
    // screen it was created on, so a layout sitting on the scrollbar
    // threshold (two self-consistent fixed points, T73's residual) lands in
    // the same one however it was reached — "the same width draws the same
    // table" leans on this. The narrow first paint lasts one frame at most:
    // the resize event or the next frame's re-read corrects it.
    if (tracked) setWidth(Math.max(1, tracked.width))
  }
  onCleanup(onFrame(renderer, read))
  const attach = (box: Sized) => {
    tracked = box
    read()
    box.on("resize", read)
  }
  return [width, attach]
}
