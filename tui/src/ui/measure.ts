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
 * HOW THE NUMBER IS KEPT TRUE: re-read `box.width` after every painted frame,
 * on a CLEAN STACK.
 *
 * It used to be the box's own `resize` event, and that was wrong twice over.
 * First, OpenTUI drops the event: `onLayoutResize` emits only
 * `if (this._visible)`, while a scrollbox's viewport culling still lays culled
 * children out — their width updates silently and the event never comes, so a
 * card first laid out off-viewport kept the pre-layout width forever (a whole
 * answer wrapped at the 12-cell floor, BUGS.md #17). Second, and worse, the
 * event fires from INSIDE `updateFromLayout` — mid-frame, mid-layout-walk,
 * inside the render loop's try/catch. A signal write there propagates
 * synchronously into Solid, rebuilding a card's children while yoga is walking
 * the very tree they hang from, and anything that throws along the way is
 * swallowed by the loop's own error handling with the reactive graph left
 * half-updated. Both freezes in BUGS.md #17 happened while exactly this card
 * was streaming.
 *
 * So: one listener on the renderer's `frame` event, and even that only
 * SCHEDULES the reads — `setTimeout(0)`, one flush for all readers — so the
 * signal writes run outside the loop, on a stack where an error is an error
 * and a layout is not being mutated mid-walk. A frame is the one trigger that
 * cannot be missed, because a layout that changed anything is only ever seen
 * through the frame that painted it; and the correcting write itself requests
 * the next frame, so the correction always lands.
 *
 * The cost is one frame: on a resize the body draws at the previous width
 * before the new one arrives. That was already true — every table was stale at
 * every width until something forced a relayout — and now it corrects itself.
 */
import { createSignal, onCleanup, type Accessor } from "solid-js"
import { useRenderer } from "@opentui/solid"

/** The subset of a renderable this needs: its laid-out width. */
interface Sized {
  readonly width: number
}

/** The subset of the renderer: frames land, and each one is announced. */
interface Frames {
  on(event: "frame", listener: () => void): unknown
}

interface Flush {
  readers: Set<() => void>
  scheduled: boolean
}

/** One "frame" listener and one deferred flush per renderer. */
const flushes = new WeakMap<Frames, Flush>()

function onFrame(renderer: Frames, read: () => void): () => void {
  let flush = flushes.get(renderer)
  if (!flush) {
    const live: Flush = { readers: new Set(), scheduled: false }
    flush = live
    flushes.set(renderer, live)
    renderer.on("frame", () => {
      if (live.scheduled) return
      live.scheduled = true
      setTimeout(() => {
        live.scheduled = false
        for (const fn of live.readers) fn()
      }, 0)
    })
  }
  flush.readers.add(read)
  return () => flush.readers.delete(read)
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
    // the next frame's re-read corrects it.
    if (tracked) setWidth(Math.max(1, tracked.width))
  }
  onCleanup(onFrame(renderer, read))
  const attach = (box: Sized) => {
    tracked = box
    read()
  }
  return [width, attach]
}
