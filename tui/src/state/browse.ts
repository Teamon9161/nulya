/**
 * Browse mode: `Esc` on an empty composer moves the keyboard into the
 * transcript, where `j`/`k` walk the foldable cards and `Enter`/`Space` toggle
 * one (tui.md §4.2). Purely view state — nothing here is session truth.
 *
 * The store only remembers WHICH card is highlighted. Which cards exist and in
 * what order is the transcript's business, so moving the selection is a
 * function of the item list, computed by the caller.
 */
import { createContext, createSignal, useContext } from "solid-js"

export interface BrowseStore {
  active(): boolean
  selected(): string | null
  enter(key: string | null): void
  select(key: string | null): void
  exit(): void
}

export function createBrowseStore(): BrowseStore {
  const [active, setActive] = createSignal(false)
  const [selected, setSelected] = createSignal<string | null>(null)
  return {
    active,
    selected: () => (active() ? selected() : null),
    enter(key) {
      setActive(true)
      setSelected(key)
    },
    select(key) {
      setSelected(key)
    },
    exit() {
      setActive(false)
      setSelected(null)
    },
  }
}

export const BrowseContext = createContext<BrowseStore>()

let fallback: BrowseStore | null = null

export function useBrowse(): BrowseStore {
  const provided = useContext(BrowseContext)
  if (provided) return provided
  fallback ??= createBrowseStore()
  return fallback
}
