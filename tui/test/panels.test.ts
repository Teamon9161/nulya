/**
 * The `panel: true` projection (DESIGN §7.2.1, tui-plugin D12, U2 §3): which
 * tool calls make it onto the strip above the composer, and in what order.
 * Pure — the rendering itself (`ui/PanelStrip.tsx`) is a snapshot in
 * `test/render.test.tsx`.
 */
import { expect, test } from "bun:test"
import { panelItemsOf } from "../src/state/panels.ts"
import type { Contributions } from "../src/nulya/files.ts"
import type { TranscriptItem, ToolItem } from "../src/state/session.ts"

function contribution(over: Partial<Contributions> & Pick<Contributions, "id">): Contributions {
  return {
    version: "v-0",
    tools: [],
    readonlyTools: [],
    driverTools: [],
    skills: [],
    systemPrompts: [],
    activation: "always",
    commands: [],
    policy: null,
    toolRender: {},
    panelTools: [],
    ...over,
  }
}

function tool(over: Partial<ToolItem> & { key: string; tool: string; seq: number }): ToolItem {
  return {
    kind: "tool",
    callId: over.key,
    args: "{}",
    state: "done",
    ok: true,
    output: "",
    spillPath: null,
    resolved: true,
    awaiting: false,
    taskResult: null,
    ...over,
  }
}

test("no member declares `panel: true`: nothing to project", () => {
  const items: TranscriptItem[] = [tool({ key: "e1:c1", tool: "todo", seq: 1 })]
  expect(panelItemsOf(items, [contribution({ id: "plan" })])).toEqual([])
})

test("a declaring tool with no call yet contributes no row", () => {
  const contributions = [contribution({ id: "plan", panelTools: ["todo"] })]
  expect(panelItemsOf([], contributions)).toEqual([])
  // Calls of OTHER tools do not manufacture a row either.
  const items: TranscriptItem[] = [tool({ key: "e1:c1", tool: "echo", seq: 1 })]
  expect(panelItemsOf(items, contributions)).toEqual([])
})

test("the LATEST call of a declaring tool wins, by ledger order", () => {
  const contributions = [contribution({ id: "plan", panelTools: ["todo"] })]
  const first = tool({ key: "e1:c1", tool: "todo", seq: 1, output: "first" })
  const second = tool({ key: "e3:c1", tool: "todo", seq: 3, output: "second" })
  const items: TranscriptItem[] = [first, second]
  expect(panelItemsOf(items, contributions)).toEqual([second])
  // Order in the ledger, not sorted seq — a later item earlier in the array
  // still wins, because "latest" means "last seen while walking the ledger".
  expect(panelItemsOf([second, first], contributions)).toEqual([first])
})

test("several declaring tools stack in package order, one row per tool", () => {
  const contributions = [
    contribution({ id: "plan", panelTools: ["todo"] }),
    contribution({ id: "watch", panelTools: ["progress"] }),
  ]
  const todo = tool({ key: "e1:c1", tool: "todo", seq: 1 })
  const progress = tool({ key: "e2:c1", tool: "progress", seq: 2 })
  // Ledger order reversed from package order: the projection still stacks by
  // PACKAGE order (`panelToolsOf`), not by which call happened last.
  expect(panelItemsOf([progress, todo], contributions)).toEqual([todo, progress])
})

test("the same tool name declared by two members is one row, not two", () => {
  const contributions = [
    contribution({ id: "plan", panelTools: ["todo"] }),
    contribution({ id: "other", panelTools: ["todo"] }),
  ]
  const items: TranscriptItem[] = [tool({ key: "e1:c1", tool: "todo", seq: 1 })]
  expect(panelItemsOf(items, contributions)).toHaveLength(1)
})
