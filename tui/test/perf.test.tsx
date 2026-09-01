/**
 * The performance bar: a 5k-event session must OPEN in under a
 * second, and drawing it must not fall over.
 *
 * "Open" is the whole real path a resume takes: spawn `nulya session events`,
 * parse every line, and fold them into transcript items. The fixture writes the
 * 5k events straight into the session file in wire format rather than paying for
 * 5000 model steps — the file IS the wire format, and what is
 * being measured here is the reader, not the kernel.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { appendFileSync } from "node:fs"
import { testRender } from "@opentui/solid"
import { sessionNew } from "../src/nulya/cli.ts"
import { sessionEvents } from "../src/nulya/cli.ts"
import { sessionPath } from "../src/nulya/files.ts"
import { createSessionState } from "../src/state/session.ts"
import { createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { App } from "../src/ui/App.tsx"
import { windowItems } from "../src/ui/Transcript.tsx"
import { unsafe_settings, scripted_env, tempWorkspace, type TempWorkspace } from "./support.ts"

const events_wanted = 5000

let ws: TempWorkspace
let id: string

beforeAll(async () => {
  ws = tempWorkspace()
  id = await sessionNew(ws, { profile: "scripted" })

  // One turn is four events: a user line, an assistant line with one call, its
  // results, and a plain assistant reply — the shape a real working session has.
  const lines: string[] = []
  for (let seq = 1; seq <= events_wanted; seq++) {
    const turn = Math.floor((seq - 1) / 4)
    switch ((seq - 1) % 4) {
      case 0:
        lines.push(JSON.stringify({ seq, kind: "user_text", text: `question ${turn}` }))
        break
      case 1:
        lines.push(
          JSON.stringify({
            seq,
            kind: "assistant",
            text: `Looking at step ${turn}.`,
            calls: [{ id: `c${turn}`, tool: "shell", args: JSON.stringify({ command: `zig build test # ${turn}` }) }],
          }),
        )
        break
      case 2:
        lines.push(
          JSON.stringify({
            seq,
            kind: "tool_results",
            results: [{ call_id: `c${turn}`, ok: true, output: `All ${turn} tests passed.\n[exit 0]`, spill_path: null }],
          }),
        )
        break
      default:
        lines.push(JSON.stringify({ seq, kind: "assistant", text: `Done with ${turn}.`, calls: [] }))
    }
  }
  appendFileSync(sessionPath(ws, id), lines.join("\n") + "\n")
}, 120_000)

afterAll(() => {
  ws.cleanup()
})

test("a 5k-event session opens in under a second", async () => {
  const state = createSessionState(id)
  const started = performance.now()
  const events = await sessionEvents(ws, id)
  state.applyEvents(events)
  const elapsed = performance.now() - started

  expect(events.length).toBe(events_wanted)
  expect(state.lastSeq()).toBe(events_wanted)
  console.log(`open 5k events: ${elapsed.toFixed(0)}ms (${state.snapshot.items.length} items)`)
  expect(elapsed).toBeLessThan(1000)
}, 60_000)

test("the transcript draws a 5k-event session without stalling", async () => {
  const state = createSessionState(id)
  state.applyEvents(await sessionEvents(ws, id))

  const started = performance.now()
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={createStyle(unsafe_settings, {})} driver={{ env: scripted_env }} />,
    { width: 100, height: 30 },
  )
  try {
    await setup.renderOnce()
    const elapsed = performance.now() - started
    console.log(`first frame with 5k events: ${elapsed.toFixed(0)}ms`)
    // The scrollbox culls offscreen children, and the transcript only mounts a
    // window of the tail, so this must stay far away from "the terminal hangs".
    expect(elapsed).toBeLessThan(1000)

    // The newest turn is on screen; the rest is windowed out of the layout but
    // still counted (the line saying so sits at the top of the scrollback).
    expect(setup.captureCharFrame()).toContain("zig build test # 1249")
    const window = default_settings.transcript.history_window
    const mounted = windowItems(state.snapshot.items, window)
    expect(mounted.length).toBe(window)
    expect(mounted[mounted.length - 1]).toBe(state.snapshot.items[state.snapshot.items.length - 1]!)

    // Streaming into a long session must stay cheap: this is the latency the
    // user actually feels while the model types.
    const steady = performance.now()
    for (let i = 0; i < 20; i++) {
      state.applyStream({ stream: "model", event: "text_delta", text: "x" })
      await setup.renderOnce()
    }
    const perFrame = (performance.now() - steady) / 20
    console.log(`streaming frame with 5k events: ${perFrame.toFixed(1)}ms`)
    expect(perFrame).toBeLessThan(33)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
