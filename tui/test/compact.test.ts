/**
 * Compaction (`src/compact.ts`): what is left on this side of it.
 *
 * The procedure — ask, summarise, fork, carry over — now lives in the bundled
 * `extensions/compact` package and is pinned down by `zig build e2e` against
 * the real binary, including the case that would silently lose a conversation
 * (no summary must move nothing). What the front end still owns is the two
 * marker lines, and the only thing that can break here is their round trip:
 * a marker that stops being recognised turns machinery back into a turn that
 * looks typed, and a stripper that eats a line turns a brief into a blank card.
 */
import { expect, test } from "bun:test"
import {
  compactionMarker,
  compact_draft,
  compact_id,
  compact_request_marker,
  compact_summary_marker,
  withoutMarker,
} from "../src/compact.ts"
import type { AssistantItem, UserItem } from "../src/state/session.ts"

function user(text: string, seq: number): UserItem {
  return { key: `e${seq}`, seq, kind: "user", text, queued: false }
}

function assistant(text: string, seq: number): AssistantItem {
  return { key: `e${seq}`, seq, kind: "assistant", text, streaming: false }
}

test("the two machinery turns are recognised by content, and read without their marker", () => {
  const request = user(`${compact_request_marker}\n# Context compaction\n\nWrite a brief.`, 1)
  const summary = user(`${compact_summary_marker}\n## Task\nship it`, 2)

  expect(compactionMarker(request)).toBe("request")
  expect(compactionMarker(summary)).toBe("summary")
  expect(compactionMarker(user("just a message", 3))).toBeNull()
  // Only user turns carry them: the kernel writes both as `user_text`.
  expect(compactionMarker(assistant(compact_summary_marker, 4))).toBeNull()

  expect(withoutMarker(summary.text)).toBe("## Task\nship it")
  expect(withoutMarker(request.text)).toContain("# Context compaction")
  // A marker with nothing under it reads as empty, never as the marker itself.
  expect(withoutMarker(compact_summary_marker)).toBe("")
})

test("the driver is named where the kernel can build it", () => {
  // `runCompact` builds this draft and runs that id; the package ships with
  // nulya's source, next to `extensions/evolution`.
  expect(compact_draft).toBe("extensions/compact")
  expect(compact_id).toBe("compact")
})
