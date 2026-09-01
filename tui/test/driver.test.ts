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
import { createDriver, stepExitError } from "../src/state/driver.ts"
import { createSessionState } from "../src/state/session.ts"
import { midTaskOf, mid_task_note, mid_task_open } from "../src/midtask.ts"
import { sessionAppend, sessionEvents, sessionNew } from "../src/nulya/cli.ts"
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
    expect(users.map((item) => (item.kind === "user" ? item.text : ""))).toEqual(["first\n\nsecond"])
    expect(users.every((item) => item.kind === "user" && !item.queued && item.seq !== null)).toBe(true)
    // The opening inbox batch is one model turn, in FIFO order.
    const events = await sessionEvents(ws, id)
    const userEvents = events.filter((event) => event.kind === "user_text") as Array<{ kind: "user_text"; text: string }>
    expect(userEvents.map((event) => event.text)).toEqual(["first\n\nsecond"])
  } finally {
    attach.dispose()
  }
}, 120_000)

test("a send joining while the opening tail is draining stays in that opening turn", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  let signalBStarted!: () => void
  let releaseB!: () => void
  const bStarted = new Promise<void>((resolve) => { signalBStarted = resolve })
  const bBarrier = new Promise<void>((resolve) => { releaseB = resolve })
  const driver = createDriver(ws, id, state, {
    env: scripted_env,
    append: async (workspace, session, text, images) => {
      if (text === "B") {
        signalBStarted()
        await bBarrier
      }
      await sessionAppend(workspace, session, text, images)
    },
  })
  try {
    const a = driver.send("A")
    const b = driver.send("B")
    // A has completed its append and is waiting on B. Add C only now: an
    // ordinary synchronous A/B/C send cannot pin this scheduler window.
    await bStarted
    await Promise.resolve()
    const c = driver.send("C")
    releaseB()

    await Promise.all([a, b, c])
    await until(() => driver.status() === "idle", 60_000)

    const events = await sessionEvents(ws, id)
    const userEvents = events.filter((event) => event.kind === "user_text") as Array<{ kind: "user_text"; text: string }>
    expect(userEvents.map((event) => event.text)).toEqual(["A\n\nB\n\nC"])
  } finally {
    releaseB()
    driver.dispose()
  }
}, 120_000)

test("a failed opening append keeps ownership until later queued appends are driven", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  let signalBStarted!: () => void
  let releaseB!: () => void
  const bStarted = new Promise<void>((resolve) => { signalBStarted = resolve })
  const bBarrier = new Promise<void>((resolve) => { releaseB = resolve })
  const driver = createDriver(ws, id, state, {
    env: scripted_env,
    append: async (workspace, session, text, images) => {
      if (text === "A") throw new Error("A append failed")
      if (text === "B") {
        signalBStarted()
        await bBarrier
      }
      await sessionAppend(workspace, session, text, images)
    },
  })
  try {
    const a = driver.send("A")
    const b = driver.send("B")

    // The opening owner has failed, but B is still in flight. `idle` here
    // would let compact fork before B reaches the durable parent inbox.
    await bStarted
    await until(() => state.snapshot.error === "A append failed")
    expect(driver.status()).toBe("sending")

    releaseB()
    await Promise.all([a, b])
    await until(() => driver.status() === "idle", 60_000)

    const events = await sessionEvents(ws, id)
    const userEvents = events.filter((event) => event.kind === "user_text") as Array<{ kind: "user_text"; text: string }>
    expect(userEvents.map((event) => event.text)).toEqual(["B"])
    expect(state.pendingCount()).toBe(0)
  } finally {
    releaseB()
    driver.dispose()
  }
}, 120_000)

test("an append failure rolls back its optimistic user card and pending count", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  state.setError("older failure")
  // Bun itself is executable but is not the nulya CLI. `session append` fails
  // before any step can start, which isolates the optimistic rollback path.
  const driver = createDriver({ dir: ws.dir, bin: process.execPath }, id, state, {})
  try {
    await driver.send("this append will fail")
    expect(driver.status()).toBe("idle")
    expect(state.pendingCount()).toBe(0)
    expect(state.snapshot.items.some((item) => item.kind === "user" && item.text === "this append will fail")).toBe(false)
    expect(state.snapshot.error).not.toBe("older failure")
    expect(state.snapshot.error).toBeTruthy()
  } finally {
    driver.dispose()
  }
}, 60_000)

