import { Match, Switch, createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { describeTool } from "../registry.ts"
import { cancelMarkerOf } from "../../nulya/ledger.ts"
import { renderHintOf, type Contributions } from "../../nulya/files.ts"
import { ShellCard } from "./ShellCard.tsx"
import { ExtToolCard } from "./ExtToolCard.tsx"
import { EvolveCard } from "./EvolveCard.tsx"
import { SubSessionCard } from "./SubSessionCard.tsx"
import { CanceledCard } from "./CanceledCard.tsx"
import { ChecklistCard } from "./ChecklistCard.tsx"
import { MarkdownToolCard } from "./MarkdownToolCard.tsx"
import { PluginToolCard } from "./PluginToolCard.tsx"
import { CardActivityContext } from "./CardFrame.tsx"
import { usePlugins } from "../../plugins/context.ts"
import type { ToolItem } from "../../state/session.ts"

/**
 * One tool call → one card. `render/registry.ts` decides WHICH card and what
 * goes on its head line; this file only dispatches on that decision, so no
 * component below ever matches on a tool name or a command prefix (tui.md §3).
 *
 * Cancellation wins over the tool's own identity: what matters about a call the
 * kernel closed out is that it did not finish, not that it was a `shell`.
 */
export function ToolCard(props: { item: ToolItem; contributions?: Contributions[]; highlighted?: boolean }) {
  const style = useStyle()
  const plugins = usePlugins()
  /**
   * A code card from the package that owns this tool, if there is one — asked
   * BEFORE the registry's own kinds, because a package that shipped a renderer
   * has superseded its own `render:` hint (the same ceiling-over-floor rule the
   * widget strip follows). Never before cancellation, which is about the call
   * not having happened at all.
   */
  const pluginCard = () => plugins?.cardFor(props.item.tool) ?? null
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
  // Waiting for approval is visibly live; otherwise the session projection
  // chooses exactly one card and keeps it sweeping through the following model
  // response. A merely streamed/pending card does not flash on and off.
  const active = () => props.item.awaiting || props.highlighted === true

  return (
    <CardActivityContext.Provider value={active}>
      <Switch>
        <Match when={marker() !== null}>
          <CanceledCard item={props.item} presentation={presentation()} marker={marker()!} />
        </Match>
        <Match when={pluginCard() !== null}>
          <PluginToolCard
            item={props.item}
            presentation={presentation()}
            card={pluginCard()!}
            revision={plugins?.revision() ?? 0}
          />
        </Match>
        {/*
          A call that opened a session of its own has its own card since T43: it
          is the one kind whose story continues somewhere else, so it says how
          that is going and offers a way in (`SubSessionCard`).
        */}
        <Match when={presentation().kind === "subsession"}>
          <SubSessionCard item={props.item} presentation={presentation()} />
        </Match>
        <Match when={presentation().kind === "evolve"}>
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
    </CardActivityContext.Provider>
  )
}
