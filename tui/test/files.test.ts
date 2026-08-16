/**
 * The `.nulya/` projections T3 added (tui.md §5.3 / §5.4): the session store,
 * the writer lease, the extension store and the usage journal. Every assertion
 * here runs against files a REAL `nulya` binary wrote — a hand-built fixture
 * would only prove that the parser parses itself.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import {
  discardIfUntouched,
  listExtensions,
  probeWriterLease,
  readToolUsage,
  sessionExists,
  storeRoots,
  type LeaseState,
} from "../src/nulya/files.ts"
import { sessionAppend, sessionList, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { scripted_env, scripted_loop_env, tempWorkspace, until, type TempWorkspace } from "./support.ts"
import { join } from "node:path"

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

async function drainStep(id: string, env: Record<string, string> = scripted_env, maxSteps?: number): Promise<void> {
  const step = sessionStep(ws, id, { env, ...(maxSteps === undefined ? {} : { maxSteps }) })
  for await (const _ of step.lines) {
    // Draining is the point; the state machine is tested elsewhere.
  }
  await step.exited
}

/**
 * The lease probe (tui.md §5.6). On Windows the kernel's exclusive lock is a
 * byte-range lock, so a read of the lock file is a faithful, non-mutating probe.
 * Elsewhere the same lease is `flock`, invisible to reads — the probe must then
 * say `unknown` rather than "free", because the difference decides whether the
 * screen claims to be driving something it is not.
 */
test("probeWriterLease sees the writer lease while a step runs", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, id, "hold the lease for a moment")
  const idle: LeaseState = probeWriterLease(ws, id)
  expect(idle === "free" || idle === "unknown").toBe(true)

  const step = sessionStep(ws, id, { env: scripted_loop_env, maxSteps: 400 })
  const seen: LeaseState[] = []
  const reader = (async () => {
    for await (const _ of step.lines) {
      if (seen.length < 6) seen.push(probeWriterLease(ws, id))
    }
  })()
  await until(() => seen.length >= 3, 30_000)
  step.kill()
  await step.exited
  await reader

  if (process.platform === "win32") {
    expect(seen).toContain("held")
  } else {
    expect(seen.every((state) => state === "unknown" || state === "held")).toBe(true)
  }
}, 60_000)

test("listExtensions reads the version line, the current pointer and the manifest", async () => {
  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir })
  expect(run(["ext", "init", "--script", "lint"]).exitCode).toBe(0)
  const built = run(["ext", "build", ".nulya/extensions/lint"])
  expect(built.exitCode).toBe(0)
  const version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0]
  expect(version).toBeDefined()
  expect(run(["ext", "activate", "lint", version!]).exitCode).toBe(0)

  const extensions = await listExtensions(ws)
  const lint = extensions.find((entry) => entry.id === "lint")!
  expect(lint.current).toBe(version!)
  expect(lint.versions.map((entry) => entry.version)).toContain(version!)
  // A `src/` entry is frozen, not compiled — that is what makes its version id
  // compiler-independent (DESIGN §7.4).
  expect(lint.kind).toBe("script")
  expect(lint.tools.length).toBeGreaterThan(0)
  // Which root it came from is the kernel's answer, not ours (DESIGN §7.2), and
  // the only copy here is the workspace one, so nothing shadows anything.
  expect(lint.root).toBe(".nulya/extensions")
  expect(lint.shadowed).toBe(false)
  // The workspace root is always first in the search order.
  expect((await storeRoots(ws))[0]).toBe(join(ws.dir, ".nulya", "extensions"))
}, 120_000)

test("readToolUsage projects the journal without ranking it", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, id, "probe")
  await drainStep(id)

  const usage = await readToolUsage(ws)
  const shell = usage.find((row) => row.toolId === "builtin.shell")
  expect(shell).toBeDefined()
  expect(shell!.uses).toBeGreaterThan(0)
  expect(shell!.ok).toBeGreaterThan(0)
  // Sorted by count, which is a display order — the kernel has no other one:
  // native slots come from pins, never from this journal.
  const counts = usage.map((row) => row.uses)
  expect([...counts].sort((a, b) => b - a)).toEqual(counts)
}, 60_000)

/**
 * Un-creating a session the TUI made and never used. The guards are the test:
 * every way a session can carry meaning must keep it.
 */
test("discardIfUntouched removes only a session that recorded nothing and holds nothing", async () => {
  // Fresh from `session new`: a header and no events → removed, siblings too.
  const empty = await sessionNew(ws, { profile: "scripted" })
  expect(sessionExists(ws, empty)).toBe(true)
  expect(discardIfUntouched(ws, empty)).toBe(true)
  expect(sessionExists(ws, empty)).toBe(false)
  expect((await sessionList(ws)).map((entry) => entry.id)).not.toContain(empty)
  // Twice is a no-op, not an error.
  expect(discardIfUntouched(ws, empty)).toBe(false)

  // A turn waiting in the inbox: the user said something nobody has drained
  // yet. Deleting would lose it → kept.
  const queued = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, queued, "not yet stepped")
  expect(discardIfUntouched(ws, queued)).toBe(false)
  expect(sessionExists(ws, queued)).toBe(true)
  // …and once it IS drained it is a ledger with events → kept, forever.
  await drainStep(queued)
  expect(discardIfUntouched(ws, queued)).toBe(false)
  expect(sessionExists(ws, queued)).toBe(true)

  // A step holding the lease right now → kept, whatever the file says.
  const held = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, held, "hold it")
  const step = sessionStep(ws, held, { env: scripted_loop_env, maxSteps: 200 })
  let holding = false
  const drain = (async () => {
    for await (const _ of step.lines) holding = true
  })()
  try {
    await until(() => holding, 30_000)
    expect(discardIfUntouched(ws, held)).toBe(false)
    expect(sessionExists(ws, held)).toBe(true)
  } finally {
    step.kill()
    await step.exited
    await drain
  }
}, 120_000)