test("explicit attempts clear an old error, while an empty timer wake does not", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const driver = createDriver(ws, id, state, { env: scripted_env })
  try {
    state.setError("old")
    await driver.wake()
    expect(state.snapshot.error).toBe("old")

    state.setError("old")
    const sending = driver.send("try again")
    expect(state.snapshot.error).toBeNull()
    await sending

    state.setError("old")
    const stepping = driver.step()
    expect(state.snapshot.error).toBeNull()
    await stepping
  } finally {
    driver.dispose()
  }
}, 120_000)

test("a send during a step in flight lands wrapped as mid-task; one at rest does not", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const pendingAtModelStart: number[] = []
  const driver = createDriver(ws, id, state, {
    env: scripted_loop_env,
    maxSteps: 12,
    onLine: (line) => {
      if (line.kind === "stream" && line.line.stream === "model" && line.line.event === "started") {
        pendingAtModelStart.push(state.pendingCount())
      }
    },
  })
  try {
    void driver.send("keep going")
    // The run is demonstrably under way: a tool call has resolved and the
    // scripted loop still has steps to spend.
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 60_000)
    expect(driver.status()).toBe("stepping")
    await driver.send("also check the docs")
    await driver.send("and the README")
    await until(() => driver.status() === "idle", 60_000)

    const events = await sessionEvents(ws, id)
    const users = events.filter((event) => event.kind === "user_text") as Array<{ kind: "user_text"; text: string }>
    expect(users.length).toBe(2)
    // At rest: verbatim. Both mid-task messages drained at one boundary become
    // one user turn; their frames and the once-per-run note stay in FIFO order.
    expect(users[0]!.text).toBe("keep going")
    expect(users[1]!.text.startsWith(mid_task_open)).toBe(true)
    expect(users[1]!.text).toContain(mid_task_note)
    const merged = state.snapshot.items.find((i) => i.kind === "user" && i.text === users[1]!.text)
    expect(merged !== undefined ? midTaskOf(merged) : null).toEqual({ text: "also check the docs\n\nand the README" })
    // The drained ledger event is emitted before every `model started`, so a
    // message is never still labelled queued while the model answers it.
    expect(pendingAtModelStart.length).toBeGreaterThan(0)
    expect(pendingAtModelStart.every((count) => count === 0)).toBe(true)
    expect(state.pendingCount()).toBe(0)
  } finally {
    driver.dispose()
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

/**
 * Interrupt-and-deliver (agent-runner ar-t1): kill the step this tab is
 * driving and re-step the moment it has actually exited, instead of letting
 * the loop mode's never-ending turn run out its whole `--max-steps` budget.
 *
 * There is no idle-poll timer anywhere in `driver.ts` — `wake()` is the only
 * thing that polls, and it lives in `attach.ts` — so a `createDriver` alone
 * resolving this at all is itself the proof that the redelivery came from the
 * explicit kill → wait-for-exit → step chain and not from some background
 * loop noticing the inbox later.
 */
test("interruptAndDeliver kills the running step, then redelivers the queued turn on its own — no hang, no crash, no lost or duplicated message", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  // `loop` never ends its own turn — a real model would likely comply with
  // "stop now" at its very next turn, but this scripted stand-in cannot, so a
  // generous budget is what stands in for "a run that would otherwise keep
  // going for a while" without the test depending on wall-clock timing.
  const driver = createDriver(ws, id, state, { env: scripted_loop_env, maxSteps: 40 })
  try {
    void driver.send("keep going")
    // Under way for real: at least one tool call has actually resolved.
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 60_000)

    await driver.interruptAndDeliver("stop and summarize instead")

    // Resolved at all — rather than hanging on a `step()` nobody ever called —
    // is itself most of what this proves: `createDriver` has no idle-poll
    // timer anywhere (`wake()`, the only thing that polls, lives in
    // `attach.ts` and was never constructed here), so the redelivery can only
    // have come from `interruptAndDeliver`'s own kill → wait-for-exit → step
    // chain.
    expect(driver.status()).toBe("idle")
    // A kill mid-gesture is not a crash, whichever run it lands in.
    expect(state.snapshot.error).toBeNull()
    // Everything queued has actually been drained: no leftover pending turn.
    expect(state.pendingCount()).toBe(0)

    const events = await sessionEvents(ws, id)
    const users = events.filter((event) => event.kind === "user_text") as Array<{ kind: "user_text"; text: string }>
    // Exactly once each — not lost to the kill, and not duplicated by a
    // process that drained it just before dying AND a fresh one after.
    expect(users.length).toBe(2)
    expect(users[0]!.text).toBe("keep going")
    // Mid-run, so it carries the same mid-task framing an ordinary `send`
    // would have (this gesture's append path is exactly `send`'s).
    expect(users[1]!.text).toContain("stop and summarize instead")
  } finally {
    driver.dispose()
  }
}, 120_000)

