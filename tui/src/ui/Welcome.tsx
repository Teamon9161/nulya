/**
 * The first screen of an empty session (tui.md §4.1).
 *
 * A session with no events has nothing to show, and a blank rectangle above a
 * blank composer is the moment a person decides a tool is unfinished. So the
 * space says the three things that are true and useful right then: what nulya
 * is, where it is working, and the handful of keys that lead everywhere else.
 * It disappears the instant the first turn lands — it is a starting point, not
 * a panel.
 *
 * It is not a card: nothing here came from the ledger, and giving it a card
 * frame would put something in the transcript that no event backs.
 *
 * The `/` lines are buttons as much as they are captions: a click runs
 * the command exactly as typing it would (`onCommand`), and the row takes the
 * same tint under the pointer as every other clickable row (`ui/rows.ts`).
 * Without the callback — a card rendered on its own — they are plain text and
 * do not light up.
 */
import { For, Show, createSignal } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { onClick } from "./rows.ts"
import { fit, wrapWords } from "./columns.ts"

/** The `/` commands worth knowing before you have typed anything. */
const openings: Array<[string, string]> = [
  ["/model", "pick what the next session runs on"],
  ["/provider", "endpoints and their keys · add a compatible one"],
  ["/sessions", "everything in .nulya/sessions, and open one"],
  ["/ext", "extensions: versions, what is active, what it is used for"],
  ["/help", "every key and every command"],
]

export function Welcome(props: {
  /** The workspace whose `.nulya/` this session writes to. */
  cwd?: string
  /** A command row was clicked: run it as if it had been typed and sent. */
  onCommand?: (command: string) => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const wide = () => screen().width >= 60
  const [hovered, setHovered] = createSignal(-1)

  return (
    <box flexDirection="column" width="100%" paddingLeft={2} paddingTop={1}>
      <Show
        when={wide() && !style.settings.transcript.ascii}
        fallback={<text fg={style.theme.accent.user}>nulya</text>}
      >
        <ascii_font text="nulya" font="tiny" color={style.theme.accent.user} />
      </Show>
      <box height={1} />
      {/* The one sentence that says what this is: a level above the key list
          under it, which is a caption on the way out. */}
      <text fg={style.theme.muted}>an immutable kernel with two tools, and everything else it builds for itself</text>
      <box height={1} />

      {/* Where. The model and the tools are the composition card above this —
          saying them twice on one screen is noise — but the card does not say
          which workspace, and that is the one fact that tells two terminals
          apart. */}
      <Show when={props.cwd}>
        <box flexDirection="row" width="100%">
          <box width={12} flexShrink={0}>
            <text fg={style.theme.dim}>cwd</text>
          </box>
          <text fg={style.theme.muted}>{props.cwd}</text>
        </box>
        <box height={1} />
      </Show>

      <For each={openings}>
        {([command, what], index) => {
          const click = onClick(() => props.onCommand?.(command))
          const live = () => props.onCommand !== undefined
          return (
            <box
              flexDirection="row"
              width="100%"
              height={1}
              backgroundColor={live() && hovered() === index() ? style.theme.hover : undefined}
              onMouseDown={live() ? click.onMouseDown : undefined}
              onMouseUp={live() ? click.onMouseUp : undefined}
              onMouseOver={() => setHovered(index())}
              onMouseOut={() => setHovered((now) => (now === index() ? -1 : now))}
            >
              <box width={12} flexShrink={0}>
                <text fg={style.theme.accent.evolve}>{command}</text>
              </box>
              {/* Cut, never wrapped: a one-row box clips a second line, and a
                  caption that wraps re-lays itself under the pointer (`ui/columns.ts`). */}
              <text fg={style.theme.dim}>{fit(what, Math.max(8, screen().width - 2 - 12 - 1))}</text>
            </box>
          )
        }}
      </For>
      <box height={1} />
      {/* Broken at its joints by us, so a narrow terminal gets two whole
          phrases rather than a line that folds mid-word. */}
      <For
        each={wrapWords(
          `${style.glyphs.user} type below and press Enter · Esc to stop a step, or to read back through the cards`,
          Math.max(20, screen().width - 3),
        )}
      >
        {(line) => (
          <text fg={style.theme.dim} height={1}>
            {line}
          </text>
        )}
      </For>
    </box>
  )
}
