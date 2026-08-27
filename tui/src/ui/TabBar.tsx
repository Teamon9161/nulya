import { For, Show, createSignal } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { onClick, createHover } from "./rows.ts"
import { displayWidth, fit } from "./columns.ts"
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
 * Below this a name is not a name, and the row gives up something else first.
 */
export const min_tab_label = 8

/**
 * What one row of N tabs looks like at this width (T70).
 *
 * The strip is the one row in this front end whose CONTENTS ARE DECIDED BY THE
 * PERSON — open a fifth tab on an eighty column terminal and the layout has to
 * absorb it. It must never wrap (a strip that grew a second row would push the
 * whole screen down every time a tab opened) and it must never overflow either,
 * because a row that runs past the edge does not stop at the last whole thing:
 * it loses the `+` and cuts the last tab mid-glyph.
 *
 * So it gives up cells from the outside in, the same rule `sidebarRowPlan` and
 * `railFooter` follow: an even share of what is left, and if that share is too
 * narrow for a name to be a name, THE BUTTONS GO BEFORE THE NAMES DO. `✕` is a
 * convenience — Ctrl+W is the verb — while a tab whose name is one letter is a
 * tab strip that has stopped doing its job.
 *
 * THE ONE LIMIT, WRITTEN DOWN. Below `marker + 1 + gap` columns per tab there
 * is no plan: five columns times N is more than the row has, and no share of
 * anything fixes that. Then the strip clips at the margin, as it did before any
 * of this. The answer if it ever bites is the one goals/tui-shell.md §4 already
 * writes down for the chip strip — keep what fits and fold the rest into a `+k`
 * — and it is not built here because it needs its own click behaviour and fires
 * only on a terminal narrower than about five columns per open tab.
 */
export function stripPlan(
  screenWidth: number,
  tabs: number,
  cost: { marker: number; close: number; gap: number; plus: number },
): { label: number; closes: boolean } {
  const count = Math.max(1, tabs)
  const share = (closes: boolean) => {
    const fixed = count * (cost.marker + (closes ? cost.close : 0)) + (count - 1) * cost.gap + cost.plus
    return Math.floor(Math.max(0, screenWidth - 2 - fixed) / count)
  }
  const withCloses = share(true)
  if (withCloses >= min_tab_label) return { label: withCloses, closes: true }
  return { label: Math.max(1, share(false)), closes: false }
}

/**
 * One line of open sessions, and only when there is more than one (tui.md §5.5).
 * A single-session screen must look exactly as it did before tabs existed —
 * which is also why the `+` lives here and not on a screen with one tab: the
 * strip is the tab UI, and a control for tabs on a screen that is not showing
 * any is chrome nobody asked for.
 *
 * A tab is the one thing on screen that looks like a control, so it answers to
 * a click as well as to F4 — the same `select` either way (tui.md §11, T18) —
 * and since T70 it carries the other two verbs a strip of tabs is expected to
 * have. Both are the front end's existing ones: `✕` is `closeTab`'s own
 * `tabs.close`, `+` is the `startDraft` a bare `/new` runs. Neither is a second
 * path to a second behaviour.
 *
 * WHICH TAB IS IN FRONT IS A SHAPE, NOT A COLOUR (§6.1 rule 1). It used to be a
 * background tint plus `accent.user`, with `⤷` — the sub-session glyph — on
 * every tab saying nothing about any of them; now the current one wears `▎`,
 * the left rule this front end marks "this is the one" with everywhere else,
 * and the rest wear two blank columns. The blanks are not alignment — a strip
 * is one row and there is no column to line up with — they are so that
 * SWITCHING TABS DOES NOT MOVE THE TABS: a marker only the active tab paid for
 * would shift every name two cells to the left of it each time the front tab
 * changed, which is the same bug shape as a right-aligned cell that moves every
 * time the cursor does (T12, T47).
 */
export function TabBar(props: {
  tabs: Tab[]
  activeIndex: number
  onSelect?: (index: number) => void
  /** Close that tab — the same verb Ctrl+W has. Absent on a strip that cannot close. */
  onClose?: (index: number) => void
  /** A new draft tab, the same one a bare `/new` opens. */
  onNew?: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const hover = createHover()
  const [overClose, setOverClose] = createSignal(-1)
  const [overNew, setOverNew] = createSignal(false)
  const labels = () => tabLabels(props.tabs)
  const newClick = onClick(() => props.onNew?.())
  const plan = () =>
    stripPlan(screen().width, props.tabs.length, {
      // `▎ ` or the two blanks that keep every name in the same column.
      marker: 2,
      close: props.onClose ? displayWidth(` ${style.glyphs.closeTab}`) : 0,
      gap: 2,
      plus: props.onNew ? displayWidth(`  ${style.glyphs.newTab}`) : 0,
    })
  const closable = () => Boolean(props.onClose) && plan().closes
  return (
    <Show when={props.tabs.length > 1}>
      <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={1} paddingRight={1}>
        <For each={props.tabs}>
          {(tab, index) => {
            const here = () => index() === props.activeIndex
            const click = onClick(() => props.onSelect?.(index()))
            // `stop`, and the release only: the tab under it would otherwise
            // select the very tab this closes (`ui/rows.ts`).
            const close = onClick(() => props.onClose?.(index()), true)
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
                    here() ? style.theme.selection : hover.at() === index() ? style.theme.hover : undefined
                  }
                  onMouseDown={click.onMouseDown}
                  onMouseUp={click.onMouseUp}
                  {...hover.row(index())}
                >
                  <text fg={here() ? style.theme.accent.user : style.theme.faint} flexShrink={0}>
                    {here() ? `${style.glyphs.bar} ` : "  "}
                  </text>
                  <text fg={here() ? style.theme.fg : style.theme.muted} flexShrink={0}>
                    {fit(labels()[index()] ?? "", plan().label)}
                  </text>
                  <Show when={tab.kind === "session" && tab.attach.role() === "observer"}>
                    <text fg={style.theme.dim} flexShrink={0}>
                      {" (observer)"}
                    </text>
                  </Show>
                  {/* Furniture until the pointer is on it, and `err` then: it
                      is the one control on this row that throws something
                      away, and it should say so at the moment it is about to
                      be pressed rather than glowing at all times. */}
                  <Show when={closable()}>
                    <box
                      flexShrink={0}
                      height={1}
                      onMouseDown={close.onMouseDown}
                      onMouseUp={close.onMouseUp}
                      onMouseOver={() => setOverClose(index())}
                      onMouseOut={() => setOverClose((now) => (now === index() ? -1 : now))}
                    >
                      <text fg={overClose() === index() ? style.theme.err : style.theme.faint}>
                        {" "}
                        {style.glyphs.closeTab}
                      </text>
                    </box>
                  </Show>
                </box>
              </>
            )
          }}
        </For>
        {/* Last, after every tab, where a new one would appear. */}
        <Show when={props.onNew}>
          <box
            flexShrink={0}
            height={1}
            backgroundColor={overNew() ? style.theme.hover : undefined}
            onMouseDown={newClick.onMouseDown}
            onMouseUp={newClick.onMouseUp}
            onMouseOver={() => setOverNew(true)}
            onMouseOut={() => setOverNew(false)}
          >
            <text fg={style.theme.faint}>
              {"  "}
              {style.glyphs.newTab}
            </text>
          </box>
        </Show>
      </box>
    </Show>
  )
}
