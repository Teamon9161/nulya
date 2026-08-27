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
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { SessionsView, sidebarRowPlan, min_said } from "../src/ui/overlays/SessionsView.tsx"
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
  const cells = { indent: 0, here: " |", live: " *", verdict: " +", clock: " just now" }
  // Wide: everything fits.
  const wide = sidebarRowPlan(40, cells)
  expect(wide.clock).toBe(" just now")
  expect(wide.said).toBeGreaterThanOrEqual(min_said)

  // Narrow: the clock is the first thing that goes, then the verdict, then the
  // live marker — and "which one am I in" is the last to go, because a list of
  // conversations that cannot say that is not a list of your conversations.
  const narrow = sidebarRowPlan(16, cells)
  expect(narrow.clock).toBe("")
  expect(narrow.here).toBe(" |")
  expect(narrow.said).toBeGreaterThanOrEqual(min_said)

  // Narrower than any of it: the sentence still gets whatever is left, and
  // nothing here can return a negative width for `fit` to choke on.
  const squeezed = sidebarRowPlan(6, cells)
  expect(squeezed).toMatchObject({ here: "", live: "", verdict: "", clock: "" })
  expect(squeezed.said).toBeGreaterThanOrEqual(0)
})

test("a full-screen view opens in the main pane even when the keyboard is in the sidebar", () => {
  const surfaces = createSurfaceRegistry<string>()
  const define = (id: string, claims: boolean) =>
    surfaces.register({ id, title: id, owner: host_owner, claimsKeyboard: claims, render: () => id })
  define(main_surface, false)
  define(sidebar_surface, true)
  define("host:ext", true)
  const panes = createPaneStore(main_surface, "main")
  const overlay = overlayAdapter(panes, (surface) => claimsKeyboard(surfaces, surface))

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
    // keyboard out of the rail. (Whether the BOX then has it is a separate,
    // older question — clicking the transcript blurs the composer with one
    // pane on screen too, and always has.)
    press(setup, ctrl_left)
    expect(cursorInRail(await settle(setup, 3))).toBe(true)
    await setup.mockMouse.click(60, 15)
    expect(cursorInRail(await settle(setup, 3))).toBe(false)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("clicking a row in the rail goes to that session, through the same verb Enter uses", async () => {
  const { setup } = await screen(80, 24, { open: true, ratio: default_sidebar_ratio })
  try {
    await until(() => setup.captureCharFrame().includes("older one"), 30_000)
    const rows = setup.captureCharFrame().split("\n")
    const at = rows.findIndex((row) => row.includes("older one"))
    expect(at).toBeGreaterThanOrEqual(0)

    // Once to land the cursor (and to bring the keyboard into the pane), again
    // for what Enter does — the two-press rule every list in this front end
    // follows, so the mouse is not a second path to a second behaviour.
    await setup.mockMouse.click(4, at)
    await settle(setup, 2)
    await setup.mockMouse.click(4, at)
    await until(() => setup.captureCharFrame().includes(`opened ${other}`), 30_000)
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
          ws={ws}
          variant="sidebar"
          width={20}
          currentId={mine}
          focused={focused}
          onOpen={() => {}}
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
