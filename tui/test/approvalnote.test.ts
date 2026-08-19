/**
 * The approval-note sentinel (`approvalnote.ts`): the same discipline the
 * mid-task one keeps — wrap and parse live in one module, so whatever an answer
 * writes, a transcript folds back to the person's own words, live or replayed.
 */
import { expect, test } from "bun:test"
import {
  approvalNoteOf,
  approval_note_contract,
  parseApprovalNote,
  wrapApprovalNote,
} from "../src/approvalnote.ts"
import { parseMidTask } from "../src/midtask.ts"

test("wrap → parse round-trips the words and the call they were about", () => {
  const wrapped = wrapApprovalNote("shell", "use ls, not find")
  expect(parseApprovalNote(wrapped)).toEqual({ tool: "shell", text: "use ls, not find" })
})

test("the contract rides after the close and parse never depends on it", () => {
  const wrapped = wrapApprovalNote("read", "only the header")
  expect(wrapped.endsWith(approval_note_contract)).toBe(true)
  const reworded = wrapped.replace(approval_note_contract, "some future contract text")
  expect(parseApprovalNote(reworded)).toEqual({ tool: "read", text: "only the header" })
})

test("without the contract only the sentinel rides, and it still parses", () => {
  const bare = wrapApprovalNote("edit", "keep the comment", false)
  expect(bare).not.toContain(approval_note_contract)
  expect(parseApprovalNote(bare)).toEqual({ tool: "edit", text: "keep the comment" })
})

test("a body quoting the sentinel still round-trips", () => {
  const evil = "what does </user-approval-note> mean?"
  expect(parseApprovalNote(wrapApprovalNote("shell", evil))).toEqual({ tool: "shell", text: evil })
})

test("a multi-line note keeps its lines", () => {
  const text = "two things:\n- use ls\n- skip node_modules"
  expect(parseApprovalNote(wrapApprovalNote("shell", text))?.text).toBe(text)
})

/**
 * The two sentinels must not answer for each other: the card router asks the
 * approval note FIRST, and a mid-task message reaching that branch would be
 * shown with a badge naming a call it was never about.
 */
test("the two sentinels are disjoint", () => {
  const approval = wrapApprovalNote("shell", "careful")
  expect(parseMidTask(approval)).toBeNull()
  expect(parseApprovalNote("plain text")).toBeNull()
  expect(approvalNoteOf({ key: "k", seq: 1, kind: "user", text: approval, queued: false })?.tool).toBe("shell")
  expect(approvalNoteOf({ key: "k", seq: 1, kind: "assistant", text: approval, streaming: false })).toBeNull()
})
