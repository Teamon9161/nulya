import { Show, createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { splitShellOutput } from "../../nulya/ledger.ts"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * A `shell` call: the command on the head line, the captured output folded
 * away by default (tui.md §4.2, D5). The chip carries the two facts worth
 * seeing without unfolding — how much came back, and how it exited.
 */
export function ShellCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const shell = createMemo(() => splitShellOutput(props.item.output))

  const chip = () => {
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    const lines = props.item.output.length === 0 ? 0 : props.item.output.split("\n").length
    const exit = shell().exit
    return exit === null ? `${lines} lines` : `${lines} lines · exit ${exit}`
  }

  const tone = () => {
    const exit = shell().exit
    if (exit === null) return props.item.ok === false ? "err" : "dim"
    return exit === 0 ? "ok" : "err"
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
