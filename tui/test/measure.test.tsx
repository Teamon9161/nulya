/**
 * `ui/measure.ts`: the measured width stays true without OpenTUI saying a
 * word.
 *
 * The event this pins the absence of: `onLayoutResize` emits `resize` only for
 * visible renderables, while scrollbox culling still lays culled children out —
 * so a body first laid out off-viewport got its width silently and the event
 * never came (BUGS.md #17: a whole answer wrapped at the 12-cell floor). The
 * mechanism is a re-read after every painted frame, deferred to a clean stack;
 * these tests drive it with a box that never announces anything, which is
 * exactly that case.
 */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { boxWidth } from "../src/ui/measure.ts"
import type { Accessor } from "solid-js"

/** The deferred flush is a macrotask; give it one turn of the loop. */
const settled = () => new Promise((resolve) => setTimeout(resolve, 1))

async function withMeasure(run: (ctx: {
  width: Accessor<number>
  attach: (box: { width: number }) => void
  renderOnce: () => Promise<void>
}) => Promise<void>) {
  let width!: Accessor<number>
  let attach!: (box: { width: number }) => void
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

test("a width laid out without any event is still read", async () => {
  await withMeasure(async ({ width, attach, renderOnce }) => {
    const box = { width: 0 }
    attach(box)
    // Layout happens while the box is culled: the width changes, no event.
    box.width = 75
    await renderOnce()
    await settled()
    expect(width()).toBe(75)
    // And it keeps following — a later silent narrowing too.
    box.width = 60
    await renderOnce()
    await settled()
    expect(width()).toBe(60)
  })
})

test("the correction is deferred off the frame's own stack", async () => {
  await withMeasure(async ({ width, attach, renderOnce }) => {
    const box = { width: 0 }
    attach(box)
    box.width = 75
    // The frame that observed the change must NOT have applied it mid-loop —
    // a signal write inside the render loop rebuilds cards while yoga walks
    // the tree they hang from, and anything thrown there is swallowed with
    // the reactive graph left half-updated (BUGS.md #17).
    await renderOnce()
    expect(width()).toBe(1)
    await settled()
    expect(width()).toBe(75)
  })
})
