/**
 * A card is laid out in the columns of the PANE it is drawn in, never the
 * terminal's (BUGS.md #10, the continuation of #17).
 *
 * Why this is content loss and not a cosmetic misalignment: a card draws each
 * of its wrapped lines in its own `height={1}` box. OpenTUI does not reflow a
 * row that turned out wider than the column it landed in — it simply never
 * paints the overflow. So a card that wrapped at the terminal's width while
 * sitting in a narrower pane (sidebar open, tab split) throws away everything
 * past the seam, and the ledger — and the model — still have the whole thing.
 * That asymmetry is the entire symptom of #10: "the paste looks half-missing
 * but the model clearly read it".
 *
 * What is pinned is the mechanism and nothing else: given N columns a card
 * uses at most N columns, and it loses no characters doing so. Row counts,
 * break positions and the wording of any of these cards are not pinned.
 */
import { expect, test } from "bun:test"
import type { JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { Transcript } from "../src/ui/Transcript.tsx"
import { PluginToolCard } from "../src/render/cards/PluginToolCard.tsx"
import { PluginUserTurnCard } from "../src/render/cards/PluginUserTurnCard.tsx"
import { describeTool } from "../src/render/registry.ts"
import { BodyWidthContext, StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { unsafe_settings } from "./support.ts"
import type { PluginCard, PluginUserTurn } from "../src/plugins/host.ts"
import type { ToolItem, TranscriptItem } from "../src/state/session.ts"

/** Everything a card can open is open, so the body is on screen to be measured. */
const style: Style = createStyle(
  {
    ...unsafe_settings,
    transcript: {
      ...unsafe_settings.transcript,
      tool_output: "expanded",
      composition: "expanded",
      run_summary: false,
    },
  },
  {},
)

/** The pane, and the much wider terminal it is a column of. */
const pane = 44
const terminal = 110

/**
 * A long ASCII message. ASCII so one character is one column, and long enough
 * that a card wrapping at `terminal` would produce rows a `pane`-wide column
 * could not hold.
 */
const message = Array.from({ length: 90 }, (_, i) => `word${String(i).padStart(2, "0")}`).join(" ")

/** The rows of a frame, with the terminal's right-hand padding removed. */
function rows(frame: string): string[] {
  return frame.split("\n").map((row) => row.replace(/\s+$/, ""))
}

/** Rendered in a pane of `pane` columns inside a terminal of `terminal`. */
async function frameInPane(node: () => JSX.Element, height: number): Promise<string> {
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <FoldContext.Provider value={createFoldStore()}>
          <BodyWidthContext.Provider value={() => pane}>{node()}</BodyWidthContext.Provider>
        </FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width: terminal, height },
  )
  try {
    // The layout pass, and the pass that draws what it decided.
    await setup.renderOnce()
    await setup.renderOnce()
    await setup.renderOnce()
    return setup.captureCharFrame()
  } finally {
    setup.renderer.destroy()
  }
}

const user_item: TranscriptItem = { key: "e1", seq: 1, kind: "user", text: message, queued: false }

const shell_item: TranscriptItem = {
  key: "e2:c1",
  seq: 2,
  kind: "tool",
  callId: "c1",
  tool: "shell",
  args: JSON.stringify({ command: `echo ${message}` }),
  state: "done",
  ok: true,
  output: "[exit 0]",
  spillPath: null,
  resolved: true,
  awaiting: false,
  autoAllowed: false,
  taskResult: null,
}

const capability_item: TranscriptItem = {
  key: "e3",
  seq: 3,
  kind: "capability",
  id: "lint",
  version: "v-3f2a91",
  text: `tools:\n- lint_zig — ${message}`,
}

test("cards are laid out in their pane's columns, not the terminal's", async () => {
  const frame = await frameInPane(
    () => <Transcript items={[user_item, shell_item, capability_item]} error={`session new refused · ${message}`} />,
    120,
  )
  const widest = Math.max(...rows(frame).map((row) => row.length))
  expect(widest).toBeLessThanOrEqual(pane)
})

test("wrapping into a narrow pane keeps every character of the message", async () => {
  const frame = await frameInPane(() => <Transcript items={[user_item]} />, 60)
  const drawn = rows(frame)
    .map((row) => row.replace(/^.{0,2}/, ""))
    .join("")
    .replace(/\s+/g, "")
  expect(drawn).toContain(message.replace(/\s+/g, ""))
})

/**
 * A plugin renderer is handed a NUMBER and wraps its own text at it, so the
 * width a card passes down decides where somebody else's code breaks its
 * lines. Getting it from the terminal makes every row that comes back too
 * long for the pane — the same loss as above, one layer removed. The compact /
 * handoff user turn is the one that carries whole paragraphs of context, which
 * is why it is here next to the tool card.
 */
test("a plugin is told the width of the pane its card is in", async () => {
  const widths: number[] = []
  const record = (_view: unknown, width: number) => {
    widths.push(width)
    return [[{ text: "x" }]]
  }

  const tool_item: ToolItem = {
    key: "e4:c2",
    seq: 4,
    kind: "tool",
    callId: "c2",
    tool: "brief",
    args: "{}",
    state: "done",
    ok: true,
    output: message,
    spillPath: null,
    resolved: true,
    awaiting: false,
    autoAllowed: false,
    taskResult: null,
  }
  const card: PluginCard = { pkg: "plan", tool: "brief", renderer: { render: record } }
  const turn: PluginUserTurn = {
    pkg: "compact",
    renderer: { id: "carried", match: () => true, render: record },
  }

  await frameInPane(
    () => (
      <>
        <PluginToolCard
          item={tool_item}
          presentation={describeTool({ tool: tool_item.tool, args: tool_item.args, output: tool_item.output }, style.glyphs)}
          card={card}
          revision={0}
        />
        <PluginUserTurnCard
          item={{ key: "e5", seq: 5, kind: "user", text: message, queued: false }}
          registration={turn}
          revision={0}
        />
      </>
    ),
    40,
  )

  expect(widths.length).toBeGreaterThan(0)
  for (const width of widths) expect(width).toBeLessThanOrEqual(pane)
})
