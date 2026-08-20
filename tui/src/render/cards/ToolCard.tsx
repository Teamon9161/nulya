import { Match, Switch, createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { describeTool } from "../registry.ts"
import { cancelMarkerOf } from "../../nulya/ledger.ts"
import { renderHintOf, type Contributions } from "../../nulya/files.ts"
import { ShellCard } from "./ShellCard.tsx"
import { EditCard } from "./EditCard.tsx"
import { ExtToolCard } from "./ExtToolCard.tsx"
import { EvolveCard } from "./EvolveCard.tsx"
import { CanceledCard } from "./CanceledCard.tsx"
import { ChecklistCard } from "./ChecklistCard.tsx"
import { MarkdownToolCard } from "./MarkdownToolCard.tsx"
import type { ToolItem } from "../../state/session.ts"

/**
 * One tool call → one card. `render/registry.ts` decides WHICH card and what
 * goes on its head line; this file only dispatches on that decision, so no
 * component below ever matches on a tool name or a command prefix (tui.md §3).
 *
 * Cancellation wins over the tool's own identity: what matters about a call the
 * kernel closed out is that it did not finish, not that it was a `shell`.
 */
export function ToolCard(props: { item: ToolItem; contributions?: Contributions[] }) {
  const style = useStyle()
  const presentation = createMemo(() =>
    describeTool({ tool: props.item.tool, args: props.item.args, output: props.item.output }, style.glyphs, {
      // Only a member of this session's frozen composition can have made a
      // rendering claim about its own tool (D12) — the hint is resolved here,
      // once, from the same `contributions` a live or replayed session hands
      // down, so `describeTool` itself stays a pure function of one call.
      render: renderHintOf(props.contributions ?? [], props.item.tool),
    }),
  )
  const marker = createMemo(() => (props.item.output ? cancelMarkerOf(props.item.output) : null))

  return (
    <Switch>
      <Match when={marker() !== null}>
        <CanceledCard item={props.item} presentation={presentation()} marker={marker()!} />
      </Match>
      <Match when={presentation().kind === "edit"}>
        <EditCard item={props.item} presentation={presentation()} />
      </Match>
      {/*
        A sub-session is an evolution action that happens to name a session
        (tui.md §5.5). The registry keeps the two kinds apart because
        `sessionId` is the fact T3 needs to open one as a second tab; until
        something is done with it, drawing a second card would be duplication.
      */}
      <Match when={presentation().kind === "evolve" || presentation().kind === "subsession"}>
        <EvolveCard item={props.item} presentation={presentation()} />
      </Match>
      <Match when={presentation().kind === "checklist"}>
        <ChecklistCard item={props.item} presentation={presentation()} />
      </Match>
      <Match when={presentation().kind === "markdown"}>
        <MarkdownToolCard item={props.item} presentation={presentation()} />
      </Match>
      <Match when={presentation().kind === "ext"}>
        <ExtToolCard item={props.item} presentation={presentation()} />
      </Match>
      <Match when={presentation().kind === "shell"}>
        <ShellCard item={props.item} presentation={presentation()} />
      </Match>
    </Switch>
  )
}
