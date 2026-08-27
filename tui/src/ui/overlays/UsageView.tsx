/**
 * `/usage`: what this session has spent, and what the workspace has learned.
 *
 * Two different scopes, kept apart on purpose:
 *
 *  - TOKENS are this session's. Every step's cost is recorded on its assistant
 *    event (DESIGN §3.1), so opening a session replays its whole price — not
 *    only the steps this process happened to watch. A step whose provider
 *    reported nothing is absent rather than zero, which is why the count of
 *    priced steps is shown next to the number of steps.
 *  - TOOL USES are the workspace's. They come from `.nulya/tool-usage.jsonl`,
 *    the journal the kernel appends to across every session (DESIGN §5.5) —
 *    counts only, never a ranking (tui.md §2.1).
 *
 * Every line is laid out here and never by the terminal: labels are a column
 * sized from their own text, and the two sentences are broken at their ` · `
 * joints (`ui/columns.ts` says why a wrapped line garbles rather than merely
 * looking untidy).
 */
import { For, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useScreen, useStyle } from "../../render/theme.ts"
import { columnWidth, fit, wrapWords } from "../columns.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { readToolUsage, type ToolUsage } from "../../nulya/files.ts"
import { UsageTable } from "./UsageTable.tsx"
import type { Workspace } from "../../nulya/bin.ts"
import { cacheShare, type SessionSnapshot } from "../../state/session.ts"

const title = "usage · this session's tokens · tool counts since the workspace began"
const caveat =
  "summed from the ledger, one step at a time · a step whose provider reported no usage is absent, not zero"

/** The left column of the token block, in the order the rows are drawn. */
const labels = ["steps priced", "input tokens", "output tokens", "cache read", "cache write", "last prompt"]

export function UsageView(props: { ws: Workspace; snapshot: SessionSnapshot; onClose: () => void }) {
  const style = useStyle()
  const screen = useScreen()
  const [rows, setRows] = createSignal<ToolUsage[]>([])
  const help = createKeyHelp()

  const refresh = async () => setRows(await readToolUsage(props.ws))
  onMount(() => void refresh())

  useKeyboard((key) => {
    if (help.consume(key)) return
    if (key.name === "escape") return props.onClose()
    if (key.name === "r") return void refresh()
  })

  const usage = () => props.snapshot.usage

  /** The columns this overlay may draw in: the box pads one on each side. */
  const inner = () => Math.max(20, screen().width - 2)
  const label = createMemo(() => columnWidth(labels, 2, 20))
  /** Every number this block draws, so the amount column is sized by them. */
  const values = () => [
    String(usage().pricedSteps),
    String(usage().input),
    String(usage().output),
    String(usage().cacheRead),
    String(usage().cacheWrite),
    String(usage().lastPrompt),
  ]
  const padLeft = (text: string, width: number) => " ".repeat(Math.max(0, width - text.length)) + text

  /**
   * The numbers are a column of their own, right-aligned (tui.md §6).
   *
   * Six counts left-aligned under one another is six different places for the
   * last digit, and the last digit is what says whether this is a hundred or a
   * million. What follows a number here is a remark about it (`· 88% of
   * prompt`), so it is dim and it starts where every other remark starts.
   */
  const amount = createMemo(() => columnWidth(values(), 1, 14))
  const Row = (row: { left: string; value: string; note?: string }) => (
    <box flexDirection="row" width="100%" height={1} flexShrink={0}>
      <box width={label()} flexShrink={0}>
        <text fg={style.theme.dim}>{fit(row.left, label() - 2)}</text>
      </box>
      <box width={amount()} flexShrink={0}>
        <text fg={style.theme.fg}>{padLeft(row.value, amount() - 1)}</text>
      </box>
      <text fg={style.theme.dim}>{fit(row.note ?? "", Math.max(0, inner() - label() - amount()))}</text>
    </box>
  )

  const Sentence = (line: { text: string }) => (
    <For each={wrapWords(line.text, inner())}>
      {(part) => (
        <text fg={style.theme.dim} height={1}>
          {part}
        </text>
      )}
    </For>
  )

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <For each={wrapWords(title, inner())}>
        {(line) => (
          <text fg={style.theme.accent.evolve} height={1}>
            {line}
          </text>
        )}
      </For>
      <box height={1} />

      {/* The body scrolls, as `/help`'s does and for the same reason it had to
          (`HelpView`): this panel's height is the token block plus however many
          tools the workspace journal has learned, and when that ran past the
          screen the footer was drawn ON TOP of the last row — the two texts
          interleaved cell by cell, which is what a `<text>` does to whatever
          was under its blanks (`ui/columns.ts`). `flexBasis: 0` so the box is
          sized from the space that is left, not from its own content. */}
      <scrollbox
        flexGrow={1}
        flexShrink={1}
        flexBasis={0}
        width="100%"
        verticalScrollbarOptions={{
          trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
        }}
        contentOptions={{ flexDirection: "column", width: "100%" }}
      >
        <Row left="steps priced" value={String(usage().pricedSteps)} note={`· ${props.snapshot.steps} watched here`} />
        <Row left="input tokens" value={String(usage().input)} />
        <Row left="output tokens" value={String(usage().output)} />
        <Row left="cache read" value={String(usage().cacheRead)} note={`· ${cacheShare(usage())}% of prompt`} />
        <Row left="cache write" value={String(usage().cacheWrite)} />
        <Row left="last prompt" value={String(usage().lastPrompt)} />
        <box height={1} />
        <Sentence text={caveat} />
        <box height={1} />

        <UsageTable rows={rows()} width={inner() - 1} />
      </scrollbox>
      <OverlayFooter width={inner()} help={help} brief="r refresh · Esc close" />
    </box>
  )
}
