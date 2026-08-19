import { Match, Show, Switch } from "solid-js"
import { UserTurn } from "./UserTurn.tsx"
import { CompactionCard } from "./CompactionCard.tsx"
import { compactionMarker } from "../../compact.ts"
import { SkillEchoCard } from "./SkillEchoCard.tsx"
import { skillEchoOf } from "../../skills.ts"
import { midTaskOf } from "../../midtask.ts"
import { AssistantTurn } from "./AssistantTurn.tsx"
import { Thinking } from "./Thinking.tsx"
import { ToolCard } from "./ToolCard.tsx"
import { ApprovalPrompt } from "./ApprovalPrompt.tsx"
import { CapabilityBanner } from "./CapabilityBanner.tsx"
import { useStyle } from "../theme.ts"
import type { TranscriptItem, UnknownItem } from "../../state/session.ts"

/**
 * One transcript item → one card. Live and replay both come through here, so a
 * card can never depend on having seen the stream (tui.md §3).
 */
export function Card(props: {
  item: TranscriptItem
  /** The call whose denial is waiting for a typed reason, if any (tui.md §5.7). */
  noteWanted?: string | null
}) {
  return (
    <Switch>
      {/* Compaction's two turns are user turns as far as the ledger is
          concerned; only their content says otherwise (`compact.ts`). */}
      <Match when={props.item.kind === "user" && compactionMarker(props.item) !== null}>
        <CompactionCard
          item={props.item as Extract<TranscriptItem, { kind: "user" }>}
          role={compactionMarker(props.item)!}
        />
      </Match>
      {/* A `/name` that loaded a skill: also an ordinary user turn, folded back
          down from its sentinel alone (`skills.ts`). */}
      <Match when={skillEchoOf(props.item) !== null}>
        <SkillEchoCard
          item={props.item as Extract<TranscriptItem, { kind: "user" }>}
          echo={skillEchoOf(props.item)!}
        />
      </Match>
      {/* Typed while a run was in flight: the ledger keeps the sentinel and the
          interrupt contract; the person reads their own words (`midtask.ts`). */}
      <Match when={midTaskOf(props.item) !== null}>
        <UserTurn
          item={props.item as Extract<TranscriptItem, { kind: "user" }>}
          text={midTaskOf(props.item)!.text}
          badge="sent mid-task"
        />
      </Match>
      <Match when={props.item.kind === "user"}>
        <UserTurn item={props.item as Extract<TranscriptItem, { kind: "user" }>} />
      </Match>
      <Match when={props.item.kind === "assistant"}>
        <AssistantTurn item={props.item as Extract<TranscriptItem, { kind: "assistant" }>} />
      </Match>
      <Match when={props.item.kind === "thinking"}>
        <Thinking item={props.item as Extract<TranscriptItem, { kind: "thinking" }>} />
      </Match>
      {/* A call the kernel is holding open for a verdict (tui.md §5.7): the card
          as usual, plus the one line that says the keys. */}
      <Match when={props.item.kind === "tool"}>
        <box flexDirection="column" width="100%">
          <ToolCard item={props.item as Extract<TranscriptItem, { kind: "tool" }>} />
          <Show when={(props.item as Extract<TranscriptItem, { kind: "tool" }>).awaiting}>
            <ApprovalPrompt
              item={props.item as Extract<TranscriptItem, { kind: "tool" }>}
              note={props.noteWanted === (props.item as Extract<TranscriptItem, { kind: "tool" }>).callId}
            />
          </Show>
        </box>
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
