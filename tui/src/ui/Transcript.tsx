import { For, Show } from "solid-js"
import { Card } from "../render/cards/index.tsx"
import { CompositionCard } from "../render/cards/CompositionCard.tsx"
import { useStyle } from "../render/theme.ts"
import type { Contributions } from "../nulya/files.ts"
import type { SessionHeader } from "../nulya/ledger.ts"
import type { TranscriptItem } from "../state/session.ts"

/**
 * The transcript: a sticky-bottom scrollbox, no borders, content capped at
 * `max_width` and left aligned (tui.md §1.2 D1/D9, §6). Cards are keyed by the
 * item key so a streaming turn updates in place instead of being rebuilt.
 *
 * The composition card leads because it is the frame everything else happened
 * inside (tui.md §5.1); it comes from the header, which is not an event, so it
 * sits outside the item list rather than being faked into it.
 */
export function Transcript(props: {
  items: TranscriptItem[]
  header?: SessionHeader | null
  contributions?: Contributions[]
}) {
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
      <Show when={props.header}>
        <CompositionCard header={props.header ?? null} contributions={props.contributions} />
      </Show>
      <For each={props.items}>{(item) => <Card item={item} />}</For>
    </scrollbox>
  )
}
