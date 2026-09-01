/**
 * Sub-agent panes: a delegation watched inside the conversation that made it.
 *
 * The same MODEL/FRAME split as elsewhere in this suite. What the MODEL says — that there are two
 * trees one hop apart, which way a split goes at a given width, where the
 * focus lands, what a pane's attribution line reads — is pinned without a
 * terminal. What only a frame can answer — that both conversations are on
 * screen at once, that the composer still takes what is typed, that switching
 * tabs switches layouts, that closing the tab takes the pane with it — is
 * pinned against real frames from a real workspace.
 *
 * What is deliberately NOT asserted: which columns anything lands in. The two
 * snapshots hold the frames; these tests hold the rules.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { attributionOf } from "../src/ui/SubAgentPane.tsx"
import { createStyle } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import {
  createPaneStore,
  focusThrough,
  main_surface,
  subagent_surface,
  tab_surface,
} from "../src/state/panes.ts"
import { openSidebar, sidebarPane } from "../src/state/sidebar.ts"
import {
  closeSubPane,
  default_sub_ratio,
  openSubPane,
  reflowSubSplits,
  subPanes,
  subSplitDirection,
  subSplitOf,
  sub_row_min_width,
} from "../src/state/subpanes.ts"
import { leaves, parentSplit } from "../src/pane/tree.ts"
import { sessionAppend, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { unsafe_settings, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style = createStyle(unsafe_settings, {})

/**
 * The single-side rule the pane draws itself with. OpenTUI's border characters
 * rather than a glyph of ours: the composer already uses that set, and this is
 * the same one-column rule turned on its other axis.
 */
const vertical_rule = "│"

/** Ctrl+←/→ have no helper on the mock keyboard; these are what a terminal sends. */
const ctrl_right = "\x1b[1;5C"
function press(setup: { renderer: { stdin: { emit(event: string, data: Buffer): void } } }, sequence: string) {
  setup.renderer.stdin.emit("data", Buffer.from(sequence))
}

// ── the model ───────────────────────────────────────────────────────────────

test("a sub-agent pane splits the tab it belongs to, and does not take the keyboard", () => {
  const tab = createPaneStore(main_surface, "main")
  tab.apply((tree) => openSubPane(tree, "main", { direction: "row", id: "sub" }))
  expect(subPanes(tab.tree())).toEqual(["sub"])

  // After the transcript, never before it: the conversation the person is
  // having keeps the position the eye starts at, on both axes.
  const split = parentSplit(tab.tree(), "sub")!
  expect(split.first.id).toBe("main")
  expect(split.direction).toBe("row")
  // The sidebar's rule, for the sidebar's reason: showing a thing and going to
  // it are two gestures, and this is the one that is not the second.
  expect(tab.focus()).toBe("main")
  // The watched half is the smaller one.
  expect(1 - split.ratio).toBeCloseTo(default_sub_ratio)
})

test("the split goes sideways where two conversations fit and stacks where they do not", () => {
  expect(subSplitDirection(sub_row_min_width)).toBe("row")
  expect(subSplitDirection(sub_row_min_width - 1)).toBe("column")
  expect(subSplitDirection(80)).toBe("column")
  expect(subSplitDirection(120)).toBe("row")

  // And the pane reads the direction back off the tree rather than remembering
  // what the width was when it opened: a terminal resized afterwards must not
  // leave a rule drawn along an edge with nothing behind it.
  const tab = createPaneStore(main_surface, "main")
  tab.apply((tree) => openSubPane(tree, "main", { direction: "column", id: "sub" }))
  expect(subSplitOf(tab.tree(), "sub")).toBe("column")
  expect(subSplitOf(tab.tree(), "main")).toBe("column")
})

test("the split turns when the terminal crosses the width it was decided at", () => {
  const tab = createPaneStore(main_surface, "main")
  tab.apply((tree) => openSubPane(tree, "main", { direction: "row", id: "sub" }))
  const wide = tab.tree()

  // Squeezed under the threshold the pair stacks, instead of staying two
  // thirty-odd column transcripts of cut sentences: the direction is a
  // function of a width somebody goes on changing after the pane is open.
  const narrow = reflowSubSplits(wide, sub_row_min_width - 1)
  expect(subSplitOf(narrow, "sub")).toBe("column")
  // Only the AXIS turns — the share is the person's, and a seam somebody
  // dragged is not something a resize gets to reset.
  expect(parentSplit(narrow, "sub")!.ratio).toBe(parentSplit(wide, "sub")!.ratio)
  // …and widening turns it back.
  expect(subSplitOf(reflowSubSplits(narrow, sub_row_min_width), "sub")).toBe("row")

  // A width that does not cross the threshold gives back the very tree it was
  // handed, which is what lets the screen re-derive this on every resize.
  expect(reflowSubSplits(wide, sub_row_min_width + 40)).toBe(wide)
})

