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
      <text fg={style.theme.accent.evolve}>usage · this session's tokens · tool counts since the workspace began</text>
      <box height={1} />

      <Row left="steps priced" right={`${usage().pricedSteps} · ${props.snapshot.steps} watched here`} />
      <Row left="input tokens" right={String(usage().input)} />
      <Row left="output tokens" right={String(usage().output)} />
      <Row left="cache read" right={`${usage().cacheRead} · ${cachePercent()}% of input`} />
      <Row left="cache write" right={String(usage().cacheWrite)} />
      <Row left="last prompt" right={String(usage().lastPrompt)} />
      <box height={1} />
      <text fg={style.theme.dim}>
        summed from the ledger, one step at a time · a step whose provider reported no usage is absent, not zero
      </text>
      <box height={1} />

      <UsageTable rows={rows()} />
      <text fg={style.theme.dim}>r refresh · Esc close</text>
    </box>
  )
}
