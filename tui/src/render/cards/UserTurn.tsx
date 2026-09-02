import { For, createMemo } from "solid-js"
import { useBodyWidth, useStyle } from "../theme.ts"
import { hardWrapLines } from "../../ui/columns.ts"
import type { NoteItem, UserItem } from "../../state/session.ts"

/**
 * A user turn. Markdown is deliberately off here: what the user
 * typed is shown as typed, newlines and all. A mid-task message (midtask.ts)
 * and a plugin's note (extnote.ts) render through here too — `text` is then the
 * folded body and `badge` says how it arrived.
 *
 * THE WRAP WIDTH IS THE PANE'S, NOT THE TERMINAL'S (`useBodyWidth`, BUGS.md
 * #10/#17). Each wrapped row here is painted by its own `height={1}` box, so a
 * row written wider than the column it sits in does not push a second row —
 * the surplus is simply not on screen, and long messages read as "most of it
 * is missing". `useScreen()` answers with the whole terminal, which is the
 * wrong number the moment the transcript shares the screen with the sidebar or
 * another pane; the pane tree's own number is what `AssistantTurn` already
 * wraps at, and the two cards have to agree or one exchange draws in two
 * different columns.
 */
export function UserTurn(props: { item: UserItem | NoteItem; text?: string; badge?: string }) {
  const style = useStyle()
  const column = useBodyWidth()
  const body = () => {
    // A note renders in this same shape with a badge for where it came from,
    // and has neither of the two things only a typed turn can have.
    const turn = props.item.kind === "user" ? props.item : null
    const images = turn?.imageCount ? `${turn.imageCount} image${turn.imageCount === 1 ? "" : "s"}` : null
    const suffix = [props.badge, images, turn?.queued ? "queued" : null].filter(Boolean).join(" · ")
    const text = props.text ?? props.item.text
    return suffix.length > 0 ? (text.length > 0 ? `${text} · ${suffix}` : suffix) : text
  }
  // − 2 the glyph column, − 2 the transcript's padding, − 1 the scrollbar's:
  // `AssistantTurn`'s arithmetic, so both halves of an exchange share a margin.
  const room = () => Math.max(12, Math.min(column(), style.maxWidth) - 5)
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
