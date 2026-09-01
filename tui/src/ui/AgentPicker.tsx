import { For, Show } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { createHover, onClick, rowBackground, rowGutter, rowText } from "./rows.ts"
import { fit, wrapWords } from "./columns.ts"
import { DialogHint, DialogTitle, dialog_gutter } from "./Dialog.tsx"
import type { AgentEntry } from "../agents.ts"

/**
 * Bare `/agent`: which personas this workspace and this machine define.
 *
 * The same dialog above the composer that `/mode` is, and for the same
 * reasons: it is a CHOICE — hence the `◈` in the title, which belongs to choices
 * and never to a panel that lists a store or a journal — and it is short enough
 * that a full screen would be a screen mostly empty. `↑↓` / digits / hover move
 * the cursor, `Enter` and a click take the row, `Esc` closes: `ui/rows.ts`, like
 * every other list in this front end.
 *
 * Taking a row does NOT start anything. A delegation needs a task, and nobody
 * can guess it — so the row puts `/agent <name> ` in the composer and leaves the
 * cursor after it, which is the honest half-step.
 */
export function AgentPicker(props: {
  defs: readonly AgentEntry[]
  selected: number
  onSelect: (index: number) => void
  onPick: (def: AgentEntry) => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const hover = createHover()
  const width = () => Math.min(screen().width, style.maxWidth)
  const room = () => Math.max(24, width() - 6)
  const nameCol = () =>
    Math.min(24, props.defs.reduce((widest, def) => Math.max(widest, def.name.length), 0) + 2)

  return (
    <box flexDirection="column" width="100%" maxWidth={style.maxWidth} paddingLeft={1} paddingRight={1} flexShrink={0}>
      <DialogTitle
        glyph={style.glyphs.picker}
        name="agents"
        caption="each one is a session of its own; only its report comes back"
      />

      <Show when={props.defs.length === 0}>
        <For
          each={wrapWords(
            `no agent definitions · write one as a markdown file in .nulya/agents/ or ~/.nulya/agents/ — front matter (name, description, readonly, model, pins, max_steps) and a body that is its system prompt`,
            room() - dialog_gutter,
          )}
        >
          {(line) => (
            <text fg={style.theme.dim} height={1}>
              {`${" ".repeat(dialog_gutter)}${line}`}
            </text>
          )}
        </For>
      </Show>

      <For each={props.defs}>
        {(def, index) => {
          const click = onClick(() => props.onPick(def))
          const tone = () => ({ selected: props.selected === index(), hovered: hover.at() === index() })
          /** What this row is, after its name: the facts that change what it can do. */
          const what = () => {
            const parts: string[] = []
            if (def.description.length > 0) parts.push(def.description)
            if (def.readonly) parts.push("read-only")
            if (def.model.length > 0) parts.push(def.model)
            else if (def.profile.length > 0) parts.push(def.profile)
            // Where it came from, said only when it is not this checkout's:
            // `builtin` is the answer to "I never wrote this, why is it here".
            if (def.agents.length > 0) parts.push("delegates")
            if (def.layer !== "workspace") parts.push(def.layer === "user" ? "this machine" : "builtin")
            // The ordinary case (`nulya`) says nothing — every row would carry
            // it otherwise; a non-`nulya` runner is said out loud because it is
            // the one fact that changes what delegating here even means (no
            // local session, no tab, ar-t2).
            if (def.runner !== "nulya") parts.push(`runner: ${def.runner}`)
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
                {rowGutter(style, tone()).text}
              </text>
              <box width={nameCol()} flexShrink={0}>
                <text fg={rowText(style, tone(), tone().selected ? style.theme.fg : style.theme.muted)}>
                  {fit(def.name, nameCol() - 1)}
                </text>
              </box>
              <text fg={rowText(style, tone(), style.theme.dim)} flexShrink={0}>
                {fit(what(), Math.max(0, room() - nameCol() - dialog_gutter))}
              </text>
            </box>
          )
        }}
      </For>

      <DialogHint text="↑↓ choose · Enter writes /agent <name> · then type the task · Esc close" width={room()} />
    </box>
  )
}
