/**
 * Frame tests over the real test renderer (tui.md §8). Two things are pinned
 * here: each card's shape, and the property the whole design rests on — live
 * and replay draw the same frame.
 *
 * Keyboard interaction is driven programmatically (`mockInput`) rather than by
 * hand, so an unattended run still proves Enter sends and Ctrl+O folds.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { For, type JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { Transcript, gapBefore } from "../src/ui/Transcript.tsx"
import { CompositionCard } from "../src/render/cards/CompositionCard.tsx"
import { App } from "../src/ui/App.tsx"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { createSessionState, type TranscriptItem } from "../src/state/session.ts"
import { default_settings, loadSettings } from "../src/state/settings.ts"
import type { SessionHeader } from "../src/nulya/ledger.ts"
import { sessionAppend, sessionEvents, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { auto_settings, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"
import { wrapSkillEcho } from "../src/skills.ts"

const style: Style = createStyle(auto_settings, {})
const narrow: Style = createStyle({ ...default_settings, transcript: { ...default_settings.transcript, max_width: 40 } }, {})

/**
 * The cards as the screen actually stacks them. It goes through `Transcript`
 * rather than mapping `Card` itself, because the blank rows BETWEEN cards are
 * part of what these snapshots are pinning (T26) and they are decided there.
 */
function Harness(props: { items: TranscriptItem[]; style?: Style }) {
  return (
    <StyleContext.Provider value={props.style ?? style}>
      <FoldContext.Provider value={createFoldStore()}>
        <Transcript items={props.items} />
      </FoldContext.Provider>
    </StyleContext.Provider>
  )
}

/** A card rendered on its own, for the rows of §4.2 that are not ledger events. */
async function frameOfNode(node: () => JSX.Element, width = 76, height = 16, theme = style): Promise<string> {
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={theme}>
        <FoldContext.Provider value={createFoldStore()}>{node()}</FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width, height },
  )
  try {
    return await settle(setup)
  } finally {
    setup.renderer.destroy()
  }
}

