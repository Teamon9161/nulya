/**
 * The `.nulya/` projections this front end reads: the session store,
 * the writer lease, the extension store and the usage journal. Every assertion
 * here runs against files a REAL `nulya` binary wrote — a hand-built fixture
 * would only prove that the parser parses itself.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import {
  listExtensions,
  probeWriterLease,
  readContributions,
  readDelegationRecord,
  readToolUsage,
  sessionExists,
  type LeaseState,
} from "../src/nulya/files.ts"
import { sessionAppend, sessionList, sessionNew, sessionPrune, sessionStep } from "../src/nulya/cli.ts"
import { scripted_env, scripted_loop_env, tempWorkspace, until, type TempWorkspace } from "./support.ts"
import { join } from "node:path"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"

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
 * The lease probe. On Windows the kernel's exclusive lock is a
 * byte-range lock, so a read of the lock file is a faithful, non-mutating probe.
 * On Linux the same lease is `flock`, invisible to reads but published in
 * `/proc/locks` — an equally non-mutating probe. Where neither exists the probe
 * must say `unknown` rather than "free", because the difference decides whether
 * the screen claims to be driving something it is not.
 */
const probe_answers = process.platform === "win32" || process.platform === "linux"

test("probeWriterLease sees the writer lease while a step runs", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, id, "hold the lease for a moment")
  const idle: LeaseState = probeWriterLease(ws, id)
  if (probe_answers) expect(idle).toBe("free")
  else expect(idle === "free" || idle === "unknown").toBe(true)

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

  if (probe_answers) {
    expect(seen).toContain("held")
  } else {
    expect(seen.every((state) => state === "unknown" || state === "held")).toBe(true)
  }
}, 60_000)

test("a manual tool that opted out of recommended is selectable but not installed", async () => {
  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
  expect(run(["ext", "init", "--script", "kit"]).exitCode).toBe(0)
  const draft = join(ws.dir, ".nulya", "extensions", "kit")
  const manifest = JSON.parse(readFileSync(join(draft, "extension.json"), "utf8")) as Record<string, unknown>
  const tool = (manifest["contributes"] as Record<string, unknown>)["tools"] as Array<Record<string, unknown>>
  tool[0]!["surface"] = "manual"
  tool.push({ ...tool[0]!, name: "extra", recommended: false })
  writeFileSync(join(draft, "extension.json"), JSON.stringify(manifest))

  const built = run(["ext", "build", ".nulya/extensions/kit"])
  expect(built.exitCode).toBe(0)
  const version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0]!

  // Two different questions: which tools a person COULD tick, and which ones
  // installing this package switches on.
  const kit = await readContributions(ws, "kit", version)
  expect(kit.manualTools).toContain("extra")
  expect(kit.recommendedTools).not.toContain("extra")
  expect(kit.recommendedTools.length).toBe(kit.manualTools.length - 1)
})

test("listExtensions reads the version line, the current pointer and the manifest", async () => {
  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
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
  // compiler-independent.
  expect(lint.kind).toBe("script")
  expect(lint.tools.length).toBeGreaterThan(0)
  // The template writes no `surface`, so this reads the kernel default through
  // a real build: a tool nobody placed is `auto` — model-facing as soon as its
  // package is a member, with no selection to write.
  expect(lint.autoTools).toEqual(lint.tools)
  expect(lint.manualTools).toEqual([])
  expect(lint.internalTools).toEqual([])
  // Which layer's pointer names it is the kernel's answer, not ours: the draft is
  // in this workspace, so the activate landed on the workspace layer.
  expect(lint.layer).toBe("workspace")
}, 120_000)

