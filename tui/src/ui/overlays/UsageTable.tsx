/**
 * The projection of `.nulya/tool-usage.jsonl` (DESIGN §5.5): counts, and only
 * counts.
 *
 * Nothing here decides anything. A tool reaches the model's tool face only
 * because somebody wrote a pin — the operator in `registry.pinned_native_tools`,
 * or an evolution session with `session new --pin` (DESIGN §5.1/§5.5) — and
 * these counts are evidence for that judgement, never a queue for it. So the
 * table sorts by uses and says as much (tui.md §2.1).
 *
 * `width` is passed in rather than read from the terminal: this table is drawn
 * both full-width (`/usage`) and inside `/ext`'s pane, and a cell sized against
 * the wrong box is a cell that wraps (`ui/columns.ts`).
 */
import { For, Show, createMemo } from "solid-js"
import { useStyle } from "../../render/theme.ts"
import { columnWidth, fit, squeeze, wrapWords } from "../columns.ts"
import type { ToolUsage } from "../../nulya/files.ts"

const caption = "tool usage · .nulya/tool-usage.jsonl · evidence for a pin, not a queue"

const usesOf = (row: ToolUsage) => `${row.uses} uses`
const okOf = (row: ToolUsage) => (row.uses > 0 ? `${Math.round((row.ok / row.uses) * 100)}% ok` : "—")

export function UsageTable(props: { rows: ToolUsage[]; width: number }) {
  const style = useStyle()

  /** A tool id is the column that grows without bound, so it is the one capped. */
  const cols = createMemo(() => {
    const [id, uses, ok] = squeeze(
      [
        columnWidth(props.rows.map((row) => row.toolId), 2, 44),
        columnWidth(props.rows.map(usesOf), 2, 12),
        columnWidth(props.rows.map(okOf), 0, 8),
      ],
      [10, 4, 0],
      props.width,
    )
    return { id: id!, uses: uses!, ok: ok! }
  })

  return (
    <box flexDirection="column" flexGrow={1}>
      <For each={wrapWords(caption, props.width)}>
        {(line) => (
          <text fg={style.theme.dim} height={1}>
            {line}
          </text>
        )}
      </For>
      <box height={1} />
      <For each={props.rows}>
        {(row) => (
          <box flexDirection="row" width="100%" height={1} flexShrink={0}>
            <box width={cols().id} flexShrink={0}>
              <text fg={style.theme.fg}>{fit(row.toolId, cols().id - 2)}</text>
            </box>
            <box width={cols().uses} flexShrink={0}>
              <text fg={style.theme.muted}>{fit(usesOf(row), cols().uses - 2)}</text>
            </box>
            <box width={cols().ok} flexShrink={0}>
              <text fg={style.theme.dim}>{fit(okOf(row), cols().ok)}</text>
            </box>
          </box>
        )}
      </For>
      {/* Zero rows is the ordinary state of a fresh workspace, and the journal
          only ever grows from tools actually running — so say what would put a
          line in it rather than reporting the absence. */}
      <Show when={props.rows.length === 0}>
        <text fg={style.theme.muted} height={1}>
          {fit("no tool usage recorded yet", props.width)}
        </text>
        <For each={wrapWords("the kernel appends a line each time a tool runs · shell and edit count too", props.width)}>
          {(line) => (
            <text fg={style.theme.dim} height={1}>
              {line}
            </text>
          )}
        </For>
      </Show>
    </box>
  )
}
