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
import { App } from "../src/ui/App.tsx"
import { rowsBelow } from "../src/ui/Transcript.tsx"
import { createStyle } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { sessionNew } from "../src/nulya/cli.ts"
import { auto_settings, scripted_env, settle, tempWorkspace, type TempWorkspace } from "./support.ts"

const style = createStyle(auto_settings, {})

let ws: TempWorkspace
beforeAll(() => {
  ws = tempWorkspace()
})
afterAll(() => ws.cleanup())

/** A session whose transcript is far taller than any of these terminals. */
async function crowded(height: number) {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created />,
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
  test(`the composer keeps its three rows under a long transcript at ${height} rows`, async () => {
    const { setup } = await crowded(height)
    try {
      const frame = await settle(setup, 5)
      // The prompt is on screen…
      expect(frame).toContain("message nulya")
      // …with its full height, not shaved down to the prompt line.
      const rows = frame.split("\n")
      const at = rows.findIndex((row) => row.includes("message nulya"))
      expect(at).toBeGreaterThanOrEqual(0)
      expect(rows[at + 1]).toBeDefined()
      expect(rows[at + 2]).toBeDefined()
      // And the status bar below it still says something.
      expect(frame).toContain("driver")
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

test("the 'more below' marker is the one clickable thing on the status bar", async () => {
  const { setup } = await crowded(24)
  try {
    await settle(setup, 6)
    press(setup, page_up)
    press(setup, page_up)
    await untilFrame(setup, (frame) => frame.includes("more below"))

    // Click the marker itself rather than pressing Shift+End: same scrollToEnd,
    // reached the other way (tui.md §11, T18).
    const rows = setup.captureCharFrame().split("\n")
    const at = rows.findIndex((row) => row.includes("more below"))
    expect(at).toBeGreaterThanOrEqual(0)
    await setup.mockMouse.click(rows[at]!.indexOf("more below"), at)
    await untilFrame(setup, (frame) => !frame.includes("more below"))
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("rowsBelow is zero for a box that does not exist yet", () => {
  expect(rowsBelow(null)).toBe(0)
})
