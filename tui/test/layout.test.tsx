/**
 * The screen's one non-negotiable: there is always somewhere to type.
 *
 * The composer used to be an ordinary flex child, so a transcript taller than
 * the terminal won the negotiation and squeezed it — first to one row, then to
 * none. Nothing errored; the input box simply was not there any more, which
 * reads as "this thing only lets me talk once".
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { ScrollBoxRenderable, type Renderable } from "@opentui/core"
import { App } from "../src/ui/App.tsx"
import { rowsBelow } from "../src/ui/Transcript.tsx"
import { createStyle } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { sessionNew } from "../src/nulya/cli.ts"
import { unsafe_settings, scripted_env, settle, tempWorkspace, type TempWorkspace } from "./support.ts"

const style = createStyle(unsafe_settings, {})

let ws: TempWorkspace
beforeAll(() => {
  ws = tempWorkspace()
})
afterAll(() => ws.cleanup())

/** A session whose transcript is far taller than any of these terminals. */
async function crowded(height: number, appStyle = style) {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={appStyle} driver={{ env: scripted_env }} created />,
    { width: 100, height },
  )
  await settle(setup, 2)
  const long = Array.from({ length: 80 }, (_, i) => `line ${i} of an answer that goes on and on`).join("\n")
  state.applyEvents([
    { seq: 1, kind: "user_text", text: "hello" } as never,
    { seq: 2, kind: "assistant", text: long, calls: [] } as never,
  ])
  return { setup, state }
}

for (const height of [30, 24, 16, 10]) {
  test(`the composer keeps its whole box under a long transcript at ${height} rows`, async () => {
    const { setup } = await crowded(height)
    try {
      const frame = await settle(setup, 5)
      // The prompt is on screen…
      expect(frame).toContain("message nulya")
      // …inside a box that still has both of its sides: the border is the
      // affordance, and half a box would be a squeezed one.
      const rows = frame.split("\n")
      const at = rows.findIndex((row) => row.includes("message nulya"))
      expect(at).toBeGreaterThanOrEqual(0)
      expect(rows[at - 1]).toContain("╭")
      expect(rows[at + 1]).toContain("╰")
      // And the row under the box still says something. What it says depends on
      // the moment — the model and the mode at rest, the news of the moment
      // while a notice is up — so what is asserted is that it is there.
      expect(rows[at + 2]?.trim().length ?? 0).toBeGreaterThan(0)
    } finally {
      setup.renderer.destroy()
    }
  }, 120_000)
}

/**
 * PgUp/PgDn and Shift+End have no helper on the mock keyboard, so they go in as
 * the escape sequences a real terminal sends. `renderer.stdin` is where the
 * mock puts everything else too.
 */
function press(setup: { renderer: { stdin: { emit(event: string, data: Buffer): void } } }, sequence: string) {
  setup.renderer.stdin.emit("data", Buffer.from(sequence))
}

const page_up = "\x1b[5~"
const shift_end = "\x1b[1;2F"

/** `until`, but rendering as it waits — a frame nobody drew never changes. */
async function untilFrame(
  setup: { renderOnce(): Promise<unknown>; captureCharFrame(): string },
  predicate: (frame: string) => boolean,
  timeoutMs = 10_000,
) {
  const deadline = Date.now() + timeoutMs
  while (!predicate(setup.captureCharFrame())) {
    if (Date.now() > deadline) throw new Error("timed out waiting for a frame")
    await new Promise((resolve) => setTimeout(resolve, 40))
    await setup.renderOnce()
  }
}

