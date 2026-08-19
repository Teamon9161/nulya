import { Show, createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { taskReportOf } from "../../nulya/ledger.ts"
import type { TaskItem } from "../../state/session.ts"

/**
 * A `task_finished` event: the background command the model started has ended,
 * and this is the report it read (DESIGN §6.1, tui.md §5.9).
 *
 * The same glyph as the call that started it — it is still that command, and a
 * new symbol for "the same command, later" would be a symbol for a moment in
 * time rather than for a kind of thing (tui.md §6). What tells them apart is the
 * note, which is where the exit code and the wall clock are.
 *
 * Folded by default like every other captured output, with the log pointer on
 * its own last line: the report carries only the head and tail of what the
 * process wrote, and the file beside it has all of it.
 */
export function TaskFinishedCard(props: { item: TaskItem }) {
  const style = useStyle()
  const report = createMemo(() => taskReportOf(props.item.text))

  /** `background <task> · exit 1 · 41.8s` — `exit 0` stays silent (T26). */
  const chip = () => {
    const parsed = report()
    const how = props.item.exitCode === 0 ? "" : ` · exit ${props.item.exitCode}`
    const ended = parsed?.ended ? ` · ${parsed.ended}` : ""
    return `background ${props.item.task}${how}${ended}${parsed?.duration ? ` · ${parsed.duration}` : ""}`
  }

  // The command, as the report itself names it. A report this build cannot read
  // is shown whole in the body and says so on the head line rather than being
  // dropped: the ledger holds it either way.
  const head = () => report()?.command ?? props.item.task
  const body = () => report()?.tail ?? props.item.text

  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={style.glyphs.shell}
      accent={style.theme.accent.tool}
      head={head()}
      chip={chip()}
      chipTone={props.item.exitCode === 0 ? "dim" : "err"}
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      foldable={body().length > 0 || Boolean(report()?.log)}
    >
      <box flexDirection="column" width="100%">
        <Show when={body().length > 0} fallback={<text fg={style.theme.dim}>(no output)</text>}>
          <text fg={style.theme.fg}>{body()}</text>
        </Show>
        <Show when={report()?.log}>
          <text fg={style.theme.dim}>full log → {report()!.log}</text>
        </Show>
      </box>
    </CardFrame>
  )
}
