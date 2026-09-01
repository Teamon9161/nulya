import { For } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { createHover, onClick, rowBackground, rowGutter, rowText } from "./rows.ts"
import { fit, wrapWords } from "./columns.ts"
import { DialogHint, DialogTitle, dialog_gutter } from "./Dialog.tsx"
import type { ExecChoice } from "../state/targets.ts"

/**
 * Bare `/env`, the `⇥` chip and the welcome screen's `shell` row: where the
 * commands of the NEXT session go.
 *
 * The same dialog above the composer as `/mode`, `/with` and `/agent`, for the
 * same reasons: it is a CHOICE, it is a handful of one-line answers,
 * and it belongs where the eye is while typing rather than on a screen of its
 * own. Which is also, exactly, where it was asked for.
 *
 * The rows are DERIVED (`state/targets.ts`) — this front end knows no
 * distribution names and no hosts. What it does know is that the list can be
 * incomplete, so the last row hands the typing back with the syntax in it: the
 * one thing a picker must never do is imply that what it lists is all there is.
 *
 * ALWAYS THE NEXT SESSION. A started session's target is frozen in its header
 * beside its model identity, because a transcript only means anything against
 * the machine that produced it. So the caption says so once, here, instead of
 * every row having to.
 */
export function EnvPicker(props: {
  choices: readonly ExecChoice[]
  /** The spec in force, in the same spelling the rows use (`local`, not ""). */
  current: string
  /** Which row the cursor is on; `choices.length` is the "type one" row. */
  selected: number
  onSelect: (index: number) => void
  /** A target row was taken, or — with `null` — the row that hands back typing. */
  onPick: (choice: ExecChoice | null) => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const hover = createHover()
  const width = () => Math.min(screen().width, style.maxWidth)
  const room = () => Math.max(24, width() - 6)
  const specCol = () =>
    Math.min(28, props.choices.reduce((widest, one) => Math.max(widest, one.spec.length), 12) + 2)

  /** The last row: not a target, so it is not in the list a probe produced. */
  const typeRow = () => props.choices.length

  return (
    <box flexDirection="column" width="100%" maxWidth={style.maxWidth} paddingLeft={1} paddingRight={1} flexShrink={0}>
      <DialogTitle
        glyph={style.glyphs.picker}
        name="shell runs in"
        caption="the next session · only shell moves, this harness stays here"
      />

      <For each={props.choices}>
        {(one, index) => {
          const click = onClick(() => props.onPick(one))
          const tone = () => ({ selected: props.selected === index(), hovered: hover.at() === index() })
          const inForce = () => one.spec === props.current
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
                props.onSelect(index())
              }}
              onMouseOut={hover.row(index()).onMouseOut}
            >
              <text fg={rowGutter(style, tone()).fg} flexShrink={0}>
                {rowGutter(style, tone()).text}
              </text>
              <box width={specCol()} flexShrink={0}>
                {/* Anywhere but this machine is warn-coloured, the same as the
                    chip that reports it afterwards: a target is what makes
                    `rm -rf build` two different acts. */}
                <text
                  fg={rowText(
                    style,
                    tone(),
                    one.spec === "local"
                      ? tone().selected
                        ? style.theme.fg
                        : style.theme.muted
                      : style.theme.warn,
                  )}
                >
                  {fit(one.spec, specCol() - 1)}
                </text>
              </box>
              <text fg={rowText(style, tone(), style.theme.dim)} flexShrink={0}>
                {fit(one.what, Math.max(0, room() - specCol() - dialog_gutter - 2))}
              </text>
              <text fg={style.theme.ok} flexShrink={0}>
                {inForce() ? ` ${style.glyphs.check}` : ""}
              </text>
            </box>
          )
        }}
      </For>

      {(() => {
        const click = onClick(() => props.onPick(null))
        const tone = () => ({ selected: props.selected === typeRow(), hovered: hover.at() === typeRow() })
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
              hover.row(typeRow()).onMouseOver()
              props.onSelect(typeRow())
            }}
            onMouseOut={hover.row(typeRow()).onMouseOut}
          >
            <text fg={rowGutter(style, tone()).fg} flexShrink={0}>
              {rowGutter(style, tone()).text}
            </text>
            <text
              fg={rowText(style, tone(), tone().selected ? style.theme.fg : style.theme.muted)}
              flexShrink={0}
            >
              {fit("somewhere else…", Math.max(0, room() - dialog_gutter))}
            </text>
          </box>
        )
      })()}

      {/* Said once, under the list, because it is the reason the last row
          exists: an ssh destination is whatever `ssh` itself would accept. */}
      <For
        each={wrapWords(
          "listed from wsl -l and your ssh config · anything else: /env remote:ssh:<destination>",
          room() - dialog_gutter,
        )}
      >
        {(line) => (
          <text fg={style.theme.dim} height={1}>
            {`${" ".repeat(dialog_gutter)}${line}`}
          </text>
        )}
      </For>

      <DialogHint text="↑↓ choose · Enter apply · Esc close" width={room()} />
    </box>
  )
}
