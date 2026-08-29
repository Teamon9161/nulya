/**
 * The pane model (goals/tui-shell.md §5.1, tui.md §11 T68).
 *
 * Three pure things get pinned here, and each one is pinned for the same
 * reason: they are the answers a window manager gives that no frame can show.
 *
 *  - the TREE: that an operation never leaves a tree that cannot be drawn (a
 *    focus naming a pane that is gone, a split with one child), and that the
 *    geometry two panes are placed at is the geometry the seam is at.
 *  - the REGISTRY: that first holder wins, so no package can take a screen a
 *    person has to be able to trust.
 *  - the ARBITER: the ORDER the keyboard is claimed in — the one property that
 *    was, before T68, spelled only as the order of `if`s in a 3000-line file.
 */
import { expect, test } from "bun:test"
import {
  clampRatio,
  closePane,
  focusPane,
  focusedSurface,
  layout,
  leaves,
  moveFocus,
  paneAt,
  resizeSplit,
  setSurface,
  singlePane,
  splitPane,
  type PaneTree,
  type Rect,
} from "../src/pane/tree.ts"
import { claimsKeyboard, createSurfaceRegistry, host_owner, type SurfaceDefinition } from "../src/pane/registry.ts"
import { composerHasKeyboard, resolveFocus, type FocusState } from "../src/pane/focus.ts"
import { main_surface, overlayKindOf, overlay_surfaces } from "../src/state/panes.ts"

const screen: Rect = { x: 0, y: 0, width: 80, height: 24 }

/** The tree every session opens on, with ids the assertions can name. */
function pair(direction: "row" | "column" = "row"): PaneTree {
  const one = singlePane("a", "one")
  return splitPane(one, "one", { direction, surface: "b", id: "two", splitId: "s" })
}

// ── the tree ────────────────────────────────────────────────────────────────

test("a fresh tree is one pane holding one surface", () => {
  const tree = singlePane(main_surface, "only")
  expect(leaves(tree.root)).toHaveLength(1)
  expect(tree.focus).toBe("only")
  expect(focusedSurface(tree)).toBe(main_surface)
})

test("changing a pane's surface is what opening a view is, and leaves the tree shape alone", () => {
  const tree = singlePane(main_surface, "only")
  const opened = setSurface(tree, "only", overlay_surfaces.ext)
  expect(focusedSurface(opened)).toBe(overlay_surfaces.ext)
  expect(leaves(opened.root)).toHaveLength(1)
  // Closing is the same move back, so there is no second code path to keep in
  // step with the first.
  expect(focusedSurface(setSurface(opened, "only", main_surface))).toBe(main_surface)
})

test("an operation returns a new tree and never mutates the one it was given", () => {
  const tree = singlePane("a", "one")
  const after = setSurface(tree, "one", "b")
  expect(focusedSurface(tree)).toBe("a")
  expect(after).not.toBe(tree)
})

test("a split puts both panes in the tree and hands the focus to the new one", () => {
  const tree = pair()
  expect(leaves(tree.root).map((leaf) => leaf.id)).toEqual(["one", "two"])
  expect(tree.focus).toBe("two")
})

test("a split's ratio is the new pane's share whichever side it lands on", () => {
  // The contract S1b's sidebar depends on: ask for a quarter, get a quarter,
  // without having to know that `place` flipped whose number it was.
  const split = (place: "before" | "after") =>
    splitPane(singlePane("a", "one"), "one", {
      direction: "row",
      surface: "b",
      id: "two",
      splitId: "s",
      ratio: 0.25,
      place,
    })
  const widthOf = (tree: PaneTree, pane: string) =>
    layout(tree.root, screen).find((box) => box.pane === pane)!.rect
  expect(widthOf(split("before"), "two")).toEqual({ x: 0, y: 0, width: 20, height: 24 })
  expect(widthOf(split("after"), "two").width).toBe(20)
  expect(widthOf(split("after"), "two").x).toBe(60)
})

test("closing a pane gives its box to the sibling and never leaves the focus dangling", () => {
  const tree = pair()
  const closed = closePane(tree, "two")
  expect(leaves(closed.root).map((leaf) => leaf.id)).toEqual(["one"])
  // The focus was on the pane that went away; it has to land somewhere real.
  expect(leaves(closed.root).some((leaf) => leaf.id === closed.focus)).toBe(true)
  // A split with one child cannot exist to be reasoned about.
  expect(closed.root.kind).toBe("leaf")
})

