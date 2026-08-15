/**
 * Frame tests over the real test renderer (tui.md §8). Two things are pinned
 * here: each card's shape, and the property the whole design rests on — live
 * and replay draw the same frame.
 *
 * Keyboard interaction is driven programmatically (`mockInput`) rather than by
 * hand, so an unattended run still proves Enter sends and Ctrl+O folds.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { For } from "solid-js"
import { testRender } from "@opentui/solid"
import { Card } from "../src/render/cards/index.tsx"
import { App } from "../src/ui/App.tsx"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { createSessionState, type TranscriptItem } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { sessionAppend, sessionEvents, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style: Style = createStyle(default_settings, {})
const narrow: Style = createStyle({ ...default_settings, transcript: { ...default_settings.transcript, max_width: 40 } }, {})

function Harness(props: { items: TranscriptItem[]; style?: Style }) {
  return (
    <StyleContext.Provider value={props.style ?? style}>
      <FoldContext.Provider value={createFoldStore()}>
        <box flexDirection="column" width="100%">
          <For each={props.items}>{(item) => <Card item={item} />}</For>
        </box>
      </FoldContext.Provider>
    </StyleContext.Provider>
  )
}

const user_item: TranscriptItem = { key: "e1", seq: 1, kind: "user", text: "make emit budgets configurable", queued: false }
const queued_item: TranscriptItem = { key: "q1", seq: null, kind: "user", text: "and write it to default.toml", queued: true }
const assistant_item: TranscriptItem = { key: "e2", seq: 2, kind: "assistant", text: "Reading `emit.zig` first.", streaming: false }
const thinking_item: TranscriptItem = { key: "e2:thinking", seq: 2, kind: "thinking", text: "weigh the options", opaque: false }
const shell_item: TranscriptItem = {
  key: "e2:c1",
  seq: 2,
  kind: "tool",
  callId: "c1",
  tool: "shell",
  args: JSON.stringify({ command: "zig build test" }),
  state: "done",
  ok: false,
  output: "running 12 tests\n--- stderr ---\ntest failure in emit.zig\n[exit 1]",
  spillPath: null,
  resolved: true,
}
const evolve_item: TranscriptItem = {
  ...(shell_item as Extract<TranscriptItem, { kind: "tool" }>),
  key: "e4:c2",
  callId: "c2",
  args: JSON.stringify({ command: "nulya ext build .nulya/extensions/lint" }),
  ok: true,
  output: "sealed lint@v-3f2a91\n[exit 0]",
}
const edit_item: TranscriptItem = {
  key: "e6:c3",
  seq: 6,
  kind: "tool",
  callId: "c3",
  tool: "edit",
  args: JSON.stringify({
    path: "src/emit.zig",
    old_string: "pub const head_bytes = 4096;",
    new_string: "pub const head_bytes = 4096; // default\npub const tail_bytes = 2048;",
  }),
  state: "done",
  ok: true,
  output: "edited src/emit.zig",
  spillPath: null,
  resolved: true,
}
const canceled_item: TranscriptItem = {
  key: "e8:c4",
  seq: 8,
  kind: "tool",
  callId: "c4",
  tool: "shell",
  args: JSON.stringify({ command: "sleep 60" }),
  state: "done",
  ok: false,
  output: "tool execution was canceled; side effects may be partial or unknown",
  spillPath: null,
  resolved: true,
}
const spill_item: TranscriptItem = {
  key: "e9:c5",
  seq: 9,
  kind: "tool",
  callId: "c5",
  tool: "shell",
  args: JSON.stringify({ command: "rg -n fn src" }),
  state: "done",
  ok: true,
  output: "…clipped…\n[exit 0]",
  spillPath: ".nulya/scratch/spill-9.txt",
  resolved: true,
}
const capability_item: TranscriptItem = {
  key: "e10",
  seq: 10,
  kind: "capability",
  id: "lint",
  version: "v-3f2a91",
  text: "tools: lint_zig\nusage: nulya ext run lint lint_zig '<json>'",
}

async function frameOf(items: TranscriptItem[], width = 76, height = 24, theme = style): Promise<string> {
  const setup = await testRender(() => <Harness items={items} style={theme} />, { width, height })
  try {
    return await settle(setup)
  } finally {
    setup.renderer.destroy()
  }
}

test("user and assistant turns", async () => {
  const frame = await frameOf([user_item, assistant_item, queued_item])
  expect(frame).toContain("› make emit budgets configurable")
  expect(frame).toContain("● Reading")
  expect(frame).toContain("· queued")
  expect(frame).toMatchSnapshot()
})

test("thinking is collapsed by default and names its size", async () => {
  const frame = await frameOf([thinking_item])
  expect(frame).toContain("▸ thinking · 17 chars")
  expect(frame).not.toContain("weigh the options")
  expect(frame).toMatchSnapshot()
})

test("shell output is collapsed, with an exit chip", async () => {
  const frame = await frameOf([shell_item])
  expect(frame).toContain("$ zig build test")
  expect(frame).toContain("exit 1")
  expect(frame).not.toContain("test failure in emit.zig")
  expect(frame).toMatchSnapshot()
})

test("an expanded shell card shows stdout and stderr", async () => {
  const expanded = createStyle(
    { ...default_settings, transcript: { ...default_settings.transcript, tool_output: "expanded" } },
    {},
  )
  const frame = await frameOf([shell_item], 76, 24, expanded)
  expect(frame).toContain("running 12 tests")
  expect(frame).toContain("test failure in emit.zig")
})

test("a `nulya …` command reads as an evolution action", async () => {
  const frame = await frameOf([evolve_item])
  expect(frame).toContain("⚙ nulya ext build")
  expect(frame).toMatchSnapshot()
})

test("edit renders its diff expanded by default", async () => {
  const frame = await frameOf([edit_item])
  expect(frame).toContain("✎ src/emit.zig")
  expect(frame).toContain("pub const tail_bytes = 2048;")
  expect(frame).toMatchSnapshot()
})

test("edit_diff = collapsed hides the diff", async () => {
  const collapsed = createStyle(
    { ...default_settings, transcript: { ...default_settings.transcript, edit_diff: "collapsed" } },
    {},
  )
  const frame = await frameOf([edit_item], 76, 24, collapsed)
  expect(frame).toContain("✎ src/emit.zig")
  expect(frame).not.toContain("pub const tail_bytes = 2048;")
})

test("a canceled call is recognised by its marker, not by any stream line", async () => {
  const frame = await frameOf([canceled_item])
  expect(frame).toContain("⊘ sleep 60")
  expect(frame).toContain("canceled · side effects unknown")
  expect(frame).toMatchSnapshot()
})

test("a spilled result points at its file", async () => {
  const frame = await frameOf([spill_item])
  expect(frame).toContain("full output → .nulya/scratch/spill-9.txt")
})

test("capability notes are expanded and carry the evolve accent", async () => {
  const frame = await frameOf([capability_item])
  expect(frame).toContain("⚡ capability · lint@v-3f2a91")
  expect(frame).toContain("tools: lint_zig")
  expect(frame).toMatchSnapshot()
})

test("a narrow viewport drops the right-hand chip", async () => {
  const frame = await frameOf([shell_item], 48, 12, narrow)
  expect(frame).toContain("$ zig build test")
  expect(frame).not.toContain("exit 1")
})

test("ascii mode degrades every glyph", async () => {
  const ascii = createStyle({ ...default_settings, transcript: { ...default_settings.transcript, ascii: true } }, {})
  const frame = await frameOf([user_item, capability_item], 76, 16, ascii)
  expect(frame).toContain("> make emit budgets configurable")
  expect(frame).toContain("! capability · lint@v-3f2a91")
  expect(frame).not.toContain("›")
})

// --- live vs replay, and the App under programmatic keys ---------------------

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

test("the same session renders identically live and replayed", async () => {
  const id = await sessionNew(ws, { model: "scripted" })
  await sessionAppend(ws, id, "probe the environment")

  const live = createSessionState(id)
  const step = sessionStep(ws, id, { env: scripted_env })
  for await (const line of step.lines) {
    if (line.kind === "stream") live.applyStream(line.line)
    else live.applyEvent(line.event)
  }
  await step.exited

  const replay = createSessionState(id)
  replay.applyEvents(await sessionEvents(ws, id))

  const liveFrame = await frameOf(live.snapshot.items as TranscriptItem[])
  const replayFrame = await frameOf(replay.snapshot.items as TranscriptItem[])
  expect(replayFrame).toBe(liveFrame)
  expect(liveFrame).toContain("hello-from-nulya".slice(0, 5))
}, 60_000)

test("typing and pressing Enter drives a real step", async () => {
  const id = await sessionNew(ws, { model: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} />,
    { width: 80, height: 24 },
  )
  try {
    await settle(setup, 4)
    await setup.mockInput.typeText("read the kernel")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).toContain("read the kernel")

    setup.mockInput.pressEnter()
    await until(() => state.snapshot.items.some((item) => item.kind === "assistant" && item.seq !== null))
    const frame = await settle(setup, 6)

    // The user turn was promoted out of `queued`, the tool card is there, and
    // the assistant's closing turn arrived — one full run, through the binary.
    expect(frame).toContain("› read the kernel")
    expect(frame).not.toContain("queued")
    expect(frame).toContain("$ echo hello-from-nulya")
    expect(state.snapshot.lastStopped).toBe("end_turn")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/** Rows between the two hairlines: the transcript, without the status bar's counters. */
