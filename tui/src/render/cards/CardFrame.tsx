import { Index, Show, createContext, createSignal, useContext, type Accessor, type JSX } from "solid-js"
import { shimmerColor, useFrame, useScreen, useStyle } from "../theme.ts"
import { displayWidth, fit } from "../../ui/columns.ts"
import { onClick } from "../../ui/rows.ts"
import { useFolds } from "../../state/folds.ts"
import { useBrowse } from "../../state/browse.ts"

/**
 * `ok` is not one of these on purpose (T26): a call that worked says how much
 * it brought back, in the same dim as every other note, and the colours are
 * left to the two cases where something needs saying.
 */
export type ChipTone = "err" | "warn" | "dim"

/** True while the card under this provider represents work still in flight. */
export const CardActivityContext = createContext<Accessor<boolean>>()

/**
 * How much a call brought back, as the note says it: nothing at all when it
 * brought back nothing, and never "1 lines".
 */
export function sizeNote(output: string): string {
  if (output.length === 0) return ""
  const lines = output.split("\n").length
  return lines === 1 ? "1 line" : `${lines} lines`
}

/**
 * The shared skeleton of every tool card: one head line (glyph · head · note)
 * and a body that folds. Each concrete card decides its glyph, head, note and
 * body; the layout, the fold affordance and the spill pointer live here once,
 * so a new card cannot accidentally invent a second visual language.
 *
 * No borders anywhere (tui.md §6): the body is indented, not boxed.
 *
 * THE HEAD LINE READS LEFT TO RIGHT (T26). The note used to be a right-aligned
 * chip, which put an `ok` at column 98 with thirty blank columns between it and
 * the call it belonged to — a second ragged column of small print, and the main
 * reason a screenful of calls looked like a form rather than a story. It sits
 * inline now, in parentheses, right where the eye already is: `$ zig build test
 * (12 lines · exit 1)`. Nothing on the line can be flex-shrunk — the head is cut
 * by us (`fit`) to whatever the note and the fold marker leave.
 */
