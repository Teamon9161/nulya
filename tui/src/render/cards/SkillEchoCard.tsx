import { CardFrame } from "./CardFrame.tsx"
import { useStyle } from "../theme.ts"
import { echoSummary } from "../../skills.ts"
import type { SkillEcho } from "../../skills.ts"
import type { UserItem } from "../../state/session.ts"

/**
 * A `/name` that loaded a skill (`skills.ts`).
 *
 * Like compaction's two turns, this is an ordinary `user_text` event — the
 * kernel has no skill-turn concept and is not getting one — so the card is a
 * reading of content. It is folded by default because what the person did was
 * type `/name args`; the two hundred lines the kernel then handed the model are
 * true, permanent and available one keypress away, but they are not the thing
 * that happened.
 *
 * The sentinel is parsed from the ledger text alone, so a live turn and the
 * same turn replayed tomorrow fold identically.
 */
export function SkillEchoCard(props: { item: UserItem; echo: SkillEcho }) {
  const style = useStyle()
  const body = () => {
    // The body between the markers, for the open state. Re-derived rather than
    // carried on the item: the parse has one home, and this card is the only
    // place that wants the text.
    const text = props.item.text
    const close = text.indexOf(">")
    const end = text.lastIndexOf("</user-skill>")
    return close < 0 || end < 0 ? text : text.slice(close + 1, end).trim()
  }
  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={style.glyphs.user}
      accent={style.theme.accent.user}
      head={echoSummary(props.echo)}
      chip={props.item.queued ? "queued" : "skill"}
      chipTone="dim"
      defaultOpen={false}
      foldable={body().length > 0}
    >
      <text fg={style.theme.dim}>{body()}</text>
    </CardFrame>
  )
}
