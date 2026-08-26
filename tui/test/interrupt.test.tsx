/**
 * Interrupt-and-deliver end to end (agent-runner ar-t1, tui.md §4.4b/§5),
 * against the real binary and the real key-decoding path — not a synthetic
 * `KeyEvent` object.
 *
 * `ctrl+j` is ambiguous on the wire: without a terminal extension that reports
 * real modifier state, the raw byte it sends is indistinguishable from a bare
 * linefeed, and the composer already binds that byte to "insert a newline"
 * (`Composer.tsx`, the non-Kitty `Shift+Enter` fallback). So this test asks
 * `testRender` for `otherModifiersMode`, the xterm `modifyOtherKeys` wire
 * shape that DOES carry a real ctrl bit — the same shape a real terminal with
 * that mode enabled would send, and the shape under which App's own
 * `interrupt` keymap layer can tell the two apart at all.
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

test("ctrl+j mid-run appends, kills the running step, and the redelivered turn shows up transcript-side without waiting for the run to end on its own", async () => {
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

    setup.mockInput.pressKey("j", { ctrl: true })

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

/**
 * The lane's resting state, at the App level (the visible content once
 * something IS queued is `queuelane.test.tsx`'s job — a pure, deterministic
 * render off a fabricated `messages` prop; racing a live scripted loop to
 * catch that same moment on screen here would only be flaky, since the loop
 * mode drains its own inbox again within a step or two).
 */
test("the queue lane draws nothing before the first message — no resting-state row", async () => {
  const setup = await testRender(
    () => <App ws={ws} style={style} pick={{ profile: "scripted", model: "scripted-demo" }} driver={{ env: scripted_loop_env }} />,
    { width: 100, height: 30 },
  )
  try {
    await settle(setup, 3)
    // The lane's own glyph, not the word "queued": a randomly chosen welcome
    // tip legitimately contains that word (it explains this very gesture), and
    // what this test pins is that the LANE is not drawn at rest.
    expect(setup.captureCharFrame()).not.toContain("⏸")
  } finally {
    setup.renderer.destroy()
  }
})
