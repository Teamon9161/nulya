import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * A tool the agent built for itself, promoted onto the model's tool face at a
 * session boundary (DESIGN §5.1/§5.5). It is a normal tool call — folded like
 * any other output — but it carries the extension glyph, because a call the
 * kernel did not ship with is worth recognising at a glance.
 */
export function ExtToolCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const chip = () => {
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    return props.item.ok === null ? "" : props.item.ok ? "ok" : "failed"
  }
  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={props.presentation.glyph}
      accent={style.theme.accent.tool}
      head={props.presentation.head}
      chip={chip()}
      chipTone={props.item.ok === false ? "err" : props.item.ok === true ? "ok" : "dim"}
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      foldable={props.item.output.length > 0}
      spillPath={props.item.spillPath}
    >
      <text fg={style.theme.fg}>{props.item.output}</text>
    </CardFrame>
  )
}
