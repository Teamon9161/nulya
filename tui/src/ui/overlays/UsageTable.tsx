/**
 * The projection of `.nulya/tool-usage.jsonl` (DESIGN §5.5): counts, and only
 * counts.
 *
 * Which tool gets promoted into the next session is `tool_selection.rank`, a
 * kernel policy (physics #8). A second implementation of that ordering in the
 * front end would silently drift from the one that actually decides, so this
 * table sorts by uses and says as much (tui.md §2.1).
 */
import { For, Show } from "solid-js"
import { useStyle } from "../../render/theme.ts"
import type { ToolUsage } from "../../nulya/files.ts"

export function UsageTable(props: { rows: ToolUsage[] }) {
  const style = useStyle()
  return (
    <box flexDirection="column" flexGrow={1}>
      <text fg={style.theme.dim}>tool usage · .nulya/tool-usage.jsonl · counts only, not the promotion order</text>
      <box height={1} />
      <For each={props.rows}>
        {(row) => (
          <text fg={style.theme.fg}>
            {row.toolId} · {row.uses} uses · {row.uses > 0 ? Math.round((row.ok / row.uses) * 100) : 0}% ok
          </text>
        )}
      </For>
      <Show when={props.rows.length === 0}>
        <text fg={style.theme.dim}>no tool usage recorded yet</text>
      </Show>
    </box>
  )
}
