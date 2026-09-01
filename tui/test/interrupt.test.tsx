/**
 * Interrupt-and-deliver end to end,
 * against the real binary and the real key-decoding path — not a synthetic
 * `KeyEvent` object.
 *
 * Ctrl+G is deliberately distinct from the composer's Ctrl+J newline fallback:
 * a terminal without a modifier protocol sends Ctrl+J as the same byte as a
 * linefeed, so using it for interrupt made Shift+Enter send while a step ran.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { createStyle } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import { sessionEvents, sessionNew } from "../src/nulya/cli.ts"
import { unsafe_settings, scripted_loop_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style = createStyle(unsafe_settings, {})

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

test("ctrl+g mid-run appends, kills the running step, and the redelivered turn shows up transcript-side without waiting for the run to end on its own", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={style}
        driver={{ env: scripted_loop_env, maxSteps: 12 }}
        statePath={join(ws.dir, `tui-state-${id}.json`)}
        created
      />
    ),
    { width: 100, height: 30, otherModifiersMode: true },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("keep going")
    setup.mockInput.pressEnter()
    // Under way for real: a shell call has actually resolved.
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 60_000)

    await setup.mockInput.typeText("please stop now")
    await settle(setup, 2)

    setup.mockInput.pressKey("g", { ctrl: true })

    // The step this tab was driving got killed and a fresh one delivered the
    // queued turn — not a crash, and not left waiting on the loop's own
    // 12-step budget to run out first. Waited for by the DELIVERED message
    // itself rather than "nothing pending and no error", which is also true
    // in the instant before the keypress has even been handled.
    await until(
      () =>
        state.snapshot.items.some(
          (item) => item.kind === "user" && !item.queued && item.text.includes("please stop now"),
        ),
      60_000,
    )
    expect(state.snapshot.error).toBeNull()
    const events = await sessionEvents(ws, id)
    const users = events.filter((event) => event.kind === "user_text") as Array<{ kind: "user_text"; text: string }>
    expect(users.length).toBe(2)
    expect(users[0]!.text).toBe("keep going")
    expect(users[1]!.text).toContain("please stop now")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("a queued turn appears once in the transcript, with no duplicate lane above the composer", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  state.enqueueUser("already visible in the transcript")
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_loop_env }} />,
    { width: 100, height: 30 },
  )
  try {
    const frame = await settle(setup, 3)
    expect(frame).toContain("already visible in the transcript")
    expect(frame).toContain("· queued")
    expect(frame).not.toContain("⏸")
  } finally {
    setup.renderer.destroy()
  }
})
