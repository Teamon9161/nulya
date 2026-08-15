import { useStyle } from "../theme.ts"
import type { AssistantItem } from "../../state/session.ts"

/**
 * An assistant turn: role colour on the glyph only, markdown body in plain `fg`
 * (tui.md §6). While the turn is streaming a block cursor trails the text — the
 * one piece of motion in the transcript.
 */
export function AssistantTurn(props: { item: AssistantItem }) {
  const style = useStyle()
  return (
    <box flexDirection="row" width="100%" marginTop={1}>
      <text fg={style.theme.accent.assistant}>{style.glyphs.assistant} </text>
      <box flexDirection="column" flexGrow={1}>
        <markdown
          content={props.item.text + (props.item.streaming && style.motion ? " ▍" : "")}
          syntaxStyle={style.syntax}
          fg={style.theme.fg}
          streaming={props.item.streaming}
          width="100%"
        />
      </box>
    </box>
  )
}
