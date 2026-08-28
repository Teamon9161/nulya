import { createMemo, createResource } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { ShellOutput } from "./ShellCard.tsx"
import { splitShellOutput, startedTaskOf } from "../../nulya/ledger.ts"
import { backgroundNote, useTasks } from "../../state/tasks.ts"
import { useNavigate } from "../../state/navigate.ts"
import { agentTaskExcerptOf } from "../registry.ts"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * A call that opened a session of its own: a delegation, or `nulya session new`
 * through `shell` (tui.md §5.5, §5.10).
 *
 * It used to be an `EvolveCard` — the right picture for `session new`, and
 * half a picture for a delegation, because a delegation is not an action that
 * FINISHED. The call returns a receipt: somewhere else, a background task is
 * driving a session that will report back later. Two things follow, and they
 * are this card (T43).
 *
 * ONE, IT SAYS HOW IT IS GOING. The note is the same reading a background
 * `shell` gets (`state/tasks.ts`): the ledger's report once it has landed,
 * otherwise the live projection with the seconds on it. So `running 42s`
 * becomes `exit 0 · 41.8s` without anything being asked of the sub-agent, and
 * a session reopened tomorrow shows the same words, because by then the fact is
 * in the ledger. For a delegation specifically the note leaves the task's full
 * name (`<sid>/tN`) out (`backgroundNote(…, {showTask: false})`) — the head
 * line above it already says which agent and what for, and a `shell`
 * background call's row is the one place that handle is worth printing (it is
 * what `nulya task status` wants).
 *
 * TWO, IT CAN BE OPENED. `Enter` in browse mode has opened the named session
 * since T3 and nothing on screen said so — an affordance three keystrokes deep
 * and undocumented is not one. The link is a row under the head line, outside
 * the fold, so it is there whether or not the body is; it opens the same tab
 * the same way (`state/navigate.ts`), and following it is how you watch a
 * delegation work rather than waiting for its report.
 *
 * THREE, SINCE ar-t2, THE CARD KNOWS THE DELEGATION'S OWN `d-…` ID. Every
 * runner mints one (goals/agent-runner.md D2); only `nulya` also opens a local
 * session a tab can show, and only the FIRST delegate() receipt says so out
 * loud (`registry.ts`'s extraction). A follow-up turn's reply never repeats
 * it, so the link falls back to the delegation's own record
 * (`nulya/files.ts`'s `readDelegationRecord`) — and when that record names a
 * runner that is not `nulya`, there is no local session to open at all, and
 * the row says so rather than guessing at one. Neither id, though, is what
 * this card SAYS: `d-2c450129452b` tells a person nothing, so the head line
 * names the agent and its task instead (`registry.ts`'s `describeTool`), and
 * the watch link and the tab it opens follow suit — see FOUR.
 */
export function SubSessionCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const tasks = useTasks()
  const navigate = useNavigate()
  const shell = createMemo(() => splitShellOutput(props.item.output))
  const task = createMemo(() => startedTaskOf(props.item.output))

  const note = createMemo(() => {
    if (props.item.state === "pending") return { text: "…", failed: false }
    if (props.item.state === "running") return { text: "starting", failed: false }
    const started = task()
    // Reaching this branch at all means the receipt named a background task —
    // which only a delegation's does, here (a `shell {background: true}` call
    // draws through `ShellCard` instead) — so the task's full name is left out
    // (see ONE, above): the head line already says which agent and what for.
    if (started) return backgroundNote(started, props.item.taskResult, tasks(), { showTask: false })
    // `nulya session new` and the like: an action that already happened, and a
    // successful one says nothing (T26).
    const exit = shell().exit
    if (exit !== null && exit !== 0) return { text: `exit ${exit}`, failed: true }
    return { text: props.item.ok === false ? "failed" : "", failed: props.item.ok === false }
  })

  const session = () => props.presentation.sessionId
  const delegation = () => props.presentation.delegationId ?? null
  /** What this delegation was told to do, cut for a label — null for a plain `nulya session new`/`session step` call, which names no task. */
  const taskExcerpt = () => agentTaskExcerptOf(props.item.args)

  /**
   * The delegation's record, read only when the receipt itself named no
   * remote — a follow-up's reply, or a "busy, queued" reply, neither of which
   * repeats what the delegation opened. `navigate` is null in a screen with no
   * tabs and its `delegationRecord` resolves to null with no workspace behind
   * it (a render test with a bare `NavigateContext`); either way there is
   * nothing to read.
   */
  const [record] = createResource(
    () => (session() === null && delegation() !== null ? delegation() : null),
    (id) => navigate?.delegationRecord(id) ?? Promise.resolve(null),
  )

  const remote = () => session() ?? record()?.remote ?? null
  const foreignRunner = () => {
    const found = record()
    return found != null && found.runner !== "nulya"
  }

  const action = createMemo(() => {
    if (!navigate) return null
    // Whatever the runner opened is not a nulya session, so there is no tab to
    // offer — the log its own task writes to is the one place to watch it
    // (D10's readonly ceiling makes the same call one door over: a fact this
    // package cannot translate is said plainly rather than guessed at).
    if (foreignRunner()) {
      return { text: `see its log in /tasks (runner: ${record()!.runner})`, onPress: () => navigate.openTasks() }
    }
    const target = remote()
    // No session, no link: until it is known there is nothing to open, and a
    // link to nowhere is worse than no link.
    if (!target) return null
    /**
     * FOUR, SINCE T72 IT OPENS BESIDE THIS CONVERSATION, NOT INSTEAD OF IT.
     * A delegation is subordinate to the turn that made it, and a tab of its
     * own said the opposite — a peer on the strip, with nothing on screen
     * relating the two. So the one row this card offers is the one gesture
     * people make ("let me watch that"), and it splits the tab.
     *
     * The tab is still reachable and is deliberately NOT a second row here:
     * a card would then carry two links of near-identical text for one
     * destination, on every delegation in the transcript. It is `t` in browse
     * mode instead — the same word `/sessions` already uses for "and give it
     * a tab" (T70), so the vocabulary is one and the rare gesture costs no
     * pixels.
     *
     * The row's text carries no id — `watch here`, not `watch d-… here` —
     * for the same reason the head line above it does not (THREE). The label
     * the pane opens WITH is the task excerpt, not the id either: the pane's
     * own attribution line already reads the agent's name from the watched
     * session's own header (`SubAgentPane`'s `personaOf`), so pairing it with
     * the task says what a `d-…` never could, and repeating the agent's name
     * a second time would not.
     */
    return {
      text: "watch here",
      onPress: () => navigate.watchSession(target, taskExcerpt() ?? delegation() ?? undefined),
    }
  })

  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={props.presentation.glyph}
      accent={style.theme.accent.evolve}
      head={props.presentation.head}
      chip={note().text}
      chipTone={note().failed ? "err" : "dim"}
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      foldable={props.item.output.length > 0}
      spillPath={props.item.spillPath}
      action={action()}
    >
      <ShellOutput output={props.item.output} />
    </CardFrame>
  )
}