test("scrolling back says how far back it is, and one key comes home", async () => {
  const { setup } = await crowded(24)
  try {
    await settle(setup, 6)
    // At the live end there is nothing below and nothing to say.
    expect(setup.captureCharFrame()).not.toContain("more below")

    press(setup, page_up)
    press(setup, page_up)
    await untilFrame(setup, (frame) => frame.includes("more below"))
    expect(setup.captureCharFrame()).toContain("Shift+End")
    // The keys that scrolled must not also have been typed into the composer.
    expect(setup.captureCharFrame()).toContain("message nulya")

    press(setup, shift_end)
    await untilFrame(setup, (frame) => !frame.includes("more below"))
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("a [keys] override moves transcript scrolling", async () => {
  const rebound = createStyle({ ...unsafe_settings, keys: { ...unsafe_settings.keys, scrollUp: "ctrl+b" } }, {})
  const { setup } = await crowded(24, rebound)
  try {
    await settle(setup, 6)
    expect(setup.captureCharFrame()).not.toContain("more below")

    setup.mockInput.pressKey("b", { ctrl: true })
    setup.mockInput.pressKey("b", { ctrl: true })
    await untilFrame(setup, (frame) => frame.includes("more below"))
    expect(setup.captureCharFrame()).toContain("Shift+End")
    expect(setup.captureCharFrame()).toContain("message nulya")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("the 'more below' marker is the one clickable thing on the status bar", async () => {
  const { setup } = await crowded(24)
  try {
    await settle(setup, 6)
    press(setup, page_up)
    press(setup, page_up)
    await untilFrame(setup, (frame) => frame.includes("more below"))

    // Click the marker itself rather than pressing Shift+End: same scrollToEnd,
    // reached the other way.
    const rows = setup.captureCharFrame().split("\n")
    const at = rows.findIndex((row) => row.includes("more below"))
    expect(at).toBeGreaterThanOrEqual(0)
    await setup.mockMouse.click(rows[at]!.indexOf("more below"), at)
    await untilFrame(setup, (frame) => !frame.includes("more below"))
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("the status line ends in a settings control, and clicking it opens the panel", async () => {
  // Chrome at the far end, opposite the sidebar handle - and the status line
  // is found by the tool count rather than by the glyph, so this stays honest
  // if a card ever draws a gear of its own.
  const { setup } = await crowded(24)
  try {
    await settle(setup, 5)
    const rows = setup.captureCharFrame().split("\n")
    const at = rows.findIndex((row) => row.includes("tools 1+"))
    expect(at).toBeGreaterThanOrEqual(0)
    // Not one more chip queued among this session's own facts: it is the last
    // thing on the line.
    expect(rows[at]!.trimEnd().endsWith(style.glyphs.settings)).toBe(true)

    await setup.mockMouse.click(rows[at]!.lastIndexOf(style.glyphs.settings), at)
    await untilFrame(setup, (frame) => frame.includes("settings · tui.toml"))
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/** Every ScrollBox on screen, in tree order. */
function scrollBoxes(from: Renderable): ScrollBoxRenderable[] {
  const found: ScrollBoxRenderable[] = from instanceof ScrollBoxRenderable ? [from] : []
  for (const child of from.getChildren()) found.push(...scrollBoxes(child as Renderable))
  return found
}

/**
 * The transcript's content box is never wider than the viewport showing it —
 * the invariant a horizontal scrollbar under the transcript is the symptom of,
 * asserted as the relation and never as a column count.
 *
 * Holds across terminal widths 90/100/120/177/178, with
 * `transcript.max_width` at 100 and at 200, with the vertical scrollbar
 * already up and with it appearing only when `/` shortens the viewport —
 * every one of those measures content and viewport equal. A frame snapshot
 * would stay green through a regression here, since a scrollbar the layout
 * grows is not a character any card wrote — this relation is what catches it.
 */
test("the transcript's content never outgrows the viewport, scrollbar and all", async () => {
  const { setup } = await crowded(20)
  try {
    await settle(setup, 6)
    await setup.mockInput.typeText("/")
    await settle(setup, 4)

    const boxes = scrollBoxes(setup.renderer.root)
    // One box, so this cannot quietly start measuring somebody else's.
    expect(boxes).toHaveLength(1)
    const transcript = boxes[0]!
    // It is actually scrolling vertically — otherwise there is no taken column
    // and nothing here would be under test.
    expect(transcript.scrollHeight).toBeGreaterThan(transcript.viewport.height)
    expect(transcript.scrollWidth).toBeLessThanOrEqual(transcript.viewport.width)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("rowsBelow is zero for a box that does not exist yet", () => {
  expect(rowsBelow(null)).toBe(0)
})