test("interruptAndDeliver on an idle driver is an ordinary send", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const driver = createDriver(ws, id, state, { env: scripted_env })
  try {
    await driver.interruptAndDeliver("hello")
    expect(driver.status()).toBe("idle")
    expect(state.snapshot.error).toBeNull()
    const events = await sessionEvents(ws, id)
    const users = events.filter((event) => event.kind === "user_text") as Array<{ kind: "user_text"; text: string }>
    expect(users.length).toBe(1)
    expect(users[0]!.text).toBe("hello")
  } finally {
    driver.dispose()
  }
}, 60_000)

test("interruptAndDeliver with nothing typed and nothing running is a no-op, not an empty send", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const driver = createDriver(ws, id, state, {})
  try {
    await driver.interruptAndDeliver("   ")
    expect(driver.status()).toBe("idle")
    const events = await sessionEvents(ws, id)
    expect(events.length).toBe(0)
  } finally {
    driver.dispose()
  }
}, 30_000)

test("a reported provider failure keeps its detailed stderr in the transcript", () => {
  expect(stepExitError(
    "session step failed: RateLimited",
    1,
    "provider API error 429: {\"error\":{\"message\":\"quota resets in 18 seconds\"}}\n",
  )).toBe(
    "session step failed: RateLimited\nprovider API error 429: {\"error\":{\"message\":\"quota resets in 18 seconds\"}}",
  )
})

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

  const retryObservedAt = Date.now()
  state.applyStream({ stream: "model", event: "retry", attempt: 1, max_retries: 5, delay_ms: 1000, error: "Transport" })
  expect(state.snapshot.items.length).toBe(0)
  expect(state.snapshot.usage.input).toBe(0)
  expect(state.snapshot.error).toBe("model request failed (Transport); retry 1/5 in 1s")
  expect(state.snapshot.retry).toEqual({
    error: "Transport",
    attempt: 1,
    maxRetries: 5,
    retryAt: expect.any(Number),
  })
  expect(state.snapshot.retry!.retryAt).toBeGreaterThanOrEqual(retryObservedAt + 1000)

  // The re-sent attempt streams from scratch: no leftover prefix or countdown.
  state.applyStream({ stream: "model", event: "started" })
  expect(state.snapshot.error).toBeNull()
  expect(state.snapshot.retry).toBeNull()
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


test("the last executing tool stays highlighted through the following model response", () => {
  const state = createSessionState("s-x")
  state.applyStream({ stream: "model", event: "started" })
  state.applyStream({ stream: "model", event: "tool_use_start", index: 0, id: "c1", name: "shell" })
  state.applyStream({ stream: "tool", event: "begin", call_id: "c1" })
  expect(state.snapshot.highlightedToolCallId).toBe("c1")

  state.applyStream({ stream: "tool", event: "end", call_id: "c1", ok: true })
  state.applyStream({ stream: "step", event: "end", status: "completed" })
  state.applyStream({ stream: "model", event: "started" })
  state.applyStream({ stream: "model", event: "text_delta", text: "Here is what it found." })
  // Result recording and the next response are still the same visible run.
  expect(state.snapshot.highlightedToolCallId).toBe("c1")

  state.applyStream({ stream: "model", event: "tool_use_start", index: 0, id: "c2", name: "read" })
  state.applyStream({ stream: "tool", event: "begin", call_id: "c2" })
  expect(state.snapshot.highlightedToolCallId).toBe("c2")

  state.applyStream({ stream: "run", event: "done", stopped: "end_turn" })
  expect(state.snapshot.highlightedToolCallId).toBeNull()
})
