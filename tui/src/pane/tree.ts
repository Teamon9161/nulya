/**
 * The pane tree: which surface owns which part of the screen (goals/tui-shell.md
 * §5.1).
 *
 * A tiling window manager's model, and nothing more than that. A node is either
 * a LEAF (one surface instance) or a SPLIT (a direction, a ratio, two children).
 * There is no floating, no overlap, no tab-in-pane and no detach — §5.1b draws
 * that line on purpose: the object of a pane here is a structured surface, not a
 * PTY, so the expensive half of a multiplexer is not ours to build.
 *
 * Everything in this file is a pure function over immutable nodes: an operation
 * returns a NEW tree and never mutates the one it was given, which is what lets
 * the whole model be tested without a terminal and lets Solid treat a tree as a
 * plain signal value.
 *
 * Two invariants hold across every operation and are asserted by the tests:
 *
 *  - `focus` always names a leaf that exists in `root`. Closing the focused pane
 *    hands focus to a sibling rather than leaving it dangling.
 *  - a split always has two children. Removing one child replaces the split with
 *    the other child, so an empty split cannot exist to be reasoned about.
 */

export type PaneId = string

/** Which surface a leaf shows. The registry (`pane/registry.ts`) resolves it. */
export type SurfaceId = string

/**
 * How a split divides its box, in flexbox's words so that the model and the
 * paint cannot mean different things by the same word: `row` puts the children
 * side by side (a vertical seam), `column` stacks them (a horizontal seam).
 */
export type SplitDirection = "row" | "column"

export type PaneNode =
  | { readonly kind: "leaf"; readonly id: PaneId; readonly surface: SurfaceId }
  | {
      readonly kind: "split"
      readonly id: PaneId
      readonly direction: SplitDirection
      /** The first child's share of the box, in (0, 1). */
      readonly ratio: number
      readonly first: PaneNode
      readonly second: PaneNode
    }

export interface PaneTree {
  readonly root: PaneNode
  /** Always a leaf id present in `root`. */
  readonly focus: PaneId
}

export interface Rect {
  readonly x: number
  readonly y: number
  readonly width: number
  readonly height: number
}

/** One leaf, placed. What the hit test and directional focus work on. */
export interface PaneBox {
  readonly pane: PaneId
  readonly surface: SurfaceId
  readonly rect: Rect
}

/**
 * How small a pane may be squeezed by dragging a seam. Not a paint concern: a
 * pane thinner than this cannot show a gutter plus content (tui.md §6.5 puts
 * every surface's content at column 3), so the model refuses to describe one.
 */
export const min_ratio = 0.1
export const max_ratio = 0.9

let counter = 0

/** A fresh pane id. Callers that care (tests, replay) pass their own instead. */
export function nextPaneId(): PaneId {
  counter += 1
  return `pane-${counter}`
}

/** The degenerate tree every session starts on: one pane, one surface. */
export function singlePane(surface: SurfaceId, id: PaneId = nextPaneId()): PaneTree {
  return { root: { kind: "leaf", id, surface }, focus: id }
}

export function isSingle(tree: PaneTree): boolean {
  return tree.root.kind === "leaf"
}

export function leaves(node: PaneNode): (PaneNode & { kind: "leaf" })[] {
  if (node.kind === "leaf") return [node]
  return [...leaves(node.first), ...leaves(node.second)]
}

export function findLeaf(tree: PaneTree, pane: PaneId): (PaneNode & { kind: "leaf" }) | null {
  return leaves(tree.root).find((leaf) => leaf.id === pane) ?? null
}

/** The surface the keyboard would go to, before any dialog preempts it. */
export function focusedLeaf(tree: PaneTree): (PaneNode & { kind: "leaf" }) | null {
  return findLeaf(tree, tree.focus)
}

export function focusedSurface(tree: PaneTree): SurfaceId | null {
  return focusedLeaf(tree)?.surface ?? null
}

/** Replace one node in the tree, returning the new root. Identity if absent. */
function replaceNode(node: PaneNode, target: PaneId, make: (found: PaneNode) => PaneNode): PaneNode {
  if (node.id === target) return make(node)
  if (node.kind === "leaf") return node
  const first = replaceNode(node.first, target, make)
  const second = replaceNode(node.second, target, make)
  if (first === node.first && second === node.second) return node
  return { ...node, first, second }
}

/**
 * Show a different surface in an existing pane.
 *
 * This — not split/close — is what opening and closing a full-screen view is
 * while there is only one pane, which is why the migration in T68 could keep
 * the drawn result byte-identical: one leaf whose surface changes.
 */
