/**
 * Run summaries (T43, `render/runs.ts`).
 *
 * The rules are all in one pure function, so this is where they are pinned:
 * what disappears into a summary line, and — the half that actually matters —
 * what refuses to.
 */
import { expect, test } from "bun:test"
import { foldsIntoRun, groupRuns, runSummary, type RunCandidate } from "../src/render/runs.ts"
import { transcriptRows } from "../src/ui/Transcript.tsx"
import { createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import type { ToolItem, TranscriptItem } from "../src/state/session.ts"

function call(over: Partial<ToolItem> & { key: string; tool: string }): ToolItem {
  return {
    seq: 2,
    kind: "tool",
    callId: over.key,
    args: "{}",
    state: "done",
    ok: true,
    output: "",
    spillPath: null,
    resolved: true,
    awaiting: false,
    autoAllowed: false,
    taskResult: null,
    ...over,
  }
}

function candidate(over: Partial<RunCandidate> & { item: ToolItem }): RunCandidate {
  return { kind: "ext", ...over }
}

test("a finished, successful, bodyless call folds into the run", () => {
  expect(foldsIntoRun(candidate({ item: call({ key: "a", tool: "read" }) }))).toBe(true)
  expect(foldsIntoRun(candidate({ item: call({ key: "b", tool: "shell", output: "ok\n[exit 0]" }), kind: "shell" }))).toBe(
    true,
  )
})

test("what a run refuses to swallow", () => {
  // Still going: the one call worth watching.
  expect(foldsIntoRun(candidate({ item: call({ key: "a", tool: "read", state: "running" }) }))).toBe(false)
  expect(foldsIntoRun(candidate({ item: call({ key: "b", tool: "read", state: "pending" }) }))).toBe(false)
  // Waiting for a person to answer the gate.
  expect(foldsIntoRun(candidate({ item: call({ key: "c", tool: "read", awaiting: true }) }))).toBe(false)
  // Failed, both ways a call can: the kernel's `ok`, and a non-zero exit.
  expect(foldsIntoRun(candidate({ item: call({ key: "d", tool: "read", ok: false }) }))).toBe(false)
  expect(
    foldsIntoRun(candidate({ item: call({ key: "e", tool: "shell", output: "boom\n[exit 1]" }), kind: "shell" })),
  ).toBe(false)
  // Cancelled: the marker IS the card.
  expect(
    foldsIntoRun(
      candidate({
        item: call({ key: "f", tool: "shell", output: "not executed because the step was canceled" }),
        kind: "shell",
      }),
    ),
  ).toBe(false)
  // A receipt for something still running elsewhere.
  expect(
    foldsIntoRun(
      candidate({
        item: call({ key: "g", tool: "shell", output: "[background task s-1/t2 started] sleep 30\nlog: x" }),
        kind: "shell",
      }),
    ),
  ).toBe(false)
  // Cards whose whole point is what they show.
  for (const kind of ["edit", "evolve", "subsession", "checklist", "markdown"]) {
    expect(foldsIntoRun(candidate({ item: call({ key: `h-${kind}`, tool: "x" }), kind }))).toBe(false)
  }
})

/**
 * The opt-out a package has, and the reason there is no new manifest field for
 * it: a `render` claim already says "I have an opinion about how this looks".
 */
test("a package's render claim keeps its call out of the summary", () => {
  const item = call({ key: "a", tool: "propose" })
  expect(foldsIntoRun(candidate({ item }))).toBe(true)
  expect(foldsIntoRun(candidate({ item, render: "diff" }))).toBe(false)
  // And so does a package that draws the card in code.
  expect(foldsIntoRun(candidate({ item, drawnByPlugin: true }))).toBe(false)
})

test("runs need two calls, and anything else breaks them apart", () => {
  const a = call({ key: "a", tool: "read" })
  const b = call({ key: "b", tool: "read" })
  const failed = call({ key: "f", tool: "read", ok: false })
  const said: TranscriptItem = { key: "s", seq: 3, kind: "assistant", text: "done", streaming: false }
  const folds = (item: ToolItem) => item.ok !== false

  // One is not a run: summarising it would hide a command to save no rows.
  expect(groupRuns([a, said], folds).map((row) => row.kind)).toEqual(["item", "item"])
  expect(groupRuns([a, b, said], folds).map((row) => row.kind)).toEqual(["run", "item"])
  // The failure stands between them, and each side is too short to be a run.
  expect(groupRuns([a, failed, b], folds).map((row) => row.kind)).toEqual(["item", "item", "item"])
  // Off is one row per call again.
  expect(groupRuns([a, b], folds, false).map((row) => row.kind)).toEqual(["item", "item"])
})

test("a run says which tools it was, in the order they first appeared", () => {
  const items = [
    call({ key: "1", tool: "ext:std/read" }),
    call({ key: "2", tool: "ext:std/read" }),
    call({ key: "3", tool: "shell" }),
    call({ key: "4", tool: "ext:std/read" }),
    call({ key: "5", tool: "ext:std/grep" }),
  ]
  expect(runSummary(items)).toBe("read ×3 · shell · grep")
})

test("a call the grouping cannot read costs the run summary, not the screen", () => {
  // The projection runs above the per-row ErrorBoundary, so it has to be total
  // (BUGS.md #22): a ledger from before the kernel fix holds an `output` that
  // is not a string, and every fold rule does string work on it.
  const items = [
    call({ key: "a", tool: "shell", args: '{"command":"ls"}', output: "fine\n[exit 0]" }),
    call({ key: "b", tool: "shell", args: '{"command":"ls"}', output: [1, 2, 3] as unknown as string }),
  ] as TranscriptItem[]
  const rows = transcriptRows(items, createStyle(default_settings, {}), [])
  expect(rows.map((row) => row.key)).toEqual(["a", "b"])
})
