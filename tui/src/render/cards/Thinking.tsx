import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import type { ThinkingItem } from "../../state/session.ts"

/**
 * Reasoning. `assistant.reasoning` is opaque provider bytes kept for replay,
 * so when no readable text can be recovered the card says
 * `reasoning (opaque)` rather than inventing a summary.
 *
 * Folded by default and dim throughout: it is context for what the model did,
 * not something it said.
 *
 * It is a `CardFrame` like every other head line, rather than drawing its
 * own fold marker and click handling — one skeleton, one gesture, one place
 * where either can be fixed.
 */
export function Thinking(props: { item: ThinkingItem }) {
  const style = useStyle()
  const setting = () => style.settings.transcript.thinking
  if (setting() === "hidden") return null
  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={style.glyphs.thinking}
      accent={style.theme.dim}
      head={props.item.opaque ? "reasoning (opaque)" : "thinking"}
      headTone="dim"
      chip={props.item.opaque || props.item.text.length === 0 ? "" : `${props.item.text.length} chars`}
      chipTone="dim"
      defaultOpen={setting() === "expanded"}
      foldable={props.item.text.length > 0}
    >
      <text fg={style.theme.dim}>{props.item.text}</text>
    </CardFrame>
  )
}
