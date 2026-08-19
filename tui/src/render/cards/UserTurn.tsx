import { Show } from "solid-js"
import { useStyle } from "../theme.ts"
import type { UserItem } from "../../state/session.ts"

/**
 * A user turn. Markdown is deliberately off here (tui.md §4.2): what the user
 * typed is shown as typed, newlines and all. A mid-task message (midtask.ts)
 * renders through here too — `text` is then the folded body and `badge` says
 * how it arrived, while the ledger keeps the full sentinel.
 */
export function UserTurn(props: { item: UserItem; text?: string; badge?: string }) {
  const style = useStyle()
  return (
    <box flexDirection="row" width="100%">
      <text fg={style.theme.accent.user}>{style.glyphs.user} </text>
      <box flexDirection="row" flexGrow={1} flexShrink={1}>
        <text fg={style.theme.fg}>{props.text ?? props.item.text}</text>
        <Show when={props.badge}>
          <text fg={style.theme.dim}> · {props.badge}</text>
        </Show>
        <Show when={props.item.queued}>
          <text fg={style.theme.dim}> · queued</text>
        </Show>
      </box>
    </box>
  )
}