function transcriptOf(frame: string): string {
  const rows = frame.split("\n")
  const rule = rows.findIndex((row) => row.startsWith("──"))
  const end = rows.findIndex((row, index) => index > rule && row.startsWith("──"))
  return rows.slice(rule + 1, end).join("\n")
}

test("closing and reopening with --session paints the same transcript", async () => {
  const id = await sessionNew(ws, { model: "scripted" })
  const first = createSessionState(id)
  const live = await testRender(
    () => <App ws={ws} id={id} state={first} style={style} driver={{ env: scripted_env }} />,
    { width: 80, height: 24 },
  )
  let liveFrame: string
  try {
    await settle(live, 4)
    await live.mockInput.typeText("probe the environment")
    live.mockInput.pressEnter()
    await until(() => first.snapshot.lastStopped !== null)
    liveFrame = transcriptOf(await settle(live, 6))
  } finally {
    live.renderer.destroy()
  }

  // A second process opening the same id sees only what the ledger holds.
  const second = createSessionState(id)
  const reopened = await testRender(
    () => <App ws={ws} id={id} state={second} style={style} driver={{ env: scripted_env }} />,
    { width: 80, height: 24 },
  )
  try {
    await until(() => second.snapshot.items.length >= first.snapshot.items.length)
    expect(transcriptOf(await settle(reopened, 6))).toBe(liveFrame)
  } finally {
    reopened.renderer.destroy()
  }
}, 120_000)

test("Ctrl+O expands the most recent tool card", async () => {
  const id = await sessionNew(ws, { model: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} />,
    { width: 80, height: 24 },
  )
  try {
    await settle(setup, 4)
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved))
    // Collapsed: the command echoes the string once, in the head line only.
    const occurrences = (frame: string) => frame.split("hello-from-nulya").length - 1
    expect(occurrences(await settle(setup, 5))).toBe(1)

    setup.mockInput.pressKey("o", { ctrl: true })
    // Expanded: the head line plus the captured stdout.
    expect(occurrences(await settle(setup, 5))).toBe(2)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
