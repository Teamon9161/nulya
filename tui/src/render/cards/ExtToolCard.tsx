import { useStyle } from "../theme.ts"
import { CardFrame, sizeNote } from "./CardFrame.tsx"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * A tool the agent built for itself, promoted onto the model's tool face at a
 * session boundary. It is a normal tool call — folded like
 * any other output — but it carries the extension glyph, because a call the
 * kernel did not ship with is worth recognising at a glance.
 */
export function ExtToolCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  // Same discipline as every other card: how much came back, and a word
  // only when something went wrong.
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
      <text fg={style.theme.fg}>{props.item.output}</text>
    </CardFrame>
  )
}
