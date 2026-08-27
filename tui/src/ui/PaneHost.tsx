/**
 * The pane tree, drawn (goals/tui-shell.md §5.1).
 *
 * The host mounts the content area through this instead of a `<Switch>` over
 * overlay kinds. Two rules earn their place here:
 *
 * ONE PANE DRAWS AS ITSELF. A tree that is a single leaf renders the surface
 * with NO wrapper box around it — exactly what the `<Switch>` it replaced
 * produced. That is not an optimisation, it is the acceptance criterion of S1a:
 * today's screen is the degenerate case of the new model, so today's screen has
 * to come out byte-identical. A wrapper would be a flex container the old
 * layout did not have, and one that inherits the child's sizing wrongly is how
 * "no visual change" quietly stops being true.
 *
 * THE HIT TEST IS THE RENDERABLE TREE. A pane inside a split gets a box of its
 * own with `onMouseDown` on it, and a click anywhere inside that box bubbles up
 * to it — so the pane a click lands in is decided by the same layout that drew
 * it, and the two cannot disagree. `pane/tree.ts` still models the geometry
 * (`layout` / `paneAt`), because directional focus movement is a question only
 * placement can answer, and because S2 surfaces will want pane-local
 * coordinates — but the routing of an actual click does not go through a second
 * copy of the layout that could drift from the paint.
 *
 * The wrapper never claims the event. `ui/rows.ts` already decides what a click
 * IS (press and release in the same cell); focusing a pane is a strictly weaker
 * thing that happens on the way down and must not stop a row underneath from
 * also acting on it.
 */
import { createMemo, type JSX } from "solid-js"
import { clampRatio, type PaneNode, type PaneTree } from "../pane/tree.ts"
import type { SurfaceMount, SurfaceRegistry } from "../pane/registry.ts"

export function PaneHost(props: {
  tree: PaneTree
  registry: SurfaceRegistry<JSX.Element>
  /** A click landed in a pane. Only ever called when there is more than one. */
  onFocusPane?: (pane: string) => void
}): JSX.Element {
  /**
   * Keyed on the ROOT NODE, not the tree: the pure operations return the same
   * root object when only the focus moved, so moving the keyboard between panes
   * does not tear down and rebuild what is on screen. Changing a pane's surface
   * does return a new root, and rebuilding then is exactly what the `<Switch>`
   * did when an overlay opened.
   */
  const root = createMemo(() => props.tree.root)

  const mountOf = (node: PaneNode & { kind: "leaf" }): SurfaceMount => ({
    pane: node.id,
    // A getter rather than a value: read inside JSX it stays reactive, so a
    // surface that cares whether it has the keyboard sees the focus move
    // without the pane being rebuilt around it.
    get focused() {
      return props.tree.focus === node.id
    },
  })

  const body = (node: PaneNode & { kind: "leaf" }): JSX.Element => {
    const definition = props.registry.get(node.surface)
    // A pane pointing at a surface nobody registered draws nothing. It is a
    // bug — a package that failed to load, a stale id — and the honest shape of
    // that bug is an empty pane the keyboard still works around, not a box of
    // apology text (tui.md §6.1 rule 4).
    if (!definition) return null
    return definition.render(mountOf(node))
  }

  /** `share` is null at the root, where nothing divides the box yet. */
  const draw = (node: PaneNode, share: number | null): JSX.Element => {
    if (node.kind === "leaf") {
      const drawn = body(node)
      if (share === null) return drawn
      return (
        <box
          flexGrow={share}
          flexBasis={0}
          flexShrink={1}
          flexDirection="column"
          onMouseDown={() => props.onFocusPane?.(node.id)}
        >
          {drawn}
        </box>
      )
    }
    const ratio = clampRatio(node.ratio)
    return (
      <box flexDirection={node.direction} flexGrow={share ?? 1} flexBasis={0} flexShrink={1}>
        {draw(node.first, ratio)}
        {draw(node.second, 1 - ratio)}
      </box>
    )
  }

  // Returned as a memo, the shape `Switch` itself returns: one dynamic child in
  // the parent's flow with no wrapper of its own.
  return createMemo(() => draw(root(), null)) as unknown as JSX.Element
}
