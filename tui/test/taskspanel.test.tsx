/**
 * `TasksPanel` (tasks panel): the composer-area, mouse-only view
 * of a session's background tasks — the same terms every panel in that region
 * lives under (nothing at rest draws anything), plus the one thing
 * specific to this one: a running row's stop button fires `onStop` with the
 * task's full name and nothing else, and a finished row has no button at all.
 */
import { expect, test } from "bun:test"
import type { JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { TasksPanel } from "../src/ui/TasksPanel.tsx"
import { StyleContext, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { frameLines, settle } from "./support.ts"
import type { TaskEntry } from "../src/nulya/cli.ts"

const style = createStyle(default_settings, {})

function mount(node: () => JSX.Element, width = 80, height = 12) {
  return testRender(() => <StyleContext.Provider value={style}>{node()}</StyleContext.Provider>, { width, height })
}

function task(over: Partial<TaskEntry> & { task: string; state: TaskEntry["state"] }): TaskEntry {
  return {
    session: "s-1",
    log: ".nulya/scratch/s-1/tasks/t1/output.log",
    notify: null,
    command: "sleep 300",
    cwd: ".",
    started: "2026-08-28T00:00:00Z",
    timeout_ms: null,
    pid: 123,
    supervisor_pid: 456,
    exit_code: null,
    ended_by: null,
    finished: null,
    duration_ms: null,
    elapsed_s: 12,
    ...over,
  }
}

test("no tasks: the panel says so and points at how one gets started", async () => {
  const setup = await mount(() => <TasksPanel tasks={[]} onStop={() => {}} />)
  try {
    const frame = await settle(setup, 2)
    expect(frame).toContain("background tasks")
    expect(frame).toContain("nothing running")
    expect(frame).toContain("shell {background: true}")
  } finally {
    setup.renderer.destroy()
  }
})

test("a running task shows its command, its elapsed time, and a stop button; a finished one shows neither a clock nor a button", async () => {
  const tasks = [
    task({ task: "s-1/t1", state: "running", command: "sleep 300", elapsed_s: 42 }),
    task({ task: "s-1/t2", state: "done", command: "echo done", exit_code: 0, duration_ms: 500, elapsed_s: null }),
  ]
  const setup = await mount(() => <TasksPanel tasks={tasks} onStop={() => {}} />)
  try {
    const frame = await settle(setup, 2)
    expect(frame).toContain("s-1/t1")
    expect(frame).toContain("running")
    expect(frame).toContain("42s")
    expect(frame).toContain("s-1/t2")
    expect(frame).toContain("done")
    const lines = frameLines(setup.captureCharFrame())
    const runningRow = lines.findIndex((line) => line.includes("s-1/t1"))
    const doneRow = lines.findIndex((line) => line.includes("s-1/t2"))
    expect(lines[runningRow]).toContain("stop")
    // A finished task's row is a fact, not a control.
    expect(lines[doneRow]).not.toContain("stop")
  } finally {
    setup.renderer.destroy()
  }
})

test("clicking stop fires onStop with that row's full task name, and only that row's", async () => {
  const tasks = [
    task({ task: "s-1/t1", state: "running", command: "sleep 300", elapsed_s: 1 }),
    task({ task: "s-1/t2", state: "running", command: "sleep 300", elapsed_s: 1 }),
  ]
  const stopped: string[] = []
  const setup = await mount(() => <TasksPanel tasks={tasks} onStop={(name) => stopped.push(name)} />)
  try {
    await settle(setup, 2)
    const lines = frameLines(setup.captureCharFrame())
    const secondRow = lines.findIndex((line) => line.includes("s-1/t2"))
    const x = lines[secondRow]!.indexOf("stop") + 1
    await setup.mockMouse.click(x, secondRow)
    expect(stopped).toEqual(["s-1/t2"])

    const firstRow = lines.findIndex((line) => line.includes("s-1/t1"))
    const x2 = lines[firstRow]!.indexOf("stop") + 1
    await setup.mockMouse.click(x2, firstRow)
    expect(stopped).toEqual(["s-1/t2", "s-1/t1"])
  } finally {
    setup.renderer.destroy()
  }
})
