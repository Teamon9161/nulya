/**
 * The pointer (tui.md §11, T18).
 *
 * The mouse is the one input path nobody had automated, and the one place a
 * front end silently rots: a click target that drifts by a row when the box
 * scrolls looks fine in every screenshot and is wrong in every session. So the
 * things pinned here are the ones a frame cannot show — WHERE a click lands
 * after a scroll, that a drag is not a click, that an open overlay is not a
 * hole through to the transcript, and that clicking calls the same function the
 * key calls rather than a second copy of the behaviour.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { join } from "node:path"
import { For, createSignal, type JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { Card } from "../src/render/cards/index.tsx"
import { TabBar } from "../src/ui/TabBar.tsx"
import { SessionsView } from "../src/ui/overlays/SessionsView.tsx"
import { ExtView } from "../src/ui/overlays/ExtView.tsx"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { BrowseContext, createBrowseStore } from "../src/state/browse.ts"
import { createSessionState, type TranscriptItem } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { sessionAppend, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { sessionPins } from "../src/state/tui_state.ts"
import { unsafe_settings, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"
import type { SessionTab } from "../src/state/tabs.ts"

const style: Style = createStyle(unsafe_settings, {})

let ws: TempWorkspace
let first: string
let second: string
/** The first session's opening line: how its row is found on screen (T47). */
const said = "make the budgets configurable"

beforeAll(async () => {
  ws = tempWorkspace()
  first = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, first, "make the budgets configurable")
  const step = sessionStep(ws, first, { env: scripted_env })
  for await (const _ of step.lines) {
    // Give the first session a transcript so the row has something to show.
  }
  await step.exited
  second = await sessionNew(ws, { profile: "scripted" })

  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
  run(["ext", "init", "--script", "lint"])
  const built = run(["ext", "build", ".nulya/extensions/lint"])
  const version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0] ?? ""
  run(["ext", "activate", "lint", version])
}, 180_000)

afterAll(() => ws.cleanup())

function mount(node: () => JSX.Element, width = 100, height = 24) {
  return testRender(
    () => (
      <StyleContext.Provider value={style}>
        <FoldContext.Provider value={createFoldStore()}>
          <BrowseContext.Provider value={createBrowseStore()}>{node()}</BrowseContext.Provider>
        </FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width, height },
  )
}

function shellItem(key: string, command: string, output: string): TranscriptItem {
  return {
    kind: "tool",
    key,
    seq: 2,
    tool: "shell",
    callId: key,
    args: JSON.stringify({ command }),
    state: "done",
    ok: true,
    output,
    spillPath: null,
    resolved: true,
    awaiting: false,
    taskResult: null,
  }
}