/** One shell call, with only the parts a card reads varied. */
function shellItem(over: { key: string; command: string; output?: string; ok?: boolean }): TranscriptItem {
  return {
    key: over.key,
    seq: 2,
    kind: "tool",
    callId: over.key,
    tool: "shell",
    args: JSON.stringify({ command: over.command }),
    state: "done",
    ok: over.ok ?? true,
    output: over.output ?? "[exit 0]",
    spillPath: null,
    resolved: true,
    awaiting: false,
  }
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
  awaiting: false,
}
const evolve_item = shellItem({
  key: "e4:c2",
  command: "nulya ext build .nulya/extensions/lint",
  output: ".nulya/extensions/lint: v-3f2a91 (built)\n[exit 0]",
})
const ext_tool_item: TranscriptItem = {
  key: "e5:c9",
  seq: 5,
  kind: "tool",
  callId: "c9",
  tool: "lint_zig",
  args: JSON.stringify({ path: "src/emit.zig" }),
  state: "done",
  ok: true,
  output: "src/emit.zig: 0 findings",
  spillPath: null,
  resolved: true,
  awaiting: false,
}
const header_fixture: SessionHeader = {
  kind: "header",
  v: 1,
  session: "s-1786815442964-8462dd",
  parent: { session: "s-1786800870313-bf37ef", seq: 41 },
  model: "anthropic",
  model_identity: {
    provider: "anthropic",
    model: "claude-sonnet-5",
    base_url: "https://api.anthropic.com",
    api_key_env: "ANTHROPIC_API_KEY",
  },
  created: "2026-08-16T14:02:11Z",
  composition: { active: [{ id: "lint", version: "v-3f2a91" }], native_tools: ["ext:lint/lint_zig"] },
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
  awaiting: false,
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
  awaiting: false,
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
  awaiting: false,
}
// Verbatim `extension/notes.zig` shape: the banner reads its head line off it.
const capability_item: TranscriptItem = {
  key: "e10",
  seq: 10,
  kind: "capability",
  id: "lint",
  version: "v-3f2a91",
  text: [
    "New capabilities from extension `lint` version `v-3f2a91` are now available:",
    "",
    "Tools:",
    "- lint_zig — Lint Zig sources.",
    "  invoke: nulya ext run lint <tool> '<json-args>'",
    "",
    "Skills:",
    "- zig-style — House Zig style.",
    "  load: nulya skill load lint/zig-style",
    "",
  ].join("\n"),
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

test("a skill echo folds back to the `/name args` that was typed", async () => {
  // What lands in the ledger is the whole body, wrapped; what the transcript
  // shows is the line the person typed. Both readings come from the same bytes,
  // which is why replay and live agree without either being told.
  const item: TranscriptItem = {
    kind: "user",
    key: "skill-1",
    seq: 4,
    queued: false,
    text: wrapSkillEcho("guide", "how do extensions work", "First.\nSecond.\nThird."),
  }
  const frame = await frameOf([item])
  expect(frame).toContain("/guide how do extensions work · 3 lines")
  expect(frame).not.toContain("Second.")
  expect(frame).toMatchSnapshot()
})

test("thinking is collapsed by default and names its size", async () => {
  const frame = await frameOf([thinking_item])
  expect(frame).toContain("⋯ thinking  (17 chars) ▸")
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

test("an extension tool call carries the ⌘ glyph and an argument digest", async () => {
  const frame = await frameOf([ext_tool_item])
  expect(frame).toContain("⌘ lint_zig · src/emit.zig")
  // A call that worked says how much it brought back and nothing else: the
  // word `ok` on every successful line was noise (T26).
  expect(frame).toContain("(1 line)")
  expect(frame).not.toContain("ok")
  expect(frame).not.toContain("0 findings")
  expect(frame).toMatchSnapshot()
})

test("a `nulya …` command reads as an evolution action", async () => {
  const frame = await frameOf([evolve_item])
  expect(frame).toContain("⚙ ext build · lint → v-3f2a91")
  expect(frame).toMatchSnapshot()
})

// One frame per row of the §5.2 evolution table: these head lines are the
// difference between "the agent ran a command" and "the agent grew".
test("every evolution action in §5.2 has its own head line", async () => {
  const frame = await frameOf(
    [
      shellItem({ key: "v1", command: "nulya src emit.zig", output: "pub const head_bytes = 4096;\n[exit 0]" }),
      shellItem({
        key: "v2",
        command: "nulya ext init lint",
        output: "initialized extension 'lint' at .nulya/extensions/lint\n[exit 0]",
      }),
      shellItem({
        key: "v3",
        command: "nulya ext build .nulya/extensions/lint",
        output: ".nulya/extensions/lint: v-3f2a91 (built)\n[exit 0]",
      }),
      shellItem({ key: "v4", command: "nulya ext activate lint v-3f2a91", output: "lint: current -> v-3f2a91\n[exit 0]" }),
      // Going back is the same verb aimed at an older version (DESIGN §7.4),
      // so it draws the same head line — there is no second glyph for it.
      shellItem({ key: "v5", command: "nulya ext activate lint v-0011aa", output: "lint: current -> v-0011aa\n[exit 0]" }),
      shellItem({ key: "v6", command: "nulya ext run lint lint_zig '{\"path\":\"src\"}'", output: "0 findings\n[exit 0]" }),
      shellItem({ key: "v7", command: "nulya skill load evolution/zig-style", output: "# Zig style\n[exit 0]" }),
    ],
    76,
    20,
  )
  expect(frame).toContain("⌕ read kernel · emit.zig")
  expect(frame).toContain("⚙ ext init · lint → .nulya/extensions/lint")
  expect(frame).toContain("⚙ ext build · lint → v-3f2a91")
  expect(frame).toContain("⚡ activate · lint@v-3f2a91")
  expect(frame).toContain("⚡ activate · lint@v-0011aa")
  expect(frame).toContain("⌘ ext run · lint/lint_zig")
  expect(frame).toContain("☰ skill · evolution/zig-style")
  expect(frame).toMatchSnapshot()
})

test("a sub-session names the session it drives", async () => {
  const frame = await frameOf(
    [
      shellItem({ key: "s1", command: "nulya session new --model scripted", output: "s-1786815442964-8462dd\n[exit 0]" }),
      shellItem({ key: "s2", command: "nulya session step s-1786815442964-8462dd", output: "[exit 0]" }),
    ],
    76,
    12,
  )
  expect(frame).toContain("⤷ sub-session · s-1786815442964-8462dd")
  expect(frame).toContain("⤷ sub-session step · s-1786815442964-8462dd")
  expect(frame).toMatchSnapshot()
})

/** The two packages the card fixtures are written against. */
const card_contributions = [
  { id: "lint", version: "v-3f2a91", tools: ["lint_zig"], readonlyTools: [], skills: ["skills/zig-style"], systemPrompts: [] },
  // A `--with` package: no tool, no skill, one prompt — worn for this
  // session only, and the card has to say so (DESIGN §7.5).
  { id: "evolution", version: "v-db04b7", tools: [], readonlyTools: [], skills: [], systemPrompts: ["prompts/evolution.md"] },
]

const expanded_card = createStyle(
  { ...default_settings, transcript: { ...default_settings.transcript, composition: "expanded" } },
  {},
)

test("the composition card is two lines at rest: what this session is, and what it carries", async () => {
  const frame = await frameOfNode(() => (
    <CompositionCard header={header_fixture} contributions={card_contributions} />
  ))
  expect(frame).toContain("session · 2026-08-16 14:02 · frozen composition")
  expect(frame).toContain("model    anthropic/claude-sonnet-5 · tools 2+1 · skills 1 · prompts 1")
  // Everything below the model row is provenance, and it is behind the fold.
  expect(frame).not.toContain("shell edit ⚡lint_zig")
  expect(frame).not.toContain("lint@v-3f2a91")
  expect(frame).not.toContain("parent s-1786800870313-bf37ef:41")
  expect(frame).toMatchSnapshot()
})

test("opened, the composition card shows what this session froze", async () => {
  const frame = await frameOfNode(
    () => <CompositionCard header={header_fixture} contributions={card_contributions} />,
    76,
    16,
    expanded_card,
  )
  expect(frame).toContain("session · 2026-08-16 14:02 · frozen composition")
  expect(frame).toContain("shell edit ⚡lint_zig")
  expect(frame).toContain("skills   zig-style")
  expect(frame).toContain("prompts  evolution")
  expect(frame).toContain("anthropic/claude-sonnet-5 · api.anthropic.com")
  expect(frame).toContain("lint@v-3f2a91")
  expect(frame).toContain("parent   s-1786800870313-bf37ef:41")
  expect(frame).toMatchSnapshot()
})

test("the composition card wraps its rows instead of letting them be shrunk", async () => {
  // At 40 columns the old flex rows were SHRUNK — names cut mid-word, the
  // space between label and value swallowed (`model` came out as `mode`). Every
  // row is a label column and a wrapping value now, so nothing is ever cut.
  const frame = await frameOfNode(
    () => (
      <CompositionCard
        header={{
          ...header_fixture,
          composition: {
            active: [
              { id: "compact", version: "v-0258f08e338c94179b855776" },
              { id: "std", version: "v-04322ca65993627ff40136c6" },
            ],
            native_tools: ["ext:std/read", "ext:std/write", "ext:std/grep"],
          },
        }}
        contributions={card_contributions}
      />
    ),
    40,
    16,
    expanded_card,
  )
  expect(frame).not.toContain("mode ")
  expect(frame).toContain("model")
  // Long hashes are cut to an identity, and the list wraps at its ` · ` joints.
  expect(frame).toContain("compact@v-0258f08e")
  expect(frame).toContain("std@v-04322ca6")
  expect(frame).not.toContain("0258f08e338c94179b855776")
  for (const line of frame.split("\n")) expect(line.length).toBeLessThanOrEqual(41)
})

test("the fold default is a setting, and a click on the head line overrides it", async () => {
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <FoldContext.Provider value={createFoldStore()}>
          <CompositionCard header={header_fixture} contributions={card_contributions} />
        </FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width: 76, height: 16 },
  )
  try {
    const frame = await settle(setup)
    const head = frame.split("\n").findIndex((row) => row.includes("frozen composition"))
    expect(head).toBeGreaterThanOrEqual(0)
    await setup.mockMouse.click(10, head)
    expect(await settle(setup, 2)).toContain("lint@v-3f2a91")
    await setup.mockMouse.click(10, head)
    expect(await settle(setup, 2)).not.toContain("lint@v-3f2a91")
  } finally {
    setup.renderer.destroy()
  }
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

/**
 * The whole point of `tui.toml` (tui.md §7): a real file in a real workspace
 * changes what the transcript looks like. Asserting on a hand-built settings
 * object would only test the renderer — this walks the actual path.
 */
test("a project tui.toml flips the edit diff default", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-cfg-"))
  try {
    const before = await loadSettings(dir, {})
    expect(before.transcript.edit_diff).toBe("expanded")
    expect(await frameOf([edit_item], 76, 24, createStyle(before, {}))).toContain("pub const tail_bytes = 2048;")

    mkdirSync(join(dir, ".nulya"), { recursive: true })
    writeFileSync(join(dir, ".nulya", "tui.toml"), '[transcript]\nedit_diff = "collapsed"\nthinking = "expanded"\n')

    const after = await loadSettings(dir, {})
    expect(after.transcript.edit_diff).toBe("collapsed")
    expect(after.transcript.thinking).toBe("expanded")
    expect(after.sources.some((source) => source.endsWith("tui.toml"))).toBe(true)

    const frame = await frameOf([edit_item, thinking_item], 76, 24, createStyle(after, {}))
    expect(frame).toContain("✎ src/emit.zig")
    expect(frame).not.toContain("pub const tail_bytes = 2048;")
    // The same file moves thinking the other way, so this is the setting and
    // not just "everything collapsed".
    expect(frame).toContain("weigh the options")
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("the transcript's rhythm: two rows before a person, one between beats, none inside a run", async () => {
  const run = (key: string, command: string) => shellItem({ key, command, output: "ok\n[exit 0]" })
  const items: TranscriptItem[] = [user_item, thinking_item, assistant_item, run("r1", "ls"), run("r2", "pwd"), user_item]
  // The pure function first: it is the whole of the rhythm (T26).
  expect(items.map((item, index) => gapBefore(items[index - 1], item))).toEqual([1, 1, 0, 1, 0, 2])
  const frame = await frameOf(items, 76, 20)
  const rows = frame.split("\n").map((row) => row.trimEnd())
  const ls = rows.findIndex((row) => row.includes("$ ls"))
  // The two calls of one run are neighbours; the sentence above them is not.
  expect(rows[ls + 1]).toContain("$ pwd")
  expect(rows[ls - 1]).toBe("")
})

test("clicking a card's head line folds it", async () => {
  const setup = await testRender(() => <Harness items={[shell_item]} />, { width: 76, height: 12 })
  try {
    // Row 0 is the transcript's leading blank; the card starts on row 1 (T26).
    expect(await settle(setup)).not.toContain("running 12 tests")
    await setup.mockMouse.click(4, 1)
    expect(await settle(setup)).toContain("running 12 tests")
    await setup.mockMouse.click(4, 1)
    expect(await settle(setup)).not.toContain("running 12 tests")
  } finally {
    setup.renderer.destroy()
  }
})

test("a canceled call is recognised by its marker, not by any stream line", async () => {
  const frame = await frameOf([canceled_item])
  expect(frame).toContain("⊘ sleep 60")
  expect(frame).toContain("canceled · side effects unknown")
  expect(frame).toMatchSnapshot()
})

test("each cancellation marker says something different about the world", async () => {
  const frame = await frameOf(
    [
      shellItem({ key: "x1", command: "sleep 60", ok: false, output: "tool execution was canceled; side effects may be partial or unknown" }),
      shellItem({ key: "x2", command: "zig build", ok: false, output: "tool execution completed, but result recording was canceled" }),
      shellItem({ key: "x3", command: "zig build test", ok: false, output: "not executed because the step was canceled" }),
      shellItem({ key: "x4", command: "rm -rf tmp", ok: false, output: "previous tool execution was interrupted before Nulya recorded results" }),
    ],
    84,
    12,
  )
  expect(frame).toContain("canceled · side effects unknown")
  expect(frame).toContain("canceled · completed but unrecorded")
  expect(frame).toContain("canceled · not executed")
  expect(frame).toContain("interrupted · results unrecorded")
  expect(frame).toMatchSnapshot()
})

test("a spilled result points at its file", async () => {
  const frame = await frameOf([spill_item])
  expect(frame).toContain("full output → .nulya/scratch/spill-9.txt")
  expect(frame).toMatchSnapshot()
})

test("capability notes are expanded and name what arrived", async () => {
  const frame = await frameOf([capability_item], 96)
  expect(frame).toContain("⚡ capability · lint@v-3f2a91 · tools: lint_zig · skills: zig-style")
  // The note the model itself was given, verbatim underneath.
  expect(frame).toContain("- lint_zig — Lint Zig sources.")
  expect(frame).toMatchSnapshot()
})

test("a narrow viewport cuts the head, never the state word", async () => {
  // The note used to be dropped whole below 60 columns, which took `exit 1`
  // off the screen — the one thing on that line worth carrying to a phone-sized
  // terminal. It stays now; the command gives up columns instead (T26).
  const frame = await frameOf([shell_item], 48, 12, narrow)
  expect(frame).toContain("exit 1")
  expect(frame).toContain("$ zig build")
  for (const line of frame.split("\n")) expect(line.length).toBeLessThanOrEqual(49)
})

test("ascii mode degrades every glyph", async () => {
  const ascii = createStyle({ ...default_settings, transcript: { ...default_settings.transcript, ascii: true } }, {})
  const frame = await frameOf([user_item, capability_item, evolve_item, edit_item], 76, 24, ascii)
  expect(frame).toContain("> make emit budgets configurable")
  expect(frame).toContain("! capability · lint@v-3f2a91")
  expect(frame).toContain("+ ext build · lint → v-3f2a91")
  expect(frame).toContain("~ src/emit.zig")
  expect(frame).not.toContain("›")
  expect(frame).not.toContain("⚙")
  expect(frame).toMatchSnapshot()
})

test("the composition card degrades to ascii too", async () => {
  const ascii = createStyle(
    { ...default_settings, transcript: { ...default_settings.transcript, ascii: true, composition: "expanded" } },
    {},
  )
  const frame = await frameOfNode(
    () => <CompositionCard header={header_fixture} contributions={[]} />,
    76,
    12,
    ascii,
  )
  expect(frame).toContain("| session · 2026-08-16 14:02 · frozen composition")
  expect(frame).toContain("shell edit !lint_zig")
  expect(frame).not.toContain("▎")
  // The fold marker too: ascii has its own pair (`v` / `>`).
  expect(frame).not.toContain("▾")
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
  const id = await sessionNew(ws, { profile: "scripted" })
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
  const id = await sessionNew(ws, { profile: "scripted" })
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

/**
 * Everything above the composer's box — the transcript, without the status
 * bar's counters (a live run has stepped, a reopened one has not). The two
 * hairlines this used to slice between are gone: the box's own border is the
 * only line drawn between the regions now (T26).
 */
function transcriptOf(frame: string): string {
  const rows = frame.split("\n")
  const box = rows.findIndex((row) => row.trimStart().startsWith("╭"))
  return rows.slice(0, box < 0 ? rows.length : box).join("\n")
}

test("closing and reopening with --session paints the same transcript", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
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
  const id = await sessionNew(ws, { profile: "scripted" })
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

test("Esc on an empty composer opens browse mode, where Enter folds a card", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
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
    const occurrences = (frame: string) => frame.split("hello-from-nulya").length - 1
    expect(occurrences(await settle(setup, 5))).toBe(1)

    // Nothing is running and nothing is typed, so Esc hands the keyboard to the
    // transcript rather than canceling (tui.md §4.2).
    setup.mockInput.pressEscape()
    expect(await settle(setup, 3)).toContain("browse · j/k move")

    setup.mockInput.pressEnter()
    expect(occurrences(await settle(setup, 5))).toBe(2)

    setup.mockInput.pressEscape()
    expect(await settle(setup, 3)).not.toContain("browse · j/k move")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
