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
 * The glyph is the assistant dot in the tool accent: this is work performed for
 * the answer, not hidden thinking. It should read like a compact activity line,
 * not like an ellipsis whose subject must be decoded.
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
      glyph={style.glyphs.assistant}
      accent={style.theme.accent.tool}
      head={runSummary(props.items)}
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      foldable
    >
      <For each={props.items}>{(item) => <ToolCard item={item} contributions={props.contributions} />}</For>
    </CardFrame>
  )
}
