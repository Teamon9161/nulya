/**
 * `ui/measure.ts`: the measured width stays true even when OpenTUI says
 * nothing.
 *
 * The event this pins the absence of: `onLayoutResize` emits `resize` only for
 * visible renderables, while scrollbox culling still lays culled children out —
 * so a body first laid out off-viewport gets its width silently and the event
 * never comes (BUGS.md #17: a whole answer wrapped at the 12-cell floor). The
 * safety net is a re-read after every painted frame; these tests drive it with
 * a box that never emits `resize` at all, which is exactly that case.
 */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { boxWidth } from "../src/ui/measure.ts"
import type { Accessor } from "solid-js"

/** A renderable-shaped box that never announces its size — the culled case. */
function silentBox(width: number) {
  return {
    width,
    on: (_event: "resize", _listener: () => void) => {},
  }
}

async function withMeasure(run: (ctx: {
  width: Accessor<number>
  attach: (box: { width: number; on(event: "resize", listener: () => void): unknown }) => void
  renderOnce: () => Promise<void>
}) => Promise<void>) {
  let width!: Accessor<number>
  let attach!: (box: { width: number; on(event: "resize", listener: () => void): unknown }) => void
  const setup = await testRender(
    () => {
      ;[width, attach] = boxWidth(40)
      return <box />
    },
    { width: 80, height: 10 },
  )
  try {
    await run({ width, attach, renderOnce: async () => void (await setup.renderOnce()) })
  } finally {
    setup.renderer.destroy()
  }
}

test("a width laid out without a resize event is still read", async () => {
  await withMeasure(async ({ width, attach, renderOnce }) => {
    const box = silentBox(0)
    attach(box)
    // Layout happens while the box is culled: the width changes, no event.
    box.width = 75
    await renderOnce()
    expect(width()).toBe(75)
    // And it keeps following — a later silent narrowing too.
    box.width = 60
    await renderOnce()
    expect(width()).toBe(60)
  })
})

test("the resize event is still the fast path", async () => {
  await withMeasure(async ({ width, attach }) => {
    let announce: (() => void) | null = null
    const box = {
      width: 0,
      on: (_event: "resize", listener: () => void) => {
        announce = listener
      },
    }
    attach(box)
    box.width = 72
    announce!()
    // No frame needed: the event corrects within the frame that laid it out.
    expect(width()).toBe(72)
  })
})
