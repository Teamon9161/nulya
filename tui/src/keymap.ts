/**
 * Key bindings, as strings like `ctrl+o` / `escape`. Defaults live here;
 * `tui.toml`'s `[keys]` table overrides individual actions (tui.md §7).
 */
import type { KeyEvent } from "@opentui/core"
import type { Settings } from "./state/settings.ts"

export type Action = "cancel" | "fold" | "foldAll" | "quit" | "redraw" | "help"

export const default_keys: Record<Action, string> = {
  cancel: "escape",
  fold: "ctrl+o",
  foldAll: "ctrl+shift+o",
  quit: "ctrl+c",
  redraw: "ctrl+l",
  help: "f1",
}

export type Keymap = Record<Action, string>

export function createKeymap(settings: Settings): Keymap {
  const map = { ...default_keys }
  for (const [action, binding] of Object.entries(settings.keys)) {
    if (action in map) map[action as Action] = binding.toLowerCase()
  }
  return map
}

/** Does `key` match a binding string such as `ctrl+shift+o`? */
export function matches(binding: string, key: KeyEvent): boolean {
  const parts = binding.toLowerCase().split("+").filter((part) => part.length > 0)
  const name = parts.pop()
  if (!name) return false
  const wantCtrl = parts.includes("ctrl")
  const wantShift = parts.includes("shift")
  const wantMeta = parts.includes("meta") || parts.includes("alt")
  return (
    key.name === name &&
    key.ctrl === wantCtrl &&
    key.shift === wantShift &&
    (key.meta ?? false) === wantMeta
  )
}
