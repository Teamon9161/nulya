/**
 * The shape every dialog above the composer shares (tui.md §6).
 *
 * There are four of them — `/mode`, `/agent`, `/with` and the approval dialog —
 * and they were four hand-built copies of the same three parts, which is how
 * they ended up with three different left edges on one screen: the title on
 * column 1, the cursor gutter on column 3, the hint line on column 3 again but
 * two columns right of a title that was supposed to head it.
 *
 * ONE LEFT EDGE, and it is the same one the overlays use: the box pads one
 * column, the two-column gutter (`ui/rows.ts`) occupies columns 1–2, and every
 * piece of content — a row's name, a title's words, a body line — starts on
 * column 3. A title glyph is exactly two columns wide for that reason: `◈ ` is
 * the title's own gutter.
 *
 * The hint is the last line and always dim: one line per screen that says what
 * can be done here, written the same way in every panel of this front end
 * (`overlays/Footer.tsx` is the same law for a full-screen panel).
 */
import { For } from "solid-js"
import { useStyle } from "../render/theme.ts"
import { wrapWords } from "./columns.ts"

/** Columns a row's gutter takes before its first content cell. */
export const dialog_gutter = 2

/**
 * A dialog's first line: what this is, then what it is for.
 *
 * `glyph` is optional and means something when it is there (tui.md §6): `◈` is
 * the mark of choosing what this session runs as. The approval dialog has none
 * on purpose — it is not a choice about identity, it is one call being judged,
 * and its colour is what says so.
 */
export function DialogTitle(props: { glyph?: string; name: string; caption?: string; tone?: string }) {
  const style = useStyle()
  return (
    <box flexDirection="row" width="100%" height={1}>
      <text fg={props.tone ?? style.theme.accent.evolve} flexShrink={0}>
        {props.glyph ? `${props.glyph} ${props.name}` : props.name}
      </text>
      <text fg={style.theme.dim} flexShrink={0}>
        {props.caption ? ` · ${props.caption}` : ""}
      </text>
    </box>
  )
}

/** A body line under the title: indented to the content column, never wrapped by the terminal. */
export function DialogBody(props: { lines: string[]; tone?: string }) {
  const style = useStyle()
  return (
    <For each={props.lines}>
      {(line) => (
        <text fg={props.tone ?? style.theme.muted} height={1}>
          {`${" ".repeat(dialog_gutter)}${line}`}
        </text>
      )}
    </For>
  )
}

/** The one dim line that says what can be done here. Broken at its ` · ` joints. */
export function DialogHint(props: { text: string; width: number }) {
  const style = useStyle()
  return (
    <For each={wrapWords(props.text, props.width)}>
      {(line) => (
        <text fg={style.theme.dim} height={1}>
          {line}
        </text>
      )}
    </For>
  )
}
