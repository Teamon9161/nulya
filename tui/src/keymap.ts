/**
 * Key bindings, as strings like `ctrl+w` / `escape`. Defaults live here;
 * `tui.toml`'s `[keys]` table overrides individual actions (tui.md §7).
 *
 * Folding is not in this table (T38). A card opens and closes by clicking its
 * head line, and from browse mode with `Enter` / `Space` — two ways already,
 * both of which say what they act on. `ctrl+o` was a third that acted on
 * whichever card happened to be last, and `ctrl+shift+o` opened all of them at
 * once, which is not a view of anything.
 */
import type { KeyEvent } from "@opentui/core"
import type { Settings } from "./state/settings.ts"

export type Action =
  | "cancel"
  | "quit"
  | "redraw"
  | "help"
  | "ext"
  | "sessions"
  | "model"
  | "provider"
  | "tasks"
  | "sidebar"
  | "focusLeft"
  | "focusRight"
  | "nextTab"
  | "closeTab"
  | "scrollUp"
  | "scrollDown"
  | "scrollEnd"
  | "interrupt"

export const default_keys: Record<Action, string> = {
  cancel: "escape",
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
  // The sessions sidebar (T69). In the F-row because it belongs to the same
  // family — "show me this" — and, more to the point, because it is the only
  // family that steals nothing: `ctrl+b` is the sidebar key everywhere else,
  // but the composer's textarea already binds it to move-left, and this layer
  // could never be disabled the way `closeTab` and `interrupt` disable
  // themselves when their key means nothing. A permanent theft is not a
  // default; a person who wants Ctrl+B can write it in `tui.toml`.
  sidebar: "f8",
  // Move the keyboard between panes — a tiling window manager's gesture, and
  // useless until there are two panes, which is exactly when this layer turns
  // itself on. Ctrl+←/→ are the textarea's word-motion the rest of the time
  // (the `closeTab` precedent: claim a key only while it means something).
  focusLeft: "ctrl+left",
  focusRight: "ctrl+right",
  nextTab: "f4",
  closeTab: "ctrl+w",
  scrollUp: "pageup",
  scrollDown: "pagedown",
  // Back to the live end of the transcript, wherever reading left off.
  scrollEnd: "shift+end",
  // Interrupt-and-deliver (agent-runner ar-t1, tui.md §4.4b/§5): kill the step
  // this tab is driving and re-step at once, instead of waiting for it to
  // reach its own next boundary. This layer only claims the key while there is
  // actually something to interrupt or already queued (`App.tsx`'s
  // `interruptRelevant`) — at rest, plain Ctrl+J falls through untouched to the
  // composer's own newline binding (the non-Kitty `Shift+Enter` fallback).
  interrupt: "ctrl+j",
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
