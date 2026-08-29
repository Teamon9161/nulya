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
 * WHAT THE FILE WILL TAKE (T94). Every row of the lower table names what it
 * accepts beside what it is set to, and the table is every key the parser
 * reads (`state/settings.ts`'s `setting_fields`) rather than the nine somebody
 * once listed here. "Read-only here, edit the file" is only an answer if the
 * screen says which words the file accepts — otherwise the way to find out
 * that `transcript.thinking` has a third value is to read the source.
 *
 * It is longer than a short terminal because of that, so the body is a
 * scrollbox and j/k move it — the same shape `/help` took for the same reason.
 *
 * A path is the one thing on this screen with no length limit, so both tables
 * are cut to their columns and the closing sentence is broken at its joints
 * rather than wrapped by the terminal (`ui/columns.ts`).
 */
import { For, Show, createMemo, createSignal } from "solid-js"
import { existsSync } from "node:fs"
import { useKeyboard } from "@opentui/solid"
import type { ScrollBoxRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { columnWidth, fit } from "../columns.ts"
import { lifted, onClick } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { settingsPaths, setting_fields, default_settings, type Settings } from "../../state/settings.ts"
import type { Workspace } from "../../nulya/bin.ts"

export interface SettingRow {
  key: string
  value: string
  /** What the file will take here — empty for a key binding, whose set is open. */
  accepts: string
  changed: boolean
}

/**
 * Every key, what it is set to, and what it accepts.
 *
 * The list comes from `setting_fields` — the one description of what the
 * parser reads — plus a row for each key binding actually overridden. Bindings
 * are not in that table because they are not a fixed set of keys: `keys.<any
 * action>` is the shape, `/help` names the actions, and a row per action would
 * be the whole keymap listed twice.
 */
export function settingRows(settings: Settings): SettingRow[] {
  const rows: SettingRow[] = setting_fields.map((field) => ({
    key: field.key,
    value: field.value(settings),
    accepts: field.accepts,
    changed: field.value(settings) !== field.value(default_settings),
  }))
  for (const [action, binding] of Object.entries(settings.keys)) {
    rows.push({ key: `keys.${action}`, value: binding, accepts: "", changed: true })
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
    if (key.name === "escape") return props.onClose()
    if (key.name === "j" || key.name === "down") return void body?.scrollBy({ x: 0, y: 1 })
    if (key.name === "k" || key.name === "up") return void body?.scrollBy({ x: 0, y: -1 })
    if (key.name === "pagedown") return void body?.scrollBy({ x: 0, y: 10 })
    if (key.name === "pageup") return void body?.scrollBy({ x: 0, y: -10 })
  })

  const candidates = () =>
    settingsPaths(props.ws.dir).map((path) => ({
      path,
      applied: settings.sources.includes(path),
      present: existsSync(path),
    }))

  /**
   * The columns this overlay may draw in: one of padding on each side, plus the
   * two the scrollbar's track takes out of the body (`HelpView` says why).
   */
  const inner = () => Math.max(20, screen().width - 4)
  const rows = createMemo(() => settingRows(settings))
  const stateCol = createMemo(() => columnWidth(["applied", "unreadable", "absent"], 2, 12))
  /** A `keys.*` name is the widest thing here, and a path is the least bounded. */
  const keyCol = createMemo(() =>
    Math.min(columnWidth(rows().map((row) => row.key), 2, 30), Math.max(10, inner() - 16)),
  )
  const valueCol = createMemo(() => columnWidth(rows().map((row) => row.value), 2, 20))
  let body: ScrollBoxRenderable | null = null
  const choices = () => props.choices ?? []
  const choiceCol = createMemo(() => columnWidth(choices().map((one) => one.label), 2, 18))
  const choiceValueCol = createMemo(() => columnWidth(choices().map((one) => one.value), 2, 24))
  const [overChoice, setOverChoice] = createSignal(-1)
  /** The third column: the vocabulary, and the default when it is not in force. */
  const accepts = (row: SettingRow) => {
    const was = setting_fields.find((field) => field.key === row.key)
    const back = row.changed && was ? ` · default ${was.value(default_settings)}` : ""
    return `${row.accepts}${back}`
  }

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve} height={1}>
        {fit("settings · tui.toml · read-only here, edit the file", inner())}
      </text>
      <box height={1} />

      <scrollbox
        ref={(box: ScrollBoxRenderable) => (body = box)}
        flexGrow={1}
        flexShrink={1}
        flexBasis={0}
        width="100%"
        verticalScrollbarOptions={{
          trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
        }}
        contentOptions={{ flexDirection: "column", width: "100%" }}
      >
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
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                onMouseOver={() => setOverChoice(index())}
                onMouseOut={() => setOverChoice((at) => (at === index() ? -1 : at))}
              >
                <box width={choiceCol()} flexShrink={0}>
                  <text fg={lifted(style, overChoice() === index(), style.theme.fg)}>
                    {fit(one.label, choiceCol() - 2)}
                  </text>
                </box>
                <box width={choiceValueCol()} flexShrink={0}>
                  <text fg={lifted(style, overChoice() === index(), style.theme.muted)}>
                    {fit(one.value, choiceValueCol() - 2)}
                  </text>
                </box>
                <text fg={lifted(style, overChoice() === index(), style.theme.accent.evolve)}>
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
            {/* What the file will take here — and, when this is not the
                default any more, what it was, which is the one thing a person
                undoing an edit needs and cannot get from anywhere else. */}
            <text fg={style.theme.faint}>
              {fit(accepts(row), Math.max(0, inner() - keyCol() - valueCol()))}
            </text>
          </box>
        )}
      </For>
      </scrollbox>

      <OverlayFooter
        width={inner()}
        help={help}
        brief="Esc close · j/k scroll"
        more={[
          "every key this front end reads is above · edit a file and reopen",
          "the kernel's own config is a different chain (`default.toml` → system → user → project) and the TUI does not read it",
        ]}
      />
    </box>
  )
}
