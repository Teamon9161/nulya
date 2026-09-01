import { Match, Show, Switch, createMemo } from "solid-js"
import { UserTurn } from "./UserTurn.tsx"
import { PluginUserTurnCard } from "./PluginUserTurnCard.tsx"
import { usePlugins } from "../../plugins/context.ts"
import { SkillEchoCard } from "./SkillEchoCard.tsx"
import { skillEchoOf } from "../../skills.ts"
import { midTaskOf } from "../../midtask.ts"
import { approvalNoteOf } from "../../approvalnote.ts"
import { taskStoppedNoteOf } from "../../taskstop.ts"
import { extNoteBadge, extNoteOf } from "../../extnote.ts"
import { AssistantTurn } from "./AssistantTurn.tsx"
import { Thinking } from "./Thinking.tsx"
import { ToolCard } from "./ToolCard.tsx"
import { ApprovalPrompt, AutoAllowedMark } from "./ApprovalPrompt.tsx"
import { CapabilityBanner } from "./CapabilityBanner.tsx"
import { TaskFinishedCard } from "./TaskFinishedCard.tsx"
import { RebindCard } from "./RebindCard.tsx"
import { useStyle } from "../theme.ts"
import type { TranscriptItem, UnknownItem } from "../../state/session.ts"
import type { Contributions } from "../../nulya/files.ts"

/**
 * One transcript item → one card. Live and replay both come through here, so a
 * card can never depend on having seen the stream.
 */
export function Card(props: { item: TranscriptItem; contributions?: Contributions[]; capabilityPreviousVersion?: string | null; highlightedCallId?: string | null }) {
  const plugins = usePlugins()
  const pluginUserTurn = createMemo(() =>
    props.item.kind === "user" ? plugins?.userTurnFor(props.item.text) ?? null : null,
  )
  return (
    <Switch>
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
      {/* A background task's stop button, pressed on screen (`taskstop.ts`):
          the TUI attesting to who asked for the kill, not the person typing —
          checked beside the approval note for the same reason it exists. */}
      <Match when={taskStoppedNoteOf(props.item) !== null}>
        <UserTurn
          item={props.item as Extract<TranscriptItem, { kind: "user" }>}
          text={taskStoppedNoteOf(props.item)!.text}
          badge="stopped from the TUI"
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
      <Match when={props.item.kind === "user" && pluginUserTurn() !== null}>
        <PluginUserTurnCard
          item={props.item as Extract<TranscriptItem, { kind: "user" }>}
          registration={pluginUserTurn()!}
          revision={plugins?.revision() ?? 0}
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
      {/* A call the kernel is holding open for a verdict: the card
          as usual, plus the mark that says this is the one being asked about.
          The keys are above the composer, where the answer is given. */}
      <Match when={props.item.kind === "tool"}>
        <box flexDirection="column" width="100%">
          <ToolCard
            item={props.item as Extract<TranscriptItem, { kind: "tool" }>}
            contributions={props.contributions}
            highlighted={(props.item as Extract<TranscriptItem, { kind: "tool" }>).callId === props.highlightedCallId}
          />
          <Show when={(props.item as Extract<TranscriptItem, { kind: "tool" }>).awaiting}>
            <ApprovalPrompt />
          </Show>
          {/* Or the opposite mark: the gate answered for the person because the
              command only reads. Never both — a call is either being asked
              about or was not asked about. */}
          <Show when={(props.item as Extract<TranscriptItem, { kind: "tool" }>).autoAllowed}>
            <AutoAllowedMark />
          </Show>
        </box>
      </Match>
      <Match when={props.item.kind === "capability"}>
        <CapabilityBanner
          item={props.item as Extract<TranscriptItem, { kind: "capability" }>}
          previousVersion={props.capabilityPreviousVersion}
        />
      </Match>
      {/* A background command ended: its own event, its own card,
          and the call that started it has already said what it is. */}
      <Match when={props.item.kind === "task"}>
        <TaskFinishedCard item={props.item as Extract<TranscriptItem, { kind: "task" }>} />
      </Match>
      {/* Not a turn at all: the boundary between two models answering the same
          conversation. */}
      <Match when={props.item.kind === "rebind"}>
        <RebindCard item={props.item as Extract<TranscriptItem, { kind: "rebind" }>} />
      </Match>
      <Match when={props.item.kind === "unknown"}>
        <UnknownCard item={props.item as UnknownItem} />
      </Match>
    </Switch>
  )
}

/**
 * An event kind this build predates. Showing it raw beats hiding it: the ledger
 * alphabet is append-only, so an unknown kind means the TUI is
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
