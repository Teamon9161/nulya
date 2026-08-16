/**
 * The projection of `.nulya/tool-usage.jsonl` (DESIGN §5.5): counts, and only
 * counts.
 *
 * Nothing here decides anything. A tool reaches the model's tool face only
 * because somebody wrote a pin — the operator in `registry.pinned_native_tools`,
 * or an evolution session with `session new --pin` (DESIGN §5.1/§5.5) — and
 * these counts are evidence for that judgement, never a queue for it. So the
 * table sorts by uses and says as much (tui.md §2.1).
 */
import { For, Show } from "solid-js"
import { useStyle } from "../../render/theme.ts"
import type { ToolUsage } from "../../nulya/files.ts"

export function UsageTable(props: { rows: ToolUsage[] }) {
  const style = useStyle()
  return (
    <box flexDirection="column" flexGrow={1}>
      <text fg={style.theme.dim}>tool usage · .nulya/tool-usage.jsonl · evidence for a pin, not a queue</text>
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
