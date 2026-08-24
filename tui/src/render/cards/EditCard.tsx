import { Show, createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { ShellOutput } from "./ShellCard.tsx"
import { diffStats, filetypeOf, parseEditArgs, unifiedDiff } from "../../nulya/diff.ts"
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
  const filetype = () => filetypeOf(args()?.path ?? "") ?? "diff"

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
        <diff
          diff={patch()}
          filetype={filetype()}
          syntaxStyle={style.syntax}
          fg={style.theme.fg}
          width="100%"
          view="unified"
          wrapMode="word"
          showLineNumbers={true}
          lineNumberFg={style.theme.faint}
          lineNumberBg="transparent"
          addedBg={style.theme.diff.addBg}
          removedBg={style.theme.diff.delBg}
          contextBg="transparent"
          addedSignColor={style.theme.diff.add}
          removedSignColor={style.theme.diff.del}
        />
      </Show>
    </CardFrame>
  )
}
