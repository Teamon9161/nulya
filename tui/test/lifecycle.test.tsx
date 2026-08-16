/**
 * What a TUI process leaves behind. A session it created and never used is
 * un-created when it goes; one it used, or one it merely opened, stays.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { createStyle } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { sessionExists } from "../src/nulya/files.ts"
import { sessionNew } from "../src/nulya/cli.ts"
import { scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style = createStyle(default_settings, {})

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

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
