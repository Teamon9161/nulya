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
import { taskIsDone, taskList, type TaskEntry } from "../nulya/cli.ts"
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
