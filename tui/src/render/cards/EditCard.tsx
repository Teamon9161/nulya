import { Show, createMemo } from "solid-js"
import { RGBA, type TextChunk } from "@opentui/core"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { ShellOutput } from "./ShellCard.tsx"
import { diffStats, filetypeOf, parseEditArgs, unifiedDiff } from "../../nulya/diff.ts"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * An `edit` call: the path on the head line, the unified diff EXPANDED by
 * default (tui.md §1.2 D5) — the one tool output worth seeing without asking,
 * because it is the change itself rather than a report about it.
 *
 * The hunk header counts the replaced fragment, not the file: `edit` is an
 * exact-string transaction and the ledger holds no file offsets (see
 * `nulya/diff.ts`).
 */
export function EditCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const args = createMemo(() => parseEditArgs(props.item.args))
  const patch = createMemo(() => {
    const parsed = args()
    return parsed ? unifiedDiff(parsed) : ""
  })
  // A failed edit changed nothing, so its diff would be a picture of something
  // that never happened: fall back to the error the kernel reported.
  const showDiff = () => patch().length > 0 && props.item.ok !== false

  const chip = () => {
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    const parsed = args()
    if (!showDiff() || !parsed) return props.item.ok === false ? "failed" : ""
    const stats = diffStats(parsed)
    // The diff is right below; `ok` on top of it would be saying it twice (T26).
    const counts = `${parsed.replace_all ? "all · " : ""}+${stats.added} -${stats.removed}`
    return props.item.ok === false ? `${counts} · failed` : counts
  }

  const tone = () => (props.item.ok === false ? "err" : "dim")
  const diff = createMemo(() => renderDiffCode(patch(), args()?.path ?? ""))
  const visibleRows = createMemo(() => diff().rows.slice(0, 40))
  const clipped = () => diff().rows.length > visibleRows().length
  const content = () => visibleRows().map((row) => row.body).join("\n")
  const onChunks = createMemo(() => diffChunkDecorator(visibleRows(), style))

  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={props.presentation.glyph}
      accent={style.theme.accent.tool}
      head={props.presentation.head}
      chip={chip()}
      chipTone={tone()}
      defaultOpen={
        showDiff()
          ? style.settings.transcript.edit_diff === "expanded"
          : style.settings.transcript.tool_output === "expanded"
      }
      foldable={showDiff() || props.item.output.length > 0}
      spillPath={props.item.spillPath}
    >
      <Show when={showDiff()} fallback={<ShellOutput output={props.item.output} />}>
        <code
          content={content()}
          filetype={diff().filetype}
          syntaxStyle={style.syntax}
          fg={style.theme.fg}
          width="100%"
          height={visibleRows().length}
          wrapMode="word"
          onChunks={onChunks()}
        />
        <Show when={clipped()}>
          <text fg={style.theme.dim} height={1}>… diff clipped after 40 rows</text>
        </Show>
      </Show>
    </CardFrame>
  )
}

type DiffTone = "add" | "del" | "hunk" | "context"

type DiffCodeRow = { tone: DiffTone; prefix: string; body: string }

type DiffCode = { filetype: string | undefined; rows: DiffCodeRow[] }

function renderDiffCode(patch: string, path: string): DiffCode {
  const rows: DiffCodeRow[] = []
  for (const raw of patch.split("\n")) {
    if (raw.length === 0 || raw.startsWith("--- ") || raw.startsWith("+++ ")) continue
    const tone: DiffTone = raw.startsWith("+")
      ? "add"
      : raw.startsWith("-")
        ? "del"
        : raw.startsWith("@@")
          ? "hunk"
          : "context"
    rows.push({ tone, prefix: tone === "hunk" ? "  " : raw.slice(0, 1), body: tone === "hunk" ? raw : raw.slice(1) })
  }
  return {
    filetype: filetypeOf(path) ?? "markdown",
    rows: rows.length > 0 ? rows : [{ tone: "context", prefix: " ", body: "" }],
  }
}

function diffChunkDecorator(rows: readonly DiffCodeRow[], style: ReturnType<typeof useStyle>) {
  const addBg = color(style.theme.diff.addBg)
  const delBg = color(style.theme.diff.delBg)
  const addFg = color(style.theme.diff.add)
  const delFg = color(style.theme.diff.del)
  const dimFg = color(style.theme.dim)

  return (chunks: TextChunk[]): TextChunk[] => {
    const out: TextChunk[] = []
    let line = 0
    let atLineStart = true

    for (const chunk of chunks) {
      const parts = chunk.text.split("\n")
      for (let i = 0; i < parts.length; i++) {
        const row = rows[Math.min(line, rows.length - 1)] ?? rows[rows.length - 1]
        if (atLineStart) {
          out.push(gutterChunk(row, addFg, delFg, dimFg))
          atLineStart = false
        }
        const part = parts[i]
        if (part && row) out.push(styleChunk(chunk, part, row, addBg, delBg, dimFg))
        if (i < parts.length - 1) {
          out.push(styleChunk(chunk, "\n", row, addBg, delBg, dimFg))
          line++
          atLineStart = true
        }
      }
    }

    return out
  }
}

function gutterChunk(row: DiffCodeRow | undefined, addFg: RGBA | undefined, delFg: RGBA | undefined, dimFg: RGBA | undefined): TextChunk {
  const tone = row?.tone ?? "context"
  return {
    __isChunk: true,
    text: `${row?.prefix ?? " "} `,
    fg: tone === "add" ? addFg : tone === "del" ? delFg : dimFg,
  }
}

function styleChunk(
  chunk: TextChunk,
  text: string,
  row: DiffCodeRow | undefined,
  addBg: RGBA | undefined,
  delBg: RGBA | undefined,
  dimFg: RGBA | undefined,
): TextChunk {
  const tone = row?.tone ?? "context"
  return {
    ...chunk,
    text,
    fg: tone === "hunk" ? dimFg : chunk.fg,
    bg: tone === "add" ? addBg : tone === "del" ? delBg : chunk.bg,
  }
}

function color(value: string): RGBA | undefined {
  return value === "transparent" ? undefined : RGBA.fromHex(value)
}
