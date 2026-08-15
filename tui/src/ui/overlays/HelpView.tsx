/**
 * `/help` (F1): the keys and slash commands, as they are bound right now.
 *
 * It reads the live keymap rather than a hand-written list, so a `[keys]`
 * override in `tui.toml` (tui.md §7) shows up here instead of quietly making
 * the documentation wrong. Bindings that differ from the default are marked.
 */
import { For } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useStyle } from "../../render/theme.ts"
import { default_keys, type Action, type Keymap } from "../../keymap.ts"

/** What each rebindable action does, in the order a newcomer needs them. */
const actions: Array<[Action, string]> = [
  ["cancel", "cancel the step (kernel stops at its next step boundary) · browse when idle"],
  ["fold", "fold / unfold the most recent tool or thinking card"],
  ["foldAll", "expand everything, again to collapse everything"],
  ["ext", "/ext — the extension store"],
  ["sessions", "/sessions — the session store"],
  ["help", "this page"],
  ["nextTab", "next tab (tabs appear once a second session is open)"],
  ["closeTab", "close the current tab"],
  ["redraw", "redraw the screen"],
  ["quit", "kill the running step; press again to quit"],
]

const fixed: Array<[string, string]> = [
  ["Enter", "send · in browse, open a sub-session or fold · as observer on an empty composer, take over"],
  ["Shift+Enter / Ctrl+J", "newline"],
  ["↑ / ↓", "previous / next message, on an empty composer"],
  ["click a head line", "fold / unfold that card"],
  ["j / k, Space", "in browse and in the overlays: move, fold"],
  ["PgUp / PgDn, wheel", "scroll the transcript"],
]

const commands: Array<[string, string]> = [
  ["/new [--model p]", "start a session with a provider profile from the kernel's config"],
  ["/sessions  /ext", "the two stores, as views"],
  ["/usage  /settings", "tokens and tool counts · effective settings and where they came from"],
  ["/step", "continue after a spent step budget (nothing continues by itself)"],
  ["/cancel  /fold", "cancel this step · collapse every card"],
  ["/help  /quit", ""],
  ["anything else after /", "goes to the model verbatim — nulya has no slash skills"],
]

export function HelpView(props: { keys: Keymap; onClose: () => void }) {
  const style = useStyle()
  useKeyboard((key) => {
    if (key.name === "escape") props.onClose()
  })

  const Row = (row: { left: string; right: string; changed?: boolean }) => (
    <box flexDirection="row" width="100%">
      <box width={24} flexShrink={0}>
        <text fg={style.theme.fg}>{row.left}</text>
      </box>
      <box flexGrow={1} flexShrink={1} flexBasis={0}>
        <text fg={style.theme.dim}>
          {row.right}
          {row.changed ? "  (tui.toml)" : ""}
        </text>
      </box>
    </box>
  )

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve}>help · keys and commands</text>
      <box height={1} />

      <For each={actions}>
        {([action, what]) => (
          <Row left={props.keys[action]} right={what} changed={props.keys[action] !== default_keys[action]} />
        )}
      </For>
      <box height={1} />
      <For each={fixed}>{([key, what]) => <Row left={key} right={what} />}</For>
      <box height={1} />

      <text fg={style.theme.dim}>slash commands</text>
      <For each={commands}>{([command, what]) => <Row left={command} right={what} />}</For>
      <box height={1} />

      <text fg={style.theme.dim}>
        a session has one writer · when somebody else holds it this window follows as an observer and can still queue
        a turn
      </text>
      <box flexGrow={1} />
      <text fg={style.theme.dim}>Esc close</text>
    </box>
  )
}
