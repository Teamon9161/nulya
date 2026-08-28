/**
 * The task-stopped sentinel (`taskstop.ts`): the same discipline every other
 * sentinel in this front end keeps — wrap and parse live in one module, so
 * whatever a stop button writes, a transcript folds back to the same words,
 * live or replayed.
 */
import { expect, test } from "bun:test"
import {
  parseTaskStoppedNote,
  taskStoppedNoteOf,
  task_stopped_contract,
  wrapTaskStoppedNote,
} from "../src/taskstop.ts"
import { parseApprovalNote } from "../src/approvalnote.ts"
import { parseMidTask } from "../src/midtask.ts"

test("wrap → parse round-trips the task name it was about", () => {
  const wrapped = wrapTaskStoppedNote("s-abc123/t2")
  expect(parseTaskStoppedNote(wrapped)).toEqual({ task: "s-abc123/t2", text: "s-abc123/t2 was stopped by the user" })
})

test("the contract rides after the close and parse never depends on it", () => {
  const wrapped = wrapTaskStoppedNote("s-1/t1")
  expect(wrapped.endsWith(task_stopped_contract)).toBe(true)
  const reworded = wrapped.replace(task_stopped_contract, "some future contract text")
  expect(parseTaskStoppedNote(reworded)?.task).toBe("s-1/t1")
})

test("without the contract only the sentinel rides, and it still parses", () => {
  const bare = wrapTaskStoppedNote("s-1/t3", false)
  expect(bare).not.toContain(task_stopped_contract)
  expect(parseTaskStoppedNote(bare)?.task).toBe("s-1/t3")
})

test("not a task-stopped note: plain text and the other sentinels all read null", () => {
  expect(parseTaskStoppedNote("plain text")).toBeNull()
  expect(parseTaskStoppedNote("")).toBeNull()
})

/**
 * The sentinels must not answer for each other: the card router checks the
 * approval note and this one separately, and each has to say no to the
 * other's shape.
 */
test("disjoint from the approval note and the mid-task sentinel", () => {
  const stopped = wrapTaskStoppedNote("s-1/t1")
  expect(parseApprovalNote(stopped)).toBeNull()
  expect(parseMidTask(stopped)).toBeNull()
  expect(taskStoppedNoteOf({ key: "k", seq: 1, kind: "user", text: stopped, queued: false })?.task).toBe("s-1/t1")
  expect(taskStoppedNoteOf({ key: "k", seq: 1, kind: "assistant", text: stopped, streaming: false })).toBeNull()
})
