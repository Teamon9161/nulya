import { Show } from "solid-js"
import { useStyle } from "../theme.ts"
import type { UserItem } from "../../state/session.ts"

/**
 * A user turn. Markdown is deliberately off here (tui.md §4.2): what the user
 * typed is shown as typed, newlines and all.
 */
export function UserTurn(props: { item: UserItem }) {
  const style = useStyle()
  return (
    <box flexDirection="row" width="100%" marginTop={1}>
      <text fg={style.theme.accent.user}>{style.glyphs.user} </text>
      <box flexDirection="row" flexGrow={1} flexShrink={1}>
        <text fg={style.theme.fg}>{props.item.text}</text>
        <Show when={props.item.queued}>
          <text fg={style.theme.dim}> · queued</text>
        </Show>
      </box>
    </box>
  )
}
