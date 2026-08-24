import { For, createMemo } from "solid-js"
import { useScreen, useStyle } from "../theme.ts"
import { hardWrapLines } from "../../ui/columns.ts"
import type { UserItem } from "../../state/session.ts"

/**
 * A user turn. Markdown is deliberately off here (tui.md §4.2): what the user
 * typed is shown as typed, newlines and all. A mid-task message (midtask.ts)
 * renders through here too — `text` is then the folded body and `badge` says
 * how it arrived, while the ledger keeps the full sentinel.
 */
export function UserTurn(props: { item: UserItem; text?: string; badge?: string }) {
  const style = useStyle()
  const screen = useScreen()
  const body = () => {
    const suffix = [props.badge, props.item.queued ? "queued" : null].filter(Boolean).join(" · ")
    const text = props.text ?? props.item.text
    return suffix.length > 0 ? `${text} · ${suffix}` : text
  }
  const room = () => Math.max(12, Math.min(screen().width, style.maxWidth) - 5)
  const lines = createMemo(() => hardWrapLines(body(), room()))
  return (
    <box flexDirection="column" width="100%">
      <For each={lines()}>
        {(line) => (
          <box flexDirection="row" width="100%" height={1}>
            <text fg={style.theme.accent.user} height={1}>{style.glyphs.bar} </text>
            <text fg={style.theme.fg} height={1}>{line}</text>
          </box>
        )}
      </For>
    </box>
  )
}
