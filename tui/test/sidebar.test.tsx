/**
 * The sessions sidebar (goals/tui-shell.md §5.4 S1b, tui.md §11 T69).
 *
 * Two halves, and the split is the same one T68 drew: what the MODEL says
 * (open, close, resize, how wide a rail actually is, what fits in one of its
 * rows) is pinned without a terminal; what only a frame can answer — that the
 * list and the transcript are on screen together, that the composer still
 * takes what is typed while the rail is up, that a narrow window puts it away
 * — is pinned against real frames from a real workspace.
 *
 * What is deliberately NOT asserted: the exact columns anything lands in. The
 * snapshots hold the frames; these tests hold the rules.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { personaOf } from "../src/agents.ts"
import {
  SessionsView,
  groupedRows,
  partitionSessions,
  railFooter,
  sidebarRowPlan,
  min_said,
} from "../src/ui/overlays/SessionsView.tsx"
import { createStyle } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import { createPaneStore, main_surface, overlayAdapter, sidebar_surface } from "../src/state/panes.ts"
import { claimsKeyboard, createSurfaceRegistry, host_owner } from "../src/pane/registry.ts"
import {
  closeSidebar,
  default_sidebar_ratio,
  isSidebarOpen,
  openSidebar,
  resizeSidebar,
  sidebarPane,
  sidebarRatio,
  sidebarWidth,
  sidebar_min_width,
} from "../src/state/sidebar.ts"
import { parentSplit, singlePane, splitPane } from "../src/pane/tree.ts"
import { loadTuiState, rememberModel, rememberSidebar, saveTuiState } from "../src/state/tui_state.ts"
import { sessionAppend, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { unsafe_settings, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style = createStyle(unsafe_settings, {})

// ── the model ───────────────────────────────────────────────────────────────

test("opening the sidebar puts it before the main pane and leaves the keyboard alone", () => {
  const one = singlePane(main_surface, "main")
  const opened = openSidebar(one, "main")
  expect(isSidebarOpen(opened)).toBe(true)
  // Before, because it is a LEFT rail: `place` is the only thing that decides
  // which side of the seam it lands on.
  const split = parentSplit(opened, sidebarPane(opened)!)!
  expect(split.first.id).toBe(sidebarPane(opened)!)
  expect(split.direction).toBe("row")
  // …and the keyboard has not moved. Showing a list and going to it are two
  // gestures; this is the one that is not the second.
  expect(opened.focus).toBe("main")
  expect(sidebarRatio(opened)).toBeCloseTo(default_sidebar_ratio)
})

test("opening twice is opening once, and closing gives the box back", () => {
  const one = singlePane(main_surface, "main")
  const opened = openSidebar(one, "main")
  expect(openSidebar(opened, "main")).toBe(opened)
  const closed = closeSidebar(opened)
  expect(isSidebarOpen(closed)).toBe(false)
  expect(closed.focus).toBe("main")
  // Closing what is not there changes nothing, so a reconcile that runs twice
  // cannot turn into a second answer.
  expect(closeSidebar(closed)).toBe(closed)
})

test("closing the sidebar while the keyboard is in it does not leave the keyboard nowhere", () => {
  const opened = openSidebar(singlePane(main_surface, "main"), "main")
  const focused = { ...opened, focus: sidebarPane(opened)! }
  const closed = closeSidebar(focused)
  expect(isSidebarOpen(closed)).toBe(false)
  expect(closed.focus).toBe("main")
})

test("the seam moves to where it is asked for, whichever side the sidebar is on", () => {
  const opened = openSidebar(singlePane(main_surface, "main"), "main")
  expect(sidebarRatio(resizeSidebar(opened, 0.4))).toBeCloseTo(0.4)
  // The model clamps, so an absurd number is a thin pane rather than an
  // undrawable one — nothing here has to range-check first.
  expect(sidebarRatio(resizeSidebar(opened, 3))!).toBeLessThanOrEqual(0.9)
  expect(sidebarRatio(resizeSidebar(opened, -1))!).toBeGreaterThanOrEqual(0.1)

  // The same number, with the rail on the far side: `share` is always the
  // sidebar's, never "the first child's".
  const mirrored = splitPane(singlePane(main_surface, "main"), "main", {
    direction: "row",
    surface: sidebar_surface,
    id: "rail",
    splitId: "s",
    place: "after",
  })
  expect(sidebarRatio(resizeSidebar(mirrored, 0.3))).toBeCloseTo(0.3)
})

test("how wide the rail is drawn is measured through the layout, not guessed", () => {
  const opened = openSidebar(singlePane(main_surface, "main"), "main")
  // A quarter of eighty. What matters is not the number but that the model and
  // the paint cannot disagree: this is the same `layout` the seam is placed by.
  expect(sidebarWidth(opened, 80)).toBe(20)
  expect(sidebarWidth(opened, 120)).toBe(30)
  // Closed, it occupies nothing at all.
  expect(sidebarWidth(closeSidebar(opened), 80)).toBe(0)
})

test("a rail row gives up its cells from the outside in, and never starves the sentence", () => {
  const cells = { indent: 0, here: " |", live: " *", verdict: " +", persona: " #", clock: " just now" }
  // Wide: everything fits.
  const wide = sidebarRowPlan(40, cells)
  expect(wide.clock).toBe(" just now")
  expect(wide.said).toBeGreaterThanOrEqual(min_said)

  // Narrow: the clock is the first thing that goes, then the verdict, then the
  // live marker — and the two that say what KIND of row this is (a delegation,
  // the one you are in) are the last, because a list of conversations that
  // cannot say either is not a list of your conversations.
  const narrow = sidebarRowPlan(18, cells)
  expect(narrow.clock).toBe("")
  expect(narrow.here).toBe(" |")
  expect(narrow.persona).toBe(" #")
  expect(narrow.said).toBeGreaterThanOrEqual(min_said)

  // Narrower than any of it: the sentence still gets whatever is left, and
  // nothing here can return a negative width for `fit` to choke on.
  const squeezed = sidebarRowPlan(6, cells)
  expect(squeezed).toMatchObject({ here: "", live: "", verdict: "", clock: "", persona: "" })
  expect(squeezed.said).toBeGreaterThanOrEqual(0)
})

test("a session an agent was handed is told apart by the prompt it wears, not by a second rule", () => {
  const row = (id: string, ...sources: string[]) =>
    ({ id, composition: { prompts: sources.map((source) => ({ source, bytes: 1 })) } }) as never
  const { own, delegated } = partitionSessions([
    row("s-1"),
    row("s-2", "agent-explore"),
    // A per-session prompt that is NOT a persona: `--prompt` is a general
    // kernel feature (DESIGN §5.6) and only the `agent-` label is the agent
    // package's (`personaOf`).
    row("s-3", "house-style"),
    row("s-4", "house-style", "agent-plan"),
  ])
  expect(own.map((entry) => entry.id)).toEqual(["s-1", "s-3"])
  expect(delegated.map((entry) => entry.id)).toEqual(["s-2", "s-4"])
  expect(personaOf([{ source: "agent-explore" }])).toBe("explore")
  expect(personaOf([{ source: "house-style" }])).toBeNull()
  expect(personaOf([])).toBeNull()
})

test("a session nothing was ever said into is not a row, whichever way `a` is set", () => {
  // `events` is the whole test: a header with no ledger events behind it. They
  // exist because a process was killed before it could take its own empty
  // session back, and opening one shows an empty screen.
  const row = (id: string, events: number, sources: string[] = [], parent: object | null = null) =>
    ({ id, events, parent, composition: { prompts: sources.map((source) => ({ source, bytes: 1 })) } }) as never
  const entries = [
    row("s-1", 12),
    row("s-2", 0),
    row("s-3", 8, ["agent-explore"]),
    row("s-4", 0, ["agent-plan"]),
    row("s-5", 0, [], { session: "s-1", seq: 12 }),
  ]
  const { own, delegated, empty } = partitionSessions(entries)
  expect(own.map((entry) => entry.id)).toEqual(["s-1", "s-5"])
  expect(delegated.map((entry) => entry.id)).toEqual(["s-3"])
  // An empty delegated session is empty first: the count that means "there is
  // a conversation here you are not seeing" must not include rows with none.
  expect(empty.map((entry) => entry.id)).toEqual(["s-2", "s-4"])

  const ws = { dir: "/w", bin: "nulya" } as never
  const ids = (showAgents: boolean) =>
    groupedRows([{ ws, entries }], showAgents)
      .map((listed) => (listed.kind === "session" ? listed.entry.id : listed.kind))
      .join(",")
  expect(ids(false)).toBe("s-1,s-5")
  // `a` switches between the two kinds of conversation; it does not uncover
  // rows with nothing in them. The zero-event continuation remains visible in
  // both views because its parent pointer says it is a real episode.
  expect(ids(true)).toBe("s-1,s-5,s-3")
})

test("the rail's one dim line is chosen for the width it has, and the count outlives the keys", () => {
  // Focused and nothing hidden: the long form while it fits, the short one after.
  expect(railFooter(40, true, 0)).toContain("t tab")
  expect(railFooter(18, true, 0)).toBe("j/k · Enter · Esc")
  // Nothing at all to say, and no line: an unfocused rail with every session
  // showing has no keys that are true and nothing it is holding back.
  expect(railFooter(40, false, 0)).toBe("")
  // With rows hidden, the count is what survives the squeeze — a key missing
  // from this line is still in `/sessions`, a hidden row is nowhere else.
  expect(railFooter(60, true, 3)).toContain("3 agent")
  expect(railFooter(18, true, 3)).toContain("3 agent")
  expect(railFooter(18, false, 3)).toBe("3 agent hidden")
  // Narrower than any candidate: nothing, rather than a truncated key list
  // that would teach the wrong key.
  expect(railFooter(4, true, 3)).toBe("")
  // Sessions with nothing in them are counted too — a list quietly shorter
  // than the store is lying — but no key rides with that count, and it is the
  // first thing given up when the line has to shrink.
  expect(railFooter(60, true, 0, 2)).toContain("2 empty")
  expect(railFooter(60, false, 0, 2)).toBe("2 empty")
  expect(railFooter(60, true, 3, 2)).toContain("2 empty")
  expect(railFooter(18, true, 3, 2)).toContain("3 agent")
  expect(railFooter(18, true, 3, 2)).not.toContain("empty")
  expect(railFooter(18, true, 0, 2)).toBe("j/k · Enter · Esc")
})

test("a full-screen view opens in the main pane even when the keyboard is in the sidebar", () => {
  const surfaces = createSurfaceRegistry<string>()
  const define = (id: string, claims: boolean) =>
    surfaces.register({ id, title: id, owner: host_owner, claimsKeyboard: claims, render: () => id })
  define(main_surface, false)
  define(sidebar_surface, true)
  define("host:ext", true)
  const panes = createPaneStore(main_surface, "main")
  // One tree here, standing in for both layers: the adapter reads whichever
  // store it is handed, and composing the two is T72's own test.
  const overlay = overlayAdapter(
    () => panes,
    () => ({ pane: panes.focus(), surface: panes.surface() }),
    (surface) => claimsKeyboard(surfaces, surface),
  )

  panes.apply((tree) => openSidebar(tree, panes.main()))
  // Merely open: the composer still has the keyboard.
  expect(overlay.active()).toBe(false)

  panes.focusOn(sidebarPane(panes.tree())!)
  // Focused: it does not, and that is what blurs the box.
  expect(overlay.active()).toBe(true)
  // …but "which view is in front" is still a fact about the main pane, so F2
  // replaces the transcript rather than the rail the keyboard happens to be in.
  overlay.open("ext")
  expect(overlay.kind()).toBe("ext")
  expect(isSidebarOpen(panes.tree())).toBe(true)
  overlay.close()
  expect(panes.mainSurface()).toBe(main_surface)
})

test("what the sidebar was asked for survives a restart, and a broken slot costs nothing else", () => {
  const path = join(ws.dir, "tui-state-sidebar.json")
  rememberModel({ profile: "scripted" }, path)
  rememberSidebar({ open: true, ratio: 0.3 }, path)
  expect(loadTuiState(path).sidebar).toEqual({ open: true, ratio: 0.3 })
  expect(loadTuiState(path).model?.profile).toBe("scripted")

  // Half a slot is read for the half it has: a file that says it was open but
  // not how wide gives back the default rather than nothing.
  saveTuiState({ model: { profile: "scripted" }, sidebar: { open: true } as never }, path)
  expect(loadTuiState(path).sidebar).toEqual({ open: true, ratio: default_sidebar_ratio })
  expect(loadTuiState(path).model?.profile).toBe("scripted")
})

// ── the screen ──────────────────────────────────────────────────────────────

let ws: TempWorkspace
let mine: string
let other: string

/**
 * Two sessions that have actually said something. The opening line only
 * reaches `session list` once a step has drained the inbox into the ledger
 * (DESIGN §6.1), and a row here IS its opening line — an undrained session
 * would put "nothing said yet" in every row and test nothing.
 *
 * They are short on purpose: the rail is eighteen columns of content at 80,
 * so a sentence long enough to be truncated would make every assertion below
 * an assertion about `fit`.
 */
