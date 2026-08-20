import { useStyle } from "../theme.ts"
import { CardFrame, sizeNote } from "./CardFrame.tsx"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * `render: "markdown"` (DESIGN §7.2.1, tui-plugin D12): the same call
 * `ExtToolCard` would draw, except the body renders through the `markdown`
 * primitive (`AssistantTurn.tsx`'s own choice) instead of plain text — for a
 * tool whose output IS prose the model or the person is meant to read, a
 * `propose{plan_md}` being the motivating case (goals/tui-plugin.md U4).
 */
export function MarkdownToolCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const chip = () => {
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    const size = sizeNote(props.item.output)
    if (props.item.ok === false) return size.length > 0 ? `${size} · failed` : "failed"
    return size
  }
  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={props.presentation.glyph}
      accent={style.theme.accent.tool}
      head={props.presentation.head}
      chip={chip()}
      chipTone={props.item.ok === false ? "err" : "dim"}
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      foldable={props.item.output.length > 0}
      spillPath={props.item.spillPath}
    >
      <markdown content={props.item.output} syntaxStyle={style.syntax} fg={style.theme.fg} width="100%" />
    </CardFrame>
  )
}
