import { useBodyWidth, useStyle } from "../theme.ts"
import { CardFrame, sizeNote } from "./CardFrame.tsx"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * `render: "markdown"`: the same call
 * `ExtToolCard` would draw, except the body renders through the `markdown`
 * primitive (`AssistantTurn.tsx`'s own choice) instead of plain text — for a
 * tool whose output IS prose the model or the person is meant to read, a
 * `propose{plan_md}` being the motivating case (goals/tui-plugin.md U4).
 *
 * The width is a derived number, not a measurement — `AssistantTurn` says why
 * at length; a table sized by the layout keeps the columns it
 * was first fitted with, so the number is what keeps it inside the frame.
 */
export function MarkdownToolCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const body = useBodyWidth()
  // − 2 the glyph column, − 4 the card frame's inset, − 1 the scrollbar's.
  const width = () => Math.max(12, Math.min(body(), style.maxWidth) - 7)
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
      <box flexDirection="column" width="100%">
        <markdown content={props.item.output} syntaxStyle={style.syntax} fg={style.theme.fg} width={width()} />
      </box>
    </CardFrame>
  )
}
