/**
 * The one line above the composer that says what is happening right now
 * (tui.md §4.4b, §11 T38).
 *
 * It exists because "what is happening" and "what this session is" are two
 * different questions, and they were sharing one row. The row under the
 * composer is a standing description — mode, model, face, cost — and a
 * description is read once and then trusted; an activity is read again every
 * second it lasts. Putting `⠋ shell` at the tail of that row meant the live
 * fact was the one thing on screen with the least room and the least contrast,
 * and it also meant the row had to keep a slot for `idle` — a word whose whole
 * content is that there was nothing to say.
 *
 * So: nothing at rest (the line is not there at all), and while something IS
 * happening, a line of its own directly above the box you are typing in, in
 * the colour of what it is, with a soft band sweeping along it
 * (`shimmerColor`). The movement is the point — a spinner says the frontend is
 * alive, the sweep says the LINE is — and it is exactly what `motion = false`
 * turns off.
 */
import { Index, Show, createSignal } from "solid-js"
import { shimmerColor, useScreen, useStyle } from "../render/theme.ts"
import { onClick } from "./rows.ts"
import { displayWidth, fit } from "./columns.ts"
import type { DriverStatus } from "../state/driver.ts"
import type { Role } from "../state/attach.ts"
import type { SessionSnapshot } from "../state/session.ts"

/**
 * What the line says, and how it should carry itself.
 *
 * `moving` is the whole distinction between the two kinds of thing that can be
 * on this line: work in flight (it sweeps) and a state waiting for a person (it
 * sits still). A shimmer over `step budget spent` would be an animation about
 * nothing happening.
 */
export interface Activity {
  text: string
  tone: "run" | "warn" | "err"
  moving: boolean
  /**
   * Esc really stops this: the step THIS tab is driving. `moving` alone is not
   * it — an observer's queued append and an idle tab's background tasks are in
   * flight, but Esc over them enters browse mode, and a background command
   * would outlive the step anyway (tui.md §5.9).
   */
  cancelable?: boolean
  /** The one entry here that is a place rather than a state: `/tasks`. */
  opens?: "tasks"
}

/**
 * The activity, from the facts — a pure function, so the rules are testable and
 * live in one place instead of in a chain of ternaries inside a render.
 *
 * `null` means the line is not drawn at all. Everything that is merely a
 * resting state resolves to null: idle, a step that finished, one that was
 * canceled. What survives is work in flight, and the states that are waiting
 * for the person to do something about them.
 */
export function activityOf(facts: {
  status: DriverStatus
  role: Role
  snapshot: SessionSnapshot
  takeoverReady: boolean
  awaiting: boolean
  background: number
}): Activity | null {
  // The kernel is stopped on a call, waiting for a verdict (tui.md §5.7). It
  // outranks everything: nothing else can be happening while it is true.
  if (facts.awaiting) return { text: "waiting for your answer", tone: "warn", moving: false }
  // The message is in the transcript in full (`ErrorNotice`); this is the
  // pointer to it, for when the transcript has been scrolled away.
  if (facts.snapshot.error) return { text: "error · see transcript", tone: "err", moving: false }
  if (facts.role === "observer") {
    if (facts.takeoverReady) return { text: "press ↵ to take over", tone: "warn", moving: false }
    if (facts.status === "sending") return { text: "queued for the other writer", tone: "run", moving: true }
    // Following is not an activity — it is what this tab IS, and the row under
    // the composer says so on its right.
    return null
  }
  if (facts.status === "canceling") return { text: "canceling", tone: "run", moving: true }
  // The tool that is running, or the model itself when none is: the two halves
  // of a step, and which one is being waited on is the whole question.
  if (facts.status === "stepping") {
    return { text: facts.snapshot.activeTool ?? "thinking", tone: "run", moving: true, cancelable: true }
  }
  if (facts.status === "sending") return { text: "sending", tone: "run", moving: true }
  if (facts.snapshot.lastStopped === "budget") {
    return { text: "step budget spent · /step to continue", tone: "warn", moving: false }
  }
  if (facts.snapshot.lastStopped === "max_tokens") {
    return { text: "reply cut off (max_tokens) · send a message to continue", tone: "warn", moving: false }
  }
  // Last, and only when nothing else is running: a detached command outlives
  // the step that started it, so an idle driver with one going is the one case
  // where saying nothing would be a lie (tui.md §5.9).
  if (facts.background > 0) {
    return { text: `${facts.background} background`, tone: "run", moving: true, opens: "tasks" }
  }
  return null
}

