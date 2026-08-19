/**
 * Key bindings, as strings like `ctrl+o` / `escape`. Defaults live here;
 * `tui.toml`'s `[keys]` table overrides individual actions (tui.md §7).
 */
import type { KeyEvent } from "@opentui/core"
import type { Settings } from "./state/settings.ts"

export type Action =
  | "cancel"
  | "fold"
  | "foldAll"
  | "quit"
  | "redraw"
  | "help"
  | "ext"
  | "sessions"
  | "model"
  | "provider"
  | "tasks"
  | "nextTab"
  | "closeTab"
  | "scrollUp"
  | "scrollDown"
  | "scrollEnd"

export const default_keys: Record<Action, string> = {
  cancel: "escape",
  fold: "ctrl+o",
  foldAll: "ctrl+shift+o",
  quit: "ctrl+c",
  redraw: "ctrl+l",
  help: "f1",
  ext: "f2",
  sessions: "f3",
  model: "f5",
  // The other half of the model question (tui.md §11, T21). Next to F5 because
  // the two are read together: what runs, and what could serve it.
  provider: "f6",
  // The background tasks (tui.md §5.9). After the two model keys because it is
  // read the same way they are: something the screen can tell you about the
  // session without you having to ask the model.
  tasks: "f7",
  nextTab: "f4",
  closeTab: "ctrl+w",
  scrollUp: "pageup",
  scrollDown: "pagedown",
  // Back to the live end of the transcript, wherever reading left off.
  scrollEnd: "shift+end",
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
