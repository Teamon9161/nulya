/**
 * The background count on the activity line, opened out (tui.md §11, T87).
 *
 * A composer-area panel like `ApprovalPanel` and a package's own `PluginPanel`
 * — NOT `/tasks`'s full-screen overlay (`overlays/TasksView.tsx`) — because
 * the question this answers is "is anything still running, and should I stop
 * it", asked while looking at the transcript that started it. `/tasks` is
 * still where a task's log is read and where `k`/`K` work from the keyboard;
 * this is the glance, and the hint says where the rest of it lives.
 *
 * Passive in the one sense that matters: it never takes the keyboard, and
 * `App` does not draw it while a trusted zone is up, the same terms a
 * package's panel lives under (tui-plugin D4) — nothing here may come between
 * a person and an approval question. Not passive in the other sense a
 * `ContextPanel` is: every running row has a stop button, a mouse-only
 * gesture the way every clickable row in this front end is (`ui/rows.ts`).
 *
 * `onStop` is `state/tasks.stopTask` bound to the front tab's `ws` and
 * `attach.send` by the caller — the same function `/tasks` calls, so there is
 * exactly one place that pairs "kill it" with "say who asked".
 */
import { Index, Show, createSignal } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { DialogHint, DialogTitle, dialog_gutter } from "./Dialog.tsx"
import { columnWidth, fit } from "./columns.ts"
import { lifted, onClick } from "./rows.ts"
import { seconds } from "../state/tasks.ts"
import { taskIsDone, type TaskEntry } from "../nulya/cli.ts"

/** How long it has been going, or how long it took — `/tasks`'s own words. */
function elapsed(task: TaskEntry): string {
  if (task.duration_ms !== null) return `${(task.duration_ms / 1000).toFixed(1)}s`
  if (task.elapsed_s !== null) return seconds(task.elapsed_s)
  return "—"
}

/** The word for a row that is not running any more. */
function endedWord(task: TaskEntry): string {
  if (task.state === "lost") return "lost"
  if (task.state === "unreachable") return "unreachable"
  if (task.exit_code !== null && task.exit_code !== 0) return `exit ${task.exit_code}`
  return "done"
}

export function TasksPanel(props: {
  tasks: TaskEntry[]
  /** A row's stop button — the same `state/tasks.stopTask` `/tasks` uses. */
  onStop: (task: string) => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const width = () => Math.min(screen().width, style.maxWidth)
  const room = () => Math.max(24, width() - 6)
  /** The name column, from the names themselves — no number to outgrow. */
  const nameCol = () => columnWidth(props.tasks.map((task) => task.task))
  const [stopOver, setStopOver] = createSignal<string | null>(null)

  return (
    <box flexDirection="column" width="100%" maxWidth={style.maxWidth} paddingLeft={1} paddingRight={1} flexShrink={0}>
      <DialogTitle name="background tasks" caption={`${props.tasks.length}`} />
      <Show
        when={props.tasks.length > 0}
        fallback={
          <text fg={style.theme.muted} height={1}>
            {`${" ".repeat(dialog_gutter)}nothing running · the model starts one with shell {background: true}`}
          </text>
        }
      >
        <Index each={props.tasks}>
          {(item) => {
            const task = () => item()
            const running = () => !taskIsDone(task())
            const hovered = () => stopOver() === task().task
            const state = () => (running() ? `running ${elapsed(task())}` : endedWord(task()))
            const noteRoom = () => Math.max(0, room() - dialog_gutter - nameCol() - 2 - 12)
            const stop = onClick(() => props.onStop(task().task))
            return (
              <box flexDirection="row" width="100%" height={1}>
                <box width={dialog_gutter + nameCol()} flexShrink={0}>
                  <text fg={style.theme.dim}>{`${" ".repeat(dialog_gutter)}${fit(task().task, nameCol())}`}</text>
                </box>
                <text fg={running() ? style.theme.accent.assistant : style.theme.muted} flexShrink={0}>
                  {"  "}
                  {fit(state(), 14)}
                </text>
                <text fg={style.theme.dim} flexShrink={1}>
                  {"  "}
                  {fit(task().command, noteRoom())}
                </text>
                {/* The stop button: only a running task has one — a finished
                    task's row is a fact, not a control (`taskIsDone`). Click
                    only, the same terms `WorkingStatus`'s background chip
                    answers to (`ui/rows.ts`). */}
                <Show when={running()}>
                  <box
                    flexShrink={0}
                    height={1}
                    onMouseDown={stop.onMouseDown}
                    onMouseUp={stop.onMouseUp}
                    onMouseOver={() => setStopOver(task().task)}
                    onMouseOut={() => setStopOver((now) => (now === task().task ? null : now))}
                  >
                    <text fg={lifted(style, hovered(), style.theme.err)}>{"  stop"}</text>
                  </box>
                </Show>
              </box>
            )
          }}
        </Index>
      </Show>
      <DialogHint text="click stop to end a task · /tasks for the log, and k/K from the keyboard" width={room()} />
    </box>
  )
}