test("closing the last pane is refused rather than emptying the screen", () => {
  const tree = singlePane("a", "only")
  expect(closePane(tree, "only")).toBe(tree)
})

test("a seam cannot be dragged until a pane has no room for its content", () => {
  const tree = pair()
  const squeezed = resizeSplit(tree, "s", 0.001)
  const boxes = layout(squeezed.root, screen)
  for (const box of boxes) expect(box.rect.width).toBeGreaterThan(0)
  // …and the clamp is the model's, not the caller's, so every entry point gets it.
  expect(clampRatio(5)).toBeLessThanOrEqual(1)
  expect(clampRatio(Number.NaN)).toBe(0.5)
})

test("a resize moves the seam both panes are placed against", () => {
  const boxes = layout(resizeSplit(pair(), "s", 0.25).root, screen)
  const first = boxes.find((box) => box.pane === "one")!
  const second = boxes.find((box) => box.pane === "two")!
  // The one property that matters: no gap and no overlap at the seam.
  expect(second.rect.x).toBe(first.rect.x + first.rect.width)
  expect(first.rect.width + second.rect.width).toBe(screen.width)
})

test("a box too small to divide gives a pane nothing rather than a lie", () => {
  const boxes = layout(pair().root, { x: 0, y: 0, width: 1, height: 24 })
  expect(boxes.some((box) => box.rect.width === 0)).toBe(true)
  // And a pane with no cells can never win a click.
  expect(paneAt(boxes, 0, 0)?.pane).toBe("one")
})

test("a cell belongs to the pane drawn there", () => {
  const boxes = layout(pair().root, screen)
  expect(paneAt(boxes, 0, 0)?.pane).toBe("one")
  expect(paneAt(boxes, 79, 23)?.pane).toBe("two")
  expect(paneAt(boxes, 200, 0)).toBeNull()
})

test("the keyboard moves to the neighbour in a direction, and does not wrap at the edge", () => {
  const tree = pair()
  expect(moveFocus(tree, screen, "left").focus).toBe("one")
  // Already at the left edge: a keystroke that jumped the screen here would be
  // worse than one that does nothing.
  expect(moveFocus(focusPane(tree, "one"), screen, "left").focus).toBe("one")
  expect(moveFocus(focusPane(tree, "one"), screen, "right").focus).toBe("two")
  // A vertical move across a vertical seam has no candidate: the panes do not
  // sit above or below one another at all.
  expect(moveFocus(tree, screen, "down").focus).toBe("two")
})

test("directional focus reads the placement, not the tree shape", () => {
  // Stacked panes answer up/down and refuse left/right — the same tree shape as
  // the row case above, so only the geometry can be telling them apart.
  const stacked = pair("column")
  expect(moveFocus(stacked, screen, "up").focus).toBe("one")
  expect(moveFocus(focusPane(stacked, "one"), screen, "down").focus).toBe("two")
  expect(moveFocus(focusPane(stacked, "one"), screen, "right").focus).toBe("one")
})

test("focusing a pane that is not there is ignored", () => {
  const tree = pair()
  expect(focusPane(tree, "ghost")).toBe(tree)
})

// ── the registry ────────────────────────────────────────────────────────────

function definition(id: string, owner = host_owner, claims = true): SurfaceDefinition<string> {
  return { id, title: id, owner, claimsKeyboard: claims, render: () => id }
}

test("a surface name has one holder, and it is the one that got there first", () => {
  const registry = createSurfaceRegistry<string>()
  expect(registry.register(definition(overlay_surfaces.ext)).accepted).toBe(true)

  // The host registers first, so a package cannot take the name of a screen a
  // person has to be able to trust (§1 推论一).
  const stolen = registry.register(definition(overlay_surfaces.ext, { kind: "package", id: "evil" }))
  expect(stolen.accepted).toBe(false)
  expect(registry.get(overlay_surfaces.ext)?.owner).toEqual(host_owner)
  // The loser is reported rather than silently dropped, as store roots do.
  expect(registry.shadowed()).toEqual([{ id: overlay_surfaces.ext, owner: { kind: "package", id: "evil" } }])
})

test("only the registration that won a name may take it back down", () => {
  const registry = createSurfaceRegistry<string>()
  const held = registry.register(definition("x"))
  const lost = registry.register(definition("x", { kind: "package", id: "p" }))
  expect(lost.accepted).toBe(false)
  if (!held.accepted) throw new Error("unreachable")
  held.dispose()
  expect(registry.has("x")).toBe(false)
})

