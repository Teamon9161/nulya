/**
 * The first screen of an empty session (tui.md §4.1).
 *
 * A session with no events has nothing to show, and a blank rectangle above a
 * blank composer is the moment a person decides a tool is unfinished. So the
 * space says the three things that are true and useful right then: what nulya
 * is, what this particular session is frozen onto, and the handful of keys that
 * lead everywhere else. It disappears the instant the first turn lands — it is
 * a starting point, not a panel.
 *
 * It is not a card: nothing here came from the ledger, and giving it a card
 * frame would put something in the transcript that no event backs.
 */
import { Show } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"

/** The `/` commands worth knowing before you have typed anything. */
const openings: Array<[string, string]> = [
  ["/model", "pick a provider and model · add a compatible one"],
  ["/sessions", "everything in .nulya/sessions, and open one"],
  ["/ext", "extensions: versions, what is active, what it is used for"],
  ["/help", "every key and every command"],
]

export function Welcome() {
  const style = useStyle()
  const screen = useScreen()
  const wide = () => screen().width >= 60

  return (
    <box flexDirection="column" width="100%" paddingLeft={2} paddingTop={1}>
      <Show
        when={wide() && !style.settings.transcript.ascii}
        fallback={<text fg={style.theme.accent.user}>nulya</text>}
      >
        <ascii_font text="nulya" font="tiny" color={style.theme.accent.user} />
      </Show>
      <box height={1} />
      <text fg={style.theme.dim}>an immutable kernel with two tools, and everything else it builds for itself</text>
      <box height={1} />

      {/* What this session is frozen onto is already the card above; saying it
          twice on the same screen is noise, so this half is only the way out. */}
      {openings.map(([command, what]) => (
        <box flexDirection="row" width="100%">
          <box width={12} flexShrink={0}>
            <text fg={style.theme.accent.evolve}>{command}</text>
          </box>
          <text fg={style.theme.dim}>{what}</text>
        </box>
      ))}
      <box height={1} />
      <text fg={style.theme.dim}>
        {style.glyphs.user} type below and press Enter · Esc to stop a step, or to read back through the cards
      </text>
    </box>
  )
}
