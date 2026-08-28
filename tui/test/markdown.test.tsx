/**
 * A markdown table is as wide as the box it is in — at every width, whatever
 * widths came before, and for as long as it is on screen.
 *
 * The bug this pins is OpenTUI's, not ours (`useBodyWidth` in
 * `render/theme.ts` says how the width is derived):
 * a table fits its columns once and never re-fits when the space narrows, so it
 * was drawn one column wider than its box, and because its row count decides
 * whether the scrollbox needs a scrollbar at all — which is what narrowed it —
 * the two layouts alternated on screen for as long as the session was open.
 *
 * What is asserted is the mechanism and nothing else: the table's right border
 * is inside the frame, the same width draws the same thing, and a still screen
 * stays still. Column positions are not pinned; they are OpenTUI's business and
 * they may change.
 */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { Transcript } from "../src/ui/Transcript.tsx"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { unsafe_settings } from "./support.ts"
import type { TranscriptItem } from "../src/state/session.ts"

const style: Style = createStyle(unsafe_settings, {})

/** Wide enough to need fitting, with cells that wrap when a column is lost. */
const table = [
  "以上可以总结为：",
  "",
  "| 动作 | active/current | tool pin | 进入每场 session |",
  "|---|---|---|---|",
  "| 开屏 sync --activate | 是 | 否，只有 std 特殊处理 | 否 |",
  "| /ext 上对 plan 按 Enter | 是 | `propose`、`todo` | 不自动戴 plan prompt |",
  "| /plan | 当前场 | `propose`、`todo` | 当前场，并带 plan prompt |",
].join("\n")

function tables(count: number): TranscriptItem[] {
  return Array.from(
    { length: count },
    (_, i) => ({ kind: "assistant", key: `a${i}`, text: table, streaming: false }) as TranscriptItem,
  )
}

/** Frames drawn after walking through `widths`, ending at the last one. */
async function frames(items: TranscriptItem[], widths: number[], height: number, extra = 0): Promise<string[]> {
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <FoldContext.Provider value={createFoldStore()}>
          <Transcript items={items} />
        </FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width: widths[0]!, height },
  )
  try {
    const out: string[] = []
    for (const width of widths) {
      setup.resize(width, height)
      // Three passes: the resize, the width it hands the body, and the
      // scrollbox's own verdict on the new content height (scrollbar or not).
      await setup.renderOnce()
      await setup.renderOnce()
      await setup.renderOnce()
    }
    out.push(setup.captureCharFrame())
    for (let i = 0; i < extra; i++) {
      await setup.renderOnce()
      out.push(setup.captureCharFrame())
    }
    return out
  } finally {
    setup.renderer.destroy()
  }
}

/** A table whose right edge fell off the box has no top-right corner on screen. */
function closed(frame: string): boolean {
  return frame.split("\n").some((line) => line.includes("┐"))
}

test("a markdown table stays inside its box", async () => {
  // Both heights matter: one where the transcript overflows and the scrollbar
  // takes a column away from the body, one where it does not.
  for (const height of [14, 30]) {
    for (const width of [72, 78, 90]) {
      const [frame] = await frames(tables(1), [width], height)
      expect(closed(frame!)).toBe(true)
    }
  }
})

/**
 * The scrollbar thumb is masked out of the comparison: its geometry reflects a
 * scrollHeight OpenTUI does not always recompute after a resize, so the thumb
 * can honestly disagree between two ways of reaching the same width while
 * every content cell is identical. The claim under test is the TABLE — the
 * thumb is OpenTUI's business, like the column positions.
 */
function content(frame: string): string {
  return frame
    .split("\n")
    .map((line) => line.replace(/[█▄▀\s]+$/u, ""))
    .join("\n")
}

test("the same width draws the same table, however it was reached", async () => {
  const items = tables(3)
  for (const height of [14, 30]) {
    const [direct] = await frames(items, [78], height)
    for (const path of [
      [100, 78],
      [60, 78],
      [90, 60, 78],
    ]) {
      const [reached] = await frames(items, path, height)
      expect(content(reached!)).toBe(content(direct!))
    }
  }
})

test("a screen nobody touches does not change", async () => {
  // Steady state at the heights where one wrapped row decides whether there is
  // a scrollbar — the boundary the two layouts used to swap across. This one
  // passed before the fix too: the swap needs the terminal's own frame loop,
  // and a test renderer only draws when asked. It is here as the cheap guard on
  // the property the person actually sees.
  for (const height of [13, 14, 15, 24]) {
    for (const count of [1, 3]) {
      const drawn = await frames(tables(count), [78], height, 12)
      expect(new Set(drawn.slice(2)).size).toBe(1)
    }
  }
})
