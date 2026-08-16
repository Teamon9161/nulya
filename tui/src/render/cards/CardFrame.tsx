import { Show, type JSX } from "solid-js"
import { useScreen, useStyle } from "../theme.ts"
import { useFolds } from "../../state/folds.ts"
import { useBrowse } from "../../state/browse.ts"

export type ChipTone = "ok" | "err" | "warn" | "dim"

/**
 * The shared skeleton of every tool card: one head line (glyph · head · chip)
 * and a body that folds. Each concrete card decides its glyph, head, chip and
 * body; the layout, the fold affordance and the spill pointer live here once,
 * so a new card cannot accidentally invent a second visual language.
 *
 * No borders anywhere (tui.md §6): the body is indented, not boxed.
 */
export function CardFrame(props: {
  /** The card's stable key — the fold store and browse mode both key off it. */
  itemKey: string
  glyph: string
  accent: string
  head: string
  chip?: string
  chipTone?: ChipTone
  /** From `tui.toml` (tui.md §7); a per-card toggle overrides it. */
  defaultOpen: boolean
  /** False when there is nothing to reveal: no fold marker, no click target. */
  foldable: boolean
  spillPath?: string | null
  children?: JSX.Element
}) {
  const style = useStyle()
  const folds = useFolds()
  const browse = useBrowse()
  const screen = useScreen()

  const open = () => props.foldable && folds.isOpen(props.itemKey, props.defaultOpen)
  const wide = () => screen().width >= 60
  const selected = () => browse.selected() === props.itemKey
  const toggle = () => {
    if (props.foldable) folds.toggle(props.itemKey, props.defaultOpen)
  }

  const chipColor = () => {
    switch (props.chipTone ?? "dim") {
      case "ok":
        return style.theme.ok
      case "err":
        return style.theme.err
      case "warn":
        return style.theme.warn
      default:
        return style.theme.dim
    }
  }

  return (
    <box flexDirection="column" width="100%" paddingLeft={2}>
      <box
        flexDirection="row"
        width="100%"
        backgroundColor={selected() ? style.theme.selection : undefined}
        // Clicking the head line is the mouse half of the fold interaction
        // (tui.md §4.2); the keyboard half is Ctrl+O and browse mode.
        onMouseDown={toggle}
      >
        <text fg={props.accent} flexShrink={0}>
          {props.glyph}{" "}
        </text>
        <box flexGrow={1} flexShrink={1} flexBasis={0}>
          <text fg={style.theme.fg}>{props.head}</text>
        </box>
        <Show when={wide() && (props.chip ?? "").length > 0}>
          <text fg={chipColor()} flexShrink={0}>
            {" "}
            {props.foldable ? `${open() ? style.glyphs.foldOpen : style.glyphs.foldClosed} ` : ""}
            {props.chip}
          </text>
        </Show>
      </box>

      <Show when={open()}>
        <box paddingLeft={2} width="100%" flexDirection="column">
          {props.children}
        </box>
      </Show>

      <Show when={props.spillPath}>
        <box paddingLeft={2}>
          <text fg={style.theme.dim}>full output → {props.spillPath}</text>
        </box>
      </Show>
    </box>
  )
}
