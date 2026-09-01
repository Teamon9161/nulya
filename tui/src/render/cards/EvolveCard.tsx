import { createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame, sizeNote } from "./CardFrame.tsx"
import { ShellOutput } from "./ShellCard.tsx"
import { splitShellOutput } from "../../nulya/ledger.ts"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * An evolution action: `nulya src | ext … | skill load` run through `shell`
 *. Same folded body as any shell call, but the evolve accent and
 * a head line the registry has already read the facts out of — these are the
 * moments nulya exists to make visible, so they must not look like `ls`.
 */
export function EvolveCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const shell = createMemo(() => splitShellOutput(props.item.output))

  const chip = () => {
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    const exit = shell().exit
    if (props.presentation.countsLines) {
      const size = sizeNote(props.item.output)
      if (exit === null || exit === 0) return size
      return size.length > 0 ? `${size} · exit ${exit}` : `exit ${exit}`
    }
    if (exit !== null && exit !== 0) return `exit ${exit}`
    // Success is silent: an evolution action that worked has its result
    // in the head line already (`ext build · lint → v-3f2a91`).
    return props.item.ok === false ? "failed" : ""
  }

  const tone = () => {
    const exit = shell().exit
    if (exit !== null && exit !== 0) return "err"
    if (props.item.ok === false) return "err"
    return "dim"
  }

  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={props.presentation.glyph}
      accent={style.theme.accent.evolve}
      head={props.presentation.head}
      chip={chip()}
      chipTone={tone()}
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      foldable={props.item.output.length > 0}
      spillPath={props.item.spillPath}
    >
      <ShellOutput output={props.item.output} />
    </CardFrame>
  )
}