test("a tree with no sub-agent pane in it is left exactly as it was", () => {
  const alone = createPaneStore(main_surface, "main").tree()
  expect(reflowSubSplits(alone, 40)).toBe(alone)
  // And it names the SUB-AGENT splits, not every seam on the screen: the
  // sidebar's own split is across tabs and decides its axis for itself.
  const app = createPaneStore(tab_surface, "portal")
  app.apply((tree) => openSidebar(tree, "portal"))
  expect(reflowSubSplits(app.tree(), 40)).toBe(app.tree())
})

test("closing a sub-agent pane gives the box back without stranding the keyboard", () => {
  const tab = createPaneStore(main_surface, "main")
  tab.apply((tree) => openSubPane(tree, "main", { direction: "row", id: "one" }))
  tab.apply((tree) => openSubPane(tree, "one", { direction: "row", id: "two" }))
  expect(subPanes(tab.tree()).sort()).toEqual(["one", "two"])

  // Closing the FOCUSED one cannot leave the keyboard naming a pane that is
  // gone — the tree's own invariant, which is why this needs no handling here.
  tab.focusOn("two")
  tab.apply((tree) => closeSubPane(tree, "two"))
  expect(subPanes(tab.tree())).toEqual(["one"])
  expect(leaves(tab.tree().root).some((leaf) => leaf.id === tab.focus())).toBe(true)

  // …and the last one takes the split with it: the transcript gets the whole
  // box back, which is the tree's own "a split always has two children".
  tab.apply((tree) => closeSubPane(tree, "one"))
  expect(subPanes(tab.tree())).toEqual([])
  expect(tab.tree().root.kind).toBe("leaf")
})

test("the keyboard is found through the portal, in whichever of the two trees holds it", () => {
  const app = createPaneStore(tab_surface, "portal")
  const tab = createPaneStore(main_surface, "main")

  // One hop: the app tree names the portal, so the answer is the tab's.
  expect(focusThrough(app, tab)).toEqual({ pane: "main", surface: main_surface })

  tab.apply((tree) => openSubPane(tree, "main", { direction: "row", id: "sub" }))
  tab.focusOn("sub")
  expect(focusThrough(app, tab)).toEqual({ pane: "sub", surface: subagent_surface })

  // No hop: a leaf of the app tree answers for itself, and the sub-agent the
  // tab is still focused on is not what the keyboard is in.
  app.apply((tree) => openSidebar(tree, "portal"))
  app.focusOn(sidebarPane(app.tree())!)
  expect(focusThrough(app, tab).surface).toBe("host:sidebar")
})

test("each tab has its own layout, so switching tabs switches trees rather than moving panes", () => {
  const first = createPaneStore(main_surface, "a")
  const second = createPaneStore(main_surface, "b")
  first.apply((tree) => openSubPane(tree, "a", { direction: "row", id: "sub" }))

  // Nothing about opening a pane in one reaches the other: there is no shared
  // tree for a leaf to be marked as belonging to a particular tab in.
  expect(subPanes(first.tree())).toEqual(["sub"])
  expect(subPanes(second.tree())).toEqual([])
  expect(second.tree().root.kind).toBe("leaf")
})

test("a pane says whose work it is and that it cannot be typed into", () => {
  expect(attributionOf({ persona: "explore", label: "d-0123456789ab" })).toBe(
    "explore · d-0123456789ab · observing",
  )
  // No persona to name — a session that wears no `agent-*` prompt — is one
  // fewer thing said, not a placeholder word.
  expect(attributionOf({ persona: null, label: "s-1" })).toBe("s-1 · observing")
})

// ── the screen ──────────────────────────────────────────────────────────────

let ws: TempWorkspace
let parent: string
let child: string

/**
 * A parent whose transcript holds one sub-session card, and a child that has
 * actually said something — an empty pane would pin the chrome and nothing
 * else, and what this is for is two conversations on one screen.
 */
beforeAll(async () => {
  ws = tempWorkspace()
  parent = await sessionNew(ws, { profile: "scripted" })
  child = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, child, "what did the delegate find")
  const step = sessionStep(ws, child, { env: scripted_env })
  for await (const _ of step.lines) {
    // Drain: the events are what the pane replays.
  }
  await step.exited
}, 180_000)

afterAll(() => ws.cleanup())

/**
 * The parent's screen, with the one card that names the child on it. The shape
 * a `nulya session new` inside a step leaves behind: the id is in the tool
 * RESULT, which is why replay finds it too.
 */
async function screen(width: number, height = 24) {
  const state = createSessionState(parent)
  state.applyEvent({
    seq: 1,
    kind: "assistant",
    text: "spawning a sub-session",
    calls: [{ id: "c1", tool: "shell", args: JSON.stringify({ command: "nulya session new --model scripted" }) }],
  })
  state.applyEvent({
    seq: 2,
    kind: "tool_results",
    results: [{ call_id: "c1", ok: true, output: `${child}\n[exit 0]`, spill_path: null }],
  })
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={parent}
        state={state}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, `tui-state-${Math.random().toString(36).slice(2)}.json`)}
      />
    ),
    { width, height },
  )
  await settle(setup, 4)
  return setup
}

