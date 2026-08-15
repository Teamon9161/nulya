import { Match, Switch } from "solid-js"
import { UserTurn } from "./UserTurn.tsx"
import { AssistantTurn } from "./AssistantTurn.tsx"
import { Thinking } from "./Thinking.tsx"
import { ToolCard } from "./ToolCard.tsx"
import { CapabilityBanner } from "./CapabilityBanner.tsx"
import { useStyle } from "../theme.ts"
import type { TranscriptItem, UnknownItem } from "../../state/session.ts"

/**
 * One transcript item → one card. Live and replay both come through here, so a
 * card can never depend on having seen the stream (tui.md §3).
 */
export function Card(props: { item: TranscriptItem }) {
  return (
    <Switch>
      <Match when={props.item.kind === "user"}>
        <UserTurn item={props.item as Extract<TranscriptItem, { kind: "user" }>} />
      </Match>
      <Match when={props.item.kind === "assistant"}>
        <AssistantTurn item={props.item as Extract<TranscriptItem, { kind: "assistant" }>} />
      </Match>
      <Match when={props.item.kind === "thinking"}>
        <Thinking item={props.item as Extract<TranscriptItem, { kind: "thinking" }>} />
      </Match>
      <Match when={props.item.kind === "tool"}>
        <ToolCard item={props.item as Extract<TranscriptItem, { kind: "tool" }>} />
      </Match>
      <Match when={props.item.kind === "capability"}>
        <CapabilityBanner item={props.item as Extract<TranscriptItem, { kind: "capability" }>} />
      </Match>
      <Match when={props.item.kind === "unknown"}>
        <UnknownCard item={props.item as UnknownItem} />
      </Match>
    </Switch>
  )
}

/**
 * An event kind this build predates. Showing it raw beats hiding it: the ledger
 * alphabet is append-only (DESIGN §3.1), so an unknown kind means the TUI is
 * older than the kernel, not that something went wrong.
 */
function UnknownCard(props: { item: UnknownItem }) {
  const style = useStyle()
  return (
    <box flexDirection="column" width="100%" paddingLeft={2}>
      <text fg={style.theme.dim}>? {props.item.eventKind}</text>
      <box paddingLeft={2}>
        <text fg={style.theme.dim}>{props.item.raw}</text>
      </box>
    </box>
  )
}
