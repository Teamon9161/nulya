/**
 * `/tasks` (F7): the background commands this session started (tui.md §5.9).
 *
 * Every row is `nulya task list --session <id> --json` — state, exit code and
 * elapsed time come from the kernel's own projection, because `starting` and
 * `lost` are answers that need the task directory and its lease read together
 * (DESIGN §6.1) and a second implementation of them here would eventually
 * disagree with the one that counts. This panel decides two things only: which
 * row the cursor is on, and whether the log is showing.
 *
 * `Enter` shows the tail of a task's log, re-read on the same poll as the rows.
 * Not a live tail: a real one would mean a process per open panel, and what a
 * person wants here is "what is it doing right now", which a re-read answers.
 *
 * `k` kills without asking. The undo for a killed task is running the command
 * again; the undo for a task nobody could stop is nothing.
 */
import { Index, Show, createEffect, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { ScrollBoxRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { displayWidth, fit } from "../columns.ts"
import { createHover, onClick, rowBackground, rowGutter } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { seconds } from "../../state/tasks.ts"
import { taskIsDone, taskKill, type TaskEntry } from "../../nulya/cli.ts"
import { readTaskLog } from "../../nulya/files.ts"
import type { Workspace } from "../../nulya/bin.ts"

/** How long it has been going, or how long it took. */
export function elapsed(task: TaskEntry): string {
  if (task.duration_ms !== null) return `${(task.duration_ms / 1000).toFixed(1)}s`
  if (task.elapsed_s !== null) return seconds(task.elapsed_s)
  return "—"
}

/** How it ended, in the fewest words that are still true. */
export function outcome(task: TaskEntry): string {
  if (!taskIsDone(task)) return ""
  if (task.state === "lost") return "no supervisor"
  const how = task.ended_by === "kill" ? "killed" : task.ended_by === "timeout" ? "timed out" : ""
  const code = task.exit_code !== null && task.exit_code !== 0 ? `exit ${task.exit_code}` : ""
  return [code, how].filter((part) => part.length > 0).join(" · ")
}

export function TasksView(props: {
  ws: Workspace
  /** The session in front; a draft tab has none and the panel says so. */
  sessionId: string
  tasks: TaskEntry[]
  /** Read the list again — the panel's own `r`, and after a kill. */
  onRefresh: () => void
  onClose: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [cursor, setCursor] = createSignal(0)
  const [showLog, setShowLog] = createSignal(false)
  const [log, setLog] = createSignal("")
  const [notice, setNotice] = createSignal<string | null>(null)
  let list: ScrollBoxRenderable | null = null
  const hover = createHover()
  const help = createKeyHelp()

  const rows = () => props.tasks
  const current = () => rows()[cursor()] ?? null
  const rowId = (task: string) => `task-row:${task}`

  const readLog = async () => {
    const task = current()
    if (!task || !showLog()) return
    setLog(await readTaskLog(props.ws, task.log))
  }

  onMount(() => {
    props.onRefresh()
    // The rows arrive on the tab's own watch; the log is this panel's, so it
    // gets the beat. Both are re-reads of files, not processes.
    const timer = setInterval(() => {
      props.onRefresh()
      void readLog()
    }, 1500)
    onCleanup(() => clearInterval(timer))
  })

  createEffect(() => {
    const count = rows().length
    if (cursor() >= count) setCursor(Math.max(0, count - 1))
  })
  createEffect(() => {
    const task = current()
    if (task) list?.scrollChildIntoView(rowId(task.task))
  })
  // Opening the log, or moving to another row while it is open, reads at once
  // rather than at the next tick.
  createEffect(() => {
    showLog()
    cursor()
    void readLog()
  })

  const inner = () => Math.max(24, screen().width - 2)
  /** Rows leave one column for ScrollBox's vertical track and one for air beside it. */
  const rowInner = () => Math.max(24, screen().width - 4)
  const logRows = () => (showLog() ? Math.min(10, Math.max(3, Math.floor(screen().height / 3))) : 0)

  const move = (delta: number) => {
    const count = rows().length
    if (count === 0) return
    setCursor(Math.min(Math.max(cursor() + delta, 0), count - 1))
  }

  const kill = async () => {
    const task = current()
    if (!task) return
    try {
      setNotice(await taskKill(props.ws, task.task))
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
    props.onRefresh()
  }

  /** `K`: every task still going. The same one key, said about all of them. */
  const killAll = async () => {
    const live = rows().filter((task) => !taskIsDone(task))
    if (live.length === 0) {
      setNotice("nothing is running")
      return
    }
    for (const task of live) {
      try {
        await taskKill(props.ws, task.task)
      } catch {
        // Already gone, or never started: the summary counts what was asked.
      }
    }
    setNotice(`asked ${live.length} task${live.length === 1 ? "" : "s"} to stop`)
    props.onRefresh()
  }

  const clickRow = (index: number) => {
    if (cursor() === index) return setShowLog(!showLog())
    setCursor(index)
  }

  useKeyboard((key) => {
    if (help.consume(key)) return
    if (key.name === "escape") {
      if (showLog()) return setShowLog(false)
      return props.onClose()
    }
    if (key.name === "down") return move(1)
    if (key.name === "up") return move(-1)
    // `k` is the kill verb here, not the cursor — the one list in this front end
    // where `j`/`k` do not move. Its rows are processes somebody may need to
    // stop, and `k` is what that has been called since kill(1); a key that moves
    // the cursor in five panels and destroys something in the sixth is the worse
    // of the two inconsistencies. So the cursor takes the arrows alone, and the
    // footer says which is which.
    if (key.name === "k") return key.shift ? void killAll() : void kill()
    if (key.name === "r") return props.onRefresh()
    if (key.name === "return") return setShowLog(!showLog())
  })

  /** The last rows of the log that fit, blank tail dropped. */
  const tail = (): string[] => {
    const lines = log().replace(/\n+$/, "").split("\n")
    if (lines.length === 1 && lines[0] === "") return []
    return lines.slice(Math.max(0, lines.length - logRows()))
  }

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve}>
        {fit(
          `background tasks · ${rows().length}${props.sessionId ? ` · ${props.sessionId}` : ""}`,
          inner(),
        )}
      </text>
      <box height={1} />
      <scrollbox
        ref={(box: ScrollBoxRenderable) => (list = box)}
        flexGrow={1}
        flexShrink={1}
        flexBasis={0}
        width="100%"
        scrollX={false}
        viewportCulling
        verticalScrollbarOptions={{
          trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
        }}
        contentOptions={{ flexDirection: "column", width: "100%" }}
      >
        <Index each={rows()}>
          {(item, index) => {
            const row = () => item()
            const tone = () => ({ selected: index === cursor(), hovered: hover.at() === index })
            const gutter = () => rowGutter(style, tone())
            const running = () => !taskIsDone(row())
            const note = () => outcome(row())
            /** name · state · elapsed · how it ended — then the command, cut to fit. */
            const lead = () => `${row().task}  ${row().state.padEnd(8)}  ${elapsed(row()).padStart(7)}  `
            const room = () => Math.max(0, rowInner() - 2 - displayWidth(lead()) - displayWidth(note()) - 2)
            const click = onClick(() => clickRow(index))
            return (
              <box
                id={rowId(row().task)}
                flexDirection="row"
                width="100%"
                height={1}
                flexShrink={0}
                backgroundColor={rowBackground(style, tone())}
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                {...hover.row(index)}
              >
                <text fg={gutter().fg} flexShrink={0}>
                  {gutter().text}
                </text>
                <text fg={running() ? style.theme.fg : style.theme.muted} flexShrink={0}>
                  {lead()}
                </text>
                <text fg={style.theme.dim} flexShrink={0}>
                  {fit(row().command, room())}
                </text>
                <Show when={note().length > 0}>
                  <text fg={row().exit_code === 0 && row().state === "done" ? style.theme.dim : style.theme.err} flexShrink={0}>
                    {"  "}
                    {note()}
                  </text>
                </Show>
              </box>
            )
          }}
        </Index>
        {/* Nothing here is the common case, and it is the one moment this panel
            can say what a background task IS and how one is started. */}
        <Show when={rows().length === 0}>
          <text fg={style.theme.muted}>
            {fit(props.sessionId ? "no background tasks in this session" : "this tab has no session yet", inner())}
          </text>
          <text fg={style.theme.dim}>
            {fit(
              "the model starts one with shell {background: true} · it outlives the step, and its report arrives as a turn",
              inner(),
            )}
          </text>
        </Show>
      </scrollbox>
      <Show when={showLog() && current()}>
        {/* One row per line, each cut by us: a log line is as long as whatever
            wrote it, and a wrapped row here would push the footer off screen
            (`ui/columns.ts`). */}
        <box flexDirection="column" width="100%" flexShrink={0}>
          <text fg={style.theme.muted}>{fit(`${current()!.task} · ${current()!.log}`, inner())}</text>
          <Index each={tail()}>{(line) => <text fg={style.theme.fg}>{fit(line(), inner())}</text>}</Index>
          <Show when={tail().length === 0}>
            <text fg={style.theme.dim}>{fit("(nothing in the log yet)", inner())}</text>
          </Show>
        </box>
      </Show>
      <OverlayFooter
        width={inner()}
        help={help}
        notice={notice()}
        brief="↑↓ move · Enter log · k kill · Esc close"
        more={[
          "K stops every task still running · r re-reads the list",
          "a task outlives this step and this window; its report arrives at the next step boundary",
        ]}
      />
    </box>
  )
}