beforeAll(async () => {
  ws = tempWorkspace()
  const talk = async (text: string) => {
    const id = await sessionNew(ws, { profile: "scripted" })
    await sessionAppend(ws, id, text)
    const step = sessionStep(ws, id, { env: scripted_env })
    for await (const _ of step.lines) {
      // Drain: the events are what `session list` reads back.
    }
    await step.exited
    return id
  }
  other = await talk("older one")
  mine = await talk("budgets")
}, 180_000)

afterAll(() => ws.cleanup())

/** The screen, with a state file of this call's own so tests cannot infect each other. */
async function screen(width: number, height = 24, sidebar?: { open: boolean; ratio: number }) {
  const statePath = join(ws.dir, `tui-state-${Math.random().toString(36).slice(2)}.json`)
  if (sidebar) rememberSidebar(sidebar, statePath)
  const state = createSessionState(mine)
  const setup = await testRender(
    () => (
      <App ws={ws} id={mine} state={state} style={style} driver={{ env: scripted_env }} statePath={statePath} created />
    ),
    { width, height },
  )
  await settle(setup, 3)
  return { setup, statePath }
}

/** The rail is on screen once its own title line is, list or no list. */
const railUp = (frame: string) => frame.includes("sessions · ")

/**
 * A frame with its clocks stopped.
 *
 * Two of them are on this screen — the composition card's date and `ago`'s
 * "just now" — and a snapshot of a clock is a snapshot that fails at midnight
 * and on any machine slow enough to take a minute getting here. What the
 * snapshot is for is the LAYOUT, so the layout is what it keeps: the cells stay
 * exactly as wide as the text they held.
 */
