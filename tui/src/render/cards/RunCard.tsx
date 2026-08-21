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
 * Folded, it is `⋯ read ×3 · grep ×2 · shell ▸` — what the model went and
 * looked at, in one row, under the sentence that said it would. Opened, it is
 * exactly the cards that were there before, each still folding on its own:
 * nothing is summarised away, and one keypress gets all of it back.
 *
 * The glyph is `thinking`'s — three dots — because that is what this is: the
 * part of the work that is context for the answer rather than the answer. It is
 * dim throughout for the same reason.
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
