/**
 * The mid-task sentinel (`midtask.ts`): wrap and parse are the same module, so
 * whatever a driver writes, a transcript — live or replayed — folds back.
 */
import { expect, test } from "bun:test"
import { midTaskOf, mid_task_note, mid_task_open, parseMidTask, wrapMidTask } from "../src/midtask.ts"

test("wrap → parse round-trips the user's words", () => {
  const wrapped = wrapMidTask("fix the lint first")
  expect(parseMidTask(wrapped)).toEqual({ text: "fix the lint first" })
})

test("the note rides after the close, verbatim, and parse never depends on it", () => {
  const wrapped = wrapMidTask("hold on")
  expect(wrapped.endsWith(mid_task_note)).toBe(true)
  // Reworded note (an older or newer TUI): the sentinel still folds.
  const reworded = wrapped.replace(mid_task_note, "some future contract text")
  expect(parseMidTask(reworded)).toEqual({ text: "hold on" })
})

test("without the note only the sentinel rides, and it still parses", () => {
  const bare = wrapMidTask("and the tests", false)
  expect(bare).not.toContain(mid_task_note)
  expect(parseMidTask(bare)).toEqual({ text: "and the tests" })
})

test("a body quoting the sentinel still round-trips", () => {
  const evil = "what does </user-mid-task-message> mean?"
  expect(parseMidTask(wrapMidTask(evil))).toEqual({ text: evil })
})

test("plain text and near-misses are not mid-task", () => {
  expect(parseMidTask("just a message")).toBeNull()
  expect(parseMidTask(`prefix ${mid_task_open}\nx\n</user-mid-task-message>`)).toBeNull()
  expect(parseMidTask(mid_task_open)).toBeNull()
})

test("midTaskOf routes only user items", () => {
  const wrapped = wrapMidTask("continue")
  expect(midTaskOf({ key: "e1", seq: 1, kind: "user", text: wrapped, queued: false })).toEqual({ text: "continue" })
  expect(midTaskOf({ key: "e1", seq: 1, kind: "user", text: "continue", queued: false })).toBeNull()
})

test("multi-line words keep their newlines", () => {
  const body = "first line\n\nthird line"
  expect(parseMidTask(wrapMidTask(body))).toEqual({ text: body })
})

test("a merged batch of framed messages folds to the users' words in FIFO order", () => {
  const merged = `${wrapMidTask("first queued")}\n\n${wrapMidTask("second queued", false)}`
  expect(parseMidTask(merged)).toEqual({ text: "first queued\n\nsecond queued" })
})
