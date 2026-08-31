/**
 * A single queue status/action row. The transcript is the only place queued
 * message bodies are shown; repeating them here made one turn look like two.
 * Clicking the row performs the same FIFO interrupt-and-deliver gesture as
 * Ctrl+J, and nothing is drawn when the queue is empty.
 */
import { Show, createSignal } from "solid-js"
import { useStyle } from "../render/theme.ts"
import { lifted, onClick } from "./rows.ts"

export interface QueuedMessage {
  key: string
  text: string
}

export function QueueLane(props: { messages: readonly QueuedMessage[]; onSelect?: () => void }) {
  const style = useStyle()
  const [hovered, setHovered] = createSignal(false)
  const click = onClick(() => props.onSelect?.())

  return (
    <Show when={props.messages.length > 0}>
      <box
        width="100%"
        height={1}
        flexShrink={0}
        paddingLeft={2}
        paddingRight={1}
        onMouseDown={click.onMouseDown}
        onMouseUp={click.onMouseUp}
        onMouseOver={() => setHovered(true)}
        onMouseOut={() => setHovered(false)}
      >
        <text fg={lifted(style, hovered(), style.theme.warn)}>
          {`⏸ ${props.messages.length} queued · ctrl+j interrupts & delivers`}
        </text>
      </box>
    </Show>
  )
}