test("a surface nobody registered claims no keyboard", () => {
  const registry = createSurfaceRegistry<string>()
  registry.register(definition(main_surface, host_owner, false))
  registry.register(definition(overlay_surfaces.ext))
  // A pane pointing at a package that failed to load must not be able to
  // swallow every keystroke.
  expect(claimsKeyboard(registry, "host:nothing")).toBe(false)
  expect(claimsKeyboard(registry, null)).toBe(false)
  // The transcript is the one registered surface that does not take keys: what
  // is typed while it is up belongs to the composer.
  expect(claimsKeyboard(registry, main_surface)).toBe(false)
  expect(claimsKeyboard(registry, overlay_surfaces.ext)).toBe(true)
})

test("every overlay name maps to a surface and back", () => {
  for (const [kind, surface] of Object.entries(overlay_surfaces)) {
    expect(overlayKindOf(surface)).toBe(kind as never)
  }
  // The transcript is not an overlay, which is what `kind() === null` meant.
  expect(overlayKindOf(main_surface)).toBeNull()
})

// ── the arbiter ─────────────────────────────────────────────────────────────

const nobody: FocusState = {
  modified: false,
  checkout: false,
  withPicker: false,
  agentPicker: false,
  envPicker: false,
  modePicker: false,
  approval: false,
  keyboardPane: null,
  pluginPanel: false,
  browse: false,
}

test("with nothing else up, the composer has the keyboard", () => {
  expect(composerHasKeyboard(resolveFocus(nobody))).toBe(true)
})

test("the keyboard is claimed in one order, outermost first", () => {
  // All of them up at once: the order is a property of the arbiter, and this is
  // the assertion that says what it is.
  const all: FocusState = {
    ...nobody,
    withPicker: true,
    agentPicker: true,
    envPicker: true,
    modePicker: true,
    approval: true,
    keyboardPane: { pane: "one", surface: overlay_surfaces.ext },
    pluginPanel: true,
    browse: true,
  }
  expect(resolveFocus(all)).toEqual({ kind: "dialog", dialog: "with" })
  expect(resolveFocus({ ...all, withPicker: false })).toEqual({ kind: "dialog", dialog: "agent" })
  expect(resolveFocus({ ...all, withPicker: false, agentPicker: false })).toEqual({ kind: "dialog", dialog: "env" })
  const afterEnv = { ...all, withPicker: false, agentPicker: false, envPicker: false }
  expect(resolveFocus(afterEnv)).toEqual({ kind: "dialog", dialog: "mode" })
  expect(resolveFocus({ ...afterEnv, modePicker: false })).toEqual({
    kind: "dialog",
    dialog: "approval",
  })
  const noDialogs = { ...afterEnv, modePicker: false, approval: false }
  expect(resolveFocus(noDialogs)).toEqual({ kind: "surface", pane: "one", surface: overlay_surfaces.ext })
  expect(resolveFocus({ ...noDialogs, keyboardPane: null })).toEqual({ kind: "plugin-panel" })
  expect(resolveFocus({ ...noDialogs, keyboardPane: null, pluginPanel: false })).toEqual({ kind: "browse" })
})

test("a chord outranks every claimant, so Ctrl+C still reaches the host", () => {
  // The reason this exception exists: killing the step is one of the two ways
  // out of a question nobody wants to answer (tui.md §5.7).
  const asked: FocusState = { ...nobody, approval: true, modified: true }
  expect(resolveFocus(asked)).toEqual({ kind: "composer" })
  expect(resolveFocus({ ...nobody, pluginPanel: true, modified: true })).toEqual({ kind: "composer" })
})

test("a full-screen surface holds the keyboard even against a chord", () => {
  // Not an oversight — it is what `if (overlay.active()) return` did before
  // T68, and the shortcuts that stay live inside a view are keymap layers,
  // which are answered before the arbiter is ever consulted.
  const inside: FocusState = { ...nobody, modified: true, keyboardPane: { pane: "one", surface: "host:ext" } }
  expect(resolveFocus(inside).kind).toBe("surface")
})

test("a pane whose surface does not claim the keyboard leaves it with the composer", () => {
  // The shape S1b's sessions sidebar has: drawn, focusable, and no reason to
  // stop a person typing.
  expect(resolveFocus({ ...nobody, keyboardPane: null })).toEqual({ kind: "composer" })
})
