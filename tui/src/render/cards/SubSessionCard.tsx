import { createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { ShellOutput } from "./ShellCard.tsx"
import { splitShellOutput, startedTaskOf } from "../../nulya/ledger.ts"
import { backgroundNote, useTasks } from "../../state/tasks.ts"
import { useNavigate } from "../../state/navigate.ts"
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
 * in the ledger.
 *
 * TWO, IT CAN BE OPENED. `Enter` in browse mode has opened the named session
 * since T3 and nothing on screen said so — an affordance three keystrokes deep
 * and undocumented is not one. The link is a row under the head line, outside
 * the fold, so it is there whether or not the body is; it opens the same tab
 * the same way (`state/navigate.ts`), and following it is how you watch a
 * delegation work rather than waiting for its report.
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
    if (started) return backgroundNote(started, props.item.taskResult, tasks())
    // `nulya session new` and the like: an action that already happened, and a
    // successful one says nothing (T26).
    const exit = shell().exit
    if (exit !== null && exit !== 0) return { text: `exit ${exit}`, failed: true }
    return { text: props.item.ok === false ? "failed" : "", failed: props.item.ok === false }
  })

  const session = () => props.presentation.sessionId

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
      // No session, no link: until the call returns there is no id to open, and
      // a link to nowhere is worse than no link.
      action={
        navigate && session()
          ? { text: `open ${session()} in a tab`, onPress: () => navigate.openSession(session()!) }
          : null
      }
    >
      <ShellOutput output={props.item.output} />
    </CardFrame>
  )
}
