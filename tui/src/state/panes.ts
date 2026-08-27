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
  findLeaf,
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
  /**
   * The pane the screen is ABOUT: the one the transcript and every full-screen
   * view live in, and the one a split puts a sidebar beside (T69).
   *
   * It is the pane the store opened on, for as long as that pane exists. The
   * distinction only starts to matter once there are two of them: `/ext` opened
   * while the keyboard happens to be in the sidebar must still replace the
   * transcript, not the sidebar — a screen whose F2 lands wherever the focus
   * was last is a screen with no fixed place for anything.
   */
  main: Accessor<PaneId>
  /** The surface in the focused pane — what the keyboard would reach. */
  surface: Accessor<SurfaceId | null>
  /** The surface in the main pane — which full-screen view is in front. */
  mainSurface: Accessor<SurfaceId | null>
  show(surface: SurfaceId, pane?: PaneId): void
  /**
   * Apply a pure tree operation written somewhere else — `state/sidebar.ts`'s
   * open/close/resize, and whatever S2 brings.
   *
   * The store is not the place where every verb has to be enumerated: the model
   * is pure functions over an immutable tree, and this is the one door through
   * which a new one reaches the signal. A store that grew a method per gesture
   * would be a second vocabulary to keep in step with the first.
   */
  apply(operation: (tree: PaneTree) => PaneTree): void
  focusOn(pane: PaneId): void
  move(direction: FocusDirection, rect: Rect): void
  split(options: SplitOptions, pane?: PaneId): void
  close(pane?: PaneId): void
  resize(split: PaneId, ratio: number): void
  boxes(rect: Rect): PaneBox[]
}

export function createPaneStore(initial: SurfaceId, id?: PaneId): PaneStore {
  const opened = singlePane(initial, id)
  const opened_id = opened.focus
  const [tree, setTree] = createSignal<PaneTree>(opened)
  const focus = createMemo(() => tree().focus)
  const surface = createMemo(() => focusedSurface(tree()))
  // The pane the store opened on. Falling back to the focused one is not a
  // convenience: it is what keeps "the main pane" from ever naming a pane that
  // is gone, the same invariant `focus` has in the tree itself.
  const main = createMemo(() => {
    const now = tree()
    return findLeaf(now, opened_id) ? opened_id : now.focus
  })
  const mainSurface = createMemo(() => findLeaf(tree(), main())?.surface ?? null)
  return {
    tree,
    focus,
    main,
    surface,
    mainSurface,
    show: (next, pane) => setTree((now) => setSurface(now, pane ?? now.focus, next)),
    apply: (operation) => setTree((now) => operation(now)),
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

/**
 * The sessions list, docked (T69). A surface of its own rather than a second
 * pane showing `host:sessions`, because the two are not the same screen: one is
 * the full-screen view F3 opens, the other is a narrow rail that lives beside
 * the transcript. They differ in width, in what they draw, and — the reason it
 * has to be a second REGISTRATION rather than a second mount — in whether
 * showing it takes the keyboard.
 */
export const sidebar_surface = "host:sidebar"

export const overlay_surfaces: Readonly<Record<OverlayKind, SurfaceId>> = {
  sessions: "host:sessions",
  ext: "host:ext",
  help: "host:help",
  settings: "host:settings",
  usage: "host:usage",
  model: "host:model",
  provider: "host:provider",
  tasks: "host:tasks",
  cwd: "host:cwd",
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
 * The two halves read DIFFERENT panes, and T69 is where that stopped being a
 * distinction without a difference:
 *
 *  - `kind()` / `open()` / `close()` are about the MAIN pane. Which full-screen
 *    view is in front is a fact about the pane the screen is about; F2 pressed
 *    while the keyboard sits in the sidebar still replaces the transcript.
 *  - `active()` is about the FOCUSED pane, because it answers "does the
 *    composer still have the keyboard" — and that is decided by wherever the
 *    keyboard actually is. It asks the registry rather than testing the surface
 *    against the transcript's name, which is what every caller writing
 *    `overlay.active()` was really after.
 *
 * So a sidebar that is merely OPEN leaves `active()` false — the composer keeps
 * the keyboard and the screen goes on being the screen it was. It is focusing
 * the sidebar that takes the keyboard, and nothing focuses it but a person.
 */
export function overlayAdapter(panes: PaneStore, claims: (surface: SurfaceId | null) => boolean): OverlayStore {
  const kind = () => overlayKindOf(panes.mainSurface())
  const show = (next: SurfaceId) => panes.show(next, panes.main())
  return {
    kind,
    active: () => claims(panes.surface()),
    open: (next) => show(overlay_surfaces[next]),
    toggle: (next) => show(kind() === next ? main_surface : overlay_surfaces[next]),
    close: () => show(main_surface),
  }
}
