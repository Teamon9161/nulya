import { For, Show } from "solid-js"
import { useStyle } from "../render/theme.ts"
import type { SessionTab } from "../state/tabs.ts"

/**
 * One line of open sessions, and only when there is more than one (tui.md §5.5).
 * A single-session screen must look exactly as it did before tabs existed.
 */
export function TabBar(props: { tabs: SessionTab[]; activeIndex: number }) {
  const style = useStyle()
  return (
    <Show when={props.tabs.length > 1}>
      <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={1} paddingRight={1}>
        <For each={props.tabs}>
          {(tab, index) => {
            const here = () => index() === props.activeIndex
            return (
              <text fg={here() ? style.theme.accent.user : style.theme.dim}>
                {index() > 0 ? "  " : ""}
                {style.glyphs.subSession} {tab.id}
                {tab.attach.role() === "observer" ? " (observer)" : ""}
              </text>
            )
          }}
        </For>
      </box>
    </Show>
  )
}
