import { useStyle } from "../theme.ts"
import type { AssistantItem } from "../../state/session.ts"

/**
 * An assistant turn: role colour on the glyph only, markdown body in plain `fg`
 * (tui.md §6).
 *
 * NO TRAILING CURSOR (T43). A ` ▍` used to be appended to the content while the
 * turn streamed, and because it was appended to the CONTENT it was markdown:
 * every delta re-parsed a document one glyph longer, and at every block
 * boundary that glyph changed the answer. Text ending in a newline put the
 * cursor on a row of its own (+1 row), the next delta took it back (−1), an
 * opening fence swallowed it entirely — a measured 7 → 6 → 7 row bounce inside
 * three deltas, and every bounce moves a sticky-bottom scrollbox, which is the
 * whole screen. Without it the block count only ever grows.
 *
 * Nothing is lost: since T38 "something is happening" is a line of its own
 * above the composer, with the spinner and the sweep on it. The transcript is
 * the record; the motion belongs to the status line.
 */
export function AssistantTurn(props: { item: AssistantItem }) {
  const style = useStyle()
  return (
    <box flexDirection="row" width="100%">
      <text fg={style.theme.accent.assistant}>{style.glyphs.assistant} </text>
      <box flexDirection="column" flexGrow={1}>
        <markdown
          content={props.item.text}
          syntaxStyle={style.syntax}
          fg={style.theme.fg}
          streaming={props.item.streaming}
          width="100%"
        />
      </box>
    </box>
  )
}
