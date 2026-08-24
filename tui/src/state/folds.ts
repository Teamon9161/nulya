/**
 * Per-card fold overrides. The DEFAULT for a card comes from `tui.toml`
 * (tui.md §7); this store only remembers what the user has since toggled, keyed
 * by the card's stable key. Nothing here is session truth — it is view state,
 * and it is allowed to be forgotten when the process exits.
 */
import { createContext, useContext } from "solid-js"
import { createStore, produce } from "solid-js/store"

export interface FoldStore {
  isOpen(key: string, byDefault: boolean): boolean
  toggle(key: string, byDefault: boolean): void
  /** `/fold`: force every known and future card one way (collapse, in practice). */
  setAll(open: boolean): void
}

export function createFoldStore(): FoldStore {
  const [state, setState] = createStore<{ overrides: Record<string, boolean>; all: boolean | null }>({
    overrides: {},
    all: null,
  })
  return {
    isOpen(key, byDefault) {
      const override = state.overrides[key]
      if (override !== undefined) return override
      return state.all ?? byDefault
    },
    toggle(key, byDefault) {
      const current = state.overrides[key] ?? state.all ?? byDefault
      setState(
        produce((draft) => {
          draft.overrides[key] = !current
        }),
      )
    },
    setAll(open) {
      setState(
        produce((draft) => {
          draft.overrides = {}
          draft.all = open
        }),
      )
    },
  }
}

export const FoldContext = createContext<FoldStore>()

let fallback: FoldStore | null = null

export function useFolds(): FoldStore {
  const provided = useContext(FoldContext)
  if (provided) return provided
  fallback ??= createFoldStore()
  return fallback
}
