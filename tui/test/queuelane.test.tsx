/**
 * The queue lane (agent-runner ar-t1, tui.md §4.4b): the inbox drawn out above
 * the composer. Pure presentational component — no session, no driver — so
 * this only pins what T35/T38 already require of everything in that region
 * (nothing drawn at rest) and the one behaviour specific to this lane: every
 * row is the same click, because the inbox is a FIFO the kernel drains whole.
 */
import { expect, test } from "bun:test"
import type { JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { QueueLane, type QueuedMessage } from "../src/ui/QueueLane.tsx"
import { StyleContext, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { frameLines, settle } from "./support.ts"

const style = createStyle(default_settings, {})

function mount(node: () => JSX.Element, width = 80, height = 10) {
  return testRender(() => <StyleContext.Provider value={style}>{node()}</StyleContext.Provider>, { width, height })
}

test("nothing queued draws nothing — no resting-state row, same rule as WorkingStatus (T35/T38)", async () => {
  const setup = await mount(() => <QueueLane messages={[]} />)
  try {
    const frame = await settle(setup, 2)
    expect(frame).not.toContain("queued")
  } finally {
    setup.renderer.destroy()
  }
})

test("the summary line names the count and the gesture; each message gets its own truncated row", async () => {
  const messages: QueuedMessage[] = [
    { key: "q:1", text: "also check the docs" },
    { key: "q:2", text: "and the README\nwith a second line folded away" },
  ]
  const setup = await mount(() => <QueueLane messages={messages} />)
  try {
    const frame = await settle(setup, 2)
    expect(frame).toContain("2 queued")
    expect(frame).toContain("enter queues")
    expect(frame).toContain("ctrl+j interrupts & delivers")
    expect(frame).toContain("also check the docs")
    // A newline inside a queued message is flattened to one line, not a
    // second row this lane never asked for.
    expect(frame).toContain("and the README with a second line folded away")
  } finally {
    setup.renderer.destroy()
  }
})

test("clicking any row fires the same onSelect — the inbox is a FIFO, not something a row can jump ahead in", async () => {
  const messages: QueuedMessage[] = [
    { key: "q:1", text: "first queued message" },
    { key: "q:2", text: "second queued message" },
  ]
  let calls = 0
  const setup = await mount(() => <QueueLane messages={messages} onSelect={() => (calls += 1)} />)
  try {
    await settle(setup, 2)
    const lines = frameLines(setup.captureCharFrame())
    const secondRow = lines.findIndex((line) => line.includes("second queued message"))
    expect(secondRow).toBeGreaterThan(-1)
    const x = lines[secondRow]!.indexOf("second") + 1
    await setup.mockMouse.click(x, secondRow)
    expect(calls).toBe(1)

    const firstRow = lines.findIndex((line) => line.includes("first queued message"))
    const x2 = lines[firstRow]!.indexOf("first") + 1
    await setup.mockMouse.click(x2, firstRow)
    expect(calls).toBe(2)
  } finally {
    setup.renderer.destroy()
  }
})
