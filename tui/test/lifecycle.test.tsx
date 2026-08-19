/**
 * When a session comes into existence, and what a TUI process leaves behind.
 *
 * Since T22 a tab starts as a DRAFT: nothing on disk until the first message.
 * That is the load-bearing fact here — composition freezes at `session new`
 * (physics #2), so a session created before the first word would have decided
 * its tools, its pins and its model on nobody's behalf. The old guard
 * (`discardIfUntouched`, which un-created an empty session on the way out) is
 * still tested, because the paths that DO create one early still exist.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { createStyle } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { readHeader, sessionExists } from "../src/nulya/files.ts"
import { sessionList, sessionNew } from "../src/nulya/cli.ts"
import { rememberSessionPins } from "../src/state/tui_state.ts"
import { auto_settings, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style = createStyle(auto_settings, {})

let ws: TempWorkspace
let lint_version: string

beforeAll(() => {
  ws = tempWorkspace()
  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
  run(["ext", "init", "--script", "lint"])
  const built = run(["ext", "build", ".nulya/extensions/lint"])
  lint_version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0] ?? ""
  run(["ext", "activate", "lint", lint_version])
})

afterAll(() => {
  ws.cleanup()
})

test("a draft creates nothing on disk; the screen says so and the store agrees", async () => {
  const before = (await sessionList(ws)).map((entry) => entry.id)
  // Tall enough for the welcome block AND the card above it: the transcript is
  // sticky-bottom, so on a short screen the card's title row scrolls away.
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted", model: "scripted-demo" }}
        style={style}
        driver={{ env: scripted_env }}
      />
    ),
    { width: 100, height: 36 },
  )
  try {
    await settle(setup, 4)
    const frame = setup.captureCharFrame()
    // The welcome screen's facts, not a composition card: nothing is frozen
    // yet, and the model is said once — under the composer (T24).
    expect(frame).toContain("tools       shell")
    expect(frame).not.toContain("frozen composition")
    expect(frame).not.toContain("model       ")
    expect(frame).toContain("scripted-demo · tools 1+0")
    expect((await sessionList(ws)).map((entry) => entry.id)).toEqual(before)
    // Look and leave: still nothing.
    setup.renderer.destroy()
    expect((await sessionList(ws)).map((entry) => entry.id)).toEqual(before)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

/**
 * Ctrl+C narrows from the nearest thing to stop to the furthest, and never
 * quits on the first press (tui.md §1.2 D6).
 *
 * The third press is not exercised here for the obvious reason — it is
 * `process.exit(0)`, and this test runs in the process it would take with it.
 * What matters is that the two before it are not that.
 */
test("Ctrl+C clears a draft first, then warns — it never quits on the first press", async () => {
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted", model: "scripted-demo" }}
        style={style}
        driver={{ env: scripted_env }}
      />
    ),
    // As `main.tsx` builds the real renderer: without this the harness's own
    // Ctrl+C handler tears the screen down before the screen sees the key.
    { width: 100, height: 24, exitOnCtrlC: false },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("half a thought nobody wants to lose")
    expect(await settle(setup, 2)).toContain("half a thought")

    setup.mockInput.pressKey("c", { ctrl: true })
    let frame = await settle(setup, 3)
    expect(frame).not.toContain("half a thought")
    expect(frame).toContain("input cleared")

    // Empty box, nothing running: now it is about the process, and it says so
    // instead of doing it.
    setup.mockInput.pressKey("c", { ctrl: true })
    frame = await settle(setup, 3)
    expect(frame).toContain("Ctrl+C again to quit")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("the first message creates exactly one session, carrying the pins as they stand at that moment", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-state-"))
  const statePath = join(dir, "tui-state.json")
  const before = (await sessionList(ws)).map((entry) => entry.id)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted" }}
        style={style}
        driver={{ env: scripted_env }}
        statePath={statePath}
      />
    ),
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 4)
    // A pin written AFTER the screen opened — what `/ext` does. The old eager
    // `session new` would have missed it by a whole session.
    rememberSessionPins(["ext:lint/lint"], statePath)

    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(async () => (await sessionList(ws)).length === before.length + 1, 60_000)

    const made = (await sessionList(ws)).map((entry) => entry.id).filter((id) => !before.includes(id))
    expect(made.length).toBe(1)
    const header = await readHeader(ws, made[0]!)
    expect(header!.composition.native_tools).toContain("ext:lint/lint")
    // And it is a real session now: the card is the frozen one.
    await until(() => setup.captureCharFrame().includes("frozen composition"), 20_000)
  } finally {
    setup.renderer.destroy()
    rmSync(dir, { recursive: true, force: true })
  }
}, 120_000)

test("a session this process created and never touched is gone when it closes", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created />,
    { width: 80, height: 24 },
  )
  await settle(setup, 3)
  expect(sessionExists(ws, id)).toBe(true)
  // Look, leave.
  setup.renderer.destroy()
  expect(sessionExists(ws, id)).toBe(false)
}, 60_000)

test("a session this process created and used stays", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created />,
    { width: 80, height: 24 },
  )
  await settle(setup, 3)
  await setup.mockInput.typeText("probe")
  setup.mockInput.pressEnter()
  await until(() => state.snapshot.lastStopped !== null)
  setup.renderer.destroy()
  expect(sessionExists(ws, id)).toBe(true)
}, 120_000)

test("a session merely opened by id is never a candidate, empty or not", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} />,
    { width: 80, height: 24 },
  )
  await settle(setup, 3)
  setup.renderer.destroy()
  expect(sessionExists(ws, id)).toBe(true)
}, 60_000)
