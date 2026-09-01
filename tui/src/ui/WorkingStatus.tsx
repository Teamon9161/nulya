/**
 * The one line above the composer that says what is happening right now.
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
import { lifted, onClick } from "./rows.ts"
import { displayWidth, fit } from "./columns.ts"
import { seconds } from "../state/tasks.ts"
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
   * would outlive the step anyway.
   */
  cancelable?: boolean
  /** The one entry here that is a place rather than a state: `/tasks`. */
  opens?: "tasks"
  /**
   * How many background tasks are running, alongside whatever else `text`
   * says (tasks panel). Kept off `text` on purpose: a count folded into
   * the sentence would fight the step's own words for the same columns, and
   * it needs its own click zone regardless of what is currently in flight —
   * a foreground step and a background task are two different things
   * happening at once, and the step being cancelable does not make the task
   * one too. `undefined` when there are none, so a session with no
   * background task costs no column: nothing at rest draws nothing.
   */
  background?: number
  /**
   * When THIS activity began, when that is not the driver's own clock. A step
   * is the usual case and the caller passes `attach.startedAt()` for it; work
   * that is not a step (the start-up extension pass) has its own start and
   * would otherwise borrow the clock of a session that has not begun.
   */
  since?: number
}

/**
 * A store pass in flight: which draft it is on, and how far along it is.
 *
 * It is here rather than in a notice because a notice is news that covers
 * the row and then takes itself down (`noticeHold`, three seconds
 * at the floor). The kernel reports a draft when that draft FINISHES, so a
 * compiled one holds the count still for as long as zig takes — a notice
 * would expire mid-build and leave the screen quiet for the rest of a minute,
 * which is exactly the state a person reads as "nothing is happening". Progress is
 * not news; it is what is happening, and that is this line.
 */
export interface SyncProgress {
  /** The whole phrase, already built by the caller: `building std`. */
  what: string
  /** Drafts finished, and how many the plan found. `total = 0` prints no count. */
  done: number
  total: number
  since: number
}

/**
 * What part of the current step the user is waiting on. `activeTool` is still
 * the kernel's direct "executor is inside this call" signal; the transcript
 * tail fills in the two gaps around it: while the model is still spelling out a
 * call, and while the just-finished result is being committed before the next
 * model turn starts.
 */
export function stepActivity(snapshot: SessionSnapshot): string {
  if (snapshot.activeTool) return `running ${snapshot.activeTool}`
  for (let i = snapshot.items.length - 1; i >= 0; i--) {
    const item = snapshot.items[i]!
    if (item.kind === "tool" && !item.resolved) {
      const tool = item.tool || "tool"
      if (item.state === "running") return `running ${tool}`
      if (item.state === "done") return `recording ${tool} result`
      return `preparing ${tool}`
    }
    if (item.seq !== null) break
    if (item.kind === "assistant" && item.text.length > 0) return "responding"
    if (item.kind === "thinking" && item.text.length > 0) return "thinking"
  }
  return "waiting for model"
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
  syncing?: SyncProgress | null
}): Activity | null {
  // Every branch below but the last one is about something OTHER than the
  // background count, and a background task does not stop existing just
  // because a step started — so whatever this function is about to say, the
  // count rides along beside it (tasks panel). The last branch is where
  // the count IS the whole sentence, and does not need to say itself twice.
  const withBackground = (activity: Activity): Activity =>
    facts.background > 0 ? { ...activity, background: facts.background } : activity
  // The kernel is stopped on a call, waiting for a verdict. It
  // outranks everything: nothing else can be happening while it is true.
  if (facts.awaiting) return withBackground({ text: "waiting for your answer", tone: "warn", moving: false })
  // The message is in the transcript in full (`ErrorNotice`); this is the
  // pointer to it, for when the transcript has been scrolled away.
  if (facts.snapshot.error) return withBackground({ text: "error · see transcript", tone: "err", moving: false })
  if (facts.role === "observer") {
    if (facts.takeoverReady) return withBackground({ text: "press ↵ to take over", tone: "warn", moving: false })
    if (facts.status === "sending") {
      return withBackground({ text: "queued for the other writer", tone: "run", moving: true })
    }
    // Following is not an activity — it is what this tab IS, and the row under
    // the composer says so on its right.
    return null
  }
  if (facts.status === "canceling") return withBackground({ text: "canceling", tone: "run", moving: true })
  // The live phase of a step: model request, streamed answer, streamed tool
  // call, executor, or result commit. `activeTool` alone only covered the
  // executor and made every other part read as generic thinking.
  if (facts.status === "stepping") {
    return withBackground({ text: stepActivity(facts.snapshot), tone: "run", moving: true, cancelable: true })
  }
  if (facts.status === "sending") return withBackground({ text: "sending", tone: "run", moving: true })
  if (facts.snapshot.lastStopped === "budget") {
    return withBackground({ text: "step budget spent · /step to continue", tone: "warn", moving: false })
  }
  if (facts.snapshot.lastStopped === "max_tokens") {
    return withBackground({
      text: "reply cut off (max_tokens) · send a message to continue",
      tone: "warn",
      moving: false,
    })
  }
  // Below every row above it on purpose: a store pass never blocks the
  // conversation, so a step in flight, a spent budget or a waiting approval is
  // always the more useful thing to be told. It outranks `background` only
  // because it is the one of the two a person is likely to be waiting on before
  // the first message.
  if (facts.syncing) {
    const { what, done, total, since } = facts.syncing
    return withBackground({
      text: total > 0 ? `${what} (${done}/${total})` : what,
      tone: "run",
      moving: true,
      since,
    })
  }
  // Last, and only when nothing else is running: a detached command outlives
  // the step that started it, so an idle driver with one going is the one case
  // where saying nothing would be a lie. The count IS the text
  // here, so it does not also ride in `background`: nothing is said twice.
  if (facts.background > 0) {
    return { text: `${facts.background} background`, tone: "run", moving: true, opens: "tasks" }
  }
  return null
}

