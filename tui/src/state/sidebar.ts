/**
 * The sessions sidebar as an operation on the pane tree.
 *
 * Everything here is a pure function over a `PaneTree`, for the reason the tree
 * itself is pure: whether the sidebar is open, how wide it is, and how many
 * columns it will actually be drawn in are questions a test can ask without a
 * terminal — and the answers must be the SAME ones the paint gets, which is why
 * `sidebarWidth` measures through `layout()` rather than doing the arithmetic
 * again. A second copy of `round(width × ratio)` is a second answer waiting to
 * disagree with the first.
 *
 * The sidebar is a pane like any other. It is not a mode, not a flag on the
 * host, not a special case in `PaneHost` — the whole of it is "there is a row
 * split whose first child shows `host:sidebar`", which is what makes §5.1's
 * claim checkable: the host's own second pane goes in through the same door a
 * package's will.
 */
import {
  clampRatio,
  closePane,
  layout,
  leaves,
  parentSplit,
  resizeSplit,
  splitPane,
  type PaneId,
  type PaneTree,
} from "../pane/tree.ts"
import { sidebar_surface } from "./panes.ts"

/**
 * A quarter of the screen. Wide enough at 80 columns for a sentence to be
 * recognisable (18 columns of content), narrow enough that the transcript —
 * which is what the screen is for — keeps its own `max_width`.
 */
export const default_sidebar_ratio = 0.25

/**
 * Below this the sidebar hides itself, and comes back when there is room again.
 *
 * The same threshold the status line's right half uses: under 60
 * columns a quarter of the screen is fifteen cells, which is a column of
 * ellipses rather than a list. Hiding rather than shrinking, because a rail
 * that cannot say which session a row is is not a smaller sidebar — it is
 * furniture in front of the transcript.
 */
export const sidebar_min_width = 60

export function sidebarPane(tree: PaneTree): PaneId | null {
  return leaves(tree.root).find((leaf) => leaf.surface === sidebar_surface)?.id ?? null
}

export function isSidebarOpen(tree: PaneTree): boolean {
  return sidebarPane(tree) !== null
}

/**
 * Put the sidebar beside `main`, WITHOUT giving it the keyboard.
 *
 * `focusNew: false` keeps the promise that a sidebar "has no reason
 * to stop a person typing": showing the list is not the same gesture as going
 * to it, and the one people do a hundred times a day is the first. Focusing it
 * takes the keyboard — there is no third state where a pane answers `j` while
 * the composer still blinks — but nothing focuses it except a person.
 */
export function openSidebar(tree: PaneTree, main: PaneId, ratio = default_sidebar_ratio): PaneTree {
  if (isSidebarOpen(tree)) return tree
  return splitPane(tree, main, {
    direction: "row",
    surface: sidebar_surface,
    ratio,
    place: "before",
    focusNew: false,
  })
}

export function closeSidebar(tree: PaneTree): PaneTree {
  const pane = sidebarPane(tree)
  return pane ? closePane(tree, pane) : tree
}

/** The sidebar's share of the screen, or null when it is not open. */
export function sidebarRatio(tree: PaneTree): number | null {
  const pane = sidebarPane(tree)
  if (!pane) return null
  const split = parentSplit(tree, pane)
  if (!split) return null
  return split.first.id === pane ? split.ratio : 1 - split.ratio
}

/**
 * Drag the seam. `share` is the sidebar's, whichever side of the split it is
 * on — the same convention `splitPane` takes, so the one number a caller has
 * ("a quarter of the screen") never has to be flipped at a call site.
 */
export function resizeSidebar(tree: PaneTree, share: number): PaneTree {
  const pane = sidebarPane(tree)
  if (!pane) return tree
  const split = parentSplit(tree, pane)
  if (!split) return tree
  const wanted = clampRatio(share)
  return resizeSplit(tree, split.id, split.first.id === pane ? wanted : 1 - wanted)
}

/**
 * How many columns the sidebar is actually drawn in, on a screen this wide.
 *
 * Measured through the model's own `layout`, so the columns this returns are
 * the columns the seam is at. The content area spans the full terminal width
 * (the split is the whole of it), so the screen's width is the box's.
 */
export function sidebarWidth(tree: PaneTree, screenWidth: number): number {
  const pane = sidebarPane(tree)
  if (!pane) return 0
  const boxes = layout(tree.root, { x: 0, y: 0, width: Math.max(0, screenWidth), height: 1 })
  return boxes.find((box) => box.pane === pane)?.rect.width ?? 0
}
