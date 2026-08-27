/**
 * `/help` (F1): the keys and slash commands, as they are bound right now.
 *
 * It reads the live keymap rather than a hand-written list, so a `[keys]`
 * override in `tui.toml` (tui.md §7) shows up here instead of quietly making
 * the documentation wrong. Bindings that differ from the default are marked.
 *
 * Every description is broken into lines here rather than left to the terminal.
 * Wrapping inside a scrollbox is the worst place for it — the wrap point moves
 * with the scroll offset, and a line that rewraps leaves the previous frame's
 * characters in each of its blanks (`ui/columns.ts`).
 */
import { For, createMemo } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { ScrollBoxRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { columnWidth, fit, wrapWords } from "../columns.ts"
import { OverlayFooter } from "./Footer.tsx"
import { commands } from "../../commands.ts"
import { default_keys, type Action, type Keymap } from "../../keymap.ts"

/** What each rebindable action does, in the order a newcomer needs them. */
const actions: Array<[Action, string]> = [
  ["cancel", "cancel the step (kernel stops at its next step boundary) · browse when idle"],
  ["ext", "/ext — the extension store"],
  ["sessions", "/sessions — the session store"],
  ["model", "/model — the models that can run; Enter starts a session on one"],
  ["provider", "/provider — endpoints and their keys; Enter on a ready one goes to its models"],
  ["tasks", "/tasks — background commands still running, their logs, k to stop one"],
  ["sidebar", "/sidebar — the session list, docked beside the transcript"],
  ["focusLeft", "keyboard to the pane on the left · Esc sends it back"],
  ["focusRight", "keyboard to the pane on the right"],
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
  ["↑↓ / 1-9, Tab", "in the approval dialog: choose an answer, or write a note that rides on it"],
  ["Shift+Enter / Ctrl+J", "newline"],
  ["/ then Tab", "complete a slash command; Enter always sends what is written"],
  ["↑ / ↓", "previous / next message, on an empty composer"],
  ["j / k, Space", "in browse and in the overlays: move, fold"],
  ["?", "in an overlay: the rest of its keys"],
]

/** What the pointer does. It is worth its own block: none of it is discoverable. */
const mouse: Array<[string, string]> = [
  ["wheel", "scroll the transcript"],
  ["click a head line", "fold / unfold that card · Esc then Enter is the keyboard way"],
  ["click a row", "move the cursor there · click it again for what Enter does"],
  ["click the model", "in the line under the composer or the composition card: open /model"],
  ["click ask / unsafe", "open the permission-mode picker, the same as /mode"],
  ["click a tab / a pane", "go to it"],
  ["click the sidebar mark", "at the head of the line under the composer: show or hide the session list"],
  ["click [x]", "in /ext's tools pane: pin or unpin that tool"],
  ["drag over text", "select it; releasing copies it to the clipboard"],
]

/**
 * The slash lines that are not built-in commands: a package's own, a skill, and
 * everything else. The first two exist only when something is active, which is
 * why they are described by shape rather than listed by name — `/evolve` is one
 * of them since T53, and it is there exactly when the evolution package is.
 */
const slashes: Array<[string, string]> = [
  ["/<package command>", "declared by an active extension · /ext lists them"],
  ["/<skill> [args]", "load an active skill's body as a user turn · `nulya skill list` names them"],
  ["anything else after /", "goes to the model verbatim"],
]

const closing =
  "a session has one writer · when somebody else holds it this window follows as an observer and can still queue a turn"

/** How a command names itself in the left column: the verb and its arguments. */
function commandLabel(command: { name: string; args?: string }): string {
  return command.args ? `${command.name} ${command.args}` : command.name
}

export function HelpView(props: { keys: Keymap; onClose: () => void }) {
  const style = useStyle()
  const screen = useScreen()
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

  /**
   * The columns this page may draw in: one of padding on each side, one more
   * for the scrollbar — its track is painted over the LAST column of the
   * scrollbox, so a row sized to the full width loses its final character to
   * it (`…stops at its nex█`) — and one more so a full-width line does not sit
   * against the track with no gap at all.
   */
  const inner = () => Math.max(24, screen().width - 4)
  /**
   * The key column is as wide as the widest binding it has to show — `/new
   * [--profile p] [--model id]` is the one that decides it — but never so wide
   * that the description beside it has nothing left to say.
   */
  const keyCol = createMemo(() =>
    Math.min(
      columnWidth(
        [
          ...actions.map(([action]) => props.keys[action]),
          ...fixed.map(([key]) => key),
          ...mouse.map(([key]) => key),
          ...commands.map(commandLabel),
          ...slashes.map(([key]) => key),
        ],
        2,
        34,
      ),
      Math.max(12, inner() - 24),
    ),
  )
  const textCol = () => Math.max(8, inner() - keyCol())

  /**
   * One row per line of the description: the key is printed beside its first
   * line and the rest are indented under the text column, so a long sentence
   * costs rows rather than a wrap.
   */
  const Row = (row: { left: string; right: string; changed?: boolean }) => {
    const lines = () => {
      const broken = wrapWords(row.changed ? `${row.right} · (tui.toml)` : row.right, textCol())
      return broken.length > 0 ? broken : [""]
    }
    return (
      <For each={lines()}>
        {(line, index) => (
          <box flexDirection="row" width="100%" height={1} flexShrink={0}>
            <box width={keyCol()} flexShrink={0}>
              <text fg={style.theme.fg}>{index() === 0 ? fit(row.left, keyCol() - 2) : ""}</text>
            </box>
            <text fg={style.theme.dim}>{line}</text>
          </box>
        )}
      </For>
    )
  }

  return (
    <box flexDirection="column" width="100%" flexGrow={1} flexShrink={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve} height={1}>
        {fit("help · keys and commands", inner())}
      </text>
      <box height={1} />

      <scrollbox
        ref={(box: ScrollBoxRenderable) => (body = box)}
        // flexBasis 0: size from the remaining space, not from the content
        // height. Otherwise the box starts out as tall as its content and
        // shrinks, squeezing the spacer above and the footer below to zero
        // rows — the footer then draws over the last visible row.
        flexGrow={1}
        flexShrink={1}
        flexBasis={0}
        width="100%"
        verticalScrollbarOptions={{
          trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
        }}
        contentOptions={{ flexDirection: "column", width: "100%" }}
      >
        {/* Every group on this page is a `muted` heading and its rows; these
            two were the exception, and an unlabelled block above three labelled
            ones reads as part of the title rather than as a section of its own. */}
        <text fg={style.theme.muted} height={1}>
          keys
        </text>
        <For each={actions}>
          {([action, what]) => (
            <Row left={props.keys[action]} right={what} changed={props.keys[action] !== default_keys[action]} />
          )}
        </For>
        <box height={1} />
        <For each={fixed}>{([key, what]) => <Row left={key} right={what} />}</For>
        <box height={1} />

        <text fg={style.theme.muted} height={1}>
          mouse
        </text>
        <For each={mouse}>{([key, what]) => <Row left={key} right={what} />}</For>
        <box height={1} />

        <text fg={style.theme.muted} height={1}>
          slash commands
        </text>
        <For each={commands}>{(command) => <Row left={commandLabel(command)} right={command.what} />}</For>
        <For each={slashes}>{([key, what]) => <Row left={key} right={what} />}</For>
        <box height={1} />

        <For each={wrapWords(closing, inner())}>
          {(line) => (
            <text fg={style.theme.dim} height={1}>
              {line}
            </text>
          )}
        </For>
      </scrollbox>
      {/* The same footer every other overlay has (tui.md §6): one dim line, in
          one place, broken at its own joints — it used to be a bare `<text>`
          here, which is the one panel where the line could not wrap and
          therefore the one panel where a narrow terminal garbled it. */}
      <OverlayFooter width={inner()} brief="j/k · PgUp/PgDn scroll · Esc close" />
    </box>
  )
}
