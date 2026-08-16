/**
 * The CLI contact surface, against the REAL `nulya` binary in scripted mode
 * (tui.md §8). No API key, no network, no mocked protocol: if the kernel's line
 * protocol moves, these fail.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { sessionAppend, sessionCancel, sessionEvents, sessionNew, sessionStep, type StepLine } from "../src/nulya/cli.ts"
import { createSessionState } from "../src/state/session.ts"
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
    expect(tags[0]).toBe("model:started")
    expect(tags[tags.length - 1]).toBe("run:done")

    // Step 1: model deltas → tool begin/end → this step's ledger lines → step end.
    expect(tags).toEqual([
      "model:started",
      "model:text_delta",
      "model:tool_use_start",
      "model:tool_use_input_delta",
      "model:done",
      "tool:begin",
      "tool:end",
      "event:user_text",
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
    const started = lines[0]!
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
