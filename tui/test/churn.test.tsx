/**
 * A streamed delta updates cards in place — it does not rebuild them.
 *
 * What this pins (BUGS.md #17, the fourth freeze): every `<text>` on screen
 * owns one native text buffer, and the native pool holds 65,534 LIVE buffers
 * (measured; destroy does recycle). Rebuilding every visible card on every
 * delta is therefore not just wasted work — destruction runs on nextTick, so
 * a burst of deltas applied inside one tick stacks its rebuilds, and a big
 * transcript under a fast stream walks the pool to the cap and freezes the
 * screen. The bug was one reactive read in an IIFE child; the property worth
 * pinning is the budget itself: a burst may cost new text rows, never the
 * whole transcript times the burst.
 */
import { expect, test } from "bun:test"
import { createSignal } from "solid-js"
import { testRender } from "@opentui/solid"
import { TextBuffer } from "@opentui/core"
import { Transcript } from "../src/ui/Transcript.tsx"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { unsafe_settings } from "./support.ts"
import type { TranscriptItem } from "../src/state/session.ts"

const style: Style = createStyle(unsafe_settings, {})

/** How many more live TextBuffers the native pool has room for, right now. */
function headroom(): number {
  const kept: TextBuffer[] = []
  try {
    for (let i = 0; i < 70000; i++) kept.push(TextBuffer.create("unicode"))
    return 70000
  } catch {
    return kept.length
  } finally {
    for (const buffer of kept) {
      try {
        buffer.destroy()
      } catch {}
    }
  }
}

const text = (n: number) =>
  Array.from({ length: 20 }, (_, i) => `第${i}行 一段足够长的中文正文用来占据整行宽度 ${n}`).join("\n")

/** Transient live-buffer spike of a 30-delta burst over `backlog` old cards. */
async function burstSpike(backlogCount: number): Promise<{ spike: number; leaked: number }> {
  const backlog: TranscriptItem[] = Array.from(
    { length: backlogCount },
    (_, i) => ({ kind: "assistant", key: `h${i}`, text: text(0), streaming: false }) as TranscriptItem,
  )
  const [items, setItems] = createSignal<TranscriptItem[]>([
    ...backlog,
    { kind: "assistant", key: "a1", text: text(0), streaming: true } as TranscriptItem,
  ])
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <FoldContext.Provider value={createFoldStore()}>
          <Transcript items={items()} />
        </FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width: 80, height: 20 },
  )
  try {
    await setup.renderOnce()
    const before = headroom()
    // The burst: many deltas inside ONE tick, the way a stream reader that
    // drained a pipe-full of lines applies them. Nothing scheduled on
    // nextTick has run yet when the burst ends — whatever each delta
    // recreated is still alive at the measurement.
    for (let n = 1; n <= 30; n++) {
      setItems((old) => [
        ...old.slice(0, -1),
        { kind: "assistant", key: "a1", text: text(n), streaming: true } as TranscriptItem,
      ])
    }
    const spike = before - headroom()
    await new Promise((resolve) => setTimeout(resolve, 50))
    await setup.renderOnce()
    return { spike, leaked: before - headroom() }
  } finally {
    setup.renderer.destroy()
  }
}

test("a burst of streamed deltas pays for the streaming card, not the transcript", async () => {
  const small = await burstSpike(0)
  const big = await burstSpike(20)
  // The streaming card rebuilds its own changed rows — that cost is the same
  // whether zero or twenty finished cards sit above it. The broken shape
  // rebuilt every card on every delta: `big` measured 10,080 against a native
  // pool of 65,534, and a real transcript under a real stream walked to the
  // cap and froze the screen. The margin is loose on purpose: it separates
  // "pays for the delta" from "pays for the transcript", nothing finer.
  expect(big.spike - small.spike).toBeLessThan(1000)
  // And nothing stays behind once the tick\'s destruction has run.
  expect(small.leaked).toBe(0)
  expect(big.leaked).toBe(0)
}, 30000)