/**
 * How long this has been going on, in the ONE format this front end uses for a
 * duration (`state/tasks.seconds`).
 *
 * It used to have its own — `1m40s` here, `1m 40s` in `/tasks` and on a
 * background card's note — which is two spellings of the same fact on two rows
 * of the same screen. The kernel's own `41.8s` on a finished task's report is
 * quoted, not reformatted; everything we count ourselves counts the same way.
 */
export function elapsedLabel(ms: number): string {
  return seconds(Math.max(0, Math.floor(ms / 1000)))
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
  /**
   * What this session has cost so far (`state/session.usageLabel`), or absent
   * before it has cost anything. It rides the line that is only up while
   * something is running: a total is worth reading while it moves, and
   * the row under the composer — where it used to stand all day — is a
   * description of the session, not a meter.
   */
  usage?: string | null
  onOpenTasks?: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [over, setOver] = createSignal(false)
  const tasksClick = onClick(() => props.onOpenTasks?.())
  const [bgOver, setBgOver] = createSignal(false)
  const bgClick = onClick(() => props.onOpenTasks?.())

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
   * The dim tail: how long, the key that stops it, and what it has cost.
   *
   * The clock goes with anything in flight; the offer goes with `cancelable`
   * alone, because `esc to cancel` over `2 background` or a queued observer
   * append names a key that would open browse mode instead. The cost comes
   * last of the three because the tail is cut from the end when the terminal is
   * narrow, and that is the order these are worth losing in.
   */
  const tail = () => {
    const activity = props.activity
    if (!activity || !activity.moving) return ""
    // The activity's own clock when it has one: work that is not a step starts
    // at a moment the driver knows nothing about (`Activity.since`).
    const since = activity.since ?? props.since
    const age = since ? ` · ${elapsedLabel((props.now ?? Date.now()) - since)}` : ""
    const esc = activity.cancelable ? " · esc to cancel" : ""
    const spent = props.usage ? ` · ${props.usage}` : ""
    return `${age}${esc}${spent}`
  }

  /**
   * The background count, said beside whatever else this line is about
   * (tasks panel) — its own segment rather than a fourth thing packed
   * into `tail()`, because it answers to a click and the rest of the tail
   * does not.
   */
  const bgText = () => (props.activity?.background ? ` · ${props.activity.background} background` : "")
  const bgClickable = () => (props.activity?.background ?? 0) > 0 && props.onOpenTasks !== undefined

  /**
   * Cut to one row: a tool name is as long as whoever wrote it made it. Lead
   * gets first claim on the width, then the dim tail, then the background
   * segment last — the same "worth losing in this order" the tail's own
   * comment states, one step further down.
   */
  const room = () => Math.max(8, screen().width - 4)
  const lead = () => fit(head(), Math.max(4, room() - displayWidth(tail()) - displayWidth(bgText())))
  const cells = () => Array.from(lead())
  const clickable = () => props.activity?.opens === "tasks" && props.onOpenTasks !== undefined
  const tailFit = () => fit(tail(), Math.max(0, room() - displayWidth(lead())))
  const bgFit = () => fit(bgText(), Math.max(0, room() - displayWidth(lead()) - displayWidth(tailFit())))

  return (
    <Show when={props.activity}>
      <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={2} paddingRight={1}>
        <box
          flexShrink={0}
          height={1}
          onMouseDown={clickable() ? tasksClick.onMouseDown : undefined}
          onMouseUp={clickable() ? tasksClick.onMouseUp : undefined}
          onMouseOver={() => setOver(true)}
          onMouseOut={() => setOver(false)}
        >
          {/* One cell, one `<text>`, so the band can cross the line while each
              character keeps its own colour underneath it. (`<span fg>` is the
              obvious way and does nothing in @opentui/solid — the prop is
              dropped and the whole run comes out in one colour; checked again
              on 0.5.9, where two `<span fg>` still land as one white span.) `Index` and not
              `For`: the positions are fixed and the characters change, which is
              the case those two are named for. At rest — and under
              `motion = false` — every cell is exactly `base()`, so the still
              version is this line without the animation, not another one. */}
          <box flexDirection="row" flexShrink={0} height={1}>
            <Index each={cells()}>
              {(ch, index) => (
                <text
                  fg={lifted(
                    style,
                    clickable() && over(),
                    props.activity?.moving && style.motion
                      ? shimmerColor(props.frame, index, cells().length, base(), style.theme.lift)
                      : base(),
                  )}
                >
                  {ch()}
                </text>
              )}
            </Index>
          </box>
        </box>
        <text fg={style.theme.dim} flexShrink={1}>
          {tailFit()}
        </text>
        {/* The background count's own click zone, separate from the tail's
            plain text: a foreground step and a background task coexist, and
            only this segment should answer to a click while one does
            (T87 tasks panel). Same shape as the status row's `tools 1+N`
            chip (`StatusBar.tsx`) — a `·` the click does not own, then a box
            that does. */}
        <Show when={bgFit().length > 0}>
          <box
            flexShrink={0}
            height={1}
            onMouseDown={bgClickable() ? bgClick.onMouseDown : undefined}
            onMouseUp={bgClickable() ? bgClick.onMouseUp : undefined}
            onMouseOver={() => setBgOver(true)}
            onMouseOut={() => setBgOver(false)}
          >
            <text fg={lifted(style, bgClickable() && bgOver(), style.theme.dim)}>{bgFit()}</text>
          </box>
        </Show>
      </box>
    </Show>
  )
}
