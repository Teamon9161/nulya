import { For } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { createHover, onClick, rowBackground, rowGutter, rowText } from "./rows.ts"
import { fit } from "./columns.ts"
import { DialogHint, DialogTitle } from "./Dialog.tsx"
import { modes, type PermissionMode } from "../approvals.ts"

/**
 * `/mode` and the status-line chip: which permission mode this run is in
 * (tui.md §5.7, T31 — tcode's `mode_picker.rs` in nulya's two-mode vocabulary).
 *
 * A dialog above the composer, not a full-screen overlay, and the same shape as
 * the approval dialog next to it (`ApprovalPanel`, T28): a title, one row per
 * answer with the shared cursor gutter, a `✓` on the one in force, one hint
 * line. Two rows of content do not earn a screen, and the thing being chosen is
 * about what happens in the transcript right there.
 *
 * It exists because the chip used to be a TOGGLE with a two-line explanation
 * after every press. A toggle cannot say what the other side is, so the words
 * had to — and they landed on the one line that has no room for them, pushing
 * the model, the cost and the activity into each other. A list says both modes
 * at once, and having said them, has nothing left to announce.
 */
export interface ModeChoice {
  mode: PermissionMode
  what: string
}

/**
 * What each mode actually does, in one line.
 *
 * `unsafe` names the standing tables on purpose: it is the one fact that keeps
 * the mode from being all-or-nothing, and it is the reason `[approvals] deny`
 * is worth writing before switching.
 */
export const mode_choices: ModeChoice[] = [
  { mode: "ask", what: "ask before every tool call no rule settles" },
  { mode: "unsafe", what: "run every tool call without asking · only [approvals] deny / ask rules still stop it" },
]

/** Where the cursor opens: on the mode in force. */
export function initialChoice(current: PermissionMode): number {
  const at = mode_choices.findIndex((choice) => choice.mode === current)
  return at >= 0 ? at : 0
}

/**
 * The cursor after `delta` rows. Clamped rather than wrapped, as tcode's picker
 * is: with two rows a wrap makes ↑ and ↓ the same key, and "press down twice to
 * be sure" would land back where it started.
 */
export function moveChoice(at: number, delta: number): number {
  return Math.min(Math.max(at + delta, 0), mode_choices.length - 1)
}

/** The mode a row picks, or null when the row is not one. */
export function modeAt(index: number): PermissionMode | null {
  return mode_choices[index]?.mode ?? null
}

export function ModePicker(props: {
  /** The mode in force: the row that carries the `✓`. */
  current: PermissionMode
  /** Which row the cursor is on. */
  selected: number
  onSelect: (index: number) => void
  onPick: (mode: PermissionMode) => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const hover = createHover()
  const width = () => Math.min(screen().width, style.maxWidth)
  const room = () => Math.max(24, width() - 6)
  /** The mode column, wide enough for the longest name and no wider. */
  const nameCol = () => modes.reduce((widest, mode) => Math.max(widest, mode.length), 0) + 2

  return (
    <box flexDirection="column" width="100%" maxWidth={style.maxWidth} paddingLeft={1} paddingRight={1} flexShrink={0}>
      <DialogTitle
        glyph={style.glyphs.picker}
        name="permission mode"
        caption="what happens to a call no rule settles"
      />

      <For each={mode_choices}>
        {(choice, index) => {
          const click = onClick(() => props.onPick(choice.mode))
          const tone = () => ({ selected: props.selected === index(), hovered: hover.at() === index() })
          const here = () => choice.mode === props.current
          return (
            <box
              flexDirection="row"
              width="100%"
              height={1}
              flexShrink={0}
              backgroundColor={rowBackground(style, tone())}
              onMouseDown={click.onMouseDown}
              onMouseUp={click.onMouseUp}
              onMouseOver={() => {
                hover.row(index()).onMouseOver()
                // The pointer is the cursor while it is over the list, as in the
                // approval dialog: a click then answers what the eye is on.
                props.onSelect(index())
              }}
              onMouseOut={hover.row(index()).onMouseOut}
            >
              <text fg={rowGutter(style, tone()).fg} flexShrink={0}>
                {rowGutter(style, tone()).text}
              </text>
              <box width={nameCol()} flexShrink={0}>
                <text
                  fg={rowText(
                    style,
                    tone(),
                    choice.mode === "unsafe"
                      ? style.theme.warn
                      : tone().selected
                        ? style.theme.fg
                        : style.theme.muted,
                  )}
                >
                  {choice.mode}
                </text>
              </box>
              <text fg={rowText(style, tone(), style.theme.dim)} flexShrink={0}>
                {fit(choice.what, Math.max(0, room() - nameCol() - 4))}
              </text>
              <text fg={style.theme.ok} flexShrink={0}>
                {here() ? ` ${style.glyphs.check}` : ""}
              </text>
            </box>
          )
        }}
      </For>

      <DialogHint text="↑↓ choose · click a mode · Enter apply · Esc close" width={room()} />
    </box>
  )
}
