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
    if (!showDiff() || !parsed) return props.item.ok === null ? "" : props.item.ok ? "ok" : "failed"
    const stats = diffStats(parsed)
    return `${parsed.replace_all ? "all · " : ""}+${stats.added} -${stats.removed} · ${props.item.ok ? "ok" : "failed"}`
  }

  const tone = () => (props.item.ok === false ? "err" : props.item.ok === true ? "ok" : "dim")
  // The diff renderable needs an explicit height; the patch's own line count is
  // it, capped so one enormous edit cannot swallow the viewport.
  const diffHeight = () => Math.min(Math.max(patch().split("\n").length - 3, 1) + 1, 40)

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
          view="unified"
          filetype={filetypeOf(args()!.path)}
          syntaxStyle={style.syntax}
          // The gutter is what carries the +/- signs: without it the diff is
          // colour-only, which fails NO_COLOR and every plain-text capture.
          showLineNumbers
          lineNumberFg={style.theme.dim}
          addedBg="transparent"
          removedBg="transparent"
          contextBg="transparent"
          addedSignColor={style.theme.diff.add}
          removedSignColor={style.theme.diff.del}
          height={diffHeight()}
          width="100%"
        />
      </Show>
    </CardFrame>
  )
}