export function setSurface(tree: PaneTree, pane: PaneId, surface: SurfaceId): PaneTree {
  const root = replaceNode(tree.root, pane, (found) =>
    found.kind === "leaf" ? { ...found, surface } : found,
  )
  return root === tree.root ? tree : { ...tree, root }
}

export interface SplitOptions {
  readonly direction: SplitDirection
  readonly surface: SurfaceId
  /**
   * The share of the box the NEW pane gets, clamped into [min_ratio,
   * max_ratio]. The new pane's, not the first child's: a caller asking for a
   * sidebar asks for the sidebar's width, and having to know whether `place`
   * flipped whose number it was is exactly the kind of arithmetic that gets
   * done differently at two call sites.
   */
  readonly ratio?: number
  /** Whether the new pane goes after the existing one (default) or before it. */
  readonly place?: "after" | "before"
  readonly id?: PaneId
  readonly splitId?: PaneId
  /** Whether focus follows the new pane. Default true — it was just asked for. */
  readonly focusNew?: boolean
}

/** Divide one pane in two. Focus follows the new pane unless told otherwise. */
export function splitPane(tree: PaneTree, pane: PaneId, options: SplitOptions): PaneTree {
  const existing = findLeaf(tree, pane)
  if (!existing) return tree
  const fresh: PaneNode = { kind: "leaf", id: options.id ?? nextPaneId(), surface: options.surface }
  const before = options.place === "before"
  const share = clampRatio(options.ratio ?? 0.5)
  const root = replaceNode(tree.root, pane, (found) => ({
    kind: "split",
    id: options.splitId ?? nextPaneId(),
    direction: options.direction,
    // A node's `ratio` is its FIRST child's share, while the option is the new
    // pane's — so which of the two numbers it is depends on where the newcomer
    // landed, and that conversion happens here once rather than at every call.
    ratio: before ? share : clampRatio(1 - share),
    first: before ? fresh : found,
    second: before ? found : fresh,
  }))
  const focus = options.focusNew === false ? tree.focus : fresh.id
  return { root, focus }
}

/**
 * Close a pane; its sibling takes the whole box.
 *
 * Closing the last pane is refused — the tree returns unchanged. What should be
 * on screen instead of nothing is host policy, not a property of the model, and
 * a model that can represent "no panes" makes every consumer handle a state
 * that is never wanted.
 */
export function closePane(tree: PaneTree, pane: PaneId): PaneTree {
  if (tree.root.kind === "leaf") return tree
  if (!findLeaf(tree, pane)) return tree
  const root = removeLeaf(tree.root, pane)
  if (!root) return tree
  const focus = leaves(root).some((leaf) => leaf.id === tree.focus)
    ? tree.focus
    : // The closed pane held the focus: hand it to whatever moved into its box,
      // which is the sibling's first leaf — the nearest thing to "where you
      // were looking" that survives.
      (nearestLeafOf(root, pane) ?? leaves(root)[0]!.id)
  return { root, focus }
}

function removeLeaf(node: PaneNode, pane: PaneId): PaneNode | null {
  if (node.kind === "leaf") return node.id === pane ? null : node
  const first = removeLeaf(node.first, pane)
  const second = removeLeaf(node.second, pane)
  if (!first) return second
  if (!second) return first
  if (first === node.first && second === node.second) return node
  return { ...node, first, second }
}

/** After a removal, the leaf that inherited the closed pane's box. */
function nearestLeafOf(root: PaneNode, _closed: PaneId): PaneId | null {
  const all = leaves(root)
  return all.length > 0 ? all[0]!.id : null
}

/**
 * The split a leaf hangs directly under, or null at the root of a single pane.
 *
 * `resizeSplit` names the SPLIT rather than either child, because a seam
 * belongs to neither of the panes it separates. A caller only ever holds the
 * pane it cares about ("make the sidebar wider"), so the walk from the one it
 * knows to the one it must name has to exist somewhere — here, once, rather
 * than in each consumer that wants to drag a seam.
 */
export function parentSplit(tree: PaneTree, pane: PaneId): (PaneNode & { kind: "split" }) | null {
  const walk = (node: PaneNode): (PaneNode & { kind: "split" }) | null => {
    if (node.kind === "leaf") return null
    if (node.first.id === pane || node.second.id === pane) return node
    return walk(node.first) ?? walk(node.second)
  }
  return walk(tree.root)
}

export function clampRatio(ratio: number): number {
  if (!Number.isFinite(ratio)) return 0.5
  return Math.min(Math.max(ratio, min_ratio), max_ratio)
}

