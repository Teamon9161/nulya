/**
 * Promoting an optimistic turn (`state/session.ts`).
 *
 * The rule under test is identity, not text: `session append` receipts the
 * delivery name, the drained `user_text` carries the same name back as its
 * `origin`, and that pairing is what removes the echo. Text cannot do this job
 * — two turns reading "hello" are two facts, and a turn some other writer sent
 * can read exactly like ours.
 */
import { expect, test } from "bun:test"
import { createSessionState, type UserItem } from "../src/state/session.ts"
import type { LedgerEvent } from "../src/nulya/ledger.ts"

function userText(seq: number, text: string, origin?: string | string[]): LedgerEvent {
  const event: Record<string, unknown> = { seq, kind: "user_text", text }
  if (typeof origin === "string") event["origin"] = origin
  if (Array.isArray(origin)) event["origins"] = origin
  return event as unknown as LedgerEvent
}

function queued(state: ReturnType<typeof createSessionState>): UserItem[] {
  return state.snapshot.items.filter((item): item is UserItem => item.kind === "user" && item.queued)
}

test("the echo is removed by its own delivery name, not by matching text", () => {
  const state = createSessionState("s-1")
  const mine = state.enqueueUser("hello")
  state.confirmQueued(mine, "msg-mine.json")

  // Same text, someone else's delivery: our turn is still out there.
  state.applyEvent(userText(1, "hello", "msg-theirs.json"))
  expect(state.pendingCount()).toBe(1)

  state.applyEvent(userText(2, "hello", "msg-mine.json"))
  expect(state.pendingCount()).toBe(0)
  expect(state.snapshot.items.filter((item) => item.kind === "user").length).toBe(2)
})

test("two identical turns merged into one drained event promote both echoes", () => {
  const state = createSessionState("s-1")
  const first = state.enqueueUser("hello")
  const second = state.enqueueUser("hello")
  state.confirmQueued(first, "msg-0001.json")
  state.confirmQueued(second, "msg-0002.json")

  state.applyEvent(userText(1, "hello\n\nhello", ["msg-0001.json", "msg-0002.json"]))
  expect(state.pendingCount()).toBe(0)
})

test("a turn drained before its receipt printed is still promoted when it arrives", () => {
  const state = createSessionState("s-1")
  const mine = state.enqueueUser("hello")

  // The step drained the inbox file while `session append` was still running.
  state.applyEvent(userText(1, "hello", "msg-mine.json"))
  expect(state.pendingCount()).toBe(1)

  state.confirmQueued(mine, "msg-mine.json")
  expect(state.pendingCount()).toBe(0)
  expect(state.snapshot.items.filter((item) => item.kind === "user").length).toBe(1)
})

test("a replayed tail promotes nothing and keeps a turn that is genuinely still queued", () => {
  const state = createSessionState("s-1")
  state.applyEvents([userText(1, "one", "msg-0001.json"), userText(2, "two", "msg-0002.json")])
  const mine = state.enqueueUser("three")
  state.confirmQueued(mine, "msg-0003.json")
  expect(queued(state).map((item) => item.text)).toEqual(["three"])
})
