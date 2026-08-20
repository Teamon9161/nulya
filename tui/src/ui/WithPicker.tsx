import { For, Show } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { createHover, onClick, rowBackground, rowGutter } from "./rows.ts"
import { fit, wrapWords } from "./columns.ts"

/** One package this machine has REGISTERED and a session may therefore name. */
export interface Wearable {
  id: string
  /** The version `current` points at — what `--with <id>` resolves to. */
  version: string
  /** How many system prompt files it contributes; > 0 is why it is listed. */
  prompts: number
  skills: number
  tools: number
}

/**
 * Bare `/with`: which packages this machine has registered for a session to
 * wear (tui.md §11, T37).
 *
 * The list is DERIVED, and that is the whole point of the command. A package
 * whose manifest says `activation: "on_request"` (DESIGN §7.2.1) is registered
 * by activating it and by nothing else, so this dialog can only offer what
 * somebody switched on — turn a mode off in `/ext` and its row here is gone.
 * The front end knows no ids of its own.
 *
 * Same dialog above the composer as `/mode` and `/agent`, for the same reasons
 * (T28/T31): it is a CHOICE — hence the `◈` — and short enough that a full
 * screen would be a screen mostly empty. Unlike `/agent`, taking a row acts:
 * wearing a package needs no argument nobody can guess, so the honest thing is
 * to open the tab.
 */
export function WithPicker(props: {
  wearables: readonly Wearable[]
  selected: number
  onSelect: (index: number) => void
  onPick: (wearable: Wearable) => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const hover = createHover()
  const width = () => Math.min(screen().width, style.maxWidth)
  const room = () => Math.max(24, width() - 6)
  const idCol = () =>
    Math.min(24, props.wearables.reduce((widest, one) => Math.max(widest, one.id.length), 0) + 2)

  return (
    <box flexDirection="column" width="100%" maxWidth={style.maxWidth} paddingLeft={1} paddingRight={1} flexShrink={0}>
      <box flexDirection="row" width="100%" height={1}>
        <text fg={style.theme.accent.evolve} flexShrink={0}>
          {style.glyphs.picker} wear
        </text>
        <text fg={style.theme.dim} flexShrink={0}>
          {" · a new tab carrying this package; nothing is activated"}
        </text>
      </box>

      <Show when={props.wearables.length === 0}>
        <For
          each={wrapWords(
            "nothing registered to wear · a package with a system prompt and activation: on_request appears here once you switch it on in /ext · or name a build directly with /with <id>@<version>",
            room(),
          )}
        >
          {(line) => (
            <text fg={style.theme.dim} height={1}>
              {`  ${line}`}
            </text>
          )}
        </For>
      </Show>

      <For each={props.wearables}>
        {(one, index) => {
          const click = onClick(() => props.onPick(one))
          const tone = () => ({ selected: props.selected === index(), hovered: hover.at() === index() })
          /** What arrives with it — the prompt first, since that is why it is a mode. */
          const what = () => {
            const parts = [`${one.prompts} prompt${one.prompts === 1 ? "" : "s"}`]
            if (one.skills > 0) parts.push(`${one.skills} skill${one.skills === 1 ? "" : "s"}`)
            if (one.tools > 0) parts.push(`${one.tools} tool${one.tools === 1 ? "" : "s"}`)
            parts.push(one.version)
            return parts.join(" · ")
          }
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
                {`  ${rowGutter(style, tone()).text}`}
              </text>
              <box width={idCol()} flexShrink={0}>
                <text fg={tone().selected ? style.theme.fg : style.theme.muted}>{fit(one.id, idCol() - 1)}</text>
              </box>
              <text fg={style.theme.dim} flexShrink={0}>
                {fit(what(), Math.max(0, room() - idCol() - 4))}
              </text>
            </box>
          )
        }}
      </For>

      <For each={wrapWords("↑↓ choose · Enter opens a tab wearing it · Esc close", room())}>
        {(line) => (
          <text fg={style.theme.dim} height={1}>
            {`  ${line}`}
          </text>
        )}
      </For>
    </box>
  )
}
