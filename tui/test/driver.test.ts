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
  const id = await sessionNew(ws, { profile: "scripted" })
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
  const id = await sessionNew(ws, { profile: "scripted" })
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
  const id = await sessionNew(ws, { profile: "scripted" })
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

test("a retry line drops the failed attempt's cards and usage; the next started clears the notice", () => {
  const state = createSessionState("s-x")
  state.applyStream({ stream: "model", event: "started" })
  state.applyStream({ stream: "model", event: "text_delta", text: "half a rep" })
  state.applyStream({ stream: "model", event: "tool_use_start", index: 0, id: "c1", name: "shell" })
  state.applyStream({ stream: "model", event: "usage", input_tokens: 100, output_tokens: 5, cache_read_tokens: 0, cache_write_tokens: 0 })
  expect(state.snapshot.items.length).toBe(2)
  expect(state.snapshot.usage.input).toBe(100)

  state.applyStream({ stream: "model", event: "retry", attempt: 1, max_retries: 5, delay_ms: 1000, error: "Transport" })
  expect(state.snapshot.items.length).toBe(0)
  expect(state.snapshot.usage.input).toBe(0)
  expect(state.snapshot.error).toBe("model request failed (Transport); retry 1/5 in 1s")

  // The re-sent attempt streams from scratch: no leftover prefix, notice gone.
  state.applyStream({ stream: "model", event: "started" })
  expect(state.snapshot.error).toBeNull()
  state.applyStream({ stream: "model", event: "text_delta", text: "a whole reply" })
  expect(state.snapshot.items.length).toBe(1)
  expect((state.snapshot.items[0] as { text: string }).text).toBe("a whole reply")
})

/**
 * Cost accounting (T8). Both mouths report the same step: the stream as it
 * happens, the ledger once the step is written (DESIGN §3.1 / §14). The ledger
 * is the one that counts — otherwise a step would be paid for twice, and a
 * session reopened tomorrow would claim to have cost nothing.
 */
test("a step's usage is counted once: the stream's number is provisional, the ledger's is the fact", () => {
  const state = createSessionState("s-x")
  state.applyStream({ stream: "model", event: "started" })
  state.applyStream({
    stream: "model",
    event: "usage",
    input_tokens: 100,
    output_tokens: 10,
    cache_read_tokens: 900,
    cache_write_tokens: 0,
  })
  // Live, before the ledger line: the status bar has something to show.
  expect(state.snapshot.usage.input).toBe(100)
  expect(state.snapshot.usage.lastPrompt).toBe(1000)
  expect(state.snapshot.usage.pricedSteps).toBe(0)

  // The same step, now written. The provider's final numbers differ slightly —
  // whatever the ledger says is what this step cost.
  state.applyEvent({
    seq: 1,
    kind: "assistant",
    text: "done",
    calls: [],
    usage: { input_tokens: 120, output_tokens: 12, cache_read_tokens: 900, cache_write_tokens: 5 },
  })
  state.applyStream({ stream: "step", event: "end", status: "completed" })
  expect(state.snapshot.usage.input).toBe(120)
  expect(state.snapshot.usage.output).toBe(12)
  expect(state.snapshot.usage.cacheWrite).toBe(5)
  expect(state.snapshot.usage.lastPrompt).toBe(1025)
  expect(state.snapshot.usage.pricedSteps).toBe(1)
})

test("replaying a session recovers what it cost, without ever watching a step", () => {
  const state = createSessionState("s-x")
  state.applyEvents([
    { seq: 1, kind: "user_text", text: "hi" },
    {
      seq: 2,
      kind: "assistant",
      text: "one",
      calls: [],
      usage: { input_tokens: 50, output_tokens: 5, cache_read_tokens: 0, cache_write_tokens: 200 },
    },
    // A step the provider never priced adds nothing — absent is not zero.
    { seq: 3, kind: "assistant", text: "two", calls: [] },
    {
      seq: 4,
      kind: "assistant",
      text: "three",
      calls: [],
      usage: { input_tokens: 30, output_tokens: 8, cache_read_tokens: 220, cache_write_tokens: 0 },
    },
  ])
  expect(state.snapshot.usage.input).toBe(80)
  expect(state.snapshot.usage.output).toBe(13)
  expect(state.snapshot.usage.pricedSteps).toBe(2)
  // The window's fullness is the LAST prompt, not the sum of all of them.
  expect(state.snapshot.usage.lastPrompt).toBe(250)
  // Nothing was watched here: steps and priced steps are different facts.
  expect(state.snapshot.steps).toBe(0)
})
