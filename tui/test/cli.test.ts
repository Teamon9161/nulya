/**
 * The CLI contact surface, against the REAL `nulya` binary in scripted mode
 *. No API key, no network, no mocked protocol: if the kernel's line
 * protocol moves, these fail.
 */
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import {
  extBuild,
  extList,
  sessionAppend,
  sessionCancel,
  sessionEvents,
  sessionList,
  sessionNew,
  sessionOutcome,
  sessionStep,
  toolSaid,
  type StepLine,
} from "../src/nulya/cli.ts"
import { cacheShare, createSessionState, usageLabel, no_snapshot } from "../src/state/session.ts"
import { projection, scripted_env, scripted_loop_env, tempWorkspace, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

async function collect(lines: AsyncGenerator<StepLine>): Promise<StepLine[]> {
  const out: StepLine[] = []
  for await (const line of lines) out.push(line)
  return out
}

function streamTags(lines: StepLine[]): string[] {
  return lines.map((line) =>
    line.kind === "stream" ? `${line.line.stream}:${line.line.event}` : `event:${line.event.kind}`,
  )
}

describe("session step --stream", () => {
  test("new → append → step emits the DESIGN §14 line protocol in order", async () => {
    const id = await sessionNew(ws, { profile: "scripted" })
    expect(id.startsWith("s-")).toBe(true)

    await sessionAppend(ws, id, "read the kernel\nthen build")

    const step = sessionStep(ws, id, { env: scripted_env })
    const lines = await collect(step.lines)
    expect(await step.exited).toBe(0)

    const tags = streamTags(lines)
    // The turn the step boundary drained comes first — before the answer to it,
    // which is the order it happened in.
    expect(tags[0]).toBe("event:user_text")
    expect(tags[tags.length - 1]).toBe("run:done")

    // Step 1: the drained turn → model deltas → tool begin/end → the rest of
    // this step's ledger lines → step end.
    expect(tags).toEqual([
      "event:user_text",
      "model:started",
      "model:text_delta",
      "model:tool_use_start",
      "model:tool_use_input_delta",
      "model:done",
      "tool:begin",
      "tool:end",
      "event:assistant",
      "event:tool_results",
      "step:end",
      "model:started",
      "model:text_delta",
      "model:done",
      "event:assistant",
      "step:end",
      "run:done",
    ])

    // Typed parsing, not string matching: every line is a real object.
    const started = lines.find((l) => l.kind === "stream" && l.line.event === "started")!
    expect(started.kind).toBe("stream")

    const toolStart = lines.find((l) => l.kind === "stream" && l.line.event === "tool_use_start")!
    expect(toolStart.kind === "stream" && (toolStart.line as { name: string }).name).toBe("shell")

    const toolEnd = lines.find((l) => l.kind === "stream" && l.line.stream === "tool" && l.line.event === "end")!
    expect(toolEnd.kind === "stream" && (toolEnd.line as { ok: boolean }).ok).toBe(true)

    const events = lines.filter((l) => l.kind === "event")
    expect(events.map((l) => (l as { event: { seq: number } }).event.seq)).toEqual([1, 2, 3, 4])

    const user = events[0]! as Extract<StepLine, { kind: "event" }>
    expect(user.event.kind).toBe("user_text")
    expect((user.event as { text: string }).text).toBe("read the kernel\nthen build")

    const runDone = lines[lines.length - 1]!
    expect(runDone.kind === "stream" && (runDone.line as { stopped: string }).stopped).toBe("end_turn")
    expect(runDone.kind === "stream" && (runDone.line as { steps: number }).steps).toBe(2)
  }, 60_000)

  test("a dead step does not keep the stream open through inherited stdout", async () => {
    if (process.platform === "win32") return
    const dir = mkdtempSync(join(tmpdir(), "nulya-tui-step-leak-"))
    const bin = join(dir, "fake-step")
    writeFileSync(
      bin,
      `#!/usr/bin/env bash\nprintf '%s\\n' '{"stream":"run","event":"error","message":"boom"}'\n(sleep 5) &\nexit 7\n`,
    )
    chmodSync(bin, 0o755)
    try {
      const started = Date.now()
      const step = sessionStep({ ...ws, bin }, "s-fake")
      const lines = await collect(step.lines)
      const code = await step.exited
      expect(code).toBe(7)
      expect(Date.now() - started).toBeLessThan(1500)
      expect(streamTags(lines)).toEqual(["run:error"])
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  }, 10_000)

  test("events replay lands on the same transcript as watching it live", async () => {
    const id = await sessionNew(ws, { profile: "scripted" })
    await sessionAppend(ws, id, "hello")

    const live = createSessionState(id)
    const step = sessionStep(ws, id, { env: scripted_env })
    for await (const line of step.lines) {
      if (line.kind === "stream") live.applyStream(line.line)
      else live.applyEvent(line.event)
    }
    await step.exited

    const replay = createSessionState(id)
    replay.applyEvents(await sessionEvents(ws, id))

    expect(projection(replay.snapshot.items)).toEqual(projection(live.snapshot.items))
    // And it is not trivially empty.
    expect(live.snapshot.items.length).toBeGreaterThan(2)
    expect(live.snapshot.items.every((item) => item.seq !== null)).toBe(true)
  }, 60_000)

  test("--since replays only the tail", async () => {
    const id = await sessionNew(ws, { profile: "scripted" })
    await sessionAppend(ws, id, "hi")
    const step = sessionStep(ws, id, { env: scripted_env })
    for await (const _ of step.lines) {
      // drain
    }
    await step.exited

    const all = await sessionEvents(ws, id)
    const tail = await sessionEvents(ws, id, 2)
    expect(all.length).toBe(4)
    expect(tail.map((event) => event.seq)).toEqual([3, 4])
  }, 60_000)
})

/**
 * The surfaces M5 handed the front end. All three are read or
 * written through the kernel rather than by walking `.nulya/` — the point being
 * that composition, cost and verdict have exactly one implementation.
 */
describe("the slow loop", () => {
  test("session list projects the store, and outcome is a judgment beside it", async () => {
    const id = await sessionNew(ws, { profile: "scripted" })
    await sessionAppend(ws, id, "the first question")
    const step = sessionStep(ws, id, { env: scripted_env })
    for await (const _ of step.lines) {
      // drain
    }
    await step.exited
    const untouchedId = await sessionNew(ws, { profile: "scripted" })

    const before = await sessionList(ws)
    const one = before.find((entry) => entry.id === id)!
    expect(one.provider).toBe("scripted")
    expect(one.events).toBeGreaterThan(0)
    expect(one.first_user_text).toBe("the first question")
    expect(one.created.endsWith("Z")).toBe(true)
    // No verdict is "not judged" — NOT failure.
    expect(one.outcome).toBeNull()
    // A session nobody stepped is listed too, with nothing in it.
    expect(before.find((entry) => entry.id === untouchedId)!.events).toBe(0)
    // Newest first, by the header's `created`.
    const created = before.map((entry) => entry.created)
    expect([...created].sort((a, b) => b.localeCompare(a))).toEqual(created)

    await sessionOutcome(ws, id, "partial", "the shell call worked, the rest did not")
    const after = (await sessionList(ws)).find((entry) => entry.id === id)!
    expect(after.outcome?.verdict).toBe("partial")
    expect(after.outcome?.note).toBe("the shell call worked, the rest did not")

    // The journal keeps every line and the last one stands.
    await sessionOutcome(ws, id, "success")
    expect((await sessionList(ws)).find((entry) => entry.id === id)!.outcome?.verdict).toBe("success")
  }, 120_000)

  test("--with brings a built version into one session's composition, activating nothing", async () => {
    // A data extension: no runtime, so no toolchain is involved.
    const draft = `${ws.dir}/mode-draft`
    await Bun.write(
      `${draft}/extension.json`,
      JSON.stringify({
        schema: "nulya.extension/v2",
        id: "reviewer",
        contributes: { system_prompts: ["prompts/reviewer.md"] },
      }),
    )
    await Bun.write(`${draft}/prompts/reviewer.md`, "You are reviewing, not writing.\n")

    const version = await extBuild(ws, "mode-draft")
    expect(version.startsWith("v-")).toBe(true)
    // Built lands in the store under the manifest's id, and stays inactive:
    // `--with` is membership in one composition, not a store pointer (physics #5).
    const listed = (await extList(ws)).find((entry) => entry.id === "reviewer")!
    expect(listed.current).toBeNull()
    expect(listed.layer).toBeNull()

    const id = await sessionNew(ws, { profile: "scripted", with: [`reviewer@${version}`] })
    const entry = (await sessionList(ws)).find((row) => row.id === id)!
    expect(entry.composition.active).toContain(`reviewer@${version}`)

    // A session started without it is not carrying it — that is the whole point.
    const plain = await sessionNew(ws, { profile: "scripted" })
    expect((await sessionList(ws)).find((row) => row.id === plain)!.composition.active).not.toContain(
      `reviewer@${version}`,
    )
  }, 120_000)

  test("a version that was never built is refused, not silently dropped", async () => {
    await expect(sessionNew(ws, { profile: "scripted", with: ["reviewer@v-nope"] })).rejects.toThrow()
  }, 60_000)
})

describe("cancel", () => {
  test("Esc's CLI path ends the run at a step boundary", async () => {
    const id = await sessionNew(ws, { profile: "scripted" })
    await sessionAppend(ws, id, "loop forever")

    // `loop` mode never ends its turn, so only the budget or a cancel stops it.
    const step = sessionStep(ws, id, { maxSteps: 20, env: scripted_loop_env })
    const seen: StepLine[] = []
    let requested = false
    for await (const line of step.lines) {
      seen.push(line)
      if (!requested && line.kind === "stream" && line.line.stream === "step" && line.line.event === "end") {
        requested = true
        await sessionCancel(ws, id)
      }
    }
    await step.exited

    const statuses = seen
      .filter((l) => l.kind === "stream" && l.line.stream === "step")
      .map((l) => (l as { line: { status: string } }).line.status)
    expect(statuses).toContain("canceled")

    const runDone = seen[seen.length - 1]!
    expect(runDone.kind === "stream" && (runDone.line as { stopped: string }).stopped).toBe("canceled")
    // Well under the budget: the cancel, not the cap, is what stopped it.
    expect(statuses.length).toBeLessThan(20)
  }, 120_000)
})

test("the cache share is of the whole prompt, not of its uncached part", () => {
  // The kernel's `input_tokens` is the NON-cached part (provider.zig), so a
  // step that served 900 of 1000 prompt tokens from cache arrives as
  // input 100 / cacheRead 900 — 90%, never 900%.
  expect(cacheShare({ input: 100, cacheRead: 900, cacheWrite: 0 })).toBe(90)
  // A cache write is prompt too: 1080 read of 1200 + 1080 + 120.
  expect(cacheShare({ input: 1200, cacheRead: 1080, cacheWrite: 120 })).toBe(45)
  // Never above 100, and 0 before anything was priced.
  expect(cacheShare({ input: 0, cacheRead: 500, cacheWrite: 0 })).toBe(100)
  expect(cacheShare({ input: 0, cacheRead: 0, cacheWrite: 0 })).toBe(0)
})

test("what a session has cost is a phrase, or nothing at all before it has cost anything", () => {
  // The absent case is every draft tab and every session reopened but not
  // stepped: the line that would carry it (the activity line) is not
  // there either, so `null` is what "say nothing" looks like here.
  expect(usageLabel(no_snapshot.usage)).toBeNull()
  expect(usageLabel({ ...no_snapshot.usage, input: 281_600, output: 12_000, cacheRead: 1_718_400 })).toBe(
    "↑281.6k ↓12.0k cache 86%",
  )
  // Output alone is still a cost — a step that was served entirely from cache.
  expect(usageLabel({ ...no_snapshot.usage, output: 12 })).toBe("↑0 ↓12 cache 0%")
})

test("toolSaid reads the tool's sentence past the plain wire's exit / stderr framing", () => {
  // A refusal on the plain wire, as `ext run` prints it.
  expect(toolSaid({ stdout: "exit 1\nstderr:\nno agent 'x' (there are: explore, plan)\n", stderr: "" })).toBe(
    "no agent 'x' (there are: explore, plan)",
  )
  // ...with something printed before the failure: the stderr line still wins.
  expect(toolSaid({ stdout: "exit 1\nstderr:\nnothing moved\nstdout:\n{}\n", stderr: "" })).toBe("nothing moved")
  // A tool that said nothing on stderr is reported by its exit line.
  expect(toolSaid({ stdout: "exit 3\n", stderr: "" })).toBe("exit 3")
  // Plain text with no framing, and the stderr fallback, are taken as they are.
  expect(toolSaid({ stdout: "already built\nmore", stderr: "" })).toBe("already built")
  expect(toolSaid({ stdout: "", stderr: "spawn failed" })).toBe("spawn failed")
  expect(toolSaid({ stdout: "", stderr: "" })).toBe("no output")
})
