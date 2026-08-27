/**
 * A sub-agent observation pane, as an operation on ONE TAB's pane tree
 * (goals/tui-shell.md §5.3c, T72).
 *
 * The sibling of `state/sidebar.ts`, and deliberately the same shape: pure
 * functions over a `PaneTree`, so what a split does — which side the newcomer
 * lands on, which way the box divides, what happens to the focus when it
 * closes — is answerable without a terminal, and the answers a test gets are
 * the answers the paint gets.
 *
 * WHY IT IS A PANE AND NOT A TAB. A delegation belongs to the conversation that
 * made it. The tab strip is horizontal and has no shape for "under": an indent
 * on a strip is not a hierarchy, it is a gap. A split inside the tab says the
 * relationship structurally — close the tab and the thing it was watching goes
 * with it, because it was never anywhere else.
 */
import {
  closePane,
  leaves,
  parentSplit,
  splitPane,
  type PaneId,
  type PaneTree,
  type SplitDirection,
} from "../pane/tree.ts"
import { subagent_surface } from "./panes.ts"

/**
 * The watched conversation's share of the tab's box.
 *
 * Less than half on purpose: the pane is a window onto somebody else's work,
 * and the conversation the person is actually having is the one that keeps the
 * larger half of the screen (and, at 100 columns, its own readable width).
 */
export const default_sub_ratio = 0.4

/**
 * At or above this width the split is side by side; below it, stacked.
 *
 * The same number `/ext` and the status line already use to decide that there
 * is room for two things at once. Under it, two transcripts sharing the width
 * would each be thirty-odd columns of cut sentences — a stacked pair keeps both
 * of them readable and spends the terminal's other axis instead.
 */
export const sub_row_min_width = 100

export function subSplitDirection(width: number): SplitDirection {
  return width >= sub_row_min_width ? "row" : "column"
}

/** Every sub-agent pane in this tab, in tree order. */
export function subPanes(tree: PaneTree): PaneId[] {
  return leaves(tree.root)
    .filter((leaf) => leaf.surface === subagent_surface)
    .map((leaf) => leaf.id)
}

export interface OpenSubOptions {
  readonly direction: SplitDirection
  readonly ratio?: number
  readonly id?: PaneId
  readonly splitId?: PaneId
}

/**
 * Split `main` and put the watched conversation after it — to the right in a
 * row, below in a column. Both readings are the same one: the thing that was
 * already there keeps the position the eye starts at.
 *
 * FOCUS DOES NOT FOLLOW IT — the sidebar's rule, for the sidebar's reason
 * (T69). The gesture is "let me see that", and the conversation the person is
 * having is still the one they are typing into; a pane that claims the keyboard
 * the moment it appears is a composer that stops answering without anybody
 * having asked it to. Going there is `Ctrl+→` (or `Ctrl+↓` on a stacked
 * split), or a click; coming back is Esc.
 */
export function openSubPane(tree: PaneTree, main: PaneId, options: OpenSubOptions): PaneTree {
  return splitPane(tree, main, {
    direction: options.direction,
    surface: subagent_surface,
    ratio: options.ratio ?? default_sub_ratio,
    place: "after",
    focusNew: false,
    ...(options.id ? { id: options.id } : {}),
    ...(options.splitId ? { splitId: options.splitId } : {}),
  })
}

export function closeSubPane(tree: PaneTree, pane: PaneId): PaneTree {
  return closePane(tree, pane)
}

/**
 * Which way the split that holds this pane divides — what the pane needs to
 * know to draw its own hairline on the side the seam is actually on.
 *
 * Read from the tree rather than remembered from the width at the moment it
 * opened: a terminal that is resized after the fact would otherwise leave a
 * rule drawn along an edge that no longer has a neighbour behind it.
 */
export function subSplitOf(tree: PaneTree, pane: PaneId): SplitDirection | null {
  return parentSplit(tree, pane)?.direction ?? null
}
