/**
 * The pointer.
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
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { For, createSignal, type JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { Card } from "../src/render/cards/index.tsx"
import { TabBar, stripPlan, min_tab_label } from "../src/ui/TabBar.tsx"
import { SessionsView } from "../src/ui/overlays/SessionsView.tsx"
import { ExtView } from "../src/ui/overlays/ExtView.tsx"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { lifted, rowBackground } from "../src/ui/rows.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { BrowseContext, createBrowseStore } from "../src/state/browse.ts"
import { createSessionState, type TranscriptItem } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { sessionAppend, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { sessionSelection } from "../src/state/tui_state.ts"
import { unsafe_settings, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"
import type { SessionTab } from "../src/state/tabs.ts"

const style: Style = createStyle(unsafe_settings, {})

let ws: TempWorkspace
let first: string
let second: string
/** The first session's opening line: how its row is found on screen. */
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
  // A turn of its own: a session with NO events is not listed (`sessionKind`),
  // and this fixture needs two rows to click between.
  await sessionAppend(ws, second, "rename the toolchain flag")
  const second_step = sessionStep(ws, second, { env: scripted_env })
  for await (const _ of second_step.lines) {
    // Drained for the same reason as the first.
  }
  await second_step.exited

  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
  run(["ext", "init", "--script", "lint"])
  // The template writes no `surface`, which now means `auto` — a tool the model
  // gets with membership and that no pin may name. These
  // tests are about PINNING, so the fixture says `manual` out loud.
  const lint_draft = join(ws.dir, ".nulya", "extensions", "lint", "extension.json")
  const lint_manifest = JSON.parse(readFileSync(lint_draft, "utf8")) as {
    contributes: { tools: Array<Record<string, unknown>> }
  }
  lint_manifest.contributes.tools[0]!["surface"] = "manual"
  writeFileSync(lint_draft, JSON.stringify(lint_manifest, null, 2))
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
    autoAllowed: false,
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

