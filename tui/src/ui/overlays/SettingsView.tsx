/**
 * `/settings`: the values in force right now, and which file each layer came
 * from (tui.md §7).
 *
 * It shows and does not write. Settings live in a file the user edits; a TUI
 * that also wrote them would be a second author of the same truth, and "where
 * does this value come from" would stop having one answer. The candidate paths
 * are listed either way, so the answer to "where do I put it" is on screen even
 * when no file exists yet.
 */
import { For, Show } from "solid-js"
import { existsSync } from "node:fs"
import { useKeyboard } from "@opentui/solid"
import { useStyle } from "../../render/theme.ts"
import { settingsPaths, default_settings, type Settings } from "../../state/settings.ts"
import type { Workspace } from "../../nulya/bin.ts"

/** Every effective value, flattened into `table.key = value` rows. */
export function settingRows(settings: Settings): Array<{ key: string; value: string; changed: boolean }> {
  const rows: Array<{ key: string; value: string; changed: boolean }> = []
  const add = (key: string, value: unknown, fallback: unknown) =>
    rows.push({ key, value: String(value), changed: value !== fallback })
  const t = settings.transcript
  const d = default_settings.transcript
  add("transcript.edit_diff", t.edit_diff, d.edit_diff)
  add("transcript.tool_output", t.tool_output, d.tool_output)
  add("transcript.thinking", t.thinking, d.thinking)
  add("transcript.max_width", t.max_width, d.max_width)
  add("transcript.history_window", t.history_window, d.history_window)
  add("transcript.ascii", t.ascii, d.ascii)
  add("ui.theme", settings.ui.theme, default_settings.ui.theme)
  add("ui.motion", settings.ui.motion, default_settings.ui.motion)
  for (const [action, binding] of Object.entries(settings.keys)) {
    rows.push({ key: `keys.${action}`, value: binding, changed: true })
  }
  return rows
}

export function SettingsView(props: { ws: Workspace; onClose: () => void }) {
  const style = useStyle()
  const settings = style.settings
  useKeyboard((key) => {
    if (key.name === "escape") props.onClose()
  })

  const candidates = () =>
    settingsPaths(props.ws.dir).map((path) => ({
      path,
      applied: settings.sources.includes(path),
      present: existsSync(path),
    }))

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve}>settings · tui.toml · read-only here, edit the file</text>
      <box height={1} />

      <For each={candidates()}>
        {(entry) => (
          <box flexDirection="row" width="100%">
            <box width={12} flexShrink={0}>
              <text fg={entry.applied ? style.theme.ok : style.theme.dim}>
                {entry.applied ? "applied" : entry.present ? "unreadable" : "absent"}
              </text>
            </box>
            <text fg={style.theme.dim}>{entry.path}</text>
          </box>
        )}
      </For>
      <box height={1} />

      <For each={settingRows(settings)}>
        {(row) => (
          <box flexDirection="row" width="100%">
            <box width={28} flexShrink={0}>
              <text fg={style.theme.dim}>{row.key}</text>
            </box>
            <text fg={row.changed ? style.theme.fg : style.theme.dim}>{row.value}</text>
            <Show when={row.changed}>
              <text fg={style.theme.dim}> · not the default</text>
            </Show>
          </box>
        )}
      </For>

      <box flexGrow={1} />
      <text fg={style.theme.dim}>
        the kernel's own config is a different chain (`default.toml` → system → user → project) and the TUI does not
        read it · Esc close
      </text>
    </box>
  )
}
