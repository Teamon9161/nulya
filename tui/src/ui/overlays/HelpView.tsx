/**
 * `/help` (F1): the keys and slash commands, as they are bound right now.
 *
 * It reads the live keymap rather than a hand-written list, so a `[keys]`
 * override in `tui.toml` (tui.md §7) shows up here instead of quietly making
 * the documentation wrong. Bindings that differ from the default are marked.
 */
import { For } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { ScrollBoxRenderable } from "@opentui/core"
import { useStyle } from "../../render/theme.ts"
import { commands } from "../../commands.ts"
import { default_keys, type Action, type Keymap } from "../../keymap.ts"

/** What each rebindable action does, in the order a newcomer needs them. */
const actions: Array<[Action, string]> = [
  ["cancel", "cancel the step (kernel stops at its next step boundary) · browse when idle"],
  ["fold", "fold / unfold the most recent tool or thinking card"],
  ["foldAll", "expand everything, again to collapse everything"],
  ["ext", "/ext — the extension store"],
  ["sessions", "/sessions — the session store"],
  ["model", "/model — providers, then their models; Enter starts a session on one"],
  ["help", "this page"],
  ["scrollUp", "scroll the transcript back a page"],
  ["scrollDown", "scroll it forward a page"],
  ["scrollEnd", "back to the live end of the transcript"],
  ["nextTab", "next tab (tabs appear once a second session is open)"],
  ["closeTab", "close the current tab"],
  ["redraw", "redraw the screen"],
  ["quit", "kill the running step; press again to quit"],
]

const fixed: Array<[string, string]> = [
  ["Enter", "send · in browse, open a sub-session or fold · as observer on an empty composer, take over"],
  ["Shift+Enter / Ctrl+J", "newline"],
  ["/ then Tab", "complete a slash command; Enter always sends what is written"],
  ["↑ / ↓", "previous / next message, on an empty composer"],
  ["click a head line", "fold / unfold that card"],
  ["j / k, Space", "in browse and in the overlays: move, fold"],
  ["wheel", "scroll the transcript"],
]

export function HelpView(props: { keys: Keymap; onClose: () => void }) {
  const style = useStyle()
  // The page is longer than a short terminal. Without a scrollbox the rows
  // below the fold do not vanish — they draw over the ones above — so the
  // content lives in one, and j/k move it.
  let body: ScrollBoxRenderable | null = null
  useKeyboard((key) => {
    if (key.name === "escape") return props.onClose()
    if (key.name === "j" || key.name === "down") return body?.scrollBy({ x: 0, y: 1 })
    if (key.name === "k" || key.name === "up") return body?.scrollBy({ x: 0, y: -1 })
    if (key.name === "pagedown") return body?.scrollBy({ x: 0, y: 10 })
    if (key.name === "pageup") return body?.scrollBy({ x: 0, y: -10 })
  })

  const Row = (row: { left: string; right: string; changed?: boolean }) => (
    <box flexDirection="row" width="100%">
      <box width={32} flexShrink={0}>
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
    <box flexDirection="column" width="100%" flexGrow={1} flexShrink={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve}>help · keys and commands</text>
      <box height={1} />

      <scrollbox
        ref={(box: ScrollBoxRenderable) => (body = box)}
        flexGrow={1}
        flexShrink={1}
        width="100%"
        verticalScrollbarOptions={{
          trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
        }}
        contentOptions={{ flexDirection: "column", width: "100%" }}
      >
        <For each={actions}>
          {([action, what]) => (
            <Row left={props.keys[action]} right={what} changed={props.keys[action] !== default_keys[action]} />
          )}
        </For>
        <box height={1} />
        <For each={fixed}>{([key, what]) => <Row left={key} right={what} />}</For>
        <box height={1} />

        <text fg={style.theme.dim}>slash commands</text>
        <For each={commands}>
          {(command) => <Row left={`${command.name}${command.args ? ` ${command.args}` : ""}`} right={command.what} />}
        </For>
        <Row left="anything else after /" right="goes to the model verbatim — nulya has no slash skills" />
        <box height={1} />

        <text fg={style.theme.dim}>
          a session has one writer · when somebody else holds it this window follows as an observer and can still queue
          a turn
        </text>
      </scrollbox>
      <text fg={style.theme.dim}>j/k · PgUp/PgDn scroll · Esc close</text>
    </box>
  )
}
