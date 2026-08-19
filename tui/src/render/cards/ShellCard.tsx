import { Show, createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame, sizeNote } from "./CardFrame.tsx"
import { splitShellOutput } from "../../nulya/ledger.ts"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * A `shell` call: the command on the head line, the captured output folded
 * away by default (tui.md §4.2, D5). The note carries the two facts worth
 * seeing without unfolding — how much came back, and how it exited.
 *
 * `exit 0` is not one of them (T26). A call that worked says only how much it
 * brought back; silence is what success looks like, and it leaves the colour
 * and the words for the call that failed.
 */
export function ShellCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const shell = createMemo(() => splitShellOutput(props.item.output))

  const chip = () => {
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    const size = sizeNote(props.item.output)
    const exit = shell().exit
    if (exit === null || exit === 0) return size
    return size.length > 0 ? `${size} · exit ${exit}` : `exit ${exit}`
  }

  const tone = () => {
    const exit = shell().exit
    if (exit !== null && exit !== 0) return "err"
    return props.item.ok === false ? "err" : "dim"
  }

  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={props.presentation.glyph}
      accent={style.theme.accent.tool}
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

/**
 * `stdout` + `--- stderr ---` + `[exit N]` is the shape `tools/shell.zig`
 * writes (tui.md §2.1). Splitting it lets stderr take the error colour without
 * washing the whole card (tui.md §6).
 */
export function ShellOutput(props: { output: string }) {
  const style = useStyle()
  const shell = createMemo(() => splitShellOutput(props.output))
  return (
    <box flexDirection="column" width="100%">
      <Show when={shell().stdout.length > 0}>
        <text fg={style.theme.fg}>{shell().stdout}</text>
      </Show>
      <Show when={shell().stderr.length > 0}>
        <text fg={style.theme.err}>{shell().stderr}</text>
      </Show>
    </box>
  )
}
