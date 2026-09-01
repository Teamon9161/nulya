import { For, Show, createMemo } from "solid-js"
import { useBodyWidth, useStyle } from "../theme.ts"
import { CardFrame, sizeNote } from "./CardFrame.tsx"
import { backgroundStartOf, splitShellOutput } from "../../nulya/ledger.ts"
import { backgroundNote, taskNamed, useTasks } from "../../state/tasks.ts"
import { hardWrapLines } from "../../ui/columns.ts"
import { shellCommandOf, type ToolPresentation } from "../registry.ts"
import type { ToolItem } from "../../state/session.ts"

/**
 * A `shell` call: the command on the head line, the captured output folded
 * away by default (tui.md §4.2, D5). The note carries the two facts worth
 * seeing without unfolding — how much came back, and how it exited.
 *
 * `exit 0` is not one of them (T26). A call that worked says only how much it
 * brought back; silence is what success looks like, and it leaves the colour
 * and the words for the call that failed.
 *
 * `background: true` is the same card with a different note (tui.md §5.9): the
 * call returned a receipt, not a result, so what is worth seeing is which task
 * it is and whether it is still going. No new glyph — it is still a command run
 * in a shell, and the note says the one thing that differs.
 */
export function ShellCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const command = createMemo(() => shellCommandOf(props.item.args) ?? props.presentation.head)
  const shell = createMemo(() => splitShellOutput(props.item.output))
  const started = createMemo(() => backgroundStartOf(props.item.output))
  const tasks = useTasks()

  /** `background <task> · running 42s` — the shared reading (`state/tasks.ts`). */
  const backgroundChip = (task: string) => `background ${backgroundNote(task, props.item.taskResult, tasks()).text}`

  const chip = () => {
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    const task = started()?.task
    if (task) return backgroundChip(task)
    const size = sizeNote(props.item.output)
    const exit = shell().exit
    if (exit === null || exit === 0) return size
    return size.length > 0 ? `${size} · exit ${exit}` : `exit ${exit}`
  }

  const tone = () => {
    const task = started()?.task
    if (task) {
      const code = props.item.taskResult?.exitCode ?? taskNamed(tasks(), task)?.exit_code ?? null
      return code !== null && code !== 0 ? "err" : "dim"
    }
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
      // The command is body content too, so an in-flight call with no output is
      // still openable and a cut or multi-line head is never the only copy.
      foldable={command().length > 0 || props.item.output.length > 0}
      spillPath={props.item.spillPath}
    >
      <ShellCommand command={command()} />
      <ShellOutput output={props.item.output} />
    </CardFrame>
  )
}

/**
 * The complete invocation, hard-wrapped so expanding never loses its tail —
 * at THIS PANE's width (`useBodyWidth`, BUGS.md #10/#17), because each wrapped
 * line is its own `height={1}` row and a row laid out wider than the column it
 * lands in loses its tail instead of reflowing.
 */
function ShellCommand(props: { command: string }) {
  const style = useStyle()
  const body = useBodyWidth()
  // CardFrame and its open body consume six columns before this text starts.
  const room = () => Math.max(8, Math.min(body(), style.maxWidth) - 6)
  const lines = createMemo(() => hardWrapLines(props.command, room()))
  return (
    <box flexDirection="column" width="100%">
      <For each={lines()}>
        {(line, index) => (
          <box flexDirection="row" width="100%" height={1} flexShrink={0}>
            <text fg={style.theme.accent.tool} flexShrink={0}>{index() === 0 ? "$ " : "  "}</text>
            <text fg={style.theme.muted} flexShrink={0}>{line}</text>
          </box>
        )}
      </For>
    </box>
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