/** `12s`, `1m40s` — how long this has been going on. */
export function elapsedLabel(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000))
  if (total < 60) return `${total}s`
  return `${Math.floor(total / 60)}m${String(total % 60).padStart(2, "0")}s`
}

export function WorkingStatus(props: {
  activity: Activity | null
  /** Monotonic animation frame: the spinner's tick drives the sweep too. */
  frame: number
  spinnerFrame: string
  /** When the run began, for the elapsed clock; absent = do not say. */
  since?: number | null
  /** Read from the caller so the clock advances on the same tick as the sweep. */
  now?: number
  onOpenTasks?: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [over, setOver] = createSignal(false)
  const tasksClick = onClick(() => props.onOpenTasks?.())

  const base = () => {
    switch (props.activity?.tone) {
      case "err":
        return style.theme.err
      case "warn":
        return style.theme.warn
      default:
        // Work in flight is the assistant's turn happening — the same green
        // that marks its cards in the transcript, not a warning colour. Amber
        // is kept for the two states that are waiting on the person.
        return style.theme.accent.assistant
    }
  }

  /** The lead: the spinner only for the things that are actually moving. */
  const head = () => {
    const activity = props.activity
    if (!activity) return ""
    return activity.moving && style.motion ? `${props.spinnerFrame} ${activity.text}` : activity.text
  }

  /**
   * The dim tail: how long, and — only when Esc would actually stop it — the
   * key that does. The clock goes with anything in flight; the offer goes with
   * `cancelable` alone, because `esc to cancel` over `2 background` or a queued
   * observer append names a key that would open browse mode instead.
   */
  const tail = () => {
    const activity = props.activity
    if (!activity || !activity.moving) return ""
    const since = props.since
    const age = since ? ` · ${elapsedLabel((props.now ?? Date.now()) - since)}` : ""
    return activity.cancelable ? `${age} · esc to cancel` : age
  }

  /** Cut to one row: a tool name is as long as whoever wrote it made it. */
  const room = () => Math.max(8, screen().width - 4)
  const lead = () => fit(head(), Math.max(4, room() - displayWidth(tail())))
  const cells = () => Array.from(lead())
  const clickable = () => props.activity?.opens === "tasks" && props.onOpenTasks !== undefined

  return (
    <Show when={props.activity}>
      <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={2} paddingRight={1}>
        <box
          flexShrink={0}
          height={1}
          backgroundColor={clickable() && over() ? style.theme.hover : undefined}
          onMouseDown={clickable() ? tasksClick.onMouseDown : undefined}
          onMouseUp={clickable() ? tasksClick.onMouseUp : undefined}
          onMouseOver={() => setOver(true)}
          onMouseOut={() => setOver(false)}
        >
          {/* One cell, one `<text>`, so the band can cross the line while each
              character keeps its own colour underneath it. (`<span fg>` is the
              obvious way and does nothing in @opentui/solid 0.5.3 — the prop is
              dropped and the whole run comes out in one colour.) `Index` and not
              `For`: the positions are fixed and the characters change, which is
              the case those two are named for. At rest — and under
              `motion = false` — every cell is exactly `base()`, so the still
              version is this line without the animation, not another one. */}
          <box flexDirection="row" flexShrink={0} height={1}>
            <Index each={cells()}>
              {(ch, index) => (
                <text
                  fg={
                    props.activity?.moving && style.motion
                      ? shimmerColor(props.frame, index, cells().length, base(), style.theme.lift)
                      : base()
                  }
                >
                  {ch()}
                </text>
              )}
            </Index>
          </box>
        </box>
        <text fg={style.theme.dim} flexShrink={1}>
          {fit(tail(), Math.max(0, room() - displayWidth(lead())))}
        </text>
      </box>
    </Show>
  )
}
