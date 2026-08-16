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
  listSessions,
  probeWriterLease,
  readToolUsage,
  sessionExists,
  type LeaseState,
} from "../src/nulya/files.ts"
import { sessionAppend, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { scripted_env, scripted_loop_env, tempWorkspace, until, type TempWorkspace } from "./support.ts"

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

test("listSessions reads the store: newest first, with header, count and title", async () => {
  const first = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, first, "the first question")
  await drainStep(first)
  const second = await sessionNew(ws, { profile: "scripted" })

  const sessions = await listSessions(ws)
  const ids = sessions.map((entry) => entry.id)
  expect(ids).toContain(first)
  expect(ids).toContain(second)

  const one = sessions.find((entry) => entry.id === first)!
  expect(one.header?.model_identity.provider).toBe("scripted")
  expect(one.events).toBeGreaterThan(0)
  expect(one.title).toBe("the first question")
  // A session nobody has stepped has a header and no events.
  expect(sessions.find((entry) => entry.id === second)!.events).toBe(0)

  const mtimes = sessions.map((entry) => entry.mtime)
  expect([...mtimes].sort((a, b) => b - a)).toEqual(mtimes)
}, 60_000)

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

  const extensions = listExtensions(ws)
  const lint = extensions.find((entry) => entry.id === "lint")!
  expect(lint.current).toBe(version!)
  expect(lint.versions.map((entry) => entry.version)).toContain(version!)
  // A `src/` entry is frozen, not compiled — that is what makes its version id
  // compiler-independent (DESIGN §7.4).
  expect(lint.kind).toBe("script")
  expect(lint.tools.length).toBeGreaterThan(0)
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
  // Sorted by count, which is a display order — not `tool_selection.rank`.
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
  expect((await listSessions(ws)).map((entry) => entry.id)).not.toContain(empty)
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
