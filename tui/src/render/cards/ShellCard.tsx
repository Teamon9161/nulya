import { Show, createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame, sizeNote } from "./CardFrame.tsx"
import { backgroundStartOf, splitShellOutput } from "../../nulya/ledger.ts"
import { seconds, taskNamed, useTasks } from "../../state/tasks.ts"
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
 *
 * `background: true` is the same card with a different note (tui.md §5.9): the
 * call returned a receipt, not a result, so what is worth seeing is which task
 * it is and whether it is still going. No new glyph — it is still a command run
 * in a shell, and the note says the one thing that differs.
 */
export function ShellCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const shell = createMemo(() => splitShellOutput(props.item.output))
  const started = createMemo(() => backgroundStartOf(props.item.output))
  const tasks = useTasks()

  /**
   * The note of a background call, from the two sources in the right order: the
   * ledger's report if it has landed (a fact, and one that survives a reopen),
   * otherwise the live projection for the seconds ticking. Neither is invented —
   * with no report and no live row all that can honestly be said is the name.
   */
  const backgroundChip = (task: string) => {
    const done = props.item.taskResult
    if (done) {
      const how = done.exitCode === 0 ? "" : ` · exit ${done.exitCode}`
      return `background ${task}${how}${done.duration ? ` · ${done.duration}` : ""}`
    }
    const live = taskNamed(tasks(), task)
    if (!live) return `background ${task}`
    if (live.state === "done") {
      const how = live.exit_code !== null && live.exit_code !== 0 ? ` · exit ${live.exit_code}` : ""
      return `background ${task}${how}`
    }
    if (live.state === "lost") return `background ${task} · lost`
    return `background ${task} · running${live.elapsed_s !== null ? ` ${seconds(live.elapsed_s)}` : ""}`
  }

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
