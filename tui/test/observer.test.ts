/**
 * Observer mode end to end (tui.md §5.6, the T3 completion criterion).
 *
 * The scenario is the one the milestone asks for: a driver script loops
 * `nulya session step` in another process while the TUI attaches to the same
 * session. Everything here is unattended — the "other terminal" is
 * `test/fixtures/driver-loop.ts` — and nothing is simulated: a real binary holds
 * the real writer lease, and the attachment discovers it the same two ways the
 * real screen does (lease probe, and the kernel's own `SessionBusy`).
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { join } from "node:path"
import { createAttachment } from "../src/state/attach.ts"
import { createSessionState } from "../src/state/session.ts"
import { sessionAppend, sessionEvents, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { scripted_loop_env, tempWorkspace, until, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

function startDriverScript(id: string, stopFile: string) {
  return Bun.spawn({
    cmd: ["bun", join(import.meta.dir, "fixtures", "driver-loop.ts"), ws.bin, ws.dir, id, stopFile],
    cwd: ws.dir,
    stdout: "pipe",
    stderr: "pipe",
  })
}

test("a session driven by somebody else is observed, appended to, and then taken over", async () => {
  const id = await sessionNew(ws, { model: "scripted" })
  await sessionAppend(ws, id, "start the work")

  const stopFile = join(ws.dir, "stop-driver")
  const script = startDriverScript(id, stopFile)

  const state = createSessionState(id)
  state.applyEvents(await sessionEvents(ws, id))
  const attach = createAttachment(ws, id, state, { pollMs: 150, freeProbesToOffer: 3 })

  try {
    // 1. The role is discovered, not chosen: somebody else holds the lease.
    await until(() => attach.role() === "observer", 30_000)

    // 2. Events arrive live while we hold no write handle at all.
    const before = state.lastSeq()
    await until(() => state.lastSeq() > before, 30_000)

    // 3. An observer may still speak: the turn is deposited in the inbox and
    //    the OTHER writer drains it at its next step boundary (DESIGN §3.4).
    await attach.send("a word from the observer")
    expect(state.snapshot.items.some((item) => item.kind === "user" && item.queued)).toBe(true)
    await until(
      () =>
        state.snapshot.items.some(
          (item) => item.kind === "user" && !item.queued && item.text === "a word from the observer",
        ),
      60_000,
    )

    // 4. The other writer goes away; take-over is offered, not taken.
    await Bun.write(stopFile, "stop")
    await script.exited
    await until(() => attach.takeoverReady(), 30_000)
    expect(attach.role()).toBe("observer")

    // 5. Taking over means driving: our own step appends to the same ledger.
    attach.takeOver()
    expect(attach.role()).toBe("driver")
    const beforeTakeover = state.lastSeq()
    await attach.send("and now I am driving")
    await until(() => state.lastSeq() > beforeTakeover, 60_000)
    expect(attach.role()).toBe("driver")
    expect(state.snapshot.error).toBeNull()
  } finally {
    await Bun.write(stopFile, "stop")
    script.kill()
    attach.dispose()
  }
}, 180_000)

/**
 * The lease probe cannot see a POSIX `flock`, so the role must also be
 * recoverable from the kernel's own refusal. This drives that path directly:
 * probing is switched off (a poll interval longer than the test) and the only
 * signal left is `SessionBusy` on a step we asked for.
 */
test("a refused step flips the role to observer instead of raising an error", async () => {
  const id = await sessionNew(ws, { model: "scripted" })
  await sessionAppend(ws, id, "hold the lease")

  // Somebody else takes the lease and keeps it for the length of the test.
  const holder = sessionStep(ws, id, { env: scripted_loop_env, maxSteps: 400 })
  let holding = false
  const drain = (async () => {
    for await (const _ of holder.lines) {
      // Keep the pipe moving so the holder is not blocked on stdout; the first
      // line means it is past `openDurable` and therefore owns the lease.
      holding = true
    }
  })()

  const state = createSessionState(id)
  const attach = createAttachment(ws, id, state, { pollMs: 600_000, freeProbesToOffer: 3 })
  try {
    await until(() => holding, 30_000)
    await attach.step()
    expect(attach.role()).toBe("observer")
    // A busy session is a fact about who is writing, not a failure to report.
    expect(state.snapshot.error).toBeNull()
  } finally {
    holder.kill()
    await holder.exited
    await drain
    attach.dispose()
  }
}, 120_000)