/** Drag a seam. `split` names the split node, not either of its children. */
export function resizeSplit(tree: PaneTree, split: PaneId, ratio: number): PaneTree {
  const root = replaceNode(tree.root, split, (found) =>
    found.kind === "split" ? { ...found, ratio: clampRatio(ratio) } : found,
  )
  return root === tree.root ? tree : { ...tree, root }
}

/** Move the keyboard to a named pane. A pane that is not there is ignored. */
export function focusPane(tree: PaneTree, pane: PaneId): PaneTree {
  if (tree.focus === pane) return tree
  if (!findLeaf(tree, pane)) return tree
  return { ...tree, focus: pane }
}

/**
 * Place every leaf inside a box, in terminal cells.
 *
 * Rounding is settled here rather than left to the paint: the first child gets
 * `round(size × ratio)` clamped so that both children keep at least one cell
 * whenever there are two to give, and the second child takes the remainder. A
 * box too small to divide gives everything to the first child and a zero-width
 * rect to the second — honest rather than clamped into a lie, and a zero-sized
 * rect can never win a hit test.
 */
export function layout(root: PaneNode, rect: Rect): PaneBox[] {
  const out: PaneBox[] = []
  place(root, rect, out)
  return out
}

function place(node: PaneNode, rect: Rect, out: PaneBox[]): void {
  if (node.kind === "leaf") {
    out.push({ pane: node.id, surface: node.surface, rect })
    return
  }
  const along = node.direction === "row" ? rect.width : rect.height
  const first = divide(along, node.ratio)
  const second = Math.max(along - first, 0)
  if (node.direction === "row") {
    place(node.first, { ...rect, width: first }, out)
    place(node.second, { ...rect, x: rect.x + first, width: second }, out)
  } else {
    place(node.first, { ...rect, height: first }, out)
    place(node.second, { ...rect, y: rect.y + first, height: second }, out)
  }
}

function divide(total: number, ratio: number): number {
  if (total <= 0) return 0
  if (total < 2) return total
  return Math.min(Math.max(Math.round(total * ratio), 1), total - 1)
}

/** Which pane a cell belongs to. Null outside the laid-out box. */
export function paneAt(boxes: readonly PaneBox[], x: number, y: number): PaneBox | null {
  for (const box of boxes) {
    const { rect } = box
    if (rect.width <= 0 || rect.height <= 0) continue
    if (x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height) return box
  }
  return null
}

export type FocusDirection = "left" | "right" | "up" | "down"

/**
 * The keyboard moves to the neighbour in a direction — a tiling WM's rule, and
 * the reason the geometry above has to exist at all: "the pane to the right" is
 * not a question the tree shape can answer, only the placement can.
 *
 * Candidates are the panes that start past the focused pane's edge in that
 * direction AND overlap it on the other axis; the nearest wins, ties going to
 * the one that overlaps most. No candidate means the focus does not move —
 * there is no wrap-around, because a keystroke that jumps the screen when a
 * pane happens to be at the edge is worse than one that does nothing.
 */
export function moveFocus(tree: PaneTree, rect: Rect, direction: FocusDirection): PaneTree {
  const boxes = layout(tree.root, rect)
  const from = boxes.find((box) => box.pane === tree.focus)
  if (!from) return tree
  const horizontal = direction === "left" || direction === "right"
  const forward = direction === "right" || direction === "down"

  const start = (box: PaneBox) => (horizontal ? box.rect.x : box.rect.y)
  const size = (box: PaneBox) => (horizontal ? box.rect.width : box.rect.height)
  const crossStart = (box: PaneBox) => (horizontal ? box.rect.y : box.rect.x)
  const crossSize = (box: PaneBox) => (horizontal ? box.rect.height : box.rect.width)

  const overlap = (box: PaneBox) =>
    Math.min(crossStart(from) + crossSize(from), crossStart(box) + crossSize(box)) -
    Math.max(crossStart(from), crossStart(box))

  const candidates = boxes.filter((box) => {
    if (box.pane === from.pane) return false
    if (size(box) <= 0 || crossSize(box) <= 0) return false
    if (overlap(box) <= 0) return false
    return forward ? start(box) >= start(from) + size(from) : start(box) + size(box) <= start(from)
  })
  if (candidates.length === 0) return tree

  const distance = (box: PaneBox) =>
    forward ? start(box) - (start(from) + size(from)) : start(from) - (start(box) + size(box))
  const best = candidates.reduce((winner, box) => {
    const closer = distance(box) - distance(winner)
    if (closer !== 0) return closer < 0 ? box : winner
    const wider = overlap(box) - overlap(winner)
    if (wider !== 0) return wider > 0 ? box : winner
    return crossStart(box) < crossStart(winner) ? box : winner
  })
  return focusPane(tree, best.pane)
}
