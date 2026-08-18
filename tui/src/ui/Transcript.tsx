import { For, Show } from "solid-js"
import type { ScrollBoxRenderable } from "@opentui/core"
import { Card } from "../render/cards/index.tsx"
import { CompositionCard, type NextSession } from "../render/cards/CompositionCard.tsx"
import { Welcome } from "./Welcome.tsx"
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

/**
 * How far the scrollbox is from the live end, in rows. Zero means the newest
 * card is on screen; anything else is "somebody is reading back", which is the
 * one thing the status bar has to say differently (tui.md §4.5).
 */
export function rowsBelow(box: ScrollBoxRenderable | null): number {
  if (!box) return 0
  const viewport = box.viewport?.height ?? 0
  return Math.max(0, Math.round(box.scrollHeight - viewport - box.scrollTop))
}

export function Transcript(props: {
  items: TranscriptItem[]
  header?: SessionHeader | null
  contributions?: Contributions[]
  /** On a tab with no session yet: what the first message will freeze (T22). */
  plan?: NextSession
  /** The workspace this session's `.nulya/` lives in — the welcome screen says so. */
  cwd?: string
  /** The model line of the composition card was clicked: open `/model`. */
  onPickModel?: () => void
  /** A `/command` on the welcome screen was clicked: run it as if typed. */
  onCommand?: (command: string) => void
  /** Handed to `App` so PgUp/PgDn and the "more below" hint have something to act on. */
  ref?: (box: ScrollBoxRenderable) => void
}) {
  const style = useStyle()
  const shown = () => windowItems(props.items, style.historyWindow)
  const hidden = () => props.items.length - shown().length
  return (
    <scrollbox
      ref={props.ref}
      flexGrow={1}
      flexShrink={1}
      width="100%"
      stickyScroll
      stickyStart="bottom"
      viewportCulling
      verticalScrollbarOptions={{
        trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
      }}
      contentOptions={{ flexDirection: "column", width: "100%", maxWidth: style.maxWidth, paddingRight: 1 }}
    >
      <Show when={props.header || props.plan}>
        <CompositionCard
          header={props.header ?? null}
          contributions={props.contributions}
          plan={props.plan}
          onPickModel={props.onPickModel}
        />
      </Show>
      <Show when={hidden() > 0}>
        <text fg={style.theme.faint}>
          {"  "}
          {style.glyphs.foldClosed} {hidden()} earlier items · in the ledger, not on screen ·
          transcript.history_window
        </text>
      </Show>
      {/* An empty session is the one screen with nothing to report; it says
          what this session is and what to do, rather than a blank rectangle. */}
      <Show when={props.items.length === 0}>
        <Welcome cwd={props.cwd} onCommand={props.onCommand} />
      </Show>
      <For each={shown()}>{(item) => <Card item={item} />}</For>
    </scrollbox>
  )
}
