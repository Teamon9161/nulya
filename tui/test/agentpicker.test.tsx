/**
 * `/agent`'s picker, the pure half: what a row says, given an
 * `AgentEntry`. The definition FORMAT has one reader (`extensions/agent`'s
 * `list`), pinned end to end in `agents.test.ts` / `delegate.test.tsx`; this
 * only pins what the picker does with the answer, including a fact today's
 * definitions can never actually produce — a non-`nulya` runner (ar-c's
 * `Runner` enum has only the one arm, so any other value is a whole
 * definition warn-and-skipped, not a row with an unusual field). The picker's
 * handling of that column has to be tested against a hand-built row for
 * exactly that reason (goals/agent-runner.md ar-t2).
 */
import { expect, test } from "bun:test"
import type { JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { AgentPicker } from "../src/ui/AgentPicker.tsx"
import { StyleContext, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { settle } from "./support.ts"
import type { AgentEntry } from "../src/agents.ts"

const style = createStyle(default_settings, {})

function mount(node: () => JSX.Element, width = 80, height = 12) {
  return testRender(() => <StyleContext.Provider value={style}>{node()}</StyleContext.Provider>, { width, height })
}

function def(over: Partial<AgentEntry> & { name: string }): AgentEntry {
  return {
    description: "",
    readonly: false,
    runner: "nulya",
    layer: "workspace",
    shadowed: false,
    source: `${over.name}.md`,
    profile: "",
    model: "",
    rung: "",
    rung_model: "",
    max_steps: 0,
    max_exchanges: 0,
    agents: [],
    with: [],
    warnings: [],
    ...over,
  }
}

test("the ordinary runner says nothing; a non-nulya one is the one fact every row of it must say out loud", async () => {
  const defs: AgentEntry[] = [def({ name: "explore" }), def({ name: "remote-review", runner: "codex" })]
  const setup = await mount(() => <AgentPicker defs={defs} selected={0} onSelect={() => {}} onPick={() => {}} />)
  try {
    const frame = await settle(setup, 2)
    // The row for the persona this build actually drives says nothing about a
    // runner: naming the ordinary case on every row would be noise.
    const rows = frame.split("\n")
    const exploreRow = rows.find((row) => row.includes("explore"))!
    expect(exploreRow).not.toContain("runner")
    expect(exploreRow).not.toContain("nulya")
    // The one persona this build could never actually delegate to — because a
    // second runner does not exist yet — says so, visibly, before it is picked.
    const foreignRow = rows.find((row) => row.includes("remote-review"))!
    expect(foreignRow).toContain("runner: codex")
  } finally {
    setup.renderer.destroy()
  }
})

test("a rung is shown with where it lands, and a rung nobody staffs says so", async () => {
  const defs: AgentEntry[] = [
    def({ name: "scout", rung: "explore", rung_model: "gpt-5.6-luna" }),
    def({ name: "ghost", rung: "nosuch", rung_model: "" }),
  ]
  const setup = await mount(() => <AgentPicker defs={defs} selected={0} onSelect={() => {}} onPick={() => {}} />)
  try {
    const rows = (await settle(setup, 2)).split("\n")
    // The name alone does not say what will run, so the landing point rides
    // with it.
    expect(rows.find((row) => row.includes("scout"))!).toContain("gpt-5.6-luna")
    // Named but landing nowhere: this delegation runs on the model it inherits,
    // which is also what a misspelled rung looks like — so it is not silent.
    const ghost = rows.find((row) => row.includes("ghost"))!
    expect(ghost).toContain("nosuch")
    expect(ghost).toContain("inherits")
  } finally {
    setup.renderer.destroy()
  }
})
