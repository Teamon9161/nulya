/**
 * Which full-screen view is in front of the transcript, if any.
 *
 * One store rather than a signal per view, because the important property is
 * exclusivity: exactly one thing owns the keyboard at a time. `App` gates its
 * own key handling on `active()`, so `j`/`k` can never be consumed twice
 * (tui.md §11, T2 reminder 3).
 */
import { createContext, createSignal, useContext } from "solid-js"

export type OverlayKind = "sessions" | "ext" | "help" | "settings" | "usage" | "model"

export interface OverlayStore {
  kind(): OverlayKind | null
  active(): boolean
  open(kind: OverlayKind): void
  toggle(kind: OverlayKind): void
  close(): void
}

export function createOverlayStore(): OverlayStore {
  const [kind, setKind] = createSignal<OverlayKind | null>(null)
  return {
    kind,
    active: () => kind() !== null,
    open: (next) => setKind(next),
    toggle: (next) => setKind(kind() === next ? null : next),
    close: () => setKind(null),
  }
}

export const OverlayContext = createContext<OverlayStore>()

export function useOverlay(): OverlayStore {
  return useContext(OverlayContext) ?? createOverlayStore()
}
