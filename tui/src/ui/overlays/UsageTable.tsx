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
import { For, Show, createEffect, createMemo } from "solid-js"
import { extend } from "@opentui/solid"
import { TextTableRenderable, parseColor, type TextTableContent } from "@opentui/core"
import { useStyle } from "../../render/theme.ts"
import { columnWidth, fit, squeeze, wrapWords } from "../columns.ts"
import type { ToolUsage } from "../../nulya/files.ts"

declare module "@opentui/solid" {
  interface OpenTUIComponents {
    text_table: typeof TextTableRenderable
  }
}

extend({ text_table: TextTableRenderable })

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

  let tableRenderable: TextTableRenderable | null = null
  const tableContent = createMemo<TextTableContent>(() => {
    const fg = parseColor(style.theme.fg)
    const muted = parseColor(style.theme.muted)
    const dim = parseColor(style.theme.dim)
    return props.rows.map((row) => [
      [{ __isChunk: true, text: fit(row.toolId, cols().id - 2), fg }],
      [{ __isChunk: true, text: fit(usesOf(row), cols().uses - 2), fg: muted }],
      [{ __isChunk: true, text: fit(okOf(row), cols().ok), fg: dim }],
    ])
  })

  createEffect(() => {
    const table = tableRenderable
    if (table) table.content = tableContent()
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
      <Show when={props.rows.length > 0}>
        <text_table
          ref={(table: TextTableRenderable) => {
            tableRenderable = table
            table.content = tableContent()
          }}
          width={props.width}
          columnWidthMode="content"
          wrapMode="none"
          columnGap={2}
          cellPadding={0}
          showBorders={false}
          border={false}
          outerBorder={false}
          fg={style.theme.fg}
          flexShrink={0}
        />
      </Show>
      {/* Zero rows is the ordinary state of a fresh workspace, and the journal
          only ever grows from tools actually running — so say what would put a
          line in it rather than reporting the absence. */}
      <Show when={props.rows.length === 0}>
        <text fg={style.theme.muted} height={1}>
          {fit("no tool usage recorded yet", props.width)}
        </text>
        <For each={wrapWords("the kernel appends a line each time a tool runs · shell counts too", props.width)}>
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
