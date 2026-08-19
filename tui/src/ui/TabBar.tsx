import { For, Show, createSignal } from "solid-js"
import { useStyle } from "../render/theme.ts"
import { onClick } from "./rows.ts"
import type { Tab } from "../state/tabs.ts"

/**
 * What a tab is called (tui.md §11, T22).
 *
 * Not the session id. An id is `s-1787067298663-31302c`: it is the handle for
 * `--session` and for `/sessions`, and it says nothing a person recognises. What
 * tells two tabs apart is what they run on, so that is the label — with a `#n`
 * only when two tabs would otherwise read the same, and `(new)` on a tab that is
 * still a draft, because "has this one started yet" is the other real difference.
 *
 * A draft wearing a `--with` package says so too (T31): `/evolve` opens a second
 * tab on the SAME model as the first, so without it the two read identically and
 * the only difference between them — which one thinks it is the slow loop — was
 * invisible from the one line whose whole job is telling tabs apart.
 */
export function tabLabels(tabs: readonly Tab[]): string[] {
  const base = tabs.map((tab) => {
    if (tab.kind === "draft") {
      const pick = tab.pick()
      const bring = tab.bring()
      return `${pick?.model || pick?.profile || "new"}${bring ? ` · ${bring.id}` : ""} (new)`
    }
    const header = tab.state.snapshot.header
    return header?.model_identity.model || header?.model || tab.id
  })
  return base.map((label, index) => {
    const twins = base.filter((other) => other === label).length
    return twins > 1 ? `${label} #${base.slice(0, index + 1).filter((other) => other === label).length}` : label
  })
}

/**
 * One line of open sessions, and only when there is more than one (tui.md §5.5).
 * A single-session screen must look exactly as it did before tabs existed.
 *
 * A tab is the one thing on screen that looks like a control, so it answers to
 * a click as well as to F4 — the same `select` either way (tui.md §11, T18).
 */
export function TabBar(props: { tabs: Tab[]; activeIndex: number; onSelect?: (index: number) => void }) {
  const style = useStyle()
  const [hovered, setHovered] = createSignal(-1)
  const labels = () => tabLabels(props.tabs)
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
                    {style.glyphs.subSession} {labels()[index()]}
                  </text>
                  <Show when={tab.kind === "session" && tab.attach.role() === "observer"}>
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
