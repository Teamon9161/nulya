/**
 * The pane tree as this front end's state, and the adapter that lets the screen
 * that used to be "one transcript with an overlay in front of it" go on saying
 * exactly that (goals/tui-shell.md §5.4, S1).
 *
 * `pane/tree.ts` is pure and knows nothing about Solid; this is the signal that
 * holds one, plus the operations spelled as verbs the host actually performs.
 *
 * The second half is the migration itself. Before T68 a screen was chosen by an
 * `OverlayStore`: one signal naming which full-screen view was in front, `null`
 * for the transcript. That store's real content was never "which overlay" — it
 * was **which surface the one pane shows**, and `active()` was **does that
 * surface hold the keyboard**. So it becomes a projection of the pane tree
 * rather than a second place where the answer lives, and every caller keeps its
 * spelling. There is no second source of truth to drift: `kind()` reads the
 * tree, `open()` writes it.
 */
import { createMemo, createSignal, type Accessor } from "solid-js"
import {
  closePane,
  focusPane,
  focusedSurface,
  layout,
  moveFocus,
  resizeSplit,
  setSurface,
  singlePane,
  splitPane,
  type FocusDirection,
  type PaneBox,
  type PaneId,
  type PaneTree,
  type Rect,
  type SplitOptions,
  type SurfaceId,
} from "../pane/tree.ts"
import type { OverlayKind, OverlayStore } from "./overlay.ts"

export interface PaneStore {
  tree: Accessor<PaneTree>
  focus: Accessor<PaneId>
  /** The surface in the focused pane — what the keyboard would reach. */
  surface: Accessor<SurfaceId | null>
  show(surface: SurfaceId, pane?: PaneId): void
  focusOn(pane: PaneId): void
  move(direction: FocusDirection, rect: Rect): void
  split(options: SplitOptions, pane?: PaneId): void
  close(pane?: PaneId): void
  resize(split: PaneId, ratio: number): void
  boxes(rect: Rect): PaneBox[]
}

export function createPaneStore(initial: SurfaceId, id?: PaneId): PaneStore {
  const [tree, setTree] = createSignal<PaneTree>(singlePane(initial, id))
  const focus = createMemo(() => tree().focus)
  const surface = createMemo(() => focusedSurface(tree()))
  return {
    tree,
    focus,
    surface,
    show: (next, pane) => setTree((now) => setSurface(now, pane ?? now.focus, next)),
    focusOn: (pane) => setTree((now) => focusPane(now, pane)),
    move: (direction, rect) => setTree((now) => moveFocus(now, rect, direction)),
    split: (options, pane) => setTree((now) => splitPane(now, pane ?? now.focus, options)),
    close: (pane) => setTree((now) => closePane(now, pane ?? now.focus)),
    resize: (split, ratio) => setTree((now) => resizeSplit(now, split, ratio)),
    boxes: (rect) => layout(tree().root, rect),
  }
}

/**
 * The surface ids the host's own screens hold. Namespaced `host:` because §3.3's
 * rule is "first holder wins" and the host registers first: a package cannot
 * take the name of a screen a person has to be able to trust.
 */
export const main_surface = "host:transcript"

export const overlay_surfaces: Readonly<Record<OverlayKind, SurfaceId>> = {
  sessions: "host:sessions",
  ext: "host:ext",
  help: "host:help",
  settings: "host:settings",
  usage: "host:usage",
  model: "host:model",
  provider: "host:provider",
  tasks: "host:tasks",
}

const overlay_kinds = Object.entries(overlay_surfaces) as [OverlayKind, SurfaceId][]

/** Which overlay a surface id is, or null for the transcript / anything else. */
export function overlayKindOf(surface: SurfaceId | null): OverlayKind | null {
  if (!surface) return null
  return overlay_kinds.find(([, id]) => id === surface)?.[0] ?? null
}

/**
 * The old `OverlayStore` shape, answered from the pane tree.
 *
 * `active()` is deliberately NOT "the surface is not the transcript": it asks
 * the registry whether the surface claims the keyboard, which is the property
 * every caller was really testing when it wrote `overlay.active()`. A pane
 * showing a surface that draws but does not take keys — the shape S1b's
 * sessions sidebar will have — must not blur the composer.
 */
export function overlayAdapter(panes: PaneStore, claims: (surface: SurfaceId | null) => boolean): OverlayStore {
  const kind = () => overlayKindOf(panes.surface())
  return {
    kind,
    active: () => claims(panes.surface()),
    open: (next) => panes.show(overlay_surfaces[next]),
    toggle: (next) => panes.show(kind() === next ? main_surface : overlay_surfaces[next]),
    close: () => panes.show(main_surface),
  }
}
