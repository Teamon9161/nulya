/**
 * The queue lane: how many user turns are sitting in the inbox waiting for a
 * step boundary to drain them, and what they say (agent-runner ar-t1, tui.md
 * §4.4b).
 *
 * Lives in the same region `WorkingStatus` does — directly above the composer
 * — for the same reason: this is "what is happening right now", not "what
 * this session is" (T38). It draws nothing when there is nothing queued
 * (`pendingCount() === 0`); T35/T38's rule against a resting-state word like
 * `idle` applies here just as much as it did to the activity line — there is
 * no "0 queued" row.
 *
 * Every row means the same click: the inbox is a FIFO the kernel drains whole
 * at the next step boundary (DESIGN §3.4), so there is no such thing as
 * delivering one queued message ahead of the others — clicking any row is the
 * interrupt-and-deliver gesture (`ctrl+j`, `App.tsx`'s `flushQueue`), the same
 * one the summary line's own hint names.
 */
import { For, Show, createSignal } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { lifted, onClick } from "./rows.ts"
import { fit } from "./columns.ts"

export interface QueuedMessage {
  key: string
  text: string
}

export function QueueLane(props: { messages: readonly QueuedMessage[]; onSelect?: () => void }) {
  const style = useStyle()
  const screen = useScreen()
  const [hovered, setHovered] = createSignal<string | null>(null)
  /** One row per message, cut to the terminal's own width (minus the gutter). */
  const room = () => Math.max(8, screen().width - 6)

  return (
    <Show when={props.messages.length > 0}>
      <box flexDirection="column" width="100%" flexShrink={0} paddingLeft={2} paddingRight={1}>
        <text fg={style.theme.warn}>
          {`⏸ ${props.messages.length} queued — enter queues · ctrl+j interrupts & delivers`}
        </text>
        <For each={props.messages}>
          {(message) => {
            const click = onClick(() => props.onSelect?.())
            return (
              <box
                flexDirection="row"
                width="100%"
                height={1}
                flexShrink={0}
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                onMouseOver={() => setHovered(message.key)}
                onMouseOut={() => setHovered((now) => (now === message.key ? null : now))}
              >
                <text fg={style.theme.dim}>{"  "}</text>
                <text fg={lifted(style, hovered() === message.key, style.theme.faint)}>
                  {fit(message.text.replace(/\n/g, " "), room())}
                </text>
              </box>
            )
          }}
        </For>
      </box>
    </Show>
  )
}