/** Browse to the card and take its primary route: watch it here. */
async function watchHere(setup: Awaited<ReturnType<typeof screen>>) {
  setup.mockInput.pressEscape()
  await settle(setup, 3)
  setup.mockInput.pressEnter()
  await until(() => setup.captureCharFrame().includes("observing"), 30_000)
  return settle(setup, 6)
}

/**
 * A frame with the parts that move stopped: session ids carry a timestamp and
 * the composition card carries a date. Masked to the SAME width, because what
 * a snapshot is for is the layout.
 */
const steady = (frame: string) =>
  frame
    .replace(/s-\d+-[0-9a-f]+/g, (id) => "#".repeat(id.length))
    .replace(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}/g, (when) => "-".repeat(when.length))
    .replace(/just now|\d+[mhd] ago/g, (when) => "~".repeat(when.length))

test("a wide terminal puts the delegation beside the conversation that made it", async () => {
  const setup = await screen(120)
  try {
    const frame = await watchHere(setup)
    // Both at once: this is a split of the tab's content area, not a screen
    // that replaced another one.
    expect(frame).toContain("sub-session")
    expect(frame).toContain("what did the delegate find")
    // The attribution line, and the one word that says this half is read-only.
    expect(frame).toContain(`${style.glyphs.subSession} ${child} · observing`)
    // Side by side: the parent's own link row and the seam are on the SAME row
    // of the frame, which is only true of a row split.
    const rows = frame.split("\n")
    expect(rows.some((row) => row.includes("↗ watch") && row.includes(vertical_rule))).toBe(true)

    // And the box still takes what is typed: opening a pane is not going to it
    // (`openSubPane`'s `focusNew: false`).
    await setup.mockInput.typeText("still typing here")
    expect(await settle(setup, 4)).toContain("still typing here")
    // Eight passes, like `/help`'s: a busy machine has captured a half-painted
    // frame here once, and a snapshot that flaky is worse than none.
    expect(steady(await settle(setup, 8))).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("a narrow terminal stacks them instead, and the rule turns with the split", async () => {
  const setup = await screen(80)
  try {
    const frame = await watchHere(setup)
    expect(frame).toContain(`${style.glyphs.subSession} ${child} · observing`)
    // Stacked: the attribution line is preceded by a full-width rule, and no
    // row holds both conversations.
    const rows = frame.split("\n")
    const at = rows.findIndex((row) => row.includes("· observing"))
    expect(at).toBeGreaterThan(0)
    expect(rows[at - 1]).toContain(style.glyphs.hairline)
    // …and the inverse of the wide case: no seam beside the parent's own rows,
    // because there is nothing beside them.
    expect(rows.some((row) => row.includes("↗ watch") && row.includes(vertical_rule))).toBe(false)
    expect(steady(await settle(setup, 8))).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("the keyboard reaches the pane, scrolls it, and Esc closes it", async () => {
  const setup = await screen(120)
  try {
    await watchHere(setup)
    // A second pane exists, so the pane-motion layer is on — and Ctrl+→ is the
    // way in on a row split.
    press(setup, ctrl_right)
    await settle(setup, 3)
    // Focused, the pane says what its keys are — one dim line, like every
    // other face on this screen (§6.1 rule 8).
    expect(setup.captureCharFrame()).toContain("Esc closes")

    setup.mockInput.pressEscape()
    await until(() => !setup.captureCharFrame().includes("observing"), 20_000)
    const closed = await settle(setup, 4)
    // The pane is gone and the conversation has the whole box back.
    expect(closed).not.toContain("observing")
    expect(closed).toContain("sub-session")
    // …and the keyboard comes home with it.
    await setup.mockInput.typeText("back in the box")
    expect(await settle(setup, 2)).toContain("back in the box")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("a tab remembers its own layout, and closing it takes the pane with it", async () => {
  const setup = await screen(120)
  try {
    await watchHere(setup)

    // A second tab: its tree is its own, so nothing of the first tab's layout
    // is on screen while it is in front.
    await setup.mockInput.typeText("/new")
    setup.mockInput.pressEnter()
    await until(() => !setup.captureCharFrame().includes("observing"), 30_000)

    // Back to the first: the pane is where it was left.
    setup.mockInput.pressKey("F4")
    await until(() => setup.captureCharFrame().includes("observing"), 30_000)

    // Close the conversation that opened it, and the window onto its
    // delegation goes with it — there is nowhere else it was ever shown.
    setup.mockInput.pressKey("w", { ctrl: true })
    await until(() => !setup.captureCharFrame().includes("observing"), 30_000)
    expect(setup.captureCharFrame()).not.toContain("observing")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
