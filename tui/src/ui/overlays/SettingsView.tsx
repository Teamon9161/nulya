/**
 * `/settings`: the values in force right now, and which file each layer came
 * from (tui.md §7).
 *
 * It shows and does not write. Settings live in a file the user edits; a TUI
 * that also wrote them would be a second author of the same truth, and "where
 * does this value come from" would stop having one answer. The candidate paths
 * are listed either way, so the answer to "where do I put it" is on screen even
 * when no file exists yet.
 *
 * WHAT IT DOES LEAD TO (T92). Not every choice on this screen lives in that
 * file: the model, the permission mode, the working directory and where the
 * shell runs are chosen in the interface and remembered in `tui-state.json`,
 * which is this front end's own note to itself and not a second author of
 * anybody's settings. Those are listed FIRST, each naming the command that
 * opens it and answering to a click — so a person who came here by clicking
 * `settings` finds the things they can actually change, rather than a table
 * whose only instruction is to go and edit a file.
 *
 * A path is the one thing on this screen with no length limit, so both tables
 * are cut to their columns and the closing sentence is broken at its joints
 * rather than wrapped by the terminal (`ui/columns.ts`).
 */
import { For, Show, createMemo, createSignal } from "solid-js"
import { existsSync } from "node:fs"
import { useKeyboard } from "@opentui/solid"
import { useScreen, useStyle } from "../../render/theme.ts"
import { columnWidth, fit } from "../columns.ts"
import { onClick } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { settingsPaths, default_settings, type Settings } from "../../state/settings.ts"
import type { Workspace } from "../../nulya/bin.ts"

/** Every effective value, flattened into `table.key = value` rows. */
export function settingRows(settings: Settings): Array<{ key: string; value: string; changed: boolean }> {
  const rows: Array<{ key: string; value: string; changed: boolean }> = []
  const add = (key: string, value: unknown, fallback: unknown) =>
    rows.push({ key, value: String(value), changed: value !== fallback })
  const t = settings.transcript
  const d = default_settings.transcript
  add("transcript.diff", t.diff, d.diff)
  add("transcript.tool_output", t.tool_output, d.tool_output)
  add("transcript.thinking", t.thinking, d.thinking)
  add("transcript.max_width", t.max_width, d.max_width)
  add("transcript.history_window", t.history_window, d.history_window)
  add("transcript.ascii", t.ascii, d.ascii)
  add("ui.theme", settings.ui.theme, default_settings.ui.theme)
  add("ui.code_theme", settings.ui.code_theme, default_settings.ui.code_theme)
  add("ui.motion", settings.ui.motion, default_settings.ui.motion)
  for (const [action, binding] of Object.entries(settings.keys)) {
    rows.push({ key: `keys.${action}`, value: binding, changed: true })
  }
  return rows
}

/**
 * One live choice: what it is, what it is set to, and the way to change it.
 *
 * `command` is not decoration — it is what a keyboard reaches this by, and the
 * row would be a mouse-only control without it. `open` is the same function the
 * status line’s own chip calls, so the two entrances cannot drift.
 */
export interface SettingChoice {
  label: string
  value: string
  command: string
  open: () => void
}

export function SettingsView(props: {
  ws: Workspace
  onClose: () => void
  /** The choices this front end makes and remembers itself. Absent in tests. */
  choices?: readonly SettingChoice[]
}) {
  const style = useStyle()
  const screen = useScreen()
  const settings = style.settings
  const help = createKeyHelp()
  useKeyboard((key) => {
    if (help.consume(key)) return
    if (key.name === "escape") props.onClose()
  })

  const candidates = () =>
    settingsPaths(props.ws.dir).map((path) => ({
      path,
      applied: settings.sources.includes(path),
      present: existsSync(path),
    }))

  /** The columns this overlay may draw in: the box pads one on each side. */
  const inner = () => Math.max(20, screen().width - 2)
  const rows = createMemo(() => settingRows(settings))
  const stateCol = createMemo(() => columnWidth(["applied", "unreadable", "absent"], 2, 12))
  /** A `keys.*` name is the widest thing here, and a path is the least bounded. */
  const keyCol = createMemo(() =>
    Math.min(columnWidth(rows().map((row) => row.key), 2, 30), Math.max(10, inner() - 16)),
  )
  const valueCol = createMemo(() => columnWidth(rows().map((row) => row.value), 2, 20))
  const choices = () => props.choices ?? []
  const choiceCol = createMemo(() => columnWidth(choices().map((one) => one.label), 2, 18))
  const choiceValueCol = createMemo(() => columnWidth(choices().map((one) => one.value), 2, 24))
  const [overChoice, setOverChoice] = createSignal(-1)

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve} height={1}>
        {fit("settings · tui.toml · read-only here, edit the file", inner())}
      </text>
      <box height={1} />

      <Show when={choices().length > 0}>
        <text fg={style.theme.dim} height={1}>
          {fit("chosen here and remembered in tui-state.json", inner())}
        </text>
        <For each={choices()}>
          {(one, index) => {
            const click = onClick(() => one.open())
            return (
              <box
                flexDirection="row"
                width="100%"
                height={1}
                flexShrink={0}
                backgroundColor={overChoice() === index() ? style.theme.hover : undefined}
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                onMouseOver={() => setOverChoice(index())}
                onMouseOut={() => setOverChoice((at) => (at === index() ? -1 : at))}
              >
                <box width={choiceCol()} flexShrink={0}>
                  <text fg={style.theme.fg}>{fit(one.label, choiceCol() - 2)}</text>
                </box>
                <box width={choiceValueCol()} flexShrink={0}>
                  <text fg={style.theme.muted}>{fit(one.value, choiceValueCol() - 2)}</text>
                </box>
                <text fg={style.theme.accent.evolve}>
                  {fit(one.command, Math.max(0, inner() - choiceCol() - choiceValueCol()))}
                </text>
              </box>
            )
          }}
        </For>
        <box height={1} />
      </Show>

      <For each={candidates()}>
        {(entry) => (
          <box flexDirection="row" width="100%" height={1} flexShrink={0}>
            <box width={stateCol()} flexShrink={0}>
              <text fg={entry.applied ? style.theme.ok : style.theme.dim}>
                {fit(entry.applied ? "applied" : entry.present ? "unreadable" : "absent", stateCol() - 2)}
              </text>
            </box>
            <text fg={entry.applied ? style.theme.muted : style.theme.dim}>
              {fit(entry.path, inner() - stateCol())}
            </text>
          </box>
        )}
      </For>
      <box height={1} />

      <For each={rows()}>
        {(row) => (
          <box flexDirection="row" width="100%" height={1} flexShrink={0}>
            <box width={keyCol()} flexShrink={0}>
              <text fg={style.theme.dim}>{fit(row.key, keyCol() - 2)}</text>
            </box>
            <box width={valueCol()} flexShrink={0}>
              <text fg={row.changed ? style.theme.fg : style.theme.muted}>{fit(row.value, valueCol() - 2)}</text>
            </box>
            <Show when={row.changed}>
              <text fg={style.theme.dim}>{fit("· not the default", inner() - keyCol() - valueCol())}</text>
            </Show>
          </box>
        )}
      </For>

      <box flexGrow={1} />
      <OverlayFooter
        width={inner()}
        help={help}
        brief="Esc close"
        more={[
          "settings are read from the files above · edit one and reopen",
          "the kernel's own config is a different chain (`default.toml` → system → user → project) and the TUI does not read it",
        ]}
      />
    </box>
  )
}
