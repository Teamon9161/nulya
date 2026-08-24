import { For, Show, createMemo } from "solid-js"
import { useScreen, useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { ShellOutput } from "./ShellCard.tsx"
import { diffStats, parseEditArgs, unifiedDiff } from "../../nulya/diff.ts"
import { hardWrap } from "../../ui/columns.ts"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * An `edit` call: the path on the head line, the unified diff EXPANDED by
 * default (tui.md §1.2 D5) — the one tool output worth seeing without asking,
 * because it is the change itself rather than a report about it.
 *
 * The hunk header counts the replaced fragment, not the file: `edit` is an
 * exact-string transaction and the ledger holds no file offsets (see
 * `nulya/diff.ts`).
 */
export function EditCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const args = createMemo(() => parseEditArgs(props.item.args))
  const patch = createMemo(() => {
    const parsed = args()
    return parsed ? unifiedDiff(parsed) : ""
  })
  // A failed edit changed nothing, so its diff would be a picture of something
  // that never happened: fall back to the error the kernel reported.
  const showDiff = () => patch().length > 0 && props.item.ok !== false

  const chip = () => {
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    const parsed = args()
    if (!showDiff() || !parsed) return props.item.ok === false ? "failed" : ""
    const stats = diffStats(parsed)
    // The diff is right below; `ok` on top of it would be saying it twice (T26).
    const counts = `${parsed.replace_all ? "all · " : ""}+${stats.added} -${stats.removed}`
    return props.item.ok === false ? `${counts} · failed` : counts
  }

  const tone = () => (props.item.ok === false ? "err" : "dim")
  const screen = useScreen()
  const diffWidth = () => Math.max(12, Math.min(screen().width, style.maxWidth) - 6)
  const diffRows = createMemo(() => renderDiffRows(patch(), diffWidth(), style))
  const visibleRows = () => diffRows().slice(0, 40)
  const clipped = () => diffRows().length > visibleRows().length

  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={props.presentation.glyph}
      accent={style.theme.accent.tool}
      head={props.presentation.head}
      chip={chip()}
      chipTone={tone()}
      defaultOpen={
        showDiff()
          ? style.settings.transcript.edit_diff === "expanded"
          : style.settings.transcript.tool_output === "expanded"
      }
      foldable={showDiff() || props.item.output.length > 0}
      spillPath={props.item.spillPath}
    >
      <Show when={showDiff()} fallback={<ShellOutput output={props.item.output} />}>
        <For each={visibleRows()}>
          {(row) => (
            <box height={1} width="100%" backgroundColor={row.bg}>
              <text fg={row.fg} height={1}>{row.text}</text>
            </box>
          )}
        </For>
        <Show when={clipped()}>
          <text fg={style.theme.dim} height={1}>… diff clipped after 40 rows</text>
        </Show>
      </Show>
    </CardFrame>
  )
}


type DiffRow = { text: string; fg: string; bg: string }

type DiffTone = "add" | "del" | "hunk" | "context"

function rowColors(tone: DiffTone, style: ReturnType<typeof useStyle>): { fg: string; bg: string } {
  switch (tone) {
    case "add":
      return { fg: style.theme.diff.add, bg: style.theme.diff.addBg }
    case "del":
      return { fg: style.theme.diff.del, bg: style.theme.diff.delBg }
    case "hunk":
      return { fg: style.theme.dim, bg: "transparent" }
    default:
      return { fg: style.theme.muted, bg: "transparent" }
  }
}

function renderDiffRows(patch: string, width: number, style: ReturnType<typeof useStyle>): DiffRow[] {
  const rows: DiffRow[] = []
  for (const raw of patch.split("\n")) {
    if (raw.length === 0 || raw.startsWith("--- ") || raw.startsWith("+++ ")) continue
    const tone: DiffTone = raw.startsWith("+")
      ? "add"
      : raw.startsWith("-")
        ? "del"
        : raw.startsWith("@@")
          ? "hunk"
          : "context"
    const prefix = tone === "hunk" ? "  " : raw.slice(0, 1)
    const body = tone === "hunk" ? raw : raw.slice(1)
    const colors = rowColors(tone, style)
    const wrapped = hardWrap(body, Math.max(1, width - 2))
    for (let i = 0; i < wrapped.length; i++) {
      rows.push({ ...colors, text: `${i === 0 ? prefix : " "} ${wrapped[i] ?? ""}` })
    }
  }
  return rows.length > 0 ? rows : [{ text: "", fg: style.theme.dim, bg: "transparent" }]
}
