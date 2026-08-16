/**
 * The driver state machine (`state/driver.ts`) against the real binary.
 *
 * These pin the ways a driver can lie about the world: spawning two steps at
 * once (and reading the kernel's refusal as "somebody else is driving"),
 * calling a kill a crash, swallowing a crash, or leaving an old error on the
 * status bar for the rest of the session.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { createAttachment } from "../src/state/attach.ts"
import { createDriver } from "../src/state/driver.ts"
import { createSessionState } from "../src/state/session.ts"
import { sessionEvents, sessionNew } from "../src/nulya/cli.ts"
import { scripted_env, scripted_loop_env, tempWorkspace, until, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

test("two sends in quick succession start ONE step and both turns land", async () => {
  const id = await sessionNew(ws, { model: "scripted" })
  const state = createSessionState(id)
  // A long poll keeps the lease probe out of this: only the driver's own
  // behaviour is under test.
  const attach = createAttachment(ws, id, state, { env: scripted_env, pollMs: 60_000 })
  try {
    // Not awaited between them: the second arrives while the first is still
    // appending. Before the fix this spawned a second `session step`, the
    // kernel refused it with SessionBusy, and the role flipped to observer.
    const first = attach.send("first")
    const second = attach.send("second")
    await Promise.all([first, second])
    await until(() => attach.status() === "idle", 60_000)

    expect(attach.role()).toBe("driver")
    expect(state.snapshot.error).toBeNull()
    const users = state.snapshot.items.filter((item) => item.kind === "user")
    expect(users.map((item) => (item.kind === "user" ? item.text : ""))).toEqual(["first", "second"])
    expect(users.every((item) => item.kind === "user" && !item.queued && item.seq !== null)).toBe(true)
    // And the ledger agrees: both turns are there exactly once.
    const events = await sessionEvents(ws, id)
    expect(events.filter((event) => event.kind === "user_text").length).toBe(2)
  } finally {
    attach.dispose()
  }
}, 120_000)

test("a killed step is not reported as a failure and is not re-stepped", async () => {
  const id = await sessionNew(ws, { model: "scripted" })
  const state = createSessionState(id)
  const driver = createDriver(ws, id, state, { env: scripted_loop_env, maxSteps: 50 })
  try {
    void driver.send("keep going")
    // Let it get properly under way, then pull the plug (Ctrl+C's first press).
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 60_000)
    driver.kill()
    await until(() => driver.status() === "idle", 30_000)
    const stepsAtKill = state.snapshot.steps
    // The exit is non-zero, but the user asked for it: no red status line.
    expect(state.snapshot.error).toBeNull()
    // And no automatic continuation: a moment later nothing more has run.
    await new Promise((resolve) => setTimeout(resolve, 500))
    expect(driver.status()).toBe("idle")
    expect(state.snapshot.steps).toBe(stepsAtKill)
  } finally {
    driver.dispose()
  }
}, 120_000)

test("a step that dies without a `run error` line still surfaces its stderr", async () => {
  const id = await sessionNew(ws, { model: "scripted" })
  const state = createSessionState(id)
  // Bun itself standing in for the kernel: `bun session step <id> --stream`
  // is not a thing, so it exits non-zero with a diagnostic on stderr and not
  // one JSON line on stdout — exactly the shape of an unexpected kernel crash.
  const broken = { dir: ws.dir, bin: process.execPath }
  const driver = createDriver(broken, id, state, {})
  try {
    // `send` would run the real `session append` through the fake binary too;
    // `step` is the path under test.
    await driver.step()
    expect(driver.status()).toBe("idle")
    expect(state.snapshot.error).toMatch(/^step exited \d+/)
  } finally {
    driver.dispose()
  }
}, 60_000)

test("the error line clears when the next step actually starts", async () => {
  const state = createSessionState("s-x")
  state.setError("session step failed: Something")
  expect(state.snapshot.error).toBe("session step failed: Something")
  state.applyStream({ stream: "model", event: "started" })
  expect(state.snapshot.error).toBeNull()

  // A `run error` after that is a new fact and shows again.
  state.applyStream({ stream: "run", event: "error", message: "boom" })
  expect(state.snapshot.error).toBe("boom")
})