test("/sessions: one click goes to that session, two give it a tab of its own", async () => {
  // What is pinned here is that the two gestures are two
  // DIFFERENT verbs — the reason the single click has to wait out the double
  // click window rather than firing and being amended.
  const [went, setWent] = createSignal<string | null>(null)
  const [tabbed, setTabbed] = createSignal<string | null>(null)
  const setup = await mount(
    () => (
      <SessionsView workspaces={[ws]} currentId={first} onSwitch={setWent} onOpenTab={setTabbed} onNew={() => {}} onClose={() => {}} />
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

    // The cursor lands on the press — the click is acknowledged in the same
    // frame — and the switch follows once the window for a second press closes.
    await setup.mockMouse.click(30, at)
    expect((await settle(setup, 2)).split("\n")[at]!.trimStart().startsWith("▾")).toBe(true)
    await until(() => went() !== null, 10_000)
    expect(went()).toBe(first)
    expect(tabbed()).toBeNull()

    // Two presses inside the window are the other verb, and ONLY the other
    // verb: no switch is fired on the way through.
    setWent(null)
    await setup.mockMouse.click(30, at)
    await setup.mockMouse.click(30, at)
    await until(() => tabbed() !== null, 10_000)
    expect(tabbed()).toBe(first)
    await settle(setup, 6)
    expect(went()).toBeNull()
  } finally {
    setup.renderer.destroy()
  }
}, 90_000)

test("/sessions: the pointer marks the row it is over, and lets go of it", async () => {
  const setup = await mount(
    () => <SessionsView workspaces={[ws]} currentId={first} onSwitch={() => {}} onOpenTab={() => {}} onNew={() => {}} onClose={() => {}} />,
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
    await until(() => setup.captureCharFrame().includes("extensions  tools  usage"), 20_000)
    const strip = (await settle(setup, 6)).split("\n").findIndex((row) => row.includes("extensions  tools"))
    expect(strip).toBeGreaterThanOrEqual(0)

    // "tools" is the second word of the strip; click it rather than pressing `t`.
    const line = (await settle(setup, 2)).split("\n")[strip]!
    await setup.mockMouse.click(line.indexOf("tools") + 2, strip)
    await until(() => setup.captureCharFrame().includes("[ ] ext:lint/lint"), 10_000)
    expect(sessionSelection(state)).not.toContain("ext:lint/lint")

    // The checkbox is its own target: clicking it is Space, and nothing else on
    // the row does that.
    const pane = (await settle(setup, 4)).split("\n")
    const row = pane.findIndex((text) => text.includes("[ ] ext:lint/lint"))
    expect(row).toBeGreaterThanOrEqual(0)
    await setup.mockMouse.click(pane[row]!.indexOf("[") + 1, row)
    await until(() => setup.captureCharFrame().includes("[x] ext:lint/lint"), 10_000)
    expect(sessionSelection(state)).toContain("ext:lint/lint")

    // And again to take it off, so the click is a toggle and not a one-way door.
    await setup.mockMouse.click(pane[row]!.indexOf("[") + 1, row)
    await until(() => setup.captureCharFrame().includes("[ ] ext:lint/lint"), 10_000)
    expect(sessionSelection(state)).not.toContain("ext:lint/lint")
  } finally {
    setup.renderer.destroy()
  }
}, 90_000)

test("the tab bar answers to a click, with the same select F4 uses", async () => {
  const [active, setActive] = createSignal(0)
  // A tab is named by what it runs on, not by its session id.
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

test("the tab strip's own two controls: ✕ closes that tab, + starts one", async () => {
  const [active, setActive] = createSignal(0)
  const [closed, setClosed] = createSignal(-1)
  const [made, setMade] = createSignal(0)
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
    () => (
      <TabBar
        tabs={tabs}
        activeIndex={active()}
        onSelect={setActive}
        onClose={setClosed}
        onNew={() => setMade((n) => n + 1)}
      />
    ),
    60,
    4,
  )
  try {
    const line = (await settle(setup, 4)).split("\n")[0]!
    // Which one is in front is a SHAPE: `▎` on it, blanks on the rest,
    // so a terminal with no colours still says it. It used to be `⤷` on every
    // tab, which said nothing about any of them.
    expect(line).toContain(`${style.glyphs.bar} alpha-1`)
    expect(line).not.toContain(`${style.glyphs.bar} beta-2`)

    // The close button is its own target: it closes that tab and does NOT let
    // the tab under it select itself on the way through.
    const cross = line.indexOf(style.glyphs.closeTab)
    expect(cross).toBeGreaterThan(0)
    await setup.mockMouse.click(cross, 0)
    await until(() => closed() === 0, 5_000)
    expect(active()).toBe(0)

    await setup.mockMouse.click(line.lastIndexOf(style.glyphs.newTab), 0)
    await until(() => made() === 1, 5_000)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a tab strip fits the row it has: names shrink, and the buttons go before the names do", () => {
  // The one row on the screen whose contents are decided by the person, not by
  // the layout. What is pinned is the INVARIANT — everything drawn fits between
  // the margins — because the failure it replaces is silent: a strip that runs
  // past the edge loses the `+` and cuts the last tab in half.
  const cost = { marker: 2, close: 2, gap: 2, plus: 3 }
  const drawn = (width: number, tabs: number) => {
    const plan = stripPlan(width, tabs, cost)
    return tabs * (cost.marker + (plan.closes ? cost.close : 0) + plan.label) + (tabs - 1) * cost.gap + cost.plus
  }
  // Every width where a plan exists at all — `marker + 1 + gap` per tab, the
  // limit `stripPlan` writes down. Past it no share of anything fits and the
  // row clips, which is a fold, not a width.
  for (const [width, tabs] of [[120, 2], [100, 5], [80, 4], [60, 5], [40, 4], [30, 4]] as [number, number][]) {
    expect(drawn(width, tabs)).toBeLessThanOrEqual(width - 2)
  }

  // Room to spare: names get the room and every tab keeps its ✕.
  expect(stripPlan(120, 2, cost)).toMatchObject({ closes: true })
  expect(stripPlan(120, 2, cost).label).toBeGreaterThan(stripPlan(60, 5, cost).label)
  // Too tight for a name to be a name: the button is what goes, not the name.
  // Ctrl+W is still the verb; a strip of one-letter stubs is not a strip.
  const tight = stripPlan(60, 5, cost)
  expect(tight.closes).toBe(false)
  expect(tight.label).toBeGreaterThan(stripPlan(60, 5, { ...cost, marker: 6 }).label)
})

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

test("clicking empty transcript does not take the keyboard away from the box", async () => {
  // Nothing on screen changes when this goes wrong, which is what makes it
  // worth pinning: `ScrollBoxRenderable` is focusable, OpenTUI's autoFocus
  // walks up from a mouse-down to the first focusable ancestor, and the
  // transcript is that ancestor for every cell of itself — so a click on empty
  // space can leave the composer bordered, blinking and deaf.
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created />,
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 3)
    state.applyEvents([{ seq: 1, kind: "user_text", text: "run the tests" } as never])
    await until(() => setup.captureCharFrame().includes("run the tests"), 15_000)

    const rows = (await settle(setup, 4)).split("\n")
    const box = rows.findIndex((row) => row.includes("message nulya"))
    expect(box).toBeGreaterThan(0)
    // A row inside the transcript with nothing drawn on it: no card, no head
    // line, nothing that answers a click at all.
    const blank = rows.slice(0, box - 2).findIndex((row) => row.trim().length === 0)
    expect(blank).toBeGreaterThanOrEqual(0)

    await setup.mockMouse.click(60, blank)
    await settle(setup, 3)
    await setup.mockInput.typeText("still mine")
    expect(await settle(setup, 3)).toContain("still mine")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("the model is a click target wherever it is written: the line under the composer, the composition card — and the welcome rows and /help", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    // A state file of this test's own: the mode chip below is CHOSEN from, and
    // `/mode` remembers the choice. Without this, picking `ask`
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
  const picker = "model · what "
  try {
    await until(() => setup.captureCharFrame().includes("frozen composition"), 15_000)
    const frame = await settle(setup, 4)
    const rows = frame.split("\n")

    // The bottom line, where tcode puts it: the model leads
    // it, and the model is the target. No session id, no provider name.
    // The frame ends with a newline, so the last row is the blank after it.
    const bar = rows.length - 2
    expect(rows[bar]).toContain("scripted-demo · tools 1+0")
    expect(rows[bar]).not.toContain(id)
    // No keyboard hints and no `/help` on it any more: a reminder that
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
    const sessionsRow = rows.findIndex((row) => row.includes("/sessions") && row.includes("every session here"))
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
    // PICKER rather than flipping the mode: a chip that
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

test("the pointer lifts a row's own colours and paints nothing behind it", () => {
  // The one background left belongs to the KEYBOARD cursor; a second band
  // for the pointer would make a row the mouse had merely crossed look chosen.
  expect(rowBackground(style, { selected: false, hovered: true })).toBeUndefined()
  expect(rowBackground(style, { selected: true, hovered: true })).toBe(style.theme.selection)
  // Lifted, not replaced: a warn-coloured cell under the pointer is still
  // nearer warn than it is to the colour it was lifted toward. That is the
  // whole reason this is a mix and not a second palette.
  const warm = lifted(style, true, style.theme.warn)
  expect(warm).not.toBe(style.theme.warn)
  expect(warm).not.toBe(style.theme.lift)
  expect(lifted(style, false, style.theme.warn)).toBe(style.theme.warn)
})

test("with no colour to lift toward, the pointer says nothing rather than something wrong", () => {
  // `NO_COLOR` collapses every token onto the terminal's own foreground, so
  // `lift` IS `fg` and the mix is a no-op. What is left of the pointer there
  // is the gutter mark.
  const mono = createStyle(default_settings, { NO_COLOR: "1" })
  expect(lifted(mono, true, mono.theme.fg).toLowerCase()).toBe(mono.theme.fg.toLowerCase())
})
