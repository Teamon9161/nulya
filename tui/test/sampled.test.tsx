/**
 * A streaming answer's markdown is redrawn on a clock, not on every delta
 * (BUGS.md #21, `render/cards/AssistantTurn.tsx`).
 *
 * The instability behind the flicker is upstream and legitimate: OpenTUI keeps
 * a streaming document's TRAILING block unstable, an answer that has not
 * reached its first blank line is entirely that block, and a block re-laid-out
 * in a sticky-bottom scrollbox moves the whole screen. A half-written fence
 * really is not a fence yet, so nothing about that is wrong. What was ours is
 * HOW OFTEN we asked for the work.
 *
 * So what is pinned here is the frequency, plus the two properties a sampler
 * must not break: the tail is never dropped, and prose — which was already
 * stable under append, one more character rewriting one row — is not slowed
 * down to fix a problem it never had.
 *
 * Deliberately not pinned: the interval itself (a setting), and what the screen
 * looks like at any moment inside a window.
 */
import { expect, test } from "bun:test"
import { createSignal } from "solid-js"
import { testRender } from "@opentui/solid"
import { Transcript } from "../src/ui/Transcript.tsx"
import { StyleContext, createStyle } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { unsafe_settings } from "./support.ts"
import type { Settings } from "../src/state/settings.ts"
import type { TranscriptItem } from "../src/state/session.ts"

const interval = 60

function styleWith(ms: number) {
  const settings = {
    ...unsafe_settings,
    transcript: { ...unsafe_settings.transcript, stream_interval_ms: ms },
  } as Settings
  return createStyle(settings, {})
}

/** A bullet list, so the card takes the markdown branch rather than the prose one. */
const structured = (n: number) => `Findings so far:\n\n- item ${n}`

/** Plain prose, which stays on the hard-wrapped branch at every length. */
const prose = (n: number) => `The answer is still being written, at length ${n}`

/**
 * Stream `steps` into one assistant card, sampling the screen twice: once the
 * instant the last delta lands, and once after the window has had time to close.
 */
async function stream(body: (n: number) => string, ms: number, steps: number[]) {
  const [items, setItems] = createSignal<TranscriptItem[]>([
    { kind: "assistant", key: "a1", text: body(steps[0]!), streaming: true } as TranscriptItem,
  ])
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={styleWith(ms)}>
        <FoldContext.Provider value={createFoldStore()}>
          <Transcript items={items()} />
        </FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width: 80, height: 20 },
  )
  // Drawing settles in more than one pass — the content changes, then markdown
  // re-parses, then the scrollbox decides about a scrollbar. No time passes in
  // these, so they cannot close a sampling window by accident.
  const drawn = async () => {
    for (let i = 0; i < 3; i++) await setup.renderOnce()
    return setup.captureCharFrame()
  }
  try {
    await setup.renderOnce()
    for (const n of steps.slice(1)) {
      setItems([{ kind: "assistant", key: "a1", text: body(n), streaming: true } as TranscriptItem])
    }
    const during = await drawn()

    await new Promise((done) => setTimeout(done, interval * 3))
    const after = await drawn()

    // Settling flushes whatever the clock was still holding.
    setItems([
      { kind: "assistant", key: "a1", text: body(steps.at(-1)!), streaming: false } as TranscriptItem,
    ])
    return { during, after, settled: await drawn() }
  } finally {
    setup.renderer.destroy()
  }
}

test("deltas inside one window do not each reach the screen, and the window's end shows the newest of them", async () => {
  const { during, after } = await stream(structured, interval, [1, 2, 3, 4])
  // The three deltas after the first were coalesced: none of them was drawn.
  expect(during).toContain("item 1")
  expect(during).not.toContain("item 4")
  // And what the window ends on is the LAST delta, not the one that opened it —
  // a sampler that showed the opening value would be permanently one window
  // behind, which is a worse bug than the one it fixes.
  expect(after).toContain("item 4")
  expect(after).not.toContain("item 1")
})

test("the turn settling flushes at once, so the last delta is never left inside a window", async () => {
  // An interval no test would ever wait out: without the flush on settle, the
  // answer on screen stays truncated for a minute.
  const { during, settled } = await stream(structured, 60_000, [1, 2])
  expect(during).not.toContain("item 2")
  expect(settled).toContain("item 2")
})

test("prose is not sampled — it was already stable under append and has nothing to gain from a clock", async () => {
  const { during } = await stream(prose, interval, [1, 2, 3])
  expect(during).toContain("length 3")
})

test("an interval of zero follows every delta, which is what this did before there was a clock", async () => {
  const { during } = await stream(structured, 0, [1, 2, 3])
  expect(during).toContain("item 3")
})
