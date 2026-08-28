/**
 * The background tasks of one session, as a live projection (tui.md §5.9).
 *
 * A task outlives the step that started it and outlives this process, so it is
 * not session view state: nothing about it is in the ledger until it ends, and
 * what IS on disk — `status.json`, the lock, the log — is the kernel's to read.
 * So this is the same kind of thing as the writer-lease probe: a fact about
 * right now, re-read on a beat, never re-derived here. `state` in particular
 * (`starting` / `lost`) is the kernel's projection and this module would be
 * wrong to compute a second answer for it.
 *
 * It lives beside the session rather than inside it because polling needs a
 * lifecycle — an interval to stop when a tab closes — and `SessionState` is a
 * pure store with nothing to dispose.
 */
import { createContext, createSignal, useContext, type Accessor } from "solid-js"
import { taskIsDone, taskKill, taskList, type TaskEntry } from "../nulya/cli.ts"
import { wrapTaskStoppedNote } from "../taskstop.ts"
import type { Workspace } from "../nulya/bin.ts"

export interface TaskWatch {
  tasks: Accessor<TaskEntry[]>
  /** How many are neither `done` nor `lost` — what the status bar counts. */
  live: Accessor<number>
  /** Read the list now: on open, when a step ends, on `r` in the panel. */
  refresh(): Promise<void>
  dispose(): void
}

export interface TaskWatchOptions {
  /** How often a session with a task still running is re-read. */
  pollMs?: number
  /** Extra child environment (tests point `NULYA_HOME` elsewhere). */
  env?: Record<string, string>
}

export function createTaskWatch(ws: Workspace, id: string, options: TaskWatchOptions = {}): TaskWatch {
  const [tasks, setTasks] = createSignal<TaskEntry[]>([])
  let disposed = false
  let reading = false

  const refresh = async () => {
    if (disposed || reading) return
    reading = true
    try {
      const rows = await taskList(ws, id, options.env)
      if (!disposed) setTasks(rows)
    } catch {
      // A binary without `task list`, a workspace that vanished: this panel is
      // an observation, and a failed observation shows the last one it had.
    } finally {
      reading = false
    }
  }

  const live = () => tasks().filter((task) => !taskIsDone(task)).length

  void refresh()
  // Only while something is actually running. A session that never started a
  // task costs one read when its tab opens and nothing after that — the poll is
  // for the seconds ticking on a card, and there is no card without a task.
  const timer = setInterval(() => {
    if (live() > 0) void refresh()
  }, options.pollMs ?? 1500)

  return {
    tasks,
    live,
    refresh,
    dispose() {
      disposed = true
      clearInterval(timer)
    },
  }
}

/**
 * The tasks of the session in front, for the cards.
 *
 * A card is handed one transcript item and nothing else, but a background call's
 * head line has to say how long the thing has been running — which is not in the
 * item and never will be, because it changes without anything being appended.
 * Same shape as the fold store and the browse store: one context, a default that
 * says "none", so a card rendered in a test needs no provider.
 */
export const TasksContext = createContext<Accessor<TaskEntry[]>>()

export function useTasks(): Accessor<TaskEntry[]> {
  return useContext(TasksContext) ?? (() => [])
}

/** The live row for a task name, when this session still has one. */
export function taskNamed(tasks: readonly TaskEntry[], name: string): TaskEntry | null {
  return tasks.find((task) => task.task === name) ?? null
}

/** `41.8s` / `2m 04s` — a duration in the space a head line has for one. */
export function seconds(total: number): string {
  if (total < 60) return `${total}s`
  const minutes = Math.floor(total / 60)
  return `${minutes}m ${String(total % 60).padStart(2, "0")}s`
}

/**
 * Stop a background task FROM THE TUI, and say so to the model in the same
 * breath (tui.md §11, tasks panel).
 *
 * `nulya task kill` alone leaves the model unable to tell a person's stop
 * button apart from its own `shell` call — both produce the same `· killed`
 * marker on the task's report (DESIGN §6.1). This is the one place that pairs
 * the kill with the attribution (`taskstop.ts`), so `TasksPanel` and
 * `TasksView` (`/tasks`) cannot drift into two different answers for "what do
 * we tell the model when a person presses stop". The note is appended only
 * after the kill call itself succeeds — a kill that failed said nothing
 * happened, and there is nothing to attribute.
 *
 * `send` is `Attachment.send` from whichever tab owns this task: `framed:
 * true` so the note lands exactly as written, whether that tab is driving
 * (drained at the next step boundary) or only observing (still appended,
 * never taking the writer lease — DESIGN §3.4).
 */
export async function stopTask(
  ws: Workspace,
  send: (text: string, framed?: boolean) => Promise<void>,
  task: string,
): Promise<string> {
  const result = await taskKill(ws, task)
  await send(wrapTaskStoppedNote(task), true)
  return result
}

/** How a call's own report of its task ended, once one has landed in the ledger. */
export interface TaskOutcome {
  exitCode: number
  duration: string
}

/**
 * How a background task is going, in the words a head line uses (T43).
 *
 * TWO SOURCES IN ONE ORDER, and the order is the whole of it: the LEDGER's
 * report if it has landed — a fact, and one that survives closing the session
 * and opening it again — otherwise the live projection, which is where the
 * seconds come from while it is still going. Neither is invented: with no
 * report and no live row, all that can honestly be said is the name.
 *
 * Two callers since T43 — a `shell {background: true}` receipt and a delegation
 * receipt — which is why it is here rather than inside one of the cards. They
 * are the same fact about the same kind of thing, and a person should not have
 * to learn that `running 42s` and `still going` mean the same.
 *
 * `showTask` (default true) is the one thing the two callers disagree about.
 * A background `shell` call's row is the one place its full name (`<sid>/tN`)
 * is worth printing — it is the handle `nulya task status` wants, and the row
 * names no agent to say it instead. A delegation's row already does (its head
 * line names the agent and its task, `registry.ts`), so `SubSessionCard` asks
 * for `showTask: false` and gets `exit 0 · 41.8s` rather than `s-1/t1 · exit 0
 * · 41.8s` — the same state, said without a handle nobody there needed.
 */
export function backgroundNote(
  task: string,
  reported: TaskOutcome | null,
  tasks: readonly TaskEntry[],
  options?: { showTask?: boolean },
): { text: string; failed: boolean } {
  const label = (options?.showTask ?? true) ? task : ""
  const join = (...pieces: string[]) => [label, ...pieces].filter((piece) => piece.length > 0).join(" · ")
  if (reported) {
    const how = reported.exitCode === 0 ? [] : [`exit ${reported.exitCode}`]
    return {
      text: join(...how, ...(reported.duration ? [reported.duration] : [])),
      failed: reported.exitCode !== 0,
    }
  }
  const live = taskNamed(tasks, task)
  if (!live) return { text: label, failed: false }
  if (live.state === "done") {
    const bad = live.exit_code !== null && live.exit_code !== 0
    return { text: join(...(bad ? [`exit ${live.exit_code}`] : [])), failed: bad }
  }
  if (live.state === "lost") return { text: join("lost"), failed: false }
  return { text: join(`running${live.elapsed_s !== null ? ` ${seconds(live.elapsed_s)}` : ""}`), failed: false }
}
