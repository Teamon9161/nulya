/** QueueLane is one status/action row; transcript cards own message bodies. */
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

test("the lane names only queue state and the delivery gesture, never message bodies", async () => {
  const messages: QueuedMessage[] = [
    { key: "q:1", text: "also check the docs" },
    { key: "q:2", text: "and the README\nwith a second line" },
  ]
  const setup = await mount(() => <QueueLane messages={messages} />)
  try {
    const frame = await settle(setup, 2)
    expect(frame).toContain("⏸ 2 queued · ctrl+g interrupts & delivers")
    expect(frame).not.toContain("also check the docs")
    expect(frame).not.toContain("and the README")
  } finally {
    setup.renderer.destroy()
  }
})

test("clicking the status row delivers the whole FIFO queue", async () => {
  const messages: QueuedMessage[] = [
    { key: "q:1", text: "first queued message" },
    { key: "q:2", text: "second queued message" },
  ]
  let calls = 0
  const setup = await mount(() => <QueueLane messages={messages} onSelect={() => (calls += 1)} />)
  try {
    await settle(setup, 2)
    const lines = frameLines(setup.captureCharFrame())
    const row = lines.findIndex((line) => line.includes("2 queued"))
    expect(row).toBeGreaterThan(-1)
    const x = lines[row]!.indexOf("queued") + 1
    await setup.mockMouse.click(x, row)
    expect(calls).toBe(1)
  } finally {
    setup.renderer.destroy()
  }
})
