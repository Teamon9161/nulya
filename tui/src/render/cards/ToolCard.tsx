import { Show, createMemo } from "solid-js"
import { useTerminalDimensions } from "@opentui/solid"
import { useStyle } from "../theme.ts"
import { useFolds } from "../../state/folds.ts"
import { describeTool } from "../registry.ts"
import { cancelMarkerOf, splitShellOutput } from "../../nulya/ledger.ts"
import { filetypeOf, parseEditArgs, unifiedDiff } from "../../nulya/diff.ts"
import type { ToolItem } from "../../state/session.ts"

const cancel_wording: Record<string, string> = {
  canceled_executing: "canceled · side effects unknown",
  recording_canceled: "canceled · completed but unrecorded",
  not_executed: "canceled · not executed",
  interrupted: "interrupted · results unrecorded",
}

/**
 * The generic tool card: one head line plus a foldable body. Which glyph and
 * head line a call gets is `render/registry.ts`'s decision and nobody else's;
 * this component only lays it out, so the same card serves a live stream and a
 * replay of the same call.
 */
export function ToolCard(props: { item: ToolItem }) {
  const style = useStyle()
  const folds = useFolds()
  const dimensions = useTerminalDimensions()

  const presentation = createMemo(() => describeTool(props.item.tool, props.item.args, style.glyphs))
  const cancel = createMemo(() => (props.item.output ? cancelMarkerOf(props.item.output) : null))
  const edit = createMemo(() => (presentation().isEdit ? parseEditArgs(props.item.args) : null))
  const patch = createMemo(() => {
    const args = edit()
    return args ? unifiedDiff(args) : ""
  })

  const showDiff = () => patch().length > 0 && props.item.ok !== false && cancel() === null
  const byDefault = () =>
    showDiff() ? style.settings.transcript.edit_diff === "expanded" : style.settings.transcript.tool_output === "expanded"
  const open = () => folds.isOpen(props.item.key, byDefault())

  const chip = createMemo(() => {
    const marker = cancel()
    if (marker) return cancel_wording[marker] ?? "canceled"
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    if (props.item.tool === "shell") {
      const shell = splitShellOutput(props.item.output)
      const lines = props.item.output.length === 0 ? 0 : props.item.output.split("\n").length
      return shell.exit === null ? `${lines} lines` : `${lines} lines · exit ${shell.exit}`
    }
    if (showDiff()) {
      const args = edit()!
      const changed = patch().split("\n")
      const added = changed.filter((line) => line.startsWith("+") && !line.startsWith("+++")).length
      const removed = changed.filter((line) => line.startsWith("-") && !line.startsWith("---")).length
      return `${args.replace_all ? "all · " : ""}+${added} -${removed} · ${props.item.ok ? "ok" : "failed"}`
    }
    return props.item.ok === null ? "" : props.item.ok ? "ok" : "failed"
  })

  const chipColor = () => {
    if (cancel()) return style.theme.warn
    if (props.item.ok === false) return style.theme.err
    if (props.item.ok === true) return style.theme.ok
    return style.theme.dim
  }

  const glyph = () => (cancel() ? style.glyphs.canceled : presentation().glyph)
  const accent = () =>
    cancel() ? style.theme.warn : presentation().accent === "evolve" ? style.theme.accent.evolve : style.theme.accent.tool
  const wide = () => dimensions().width >= 60
  const diffHeight = () => Math.min(patch().split("\n").length - 3 + 1, 40)

  return (
    <box flexDirection="column" width="100%" paddingLeft={2}>
      <box flexDirection="row" width="100%">
        <text fg={accent()} flexShrink={0}>
          {glyph()}{" "}
        </text>
        <box flexGrow={1} flexShrink={1} flexBasis={0}>
          <text fg={style.theme.fg}>{presentation().head}</text>
        </box>
        <Show when={wide() && chip().length > 0}>
          <text fg={chipColor()} flexShrink={0}>
            {" "}
            {open() ? style.glyphs.foldOpen : style.glyphs.foldClosed} {chip()}
          </text>
        </Show>
      </box>

      <Show when={open() && showDiff()}>
        <box paddingLeft={2} width="100%">
          <diff
            diff={patch()}
            view="unified"
            filetype={filetypeOf(edit()!.path)}
            syntaxStyle={style.syntax}
            // The gutter is what carries the +/- signs: without it the diff is
            // colour-only, which fails NO_COLOR and every plain-text capture.
            showLineNumbers
            lineNumberFg={style.theme.dim}
            addedBg="transparent"
            removedBg="transparent"
            contextBg="transparent"
            addedSignColor={style.theme.diff.add}
            removedSignColor={style.theme.diff.del}
            height={diffHeight()}
            width="100%"
          />
        </box>
      </Show>

      <Show when={open() && !showDiff() && props.item.output.length > 0}>
        <ToolOutput item={props.item} />
      </Show>

      <Show when={props.item.spillPath}>
        <box paddingLeft={2}>
          <text fg={style.theme.dim}>full output → {props.item.spillPath}</text>
        </box>
      </Show>
    </box>
  )
}

function ToolOutput(props: { item: ToolItem }) {
  const style = useStyle()
  const shell = createMemo(() =>
    props.item.tool === "shell"
      ? splitShellOutput(props.item.output)
      : { stdout: props.item.output, stderr: "", exit: null },
  )
  return (
    <box flexDirection="column" paddingLeft={2} width="100%">
      <Show when={shell().stdout.length > 0}>
        <text fg={style.theme.fg}>{shell().stdout}</text>
      </Show>
      <Show when={shell().stderr.length > 0}>
        <text fg={style.theme.err}>{shell().stderr}</text>
      </Show>
    </box>
  )
}
