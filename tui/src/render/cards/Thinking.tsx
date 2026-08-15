import { Show } from "solid-js"
import { useStyle } from "../theme.ts"
import { useFolds } from "../../state/folds.ts"
import type { ThinkingItem } from "../../state/session.ts"

/**
 * Reasoning. `assistant.reasoning` is opaque provider bytes kept for replay
 * (DESIGN §3.1), so when no readable text can be recovered the card says
 * `reasoning (opaque)` rather than inventing a summary.
 */
export function Thinking(props: { item: ThinkingItem }) {
  const style = useStyle()
  const folds = useFolds()
  const setting = () => style.settings.transcript.thinking
  const open = () => folds.isOpen(props.item.key, setting() === "expanded")
  const head = () =>
    props.item.opaque ? "reasoning (opaque)" : `thinking · ${props.item.text.length} chars`

  return (
    <Show when={setting() !== "hidden"}>
      <box flexDirection="column" width="100%" paddingLeft={2}>
        <text fg={style.theme.dim}>
          {open() ? style.glyphs.foldOpen : style.glyphs.foldClosed} {head()}
        </text>
        <Show when={open() && props.item.text.length > 0}>
          <box paddingLeft={2}>
            <text fg={style.theme.dim}>{props.item.text}</text>
          </box>
        </Show>
      </box>
    </Show>
  )
}
