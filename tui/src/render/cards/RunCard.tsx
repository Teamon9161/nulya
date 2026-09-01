import { For } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { ToolCard } from "./ToolCard.tsx"
import { runSummary, runSummaryParts } from "../runs.ts"
import type { ToolItem } from "../../state/session.ts"
import type { Contributions } from "../../nulya/files.ts"

/**
 * A run of finished, successful, bodyless calls, as one line (`runs.ts`).
 *
 * Folded, it is `⋯ read ×3 · grep ×2 · shell ▸` — what the model went and
 * looked at, in one row, under the sentence that said it would. Opened, it is
 * exactly the cards that were there before, each still folding on its own:
 * nothing is summarised away, and one keypress gets all of it back.
 *
 * The glyph is the ellipsis, dim like every other row's chrome.
 * It used to be the assistant dot in the tool accent, which put the SAME
 * glyph on two kinds of row that sit next to each other constantly — what the
 * model said, and the calls it made under it — with nothing but two columns
 * of indent between them once a terminal has no colour. `⋯` says the one
 * thing both this card and the thinking card say: a stretch you are being
 * given one line of.
 *
 * THE HEAD LINE IS TWO TONES, not one. It used to be `headTone="dim"` end to
 * end, which put `read` at the same weight as the `×3` counting it and the
 * `·` joining it to the next tool — a plain `ToolCard`'s own head line reads
 * a call's NAME at full (muted) weight, and a folded run is a row of exactly
 * those names, worth exactly as much attention stacked as apart. So
 * `runSummaryParts` (`runs.ts`) marks only the counting and the joints dim;
 * `CardFrame`'s `headParts` colours the rest the way any other card's head is
 * coloured.
 *
 * NO NOTE. Every other card's note says how much came back or what went wrong,
 * and a run is by construction the calls that worked and brought back
 * nothing worth showing — a `(6 calls)` beside `read ×3 · grep ×2 · shell`
 * would be the same sentence twice. Success is silent here too.
 */
export function RunCard(props: { items: ToolItem[]; itemKey: string; contributions?: Contributions[]; highlightedCallId?: string | null }) {
  const style = useStyle()
  return (
    <CardFrame
      itemKey={props.itemKey}
      glyph={style.glyphs.thinking}
      accent={style.theme.dim}
      head={runSummary(props.items)}
      headParts={runSummaryParts(props.items)}
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      foldable
    >
      <For each={props.items}>{(item) => <ToolCard item={item} contributions={props.contributions} highlighted={item.callId === props.highlightedCallId} />}</For>
    </CardFrame>
  )
}
