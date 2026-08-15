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
/**
 * The tail that gets mounted. `viewportCulling` skips the RENDER of offscreen
 * children, but every mounted card still costs layout on every frame, so a
 * 5k-event session would pay for 5000 boxes to draw one screenful. The ledger
 * file keeps the whole history either way, and `history_window = 0` mounts all
 * of it (tui.md §11, T4).
 */
export function windowItems(items: readonly TranscriptItem[], window: number): TranscriptItem[] {
  if (window <= 0 || items.length <= window) return items as TranscriptItem[]
  return items.slice(-window)
}

export function Transcript(props: {
  items: TranscriptItem[]
  header?: SessionHeader | null
  contributions?: Contributions[]
}) {
  const style = useStyle()
  const shown = () => windowItems(props.items, style.historyWindow)
  const hidden = () => props.items.length - shown().length
  return (
    <scrollbox
      flexGrow={1}
      width="100%"
      stickyScroll
      stickyStart="bottom"
      viewportCulling
      verticalScrollbarOptions={{
        trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
      }}
      contentOptions={{ flexDirection: "column", width: "100%", maxWidth: style.maxWidth, paddingRight: 1 }}
    >
      <Show when={props.header}>
        <CompositionCard header={props.header ?? null} contributions={props.contributions} />
      </Show>
      <Show when={hidden() > 0}>
        <text fg={style.theme.dim}>
          {"  "}
          {style.glyphs.foldClosed} {hidden()} earlier items · in the ledger, not on screen ·
          transcript.history_window
        </text>
      </Show>
      <For each={shown()}>{(item) => <Card item={item} />}</For>
    </scrollbox>
  )
}