test("a drag across a head line selects, it does not fold", async () => {
  const item = shellItem("c1", "zig build test", "running 12 tests")
  const setup = await mount(() => <Card item={item} />, 76, 12)
  try {
    expect(await settle(setup)).not.toContain("running 12 tests")
    // Press on the head line and release three cells away: that is a selection
    // gesture, and the card must be exactly as it was.
    await setup.mockMouse.drag(4, 0, 12, 0)
    expect(await settle(setup)).not.toContain("running 12 tests")
    // What the drag DID do: OpenTUI holds a selection over the cells crossed,
    // and its text is what `App` hands to the clipboard on release.
    // Exactly the cells crossed — the head line reads `$ zig build test` from
    // column 2, so columns 4 through 12 are `zig buil`.
    expect(setup.renderer.getSelection()?.getSelectedText() ?? "").toContain("zig buil")

    // The same two events in the same cell are a click, and it folds.
    await setup.mockMouse.click(4, 0)
    expect(await settle(setup)).toContain("running 12 tests")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a click lands on the card under it after the transcript has scrolled", async () => {
  // Ten cards, a viewport that holds a few of them: the card at screen row 0 is
  // NOT the first card, which is the whole point. Nothing in the front end
  // converts screen rows to items — OpenTUI hit-tests the renderable that is
  // actually painted there — and this is the test that says so.
  const items = Array.from({ length: 10 }, (_, i) =>
    shellItem(`c${i}`, `command number ${i}`, `body of command ${i}`),
  )
  const setup = await mount(
    () => (
      <scrollbox style={{ height: 6 }} height={6} width="100%">
        <For each={items}>{(item) => <Card item={item} />}</For>
      </scrollbox>
    ),
    76,
    8,
  )
  try {
    await settle(setup)
    const frame = await settle(setup)
    // Whatever the box chose to show, click the head line on the third row and
    // the card whose text is on that row is the one that opens.
    const rows = frame.split("\n")
    const at = rows.findIndex((row) => row.includes("command number"))
    expect(at).toBeGreaterThanOrEqual(0)
    const which = /command number (\d+)/.exec(rows[at]!)![1]!
    await setup.mockMouse.click(4, at)
    expect(await settle(setup)).toContain(`body of command ${which}`)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/sessions: a click selects the row, a second click opens it", async () => {
  const [opened, setOpened] = createSignal<string | null>(null)
  const setup = await mount(
    () => (
      <SessionsView ws={ws} currentId={first} onOpen={setOpened} onNew={() => {}} onClose={() => {}} />
    ),
    120,
    20,
  )
  try {
    await until(() => setup.captureCharFrame().includes(said), 20_000)
    const frame = await settle(setup, 6)
    const rows = frame.split("\n")
    // Newest first, so `first` is the SECOND row and the cursor starts above it.
    const at = rows.findIndex((row) => row.includes(said))
    expect(at).toBeGreaterThanOrEqual(0)
    expect(rows[at]!.trimStart().startsWith("▾")).toBe(false)

    // One click moves the cursor there and opens nothing…
    await setup.mockMouse.click(30, at)
    const moved = await settle(setup, 4)
    expect(moved.split("\n")[at]!.trimStart().startsWith("▾")).toBe(true)
    expect(opened()).toBeNull()

    // …a second one does what Enter does.
    await setup.mockMouse.click(30, at)
    await until(() => opened() !== null, 10_000)
    expect(opened()).toBe(first)
  } finally {
    setup.renderer.destroy()
  }
}, 90_000)

test("/sessions: the pointer marks the row it is over, and lets go of it", async () => {
  const setup = await mount(
    () => <SessionsView ws={ws} currentId={first} onOpen={() => {}} onNew={() => {}} onClose={() => {}} />,
    120,
    20,
  )
  try {
    await until(() => setup.captureCharFrame().includes(said), 20_000)
    const rows = (await settle(setup, 6)).split("\n")
    const at = rows.findIndex((row) => row.includes(said))
    expect(rows[at]!.trimStart().startsWith("·")).toBe(false)

    await setup.mockMouse.moveTo(30, at)
    expect((await settle(setup, 4)).split("\n")[at]!.trimStart().startsWith("·")).toBe(true)

    // Off the list entirely: the mark goes with the pointer.
    await setup.mockMouse.moveTo(30, rows.length - 2)
    expect((await settle(setup, 4)).split("\n")[at]!.trimStart().startsWith("·")).toBe(false)
  } finally {
    setup.renderer.destroy()
  }
}, 90_000)

test("/ext: clicking a pane name goes to it, clicking [x] pins the tool", async () => {
  const state = `${ws.dir}/tui-state.json`
  const setup = await mount(() => <ExtView ws={ws} header={null} statePath={state} onClose={() => {}} />, 120, 24)
  try {
    await until(() => setup.captureCharFrame().includes("extensions  versions  tools  usage"), 20_000)
    const strip = (await settle(setup, 6)).split("\n").findIndex((row) => row.includes("extensions  versions"))
    expect(strip).toBeGreaterThanOrEqual(0)

    // "tools" is the third word of the strip; click it rather than pressing `t`.
    const line = (await settle(setup, 2)).split("\n")[strip]!
    await setup.mockMouse.click(line.indexOf("tools") + 2, strip)
    await until(() => setup.captureCharFrame().includes("[ ] ext:lint/lint"), 10_000)
    expect(sessionPins(state)).not.toContain("ext:lint/lint")

    // The checkbox is its own target: clicking it is Space, and nothing else on
    // the row does that.
    const pane = (await settle(setup, 4)).split("\n")
    const row = pane.findIndex((text) => text.includes("[ ] ext:lint/lint"))
    expect(row).toBeGreaterThanOrEqual(0)
    await setup.mockMouse.click(pane[row]!.indexOf("[") + 1, row)
    await until(() => setup.captureCharFrame().includes("[x] ext:lint/lint"), 10_000)
    expect(sessionPins(state)).toContain("ext:lint/lint")

    // And again to take it off, so the click is a toggle and not a one-way door.
    await setup.mockMouse.click(pane[row]!.indexOf("[") + 1, row)
    await until(() => setup.captureCharFrame().includes("[ ] ext:lint/lint"), 10_000)
    expect(sessionPins(state)).not.toContain("ext:lint/lint")
  } finally {
    setup.renderer.destroy()
  }
}, 90_000)

test("the tab bar answers to a click, with the same select F4 uses", async () => {
  const [active, setActive] = createSignal(0)
  // A tab is named by what it runs on, not by its session id (tui.md §11, T22).
  const tab = (model: string) =>
    ({
      kind: "session",
      key: model,
      id: `s-${model}`,
      attach: { role: () => "driver" },
      state: { snapshot: { header: { model, model_identity: { model } } } },
    }) as unknown as SessionTab
  const tabs = [tab("alpha-1"), tab("beta-2")]
  const setup = await mount(
    () => <TabBar tabs={tabs} activeIndex={active()} onSelect={setActive} />,
    60,
    4,
  )
  try {
    const line = (await settle(setup, 4)).split("\n")[0]!
    expect(line).toContain("alpha-1")
    expect(line).not.toContain("s-alpha-1")
    await setup.mockMouse.click(line.indexOf("beta-2") + 1, 0)
    await until(() => active() === 1, 5_000)
    await setup.mockMouse.click(line.indexOf("alpha-1") + 1, 0)
    await until(() => active() === 0, 5_000)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("an open overlay is not a hole: a click where a card was folds nothing", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created />,
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 3)
    state.applyEvents([
      { seq: 1, kind: "user_text", text: "run the tests" } as never,
      {
        seq: 2,
        kind: "assistant",
        text: "",
        calls: [{ id: "t1", tool: "shell", args: JSON.stringify({ command: "zig build test" }) }],
      } as never,
      {
        seq: 3,
        kind: "tool_results",
        results: [{ call_id: "t1", ok: true, output: "running 12 tests", spill_path: null }],
      } as never,
    ])
    await until(() => setup.captureCharFrame().includes("zig build test"), 15_000)
    const head = (await settle(setup, 4)).split("\n").findIndex((row) => row.includes("zig build test"))
    expect(head).toBeGreaterThanOrEqual(0)

    // Open /help over the transcript. The transcript is not merely covered — it
    // is unmounted — so the click below has nothing of it to reach.
    setup.mockInput.pressKey("F1")
    await until(() => setup.captureCharFrame().includes("help · keys and commands"), 10_000)
    await setup.mockMouse.click(6, head)
    const covered = await settle(setup, 4)
    expect(covered).toContain("help · keys and commands")
    expect(covered).not.toContain("running 12 tests")

    // Close it and the card is exactly as it was: still folded, still clickable.
    setup.mockInput.pressEscape()
    await until(() => setup.captureCharFrame().includes("zig build test"), 10_000)
    expect(setup.captureCharFrame()).not.toContain("running 12 tests")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("clicking the input box leaves browse mode", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created />,
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 3)
    state.applyEvents([
      { seq: 1, kind: "user_text", text: "run the tests" } as never,
      {
        seq: 2,
        kind: "assistant",
        text: "",
        calls: [{ id: "t1", tool: "shell", args: JSON.stringify({ command: "zig build test" }) }],
      } as never,
      {
        seq: 3,
        kind: "tool_results",
        results: [{ call_id: "t1", ok: true, output: "running 12 tests", spill_path: null }],
      } as never,
    ])
    await until(() => setup.captureCharFrame().includes("zig build test"), 15_000)

    // Esc on an empty composer hands the keyboard to browse mode, which blurs
    // the textarea — so nothing the textarea does can get it back.
    setup.mockInput.pressEscape()
    await until(() => setup.captureCharFrame().includes("browse · j/k move"), 10_000)

    const rows = setup.captureCharFrame().split("\n")
    const box = rows.findIndex((row) => row.includes("message nulya"))
    expect(box).toBeGreaterThanOrEqual(0)
    await setup.mockMouse.click(20, box)
    await until(() => !setup.captureCharFrame().includes("browse · j/k move"), 10_000)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("the model is a click target wherever it is written: the line under the composer, the composition card — and the welcome rows and /help", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    // A state file of this test's own: the mode chip below is CHOSEN from, and
    // `/mode` remembers the choice (tui.md §7). Without this, picking `ask`
    // here would be picking it for every later test in the run that renders an
    // App without a state path — and their tool calls would sit waiting for a
    // person who is not there.
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, `tui-state-${id}.json`)}
        created
      />
    ),
    { width: 100, height: 30 },
  )
  const picker = "model · what the next session runs on"
  try {
    await until(() => setup.captureCharFrame().includes("frozen composition"), 15_000)
    const frame = await settle(setup, 4)
    const rows = frame.split("\n")

    // The bottom line, where tcode puts it (tui.md §11, T22): the model leads
    // it, and the model is the target. No session id, no provider name.
    // The frame ends with a newline, so the last row is the blank after it.
    const bar = rows.length - 2
    expect(rows[bar]).toContain("scripted-demo · tools 1+0")
    expect(rows[bar]).not.toContain(id)
    // No keyboard hints and no `/help` on it any more (T38): a reminder that
    // is always there is read once and then never again, and it was spending
    // the busiest line on the screen. The permission mode leads the line.
    expect(rows[bar]).not.toContain("Ctrl+O")
    expect(rows[bar]).not.toContain("/help")
    expect(rows[bar]).toContain("unsafe")
    await setup.mockMouse.click(rows[bar]!.indexOf("scripted-demo") + 2, bar)
    expect(await settle(setup, 4)).toContain(picker)
    setup.mockInput.pressEscape()
    expect(await settle(setup, 4)).toContain("frozen composition")

    // The composition card's `model` row: the same overlay, the same way in
    // (`openOverlay`, which also takes the keyboard from the composer).
    const card = rows.findIndex((row) => /model\s+scripted/.test(row))
    expect(card).toBeGreaterThan(0)
    await setup.mockMouse.click(rows[card]!.indexOf("scripted") + 3, card)
    expect(await settle(setup, 4)).toContain(picker)
    // The picker owns the keys now: `j` moves it, nothing lands in the composer.
    setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).not.toMatch(/›\s*j\s*$/m)
    setup.mockInput.pressEscape()
    expect(await settle(setup, 4)).toContain("frozen composition")

    // A welcome row runs its command exactly as typing it would.
    const sessionsRow = rows.findIndex((row) => row.includes("/sessions") && row.includes("everything in .nulya/sessions"))
    expect(sessionsRow).toBeGreaterThan(0)
    await setup.mockMouse.click(4, sessionsRow)
    await until(() => setup.captureCharFrame().includes("sessions ·"), 10_000)
    setup.mockInput.pressEscape()
    expect(await settle(setup, 4)).toContain("frozen composition")

    // …and so does `/help`, the last of the welcome rows.
    const helpRow = rows.findIndex((row) => row.includes("/help") && row.includes("every key and every command"))
    expect(helpRow).toBeGreaterThan(0)
    await setup.mockMouse.click(4, helpRow)
    expect(await settle(setup, 4)).toContain("help · keys and commands")
    setup.mockInput.pressEscape()
    expect(await settle(setup, 4)).toContain("frozen composition")

    // The permission mode is on that line too, and clicking it OPENS THE
    // PICKER rather than flipping the mode (tui.md §11, T31): a chip that
    // silently changed how every tool call is treated, in one click, with the
    // two words never spelled out anywhere, was the worst kind of quiet.
    const chip = rows[bar]!.lastIndexOf("unsafe")
    expect(chip).toBeGreaterThan(0)
    await setup.mockMouse.click(chip + 1, bar)
    const modeRows = await settle(setup, 4)
    expect(modeRows).toContain("permission mode")
    expect(modeRows).toContain("ask before every tool call no rule settles")
    // …and clicking a row in it is an answer, as in the approval dialog.
    const askRow = modeRows.split("\n").findIndex((line) => line.includes("ask before every tool call"))
    await setup.mockMouse.click(6, askRow)
    const after = await settle(setup, 4)
    expect(after).not.toContain("permission mode")
    expect(after.split("\n")[bar]).toContain("ask")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
