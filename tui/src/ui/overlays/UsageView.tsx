/**
 * `/usage`: what this attachment has spent, and what the workspace has learned.
 *
 * Two different kinds of number, kept apart on purpose:
 *
 *  - TOKENS are transient. The stream reports per-step counts (DESIGN §14) and
 *    this process sums the steps it watched; whatever happened before we
 *    attached is genuinely unknown, so the header says `since attach` rather
 *    than pretending to a total.
 *  - TOOL USES are durable. They come from `.nulya/tool-usage.jsonl`, the
 *    journal the kernel appends to across every session (DESIGN §5.5) — counts
 *    only, never a ranking (tui.md §2.1).
 */
import { createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useStyle } from "../../render/theme.ts"
import { readToolUsage, type ToolUsage } from "../../nulya/files.ts"
import { UsageTable } from "./UsageTable.tsx"
import type { Workspace } from "../../nulya/bin.ts"
import type { SessionSnapshot } from "../../state/session.ts"

export function UsageView(props: { ws: Workspace; snapshot: SessionSnapshot; onClose: () => void }) {
  const style = useStyle()
  const [rows, setRows] = createSignal<ToolUsage[]>([])

  const refresh = async () => setRows(await readToolUsage(props.ws))
  onMount(() => void refresh())

  useKeyboard((key) => {
    if (key.name === "escape") return props.onClose()
    if (key.name === "r") return void refresh()
  })

  const usage = () => props.snapshot.usage
  const cachePercent = () => (usage().input > 0 ? Math.round((usage().cacheRead / usage().input) * 100) : 0)

  const Row = (row: { left: string; right: string }) => (
    <box flexDirection="row" width="100%">
      <box width={20} flexShrink={0}>
        <text fg={style.theme.dim}>{row.left}</text>
      </box>
      <text fg={style.theme.fg}>{row.right}</text>
    </box>
  )

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve}>usage · tokens since attach · tool counts since the workspace began</text>
      <box height={1} />

      <Row left="steps watched" right={String(props.snapshot.steps)} />
      <Row left="input tokens" right={String(usage().input)} />
      <Row left="output tokens" right={String(usage().output)} />
      <Row left="cache read" right={`${usage().cacheRead} · ${cachePercent()}% of input`} />
      <Row left="cache write" right={String(usage().cacheWrite)} />
      <box height={1} />
      <text fg={style.theme.dim}>
        per-step counts summed by this process · the session's history before we attached is not ours to know
      </text>
      <box height={1} />

      <UsageTable rows={rows()} />
      <text fg={style.theme.dim}>r refresh · Esc close</text>
    </box>
  )
}
