import { For, Show, createSignal } from "solid-js"
import { useStyle } from "../render/theme.ts"
import { onClick } from "./rows.ts"
import type { SessionTab } from "../state/tabs.ts"

/**
 * One line of open sessions, and only when there is more than one (tui.md §5.5).
 * A single-session screen must look exactly as it did before tabs existed.
 *
 * A tab is the one thing on screen that looks like a control, so it answers to
 * a click as well as to F4 — the same `select` either way (tui.md §11, T18).
 */
export function TabBar(props: { tabs: SessionTab[]; activeIndex: number; onSelect?: (index: number) => void }) {
  const style = useStyle()
  const [hovered, setHovered] = createSignal(-1)
  return (
    <Show when={props.tabs.length > 1}>
      <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={1} paddingRight={1}>
        <For each={props.tabs}>
          {(tab, index) => {
            const here = () => index() === props.activeIndex
            const click = onClick(() => props.onSelect?.(index()))
            return (
              <>
                {/* The gap between tabs stays outside both boxes: a highlight
                    that ran into it would make two tabs look like one block. */}
                <Show when={index() > 0}>
                  <text fg={style.theme.faint}>{"  "}</text>
                </Show>
                <box
                  flexDirection="row"
                  flexShrink={0}
                  height={1}
                  backgroundColor={
                    here() ? style.theme.selection : hovered() === index() ? style.theme.hover : undefined
                  }
                  onMouseDown={click.onMouseDown}
                  onMouseUp={click.onMouseUp}
                  onMouseOver={() => setHovered(index())}
                  onMouseOut={() => setHovered((now) => (now === index() ? -1 : now))}
                >
                  <text fg={here() ? style.theme.accent.user : style.theme.muted}>
                    {style.glyphs.subSession} {tab.id}
                  </text>
                  <Show when={tab.attach.role() === "observer"}>
                    <text fg={style.theme.dim}> (observer)</text>
                  </Show>
                </box>
              </>
            )
          }}
        </For>
      </box>
    </Show>
  )
}
