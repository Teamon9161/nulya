/**
 * Compaction (`src/compact.ts`): the summary shape, and the fork it opens
 * against the REAL binary.
 *
 * The part that needs a model — whether the brief is any good — is not testable
 * here and is not pretended to be. What IS pinned down is everything that would
 * silently lose a conversation: a missing summary must not move anything, and
 * the new session must carry both the lineage and the parent's frozen identity.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import {
  compactPrompt,
  compactionMarker,
  compact_request_marker,
  compact_summary_marker,
  openCompacted,
  summaryFrom,
  summaryTurn,
  withoutMarker,
} from "../src/compact.ts"
import { readHeader } from "../src/nulya/files.ts"
import { sessionAppend, sessionEvents, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import { createSessionState, type TranscriptItem } from "../src/state/session.ts"
import { scripted_env, tempWorkspace, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

function user(text: string, seq: number): TranscriptItem {
  return { key: `e${seq}`, seq, kind: "user", text, queued: false }
}

function assistant(text: string, seq: number): TranscriptItem {
  return { key: `e${seq}`, seq, kind: "assistant", text, streaming: false }
}

test("the brief asks for the sections a new session cannot go back and read", () => {
  const plain = compactPrompt()
  expect(plain.startsWith(compact_request_marker)).toBe(true)
  expect(plain).toContain("**Task and success criteria**")
  expect(plain).toContain("**Next steps**")
  expect(plain).toContain("**Continuation details**")
  expect(plain).not.toContain("Additional focus")

  // A focus supplements the required sections; it never replaces them, or
  // "focus on the API design" would quietly drop the file list.
  const focused = compactPrompt("the provider wire formats")
  expect(focused).toContain("the provider wire formats")
  expect(focused).toContain("supplements, and never replaces")
  expect(focused).toContain("**Task and success criteria**")
  // Whitespace-only is no focus at all.
  expect(compactPrompt("   ")).toBe(plain)
})

test("the summary is read from the answer to the request, and its absence is reported as absence", () => {
  const before: TranscriptItem[] = [user("do the thing", 1), assistant("on it", 2)]

  // No request yet: nothing to compact into.
  expect(summaryFrom(before)).toBeNull()

  const request = user(compactPrompt(), 3)
  // A request the model answered with tool calls and no text leaves the window
  // exactly as full as it was — null, not an empty summary that would wipe it.
  expect(summaryFrom([...before, request])).toBeNull()
  expect(summaryFrom([...before, request, assistant("   ", 4)])).toBeNull()

  // Only what came AFTER the request counts, so an earlier answer is never
  // mistaken for the brief.
  expect(summaryFrom([...before, request, assistant("## Task\nship it", 4)])).toBe("## Task\nship it")
})

test("the two machinery turns are recognised by content, and read without their marker", () => {
  expect(compactionMarker(user(compactPrompt(), 1))).toBe("request")
  expect(compactionMarker(user(summaryTurn("a brief"), 2))).toBe("summary")
  expect(compactionMarker(user("just a message", 3))).toBeNull()
  expect(compactionMarker(assistant(compact_summary_marker, 4))).toBeNull()

  expect(withoutMarker(summaryTurn("line one\nline two"))).toBe("line one\nline two")
  // A marker with nothing under it reads as empty, never as the marker itself.
  expect(withoutMarker(compact_summary_marker)).toBe("")
})

test("openCompacted forks the real session: lineage recorded, identity inherited, summary queued", async () => {
  const parent = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, parent, "do the thing")
  const step = sessionStep(ws, parent, { env: scripted_env })
  for await (const _ of step.lines) {
    // Drained so the step can finish and release the writer lease.
  }
  expect(await step.exited).toBe(0)

  // The cut point is where the parent actually stopped, not a placeholder.
  const tail = await sessionEvents(ws, parent)
  const cut = tail[tail.length - 1]!.seq
  expect(cut).toBeGreaterThan(0)
  const id = await openCompacted(ws, parent, cut, "## Task\nship it\n\n## Next steps\nkeep going")

  const header = await readHeader(ws, id)
  expect(header).not.toBeNull()
  expect(header!.parent).toEqual({ session: parent, seq: cut })
  // The kernel carried the parent's frozen identity over (DESIGN §14): a
  // compaction must not change who the conversation is with.
  const parentHeader = await readHeader(ws, parent)
  expect(header!.model).toBe(parentHeader!.model)
  expect(header!.model_identity).toEqual(parentHeader!.model_identity)

  // The summary is deposited, not stepped: it waits in the inbox exactly like a
  // turn typed before a step runs, and the new ledger is still only a header.
  const file = readFileSync(join(ws.dir, ".nulya", "sessions", `${id}.jsonl`), "utf8")
  expect(file.trim().split("\n").length).toBe(1)

  const next = sessionStep(ws, id, { env: scripted_env })
  const seen = createSessionState(id)
  for await (const line of next.lines) {
    if (line.kind === "stream") seen.applyStream(line.line)
    else seen.applyEvent(line.event)
  }
  expect(await next.exited).toBe(0)
  const carried = seen.snapshot.items.find((item) => item.kind === "user")
  expect(carried?.kind === "user" && carried.text.startsWith(compact_summary_marker)).toBe(true)
  expect(carried?.kind === "user" && withoutMarker(carried.text)).toContain("ship it")
}, 60_000)