test("a system prompt entry projects its path in either form, bare or with a position", async () => {
  // `contributes.system_prompts` entries may be a bare path or an object
  // carrying `path` plus an optional `position`. `position`
  // orders one session's system blocks — the kernel's business — so this
  // projection takes the path from both forms and nothing else.
  const dir = join(ws.dir, ".nulya", "extensions", "mode.two")
  mkdirSync(dir, { recursive: true })
  writeFileSync(
    join(dir, "extension.json"),
    JSON.stringify({
      schema: "nulya.extension/v2",
      id: "mode.two",
      contributes: { system_prompts: ["head.md", { path: "tail.md", position: "late" }] },
    }),
  )
  writeFileSync(join(dir, "head.md"), "head\n")
  writeFileSync(join(dir, "tail.md"), "tail\n")

  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
  const built = run(["ext", "build", ".nulya/extensions/mode.two"])
  expect(built.exitCode).toBe(0)
  const version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0]
  expect(run(["ext", "activate", "mode.two", version!]).exitCode).toBe(0)

  const entry = (await listExtensions(ws)).find((e) => e.id === "mode.two")!
  expect(entry.systemPrompts).toEqual(["head.md", "tail.md"])
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
test("sessionPrune removes only a session that recorded nothing and holds nothing", async () => {
  // Fresh from `session new`: a header and no events → removed, siblings too.
  const empty = await sessionNew(ws, { profile: "scripted" })
  expect(sessionExists(ws, empty)).toBe(true)
  expect(sessionPrune(ws, empty)).toBe(true)
  expect(sessionExists(ws, empty)).toBe(false)
  expect((await sessionList(ws)).map((entry) => entry.id)).not.toContain(empty)
  // Twice is a no-op, not an error.
  expect(sessionPrune(ws, empty)).toBe(false)

  // A turn waiting in the inbox: the user said something nobody has drained
  // yet. Deleting would lose it → kept.
  const queued = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, queued, "not yet stepped")
  expect(sessionPrune(ws, queued)).toBe(false)
  expect(sessionExists(ws, queued)).toBe(true)
  // …and once it IS drained it is a ledger with events → kept, forever.
  await drainStep(queued)
  expect(sessionPrune(ws, queued)).toBe(false)
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
    expect(sessionPrune(ws, held)).toBe(false)
    expect(sessionExists(ws, held)).toBe(true)
  } finally {
    step.kill()
    await step.exited
    await drain
  }
}, 120_000)

// --- delegations (goals/agent-runner.md ar-t2) ------------------------------

/**
 * `readDelegationRecord`'s wire format is `extensions/agent/src/record.zig`'s
 * own, not this front end's — a package the TUI never builds and a session it
 * never opens. One hand-built fixture is the right tool here, unlike every
 * test above it in this file: the record is small, independently specified,
 * and building a real one would mean compiling the bundled `agent` package
 * just to prove this reader agrees with a format it does not write either
 * side of (`agents.test.ts`'s 300s timeouts are that cost, paid for a
 * different question).
 */
test("readDelegationRecord reads the created row, drops a torn tail, and a bad id or a missing one is null", async () => {
  const id = "d-0123456789ab"
  const dir = join(ws.dir, ".nulya", "delegations", id)
  mkdirSync(dir, { recursive: true })
  const path = join(dir, "record.jsonl")
  writeFileSync(
    path,
    [
      JSON.stringify({
        v: 1,
        kind: "created",
        at: "2026-08-26T00:00:00Z",
        agent: "explore",
        runner: "nulya",
        remote: "s-1-abc",
        parent: "s-0-def",
        readonly: true,
      }),
      JSON.stringify({ v: 1, kind: "turn", at: "2026-08-26T00:00:01Z" }),
      "",
    ].join("\n"),
  )

  const record = await readDelegationRecord(ws, id)
  expect(record).toEqual({ agent: "explore", runner: "nulya", remote: "s-1-abc", readonly: true })

  // A torn last line — an append in flight, or cut short by a crash — is
  // dropped rather than glued onto the next one, exactly as `record.zig`'s own
  // reader does it; it does not change what the last WHOLE row said.
  const whole = readFileSync(path, "utf8")
  writeFileSync(path, `${whole}{"v":1,"kind":"tu`)
  expect(await readDelegationRecord(ws, id)).toEqual({ agent: "explore", runner: "nulya", remote: "s-1-abc", readonly: true })

  // A shape that is not a delegation id never becomes a path, and a valid
  // shape nobody has opened is simply nothing to report — neither is an error.
  expect(await readDelegationRecord(ws, "s-1-abc")).toBeNull()
  expect(await readDelegationRecord(ws, "d-999999999999")).toBeNull()
})
