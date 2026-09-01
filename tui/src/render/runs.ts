/**
 * A RUN: the stretch of calls between one thing the model said and the next,
 * collapsed to a line.
 *
 * The transcript already treated a run as one block, but the block was still
 * one row per call, and a model that reads eleven files before answering pushed
 * everything it SAID off the screen. What a person wants from those eleven
 * rows, while the answer is still coming, is one sentence: it read some files.
 *
 * WHAT DOES NOT GO IN, and why each one is a rule rather than a taste:
 *
 *  - **Anything still going.** The call in flight is the whole of "what is
 *    happening"; folding it away would leave the screen silent at the one
 *    moment there is something to watch.
 *  - **Anything that failed.** Success is silent here and failure is not:
 *    a call that came back `exit 1` keeps its own row, in its own colour. A
 *    summary line that quietly contains a failure is the one shape of this
 *    feature that would be worse than not having it.
 *  - **Anything with a body worth seeing** — a diff, a checklist, a rendered
 *    markdown, a card a package drew in code. These are the calls whose POINT
 *    is what they show.
 *  - **Anything that opened something else**: a session, a background task.
 *    Those cards carry a link and a live note; they are not finished actions.
 *  - **Evolution actions.** `nulya ext build`, `activate`, `skill load` — the
 *    moments this harness exists to make visible. Not noise, by
 *    definition.
 *
 * WHICH LEAVES: plain `shell` calls and plain extension tool calls that worked.
 * The reading (`read`, `grep`, `glob`, `ls`) that a run is mostly made of.
 *
 * HOW A PACKAGE OPTS OUT: it declares `render` on the tool. The
 * vocabulary is open and the kernel enforces nothing; what a driver may read
 * out of it is "this package has an opinion about how its call should look",
 * and a call with a picture to show is not one to summarise. One declaration,
 * no new manifest field, and it is the same one that already chooses the card.
 */
import { cancelMarkerOf, splitShellOutput, startedTaskOf } from "../nulya/ledger.ts"
import type { ToolItem, TranscriptItem } from "../state/session.ts"

/** Everything the decision looks at, so it stays a pure function of one call. */
export interface RunCandidate {
  item: ToolItem
  /** `describeTool(...).kind` for this call. */
  kind: string
  /** The package's `render` claim about this tool, if it made one. */
  render?: string | null
  /** True when a loaded plugin draws this call itself. */
  drawnByPlugin?: boolean
}

export function foldsIntoRun(candidate: RunCandidate): boolean {
  const item = candidate.item
  if (item.state !== "done" || item.awaiting) return false
  if (item.ok === false) return false
  if (candidate.render || candidate.drawnByPlugin) return false
  if (candidate.kind !== "shell" && candidate.kind !== "ext") return false
  // A cancellation marker is a result the kernel wrote in place of one, and it
  // is the card's whole subject (`CanceledCard`).
  if (item.output.length > 0 && cancelMarkerOf(item.output) !== null) return false
  // A receipt, not a result: the thing it started is still going.
  if (startedTaskOf(item.output) !== null) return false
  const exit = splitShellOutput(item.output).exit
  return exit === null || exit === 0
}

/** A transcript row: one item, or a run of calls drawn as one. */
export type TranscriptRow =
  | { kind: "item"; key: string; item: TranscriptItem }
  | { kind: "run"; key: string; items: ToolItem[] }

/**
 * The item list, with runs of foldable calls gathered up.
 *
 * TWO IS THE MINIMUM. One call summarised as "1 call" is a row that replaced a
 * row, and it hid a command to do it.
 */
export function groupRuns(
  items: readonly TranscriptItem[],
  folds: (item: ToolItem) => boolean,
  enabled = true,
): TranscriptRow[] {
  const rows: TranscriptRow[] = []
  let run: ToolItem[] = []

  const flush = () => {
    if (run.length >= 2) rows.push({ kind: "run", key: `${run[0]!.key}:run`, items: run })
    else for (const item of run) rows.push({ kind: "item", key: item.key, item })
    run = []
  }

  for (const item of items) {
    if (enabled && item.kind === "tool" && folds(item)) {
      run.push(item)
      continue
    }
    flush()
    rows.push({ kind: "item", key: item.key, item })
  }
  flush()
  return rows
}

/** The bare tool name: `ext:std/read` and `read` are the same tool to a reader. */
function shortName(tool: string): string {
  return tool.startsWith("ext:") ? (tool.split("/").pop() ?? tool) : tool
}

/**
 * What a run says it did. TUI core only owns the kernel's `shell` wording; an
 * extension tool keeps the name its manifest chose unless a package-owned UI
 * layer draws something richer.
 */
export function runSummary(items: readonly ToolItem[]): string {
  return runSummaryParts(items)
    .map((part) => part.text)
    .join("")
}

function plural(count: number, singular: string, pluralForm = `${singular}s`): string {
  return `${count} ${count === 1 ? singular : pluralForm}`
}

/** One run of a run summary's head line: what it did (muted) against the chrome around it (dim). */
export interface RunSummaryPart {
  text: string
  dim?: boolean
}

/**
 * `runSummary` broken into the two things a head line says at different
 * volumes: WHAT the run did — a tool name, or the `Run N commands` sentence
 * shell earns at more than one call — and the counting and joining around it,
 * which is chrome the same way a fold marker or a `×3` on any other card is
 * (`CardFrame`'s `headParts`). `runSummary` itself is built
 * from this rather than the other way round, so the two can never say
 * different words for the same run.
 */
export function runSummaryParts(items: readonly ToolItem[]): RunSummaryPart[] {
  const counts = new Map<string, number>()
  for (const item of items) {
    const name = shortName(item.tool)
    counts.set(name, (counts.get(name) ?? 0) + 1)
  }
  const parts: RunSummaryPart[] = []
  ;[...counts].forEach(([name, count], index) => {
    if (index > 0) parts.push({ text: " · ", dim: true })
    if (name === "shell" && count > 1) {
      parts.push({ text: `Run ${plural(count, "command")}` })
      return
    }
    parts.push({ text: name })
    if (count > 1) parts.push({ text: ` ×${count}`, dim: true })
  })
  return parts
}
