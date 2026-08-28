import { For, Show } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { DialogHint, DialogTitle, dialog_gutter } from "./Dialog.tsx"
import { columnWidth, fit } from "./columns.ts"
import { barCells, fillGlyph, type ContextFill, type ContextSection } from "../state/context.ts"

/**
 * The ring, opened out (tui.md §4.5, §11 T82).
 *
 * A composer-area panel, like every other thing on this screen that is about
 * the conversation right there (`ApprovalPanel`, `ModePicker`, `PluginPanel`) —
 * NOT a full-screen overlay, because the one question it answers is "should I
 * compact", and that is asked while looking at what is on screen.
 *
 * It is passive: it does not take the keyboard, nothing in it is chosen, and
 * `App` simply does not draw it while a trusted zone is up — the same rule a
 * package's panel lives under (tui-plugin D4). Nothing an extension or a person
 * does here can come between somebody and an approval question.
 *
 * `/usage` is still where the whole ledger's arithmetic lives. This is the few
 * numbers that bear on one decision, beside the meter that raised it.
 */
export function ContextPanel(props: { fill: ContextFill | null; sections: ContextSection[] }) {
  const style = useStyle()
  const screen = useScreen()
  const width = () => Math.min(screen().width, style.maxWidth)
  const room = () => Math.max(24, width() - 6)
  /** The label column, from the labels themselves — no number to outgrow. */
  const labelCol = () => columnWidth(props.sections.flatMap((s) => s.rows.map((r) => r.label)))

  const tone = () => {
    switch (props.fill?.band) {
      case "urgent":
        return style.theme.err
      case "warn":
        return style.theme.warn
      default:
        return style.theme.muted
    }
  }

  /** The bar is the percentage drawn; the row above already says the number. */
  const barWidth = () => Math.max(8, Math.min(40, room() - dialog_gutter - 8))
  const filled = () => barCells(props.fill?.percent ?? 0, barWidth())

  return (
    <box flexDirection="column" width="100%" maxWidth={style.maxWidth} paddingLeft={1} paddingRight={1} flexShrink={0}>
      <DialogTitle
        glyph={props.fill ? fillGlyph(props.fill.percent, style.glyphs.ring) : style.glyphs.picker}
        name="context"
        caption={props.fill ? `${props.fill.percent}% of the window` : "how full the next request is"}
        tone={tone()}
      />

      <Show when={props.fill}>
        <box flexDirection="row" width="100%" height={1}>
          <text fg={style.theme.faint} flexShrink={0}>
            {" ".repeat(dialog_gutter)}
          </text>
          <text fg={tone()} flexShrink={0}>
            {style.glyphs.meter[0].repeat(filled())}
          </text>
          <text fg={style.theme.faint} flexShrink={0}>
            {style.glyphs.meter[1].repeat(Math.max(0, barWidth() - filled()))}
          </text>
        </box>
      </Show>

      <For each={props.sections}>
        {(section, index) => (
          <>
            {/* A blank line before every section but the first: the sections are
                what makes this a panel rather than a paragraph, and the next one
                to arrive is a provider's own usage window. */}
            <Show when={index() > 0}>
              <box height={1} flexShrink={0} />
            </Show>
            <text fg={style.theme.dim} height={1}>
              {`${" ".repeat(dialog_gutter)}${section.title}`}
            </text>
            <For each={section.rows}>
              {(row) => (
                <box flexDirection="row" width="100%" height={1}>
                  <box width={dialog_gutter + labelCol()} flexShrink={0}>
                    <text fg={style.theme.dim}>{`${" ".repeat(dialog_gutter)}${row.label}`}</text>
                  </box>
                  <text fg={style.theme.fg} flexShrink={0}>
                    {fit(row.value, Math.max(0, room() - dialog_gutter - labelCol()))}
                  </text>
                </box>
              )}
            </For>
          </>
        )}
      </For>

      <DialogHint text="Esc close · /compact carries a summary into a new session" width={room()} />
    </box>
  )
}