const steady = (frame: string) =>
  frame
    .replace(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}/g, (when) => "-".repeat(when.length))
    .replace(/just now|\d+[mhd] ago/g, (when) => "~".repeat(when.length))

/**
 * Does the rail have room for its clock column at this width?
 *
 * Measured over the leftmost columns only: the transcript beside it prints
 * dates of its own, and a test that read the whole frame would pass at any
 * width at all.
 */
const hasClock = (frame: string) =>
  frame
    .split("\n")
    .map((row) => row.slice(0, 30))
    .some((row) => /(just now|\d+[mhd] ago)/.test(row))

test("the sidebar comes up docked, beside a transcript that is still there", async () => {
  const { setup } = await screen(80)
  try {
    expect(railUp(setup.captureCharFrame())).toBe(false)
    await setup.mockInput.typeText("/sidebar")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("older one"), 30_000)
    const frame = await settle(setup, 3)

    // Both at once: this is a split, not a screen that replaced another one.
    expect(railUp(frame)).toBe(true)
    expect(frame).toContain("older one")
    expect(frame).toContain("budgets")

    // And the box still takes what is typed — the whole reason opening the rail
    // does not focus it (T69).
    await setup.mockInput.typeText("still typing here")
    expect(await settle(setup, 2)).toContain("still typing here")
    expect(steady(frame)).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("a wider terminal spends the room on the rail's own columns", async () => {
  const { setup } = await screen(120, 24, { open: true, ratio: default_sidebar_ratio })
  try {
    await until(() => setup.captureCharFrame().includes("older one"), 30_000)
    const frame = await settle(setup, 3)
    expect(railUp(frame)).toBe(true)
    // Thirty columns is room for the clock; twenty is not, and the sentence is
    // what neither width is allowed to lose (`sidebarRowPlan`).
    expect(hasClock(frame)).toBe(true)
    expect(steady(frame)).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("a terminal too narrow for a rail does not draw one, and has not forgotten it", async () => {
  const asked = { open: true, ratio: default_sidebar_ratio }
  const { setup, statePath } = await screen(sidebar_min_width - 10, 24, asked)
  try {
    const frame = await settle(setup, 3)
    expect(railUp(frame)).toBe(false)
    // A quarter of fifty columns is a column of ellipses, so it hides itself —
    // without anybody deciding to, which is why what was ASKED for is what is
    // remembered.
    expect(loadTuiState(statePath).sidebar).toEqual(asked)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("the sidebar is where it was left, and putting it away is remembered too", async () => {
  const { setup, statePath } = await screen(80, 24, { open: true, ratio: default_sidebar_ratio })
  try {
    // No command typed: it is up because that is how it was left.
    expect(railUp(await settle(setup, 2))).toBe(true)
    await setup.mockInput.typeText("/sidebar")
    setup.mockInput.pressEnter()
    await until(() => !railUp(setup.captureCharFrame()), 30_000)
    expect(loadTuiState(statePath).sidebar?.open).toBe(false)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/** The rail's cursor row — drawn only while the rail holds the keyboard. */
const cursorInRail = (frame: string) =>
  frame
    .split("\n")
    .some((row) => row.slice(0, 20).includes(style.glyphs.foldOpen))

/** Ctrl+←/→ have no helper on the mock keyboard; these are what a terminal sends. */
const ctrl_left = "\x1b[1;5D"
const ctrl_right = "\x1b[1;5C"
function press(setup: { renderer: { stdin: { emit(event: string, data: Buffer): void } } }, sequence: string) {
  setup.renderer.stdin.emit("data", Buffer.from(sequence))
}

test("the keyboard goes to the rail only when it is sent there, and Esc sends it back", async () => {
  const { setup } = await screen(80, 24, { open: true, ratio: default_sidebar_ratio })
  try {
    await until(() => setup.captureCharFrame().includes("older one"), 30_000)
    // Up, and the box still has the keyboard: no cursor row in the rail, and
    // what is typed is typed (T69 — opening is not going).
    await setup.mockInput.typeText("before")
    expect(await settle(setup, 2)).toContain("before")

    press(setup, ctrl_left)
    await settle(setup, 3)
    // The rail answers `j` now, which it could not have done a moment ago.
    setup.mockInput.pressKey("j")
    const inside = await settle(setup, 3)
    expect(cursorInRail(inside)).toBe(true)

    setup.mockInput.pressEscape()
    const back = await settle(setup, 3)
    // The cursor goes with the keyboard, and the draft was never touched.
    expect(cursorInRail(back)).toBe(false)
    expect(back).toContain("before")
    await setup.mockInput.typeText(" and after")
    expect(await settle(setup, 2)).toContain("before and after")

    // …and the other direction is the way out too, for a rail on the left.
    press(setup, ctrl_left)
    expect(cursorInRail(await settle(setup, 3))).toBe(true)
    press(setup, ctrl_right)
    expect(cursorInRail(await settle(setup, 3))).toBe(false)
    // …and the box is typeable again the moment it is, not a frame later.
    await setup.mockInput.typeText("!")
    expect(await settle(setup, 2)).toContain("before and after!")

    // The mouse is the third way out: a click on the transcript takes the
    // keyboard out of the rail — and, since T70, hands it all the way back to
    // the box rather than to the scrollbox that used to swallow it.
    press(setup, ctrl_left)
    expect(cursorInRail(await settle(setup, 3))).toBe(true)
    await setup.mockMouse.click(60, 15)
    expect(cursorInRail(await settle(setup, 3))).toBe(false)
    await setup.mockInput.typeText("?")
    expect(await settle(setup, 2)).toContain("before and after!?")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("one click in the rail goes to that session in this tab, and the strip does not grow", async () => {
  // T70's whole point: "show me that conversation" is one press, and it does
  // NOT open a second tab — which is what the tab strip's absence says here,
  // since the strip only exists once there is more than one tab (T22).
  const { setup } = await screen(80, 24, { open: true, ratio: default_sidebar_ratio })
  try {
    await until(() => setup.captureCharFrame().includes("older one"), 30_000)
    const rows = setup.captureCharFrame().split("\n")
    const at = rows.findIndex((row) => row.includes("older one"))
    expect(at).toBeGreaterThanOrEqual(0)

    await setup.mockMouse.click(4, at)
    const switched = await settle(setup, 3)
    // Selecting a session is the action itself; it does not need a full-width
    // reading notice underneath the composer.
    expect(switched).not.toContain(`switched to ${other}`)
    expect(switched).toContain(style.glyphs.sidebar)
    // One tab still: a switch replaces what was in front rather than adding to
    // it, so nothing has to be closed afterwards.
    expect(switched).not.toContain("(observer)")
    expect(switched.split("\n")[0]).not.toContain(style.glyphs.closeTab)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("two clicks in the rail give that session a tab of its own", async () => {
  const { setup } = await screen(80, 24, { open: true, ratio: default_sidebar_ratio })
  try {
    await until(() => setup.captureCharFrame().includes("older one"), 30_000)
    const rows = setup.captureCharFrame().split("\n")
    const at = rows.findIndex((row) => row.includes("older one"))
    expect(at).toBeGreaterThanOrEqual(0)

    await setup.mockMouse.click(4, at)
    await setup.mockMouse.click(4, at)
    await until(() => setup.captureCharFrame().includes(`opened ${other}`), 30_000)
    // …and NOW there are two, which is what the strip appearing means.
    const opened = await settle(setup, 3)
    const strip = opened.split("\n")[0]!
    expect(strip).toContain(style.glyphs.closeTab)
    expect(strip).toContain(style.glyphs.newTab)
    // A different notice may still be useful, but it must not remove the only
    // visible way to close the rail.
    const statusAt = opened.split("\n").findIndex((row) => row.includes(`opened ${other}`))
    expect(statusAt).toBeGreaterThanOrEqual(0)
    expect(opened.split("\n")[statusAt]).toContain(style.glyphs.sidebar)
    await setup.mockMouse.click(1, statusAt)
    await until(() => !railUp(setup.captureCharFrame()), 30_000)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("an unfocused rail draws no cursor row, because Enter would not act on it", async () => {
  // Two mounts of the same view, differing only in whether they hold the
  // keyboard. A highlighted row in a pane that would not answer is a promise
  // the screen cannot keep.
  const mount = (focused: boolean) =>
    testRender(
      () => (
        <SessionsView
          workspaces={[ws]}
          variant="sidebar"
          width={20}
          currentId={mine}
          focused={focused}
          onSwitch={() => {}} onOpenTab={() => {}}
          onNew={() => {}}
          onClose={() => {}}
        />
      ),
      { width: 20, height: 12 },
    )
  const off = await mount(false)
  const on = await mount(true)
  try {
    await until(() => on.captureCharFrame().includes("older one"), 30_000)
    await until(() => off.captureCharFrame().includes("older one"), 30_000)
    expect(await settle(on, 3)).toContain(style.glyphs.foldOpen)
    expect(await settle(off, 3)).not.toContain(style.glyphs.foldOpen)
  } finally {
    off.renderer.destroy()
    on.renderer.destroy()
  }
}, 120_000)

test("the list is about the sessions a person is having, and says how many it is not showing", async () => {
  // A delegated session is a real session with a real ledger — `session list`
  // is right to project it — and it is not a conversation anybody started, nor
  // one to send a message to from here. The frozen `agent-<name>` prompt is the
  // whole test, and it is the same one `wearing()` reads (T70).
  const persona = join(ws.dir, "agent-explore.md")
  writeFileSync(persona, "you are the scout\n")
  const handed = await sessionNew(ws, { profile: "scripted", prompt: [persona] })
  await sessionAppend(ws, handed, "go and look")
  const step = sessionStep(ws, handed, { env: scripted_env })
  for await (const _ of step.lines) {
    // Drain: the opening line only reaches `session list` once a step has run.
  }
  await step.exited

  const setup = await testRender(
    () => (
      <SessionsView workspaces={[ws]} currentId={mine} onSwitch={() => {}} onOpenTab={() => {}} onNew={() => {}} onClose={() => {}} />
    ),
    { width: 110, height: 20 },
  )
  try {
    await until(() => setup.captureCharFrame().includes("budgets"), 30_000)
    const hiding = await settle(setup, 4)
    expect(hiding).not.toContain("go and look")
    // …and it says so, on the one dim line it already had (§6.1 rule 8).
    expect(hiding).toContain("1 agent session hidden · a shows")

    // `a` shows them, and a shown one says which persona it is wearing rather
    // than passing for a conversation.
    setup.mockInput.pressKey("a")
    const showing = await settle(setup, 4)
    expect(showing).toContain("go and look")
    expect(showing).toContain(`${style.glyphs.picker} explore`)
    expect(showing).not.toContain("hidden")

    setup.mockInput.pressKey("a")
    expect(await settle(setup, 4)).not.toContain("go and look")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
