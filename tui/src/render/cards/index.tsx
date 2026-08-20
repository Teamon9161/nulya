import { Match, Show, Switch } from "solid-js"
import { UserTurn } from "./UserTurn.tsx"
import { CompactionCard } from "./CompactionCard.tsx"
import { compactionMarker } from "../../compact.ts"
import { SkillEchoCard } from "./SkillEchoCard.tsx"
import { skillEchoOf } from "../../skills.ts"
import { midTaskOf } from "../../midtask.ts"
import { approvalNoteOf } from "../../approvalnote.ts"
import { extNoteBadge, extNoteOf } from "../../extnote.ts"
import { AssistantTurn } from "./AssistantTurn.tsx"
import { Thinking } from "./Thinking.tsx"
import { ToolCard } from "./ToolCard.tsx"
import { ApprovalPrompt } from "./ApprovalPrompt.tsx"
import { CapabilityBanner } from "./CapabilityBanner.tsx"
import { TaskFinishedCard } from "./TaskFinishedCard.tsx"
import { useStyle } from "../theme.ts"
import type { TranscriptItem, UnknownItem } from "../../state/session.ts"
import type { Contributions } from "../../nulya/files.ts"

/**
 * One transcript item → one card. Live and replay both come through here, so a
 * card can never depend on having seen the stream (tui.md §3).
 */
export function Card(props: { item: TranscriptItem; contributions?: Contributions[] }) {
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
      {/* Said while approving a call: same shape as a mid-task message, and
          checked first because it IS one — a more specific one, whose badge
          names the call it was about (`approvalnote.ts`). */}
      <Match when={approvalNoteOf(props.item) !== null}>
        <UserTurn
          item={props.item as Extract<TranscriptItem, { kind: "user" }>}
          text={approvalNoteOf(props.item)!.text}
          badge={`note on ${approvalNoteOf(props.item)!.tool}`}
        />
      </Match>
      {/* Assembled by a plugin on the person's behalf (`extnote.ts`, tui-plugin
          D5). Its badge names the package, because a block of text a package
          composed is not the same thing as a person typing it — and the
          transcript is the one place that distinction survives a replay. */}
      <Match when={extNoteOf(props.item) !== null}>
        <UserTurn
          item={props.item as Extract<TranscriptItem, { kind: "user" }>}
          text={extNoteOf(props.item)!.text}
          badge={extNoteBadge(extNoteOf(props.item)!)}
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
          as usual, plus the mark that says this is the one being asked about.
          The keys are above the composer, where the answer is given. */}
      <Match when={props.item.kind === "tool"}>
        <box flexDirection="column" width="100%">
          <ToolCard
            item={props.item as Extract<TranscriptItem, { kind: "tool" }>}
            contributions={props.contributions}
          />
          <Show when={(props.item as Extract<TranscriptItem, { kind: "tool" }>).awaiting}>
            <ApprovalPrompt />
          </Show>
        </box>
      </Match>
      <Match when={props.item.kind === "capability"}>
        <CapabilityBanner item={props.item as Extract<TranscriptItem, { kind: "capability" }>} />
      </Match>
      {/* A background command ended (tui.md §5.9): its own event, its own card,
          and the shell call that started it has already said what it is. */}
      <Match when={props.item.kind === "task"}>
        <TaskFinishedCard item={props.item as Extract<TranscriptItem, { kind: "task" }>} />
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
