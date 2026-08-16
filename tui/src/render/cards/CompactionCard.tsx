import { CardFrame } from "./CardFrame.tsx"
import { useStyle } from "../theme.ts"
import { withoutMarker } from "../../compact.ts"
import type { UserItem } from "../../state/session.ts"

/**
 * The two turns compaction writes (`compact.ts`): the brief it asks the old
 * session for, and the brief the new session starts from.
 *
 * Both are ordinary `user_text` events — the kernel has no compaction concept
 * and is not getting one — so this card is a reading of content, not of a new
 * event kind. It exists because these two turns are machinery: the request is a
 * prompt nobody typed, and the summary is the whole of what the model now stands
 * on. Showing the first folded and the second open puts the attention where it
 * belongs, without hiding either from the transcript (tui.md §0.2).
 */
export function CompactionCard(props: { item: UserItem; role: "request" | "summary" }) {
  const style = useStyle()
  const body = () => withoutMarker(props.item.text)
  const request = () => props.role === "request"
  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={style.glyphs.subSession}
      accent={style.theme.accent.user}
      head={request() ? "compaction · continuation brief requested" : "context summary · carried from the previous session"}
      chip={props.item.queued ? "queued" : undefined}
      chipTone="dim"
      defaultOpen={!request()}
      foldable={body().length > 0}
    >
      <text fg={request() ? style.theme.dim : style.theme.fg}>{body()}</text>
    </CardFrame>
  )
}
