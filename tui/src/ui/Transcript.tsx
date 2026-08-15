import { For } from "solid-js"
import { Card } from "../render/cards/index.tsx"
import { useStyle } from "../render/theme.ts"
import type { TranscriptItem } from "../state/session.ts"

/**
 * The transcript: a sticky-bottom scrollbox, no borders, content capped at
 * `max_width` and left aligned (tui.md §1.2 D1/D9, §6). Cards are keyed by the
 * item key so a streaming turn updates in place instead of being rebuilt.
 */
export function Transcript(props: { items: TranscriptItem[]; empty?: boolean }) {
  const style = useStyle()
  return (
    <scrollbox
      flexGrow={1}
      width="100%"
      stickyScroll
      stickyStart="bottom"
      verticalScrollbarOptions={{
        trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
      }}
      contentOptions={{ flexDirection: "column", width: "100%", maxWidth: style.maxWidth, paddingRight: 1 }}
    >
      <For each={props.items}>{(item) => <Card item={item} />}</For>
    </scrollbox>
  )
}