export function CardFrame(props: {
  /** The card's stable key — the fold store and browse mode both key off it. */
  itemKey: string
  glyph: string
  accent: string
  head: string
  chip?: string
  chipTone?: ChipTone
  /** `dim` for a card that is context rather than something that happened. */
  headTone?: "muted" | "dim"
  /** From `tui.toml` (tui.md §7); a per-card toggle overrides it. */
  defaultOpen: boolean
  /** False when there is nothing to reveal: no fold marker, no click target. */
  foldable: boolean
  spillPath?: string | null
  /**
   * One thing this card can DO, on a row of its own under the head line (T43).
   *
   * OUTSIDE THE FOLD, like the spill pointer above it and for the same reason:
   * a card is folded by default, and an affordance nobody can see is not one.
   * The head line keeps meaning "fold me" — one gesture, one meaning, on every
   * card — and this row is the only place a card offers a second one.
   */
  action?: { text: string; onPress: () => void } | null
  children?: JSX.Element
}) {
  const style = useStyle()
  const folds = useFolds()
  const browse = useBrowse()
  const screen = useScreen()
  const frame = useFrame()
  const contextualActive = useContext(CardActivityContext)
  const [hovered, setHovered] = createSignal(false)

  const open = () => props.foldable && folds.isOpen(props.itemKey, props.defaultOpen)
  const selected = () => browse.selected() === props.itemKey
  const toggle = () => {
    if (props.foldable) folds.toggle(props.itemKey, props.defaultOpen)
  }
  // Press and release on the same cell. A press that travelled was a drag over
  // the text, which OpenTUI turns into a selection — and a card that folded
  // itself because somebody selected its head line would make copying text out
  // of the transcript rearrange the transcript (`ui/rows.ts`).
  const click = onClick(toggle)

  /**
   * The line's own width discipline. The note keeps what it needs (it is short
   * and it is the part that says something went wrong); the head gives up
   * columns first, because the beginning of a path or a command is the half
   * worth reading.
   */
  const room = () => Math.min(screen().width, style.maxWidth) - 2 - 2 - (props.foldable ? 2 : 0)
  const note = () => fit(props.chip ?? "", Math.max(0, Math.floor(room() / 2)))
  const head = () => fit(props.head, Math.max(4, room() - (note().length > 0 ? displayWidth(note()) + 4 : 0)))
  const headCells = () => Array.from(head())
  const active = () => contextualActive?.() ?? false
  const headBase = () => (props.headTone === "dim" ? style.theme.dim : style.theme.muted)

  const chipColor = () => {
    switch (props.chipTone ?? "dim") {
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
        backgroundColor={
          selected() ? style.theme.selection : props.foldable && hovered() ? style.theme.hover : undefined
        }
        // Clicking the head line is the mouse half of the fold interaction
        // (tui.md §4.2); the keyboard half is browse mode. The tint under the
        // pointer is the only thing that says a head line answers to a click
        // at all — a card has no button to look like.
        onMouseDown={click.onMouseDown}
        onMouseUp={click.onMouseUp}
        onMouseOver={() => setHovered(true)}
        onMouseOut={() => setHovered(false)}
      >
        <text fg={props.accent} flexShrink={0}>
          {props.glyph}{" "}
        </text>
        {/* `muted`, not `fg`: a call is what the model DID, and the brightest
            text on screen should stay what it and the person SAID. The glyph
            already carries the role colour (tui.md §6). */}
        <box flexDirection="row" flexShrink={0} height={1}>
          <Index each={headCells()}>
            {(ch, index) => (
              <text
                fg={
                  active() && style.motion
                    ? shimmerColor(frame(), index, headCells().length, headBase(), style.theme.lift)
                    : headBase()
                }
              >
                {ch()}
              </text>
            )}
          </Index>
        </box>
        <Show when={note().length > 0}>
          <text fg={chipColor()} flexShrink={0}>{`  (${note()})`}</text>
        </Show>
        <Show when={props.foldable}>
          <text fg={style.theme.faint} flexShrink={0}>
            {" "}
            {open() ? style.glyphs.foldOpen : style.glyphs.foldClosed}
          </text>
        </Show>
      </box>

      <Show when={open()}>
        <box paddingLeft={2} width="100%" flexDirection="column">
          {props.children}
        </box>
      </Show>

      <Show when={props.action}>
        <ActionRow action={props.action!} />
      </Show>

      {/* Cut, never wrapped (tui.md §6): a spill path is as long as the scratch
          directory made it, and a second row of path under every long-output
          card is the transcript's rhythm broken by a pointer nobody reads twice. */}
      <Show when={props.spillPath}>
        <box paddingLeft={2}>
          <text fg={style.theme.dim}>{fit(`full output → ${props.spillPath}`, Math.max(8, room()))}</text>
        </box>
      </Show>
    </box>
  )
}

/**
 * The one clickable row a card may offer. It looks like what it is — the arrow
 * glyph, `accent.evolve`, and the same hover tint the head line uses, because
 * the tint is the only thing on this screen that says "a click does something
 * here" (T43). Press and release on the same cell, so dragging across it to
 * copy text does not navigate.
 */
function ActionRow(props: { action: { text: string; onPress: () => void } }) {
  const style = useStyle()
  const screen = useScreen()
  const [hovered, setHovered] = createSignal(false)
  const click = onClick(() => props.action.onPress())
  /** Cut like every other row: a session id is long and a wrapped link is two rows. */
  const room = () => Math.max(8, Math.min(screen().width, style.maxWidth) - 6)
  return (
    <box
      paddingLeft={2}
      flexDirection="row"
      backgroundColor={hovered() ? style.theme.hover : undefined}
      onMouseDown={click.onMouseDown}
      onMouseUp={click.onMouseUp}
      onMouseOver={() => setHovered(true)}
      onMouseOut={() => setHovered(false)}
    >
      <text fg={style.theme.accent.evolve} flexShrink={0}>
        {fit(`${style.glyphs.open} ${props.action.text}`, room())}
      </text>
    </box>
  )
}
