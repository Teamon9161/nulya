/** Pure package policy for the compact TUI plugin. */
import { expect, test } from "bun:test"
import {
  briefOf,
  compactResult,
  requestMarker,
  summaryMarker,
  withoutMarker,
} from "../../extensions/compact/tui/compact.ts"

test("compact markers remain package-owned and strip without losing their body", () => {
  const request = `${requestMarker}\n# Context compaction\n\nWrite a brief.`
  const summary = `${summaryMarker}\n## Task\nship it`
  expect(withoutMarker(request)).toContain("# Context compaction")
  expect(withoutMarker(summary)).toBe("## Task\nship it")
  expect(withoutMarker(summaryMarker)).toBe("")
})

test("only a complete accepted handoff shape is a proposal", () => {
  expect(briefOf(JSON.stringify({ done: "read", next_task: "write", keep: "paths" }))).toEqual({
    done: "read",
    next_task: "write",
    keep: "paths",
    drop: "",
  })
  expect(briefOf('{"done":"read"}')).toBeNull()
  expect(briefOf("{" )).toBeNull()
})

test("compact results require a real child session id", () => {
  expect(compactResult('{"session":"s-child","parent":{"session":"s-parent","seq":2}}', "", 0).session).toBe("s-child")
  expect(() => compactResult("{}", "", 0)).toThrow("no session id")
  expect(() => compactResult("refused", "", 1)).toThrow("refused")
})
