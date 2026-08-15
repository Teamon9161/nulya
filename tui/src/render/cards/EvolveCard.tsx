import { createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { ShellOutput } from "./ShellCard.tsx"
import { splitShellOutput } from "../../nulya/ledger.ts"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * An evolution action: `nulya src | ext … | skill load` run through `shell`
 * (tui.md §5.2). Same folded body as any shell call, but the evolve accent and
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
      const lines = props.item.output.length === 0 ? 0 : props.item.output.split("\n").length
      return exit === null || exit === 0 ? `${lines} lines` : `${lines} lines · exit ${exit}`
    }
    if (exit !== null && exit !== 0) return `exit ${exit}`
    if (props.item.ok === null) return ""
    return props.item.ok ? "ok" : "failed"
  }

  const tone = () => {
    const exit = shell().exit
    if (exit !== null && exit !== 0) return "err"
    if (props.item.ok === false) return "err"
    if (props.item.ok === true) return "ok"
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
