import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import type { ThinkingItem } from "../../state/session.ts"

/**
 * Reasoning. `assistant.reasoning` is opaque provider bytes kept for replay
 * (DESIGN §3.1), so when no readable text can be recovered the card says
 * `reasoning (opaque)` rather than inventing a summary.
 *
 * Folded by default and dim throughout: it is context for what the model did,
 * not something it said (tui.md §1.2 D5).
 *
 * It is a `CardFrame` like every other head line (T26). It used to draw its own
 * — fold marker on the LEFT, where every other card has a glyph, and a toggle on
 * bare `onMouseDown`, so dragging across it to copy the text folded it away.
 * One skeleton, one gesture, one place where either can be fixed.
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
