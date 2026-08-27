import { For } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { ToolCard } from "./ToolCard.tsx"
import { runSummary } from "../runs.ts"
import type { ToolItem } from "../../state/session.ts"
import type { Contributions } from "../../nulya/files.ts"

/**
 * A run of finished, successful, bodyless calls, as one line (T43, `runs.ts`).
 *
 * Folded, it is `● Read 3 files · Search 2 patterns ▸` — what the model went
 * and looked at, in one row, under the sentence that said it would. Opened, it
 * is exactly the cards that were there before, each still folding on its own:
 * nothing is summarised away, and one keypress gets all of it back.
 *
 * The glyph is the ellipsis, all of it dim (tui.md §4.2). It used to be the
 * assistant dot in the tool accent, which put the SAME glyph on two kinds of
 * row that sit next to each other constantly — what the model said, and the
 * calls it made under it — with nothing but two columns of indent between them
 * once a terminal has no colour. `⋯` says the one thing both this card and the
 * thinking card say: a stretch you are being given one line of.
 *
 * NO NOTE. Every other card's note says how much came back or what went wrong
 * (T26), and a run is by construction the calls that worked and brought back
 * nothing worth showing — a `(6 calls)` beside `read ×3 · grep ×2 · shell`
 * would be the same sentence twice. Success is silent here too.
 */
export function RunCard(props: { items: ToolItem[]; itemKey: string; contributions?: Contributions[] }) {
  const style = useStyle()
  return (
    <CardFrame
      itemKey={props.itemKey}
      glyph={style.glyphs.thinking}
      accent={style.theme.dim}
      head={runSummary(props.items)}
      headTone="dim"
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      foldable
    >
      <For each={props.items}>{(item) => <ToolCard item={item} contributions={props.contributions} />}</For>
    </CardFrame>
  )
}
