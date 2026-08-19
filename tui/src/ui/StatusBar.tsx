import { Show, createMemo, createSignal } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { onClick } from "./rows.ts"
import { displayWidth, fit } from "./columns.ts"
import { builtin_tools } from "../pins.ts"
import type { SessionSnapshot } from "../state/session.ts"
import type { DriverStatus } from "../state/driver.ts"
import type { Role } from "../state/attach.ts"
import type { PermissionMode } from "../approvals.ts"

function compact(n: number): string {
  if (n < 1000) return String(n)
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`
  return `${(n / 1_000_000).toFixed(1)}M`
}

/**
 * The one line under the composer (tui.md §4.1, §4.5, §11 T22): what this
 * session runs on, what its face carries, what it has cost, what is happening
 * right now, and the way to everything else.
 *
 * It replaced a header line whose subject was the session id — a string a
 * person never reads and cannot use — and it sits under the input box for the
 * same reason tcode's does: the model is the answer to "what am I talking to",
 * which is a question you ask while typing, not while scrolling.
 *
 * The totals are the ledger's — every step records what it cost (DESIGN §3.1) —
 * so they survive a reopen and are the same numbers whoever is driving.
 */
export function StatusBar(props: {
  snapshot: SessionSnapshot
  status: DriverStatus
  /** Who holds the writer lease: us, or somebody else (tui.md §5.6). */
  role: Role
  takeoverReady: boolean
  spinnerFrame: string
  /**
   * The model this tab talks to: the session's frozen identity, or — on a tab
   * that is still a draft — what the next `session new` will name.
   */
  model: string
  /** `session step --effort`, when this tab names one; absent = the kernel's default. */
  effort?: string
  /** Extension tools on the face beside the builtin (`tools 1+N`). */
  tools: number
  /** The permission mode this TUI answers the kernel's gate with (tui.md §5.7). */
  mode?: PermissionMode
  /** A tool call is on screen waiting for a verdict right now. */
  awaiting?: boolean
  /**
   * Background tasks of this session that have not finished (tui.md §5.9). They
   * outlive the step that started them, so this is shown while the driver is
   * IDLE too — an idle bar with work going on in the background is the one case
   * where "idle" would be a lie.
   */
  background?: number
  /** Clicking the background count: the mouse half of `/tasks`. */
  onOpenTasks?: () => void
  /** Clicking the mode chip: the mouse half of `/mode`. */
  onToggleMode?: () => void
  hint?: string
  /** Rows of transcript below the viewport: >0 means somebody is reading back. */
  behind?: number
  /**
   * The model's context window, from the `[[models]]` catalog. Absent whenever
   * the catalog does not say — an unlisted model id, a bare endpoint — and then
   * no fullness is shown at all rather than a made-up denominator.
   */
  contextWindow?: number | null
  /** Clicking the model: the mouse half of `/model` (tui.md §11, T20). */
  onPickModel?: () => void
  /** Clicking the "N more below" marker: the mouse half of Shift+End. */
  onScrollEnd?: () => void
  /** Clicking `/help` in the default hint: the mouse half of typing it. */
  onHelp?: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [overBehind, setOverBehind] = createSignal(false)
  const [overHelp, setOverHelp] = createSignal(false)
  const [overModel, setOverModel] = createSignal(false)
  const [overMode, setOverMode] = createSignal(false)
  const [overTasks, setOverTasks] = createSignal(false)
  const tasksClick = onClick(() => props.onOpenTasks?.())
  const behindClick = onClick(() => props.onScrollEnd?.())
  const helpClick = onClick(() => props.onHelp?.())
  const modelClick = onClick(() => props.onPickModel?.())
  const modeClick = onClick(() => props.onToggleMode?.())

  const usage = createMemo(() => {
    const u = props.snapshot.usage
    if (u.input === 0 && u.output === 0) return "no usage yet"
    const cache = u.input > 0 ? Math.round((u.cacheRead / u.input) * 100) : 0
    return `↑${compact(u.input)} ↓${compact(u.output)} cache ${cache}%`
  })

  /**
   * How full the window is, after the last step. Nothing acts on this — nulya
   * never compacts behind the user's back — but a number that only appears once
   * it matters is how `/compact` gets found at the moment it is worth running.
   */
  const context = createMemo(() => {
    const window = props.contextWindow ?? 0
    const used = props.snapshot.usage.lastPrompt
    if (window <= 0 || used <= 0) return null
    const percent = Math.round((used / window) * 100)
    if (percent < 60) return null
    return { percent, urgent: percent >= 80 }
  })

  /** `⠋ 2 background`, or nothing at all when nothing is running. */
  const background = () => {
    const n = props.background ?? 0
    return n > 0 ? `${props.spinnerFrame} ${n} background` : null
  }

  const activity = createMemo(() => {
    // A call waiting for a verdict is the only thing happening: the kernel is
    // stopped on it, and the keys that move it are on the card (tui.md §5.7).
    // The keys are on the panel right above this line now, spelled out one per
    // row; repeating them here in a line that has to fit whatever is left over
    // is how they ended up as `y allow · nasknstep` on a narrow window.
    if (props.awaiting) return "waiting for your answer"
    if (props.snapshot.error) return `error: ${props.snapshot.error}`
    // Observer mode is not idleness: nothing is stuck, we simply are not the
    // writer. Say which, and say when taking over is possible.
    if (props.role === "observer") {
      if (props.takeoverReady) return "press ↵ to take over"
      if (props.status === "sending") return `${props.spinnerFrame} queued for the other writer`
      return "following"
    }
    if (props.status === "canceling") return `${props.spinnerFrame} canceling`
    if (props.status === "stepping") {
      const tool = props.snapshot.activeTool
      return `${props.spinnerFrame} ${tool ? tool : "model"}`
    }
    if (props.status === "sending") return `${props.spinnerFrame} sending`
    if (props.snapshot.lastStopped === "budget") return "step budget spent · /step to continue"
    // Below the two stop reasons, which ask for a keypress, and above every
    // resting state: with nothing else happening, a command still running in
    // the background IS what is happening.
    if (background() !== null && props.snapshot.lastStopped !== "max_tokens") return background()!
    // The kernel stops after two replies in a row hit max_tokens (DESIGN §4); the
    // marker results already told the model why. Sending a message continues
    // whether the cut reply ended in calls (results present) or in text (a bare
    // /step would prefill the assistant, which thinking-on providers reject).
    if (props.snapshot.lastStopped === "max_tokens") return "reply cut off (max_tokens) · send a message to continue"
    if (props.snapshot.lastStopped === "canceled") return "canceled"
    return "idle"
  })

  /**
   * The activity is the one live fact on this line, so it is the one thing here
   * drawn at full brightness besides the model — and only while something is
   * actually happening. An idle bar has nothing to shout about and drops back a
   * level.
   */
  const color = () => {
    if (props.awaiting) return style.theme.warn
    if (props.snapshot.error) return style.theme.err
    if (props.snapshot.lastStopped === "budget" || props.snapshot.lastStopped === "max_tokens") return style.theme.warn
    if (props.status !== "idle" || props.takeoverReady || showingBackground()) return style.theme.fg
    return style.theme.muted
  }

  /** Whether the activity slot is the background count — the one that is a link. */
  const showingBackground = () => background() !== null && activity() === background()

  /**
   * The model, and the effort only when this tab has chosen one — `auto` is the
   * kernel's default for that model and saying so costs seven columns of the
   * one line that has none to spare.
   */
  const modelText = () => `${props.model || "…"}${props.effort ? ` (${props.effort})` : ""}`

  /** The right-hand chips, as strings first, so the middle can be cut to what they leave. */
  const contextChip = () => (context() ? ` ctx ${context()!.percent}% · /compact` : "")
  const behindChip = () =>
    (props.behind ?? 0) > 0 ? ` ${style.glyphs.foldOpen} ${props.behind} more below · Shift+End` : ""
  /** `ask` / `auto`: which one is only worth a chip when somebody can act on it. */
  const modeChip = () => (props.mode && screen().width >= 60 ? ` ${props.mode}` : "")
  const roleChip = () =>
    screen().width >= 60
      ? ` step ${props.snapshot.steps} · ${props.role === "observer" ? "observer · driven elsewhere" : "driver"}`
      : ""

  /**
   * Who gives up columns first, when there are not enough.
   *
   * A `<text>` that runs out of box does not stop at the last whole word, so
   * every segment on this line is measured and cut by us (`ui/columns.ts`). The
   * order is a judgement about what this line is FOR: the model (what you are
   * talking to), what is happening, and the way to the rest of the keys must
   * survive every width; the running cost gives up next; `tools 1+N` first,
   * because the composition card above says the same thing at length.
   */
  const layout = createMemo(() => {
    const budget = Math.max(0, screen().width - 2)
    const right =
      displayWidth(contextChip()) + displayWidth(behindChip()) + displayWidth(modeChip()) + displayWidth(roleChip())
    const wanted = ` · ${activity()}`
    const model = fit(modelText(), Math.max(8, budget - right - displayWidth(wanted)))
    // Cut too, not just measured. An error message or a long tool name is as
    // long as somebody else made it, and a segment that overflows its row does
    // not stop at the edge — it runs into the chips beside it and both become
    // one unreadable word (`nasknstep 1`, T27).
    const activity_chip = fit(wanted, Math.max(0, budget - right - displayWidth(model)))
    let room = Math.max(0, budget - displayWidth(model) - displayWidth(activity_chip) - right)
    // What the tail insists on before the ambient chips get anything. A NOTICE
    // is news — what just happened, or why something did not — and it outranks
    // both of them; the default hint only insists on ` · /help`, because an
    // overlay nobody can reach is worse than a chip nobody can see.
    const floor =
      props.hint !== undefined
        ? Math.min(displayWidth(` · ${props.hint}`), room)
        : displayWidth(" · /help")
    const usage_chip = ` · ${usage()}`
    const keepUsage = room - displayWidth(usage_chip) >= floor
    if (keepUsage) room -= displayWidth(usage_chip)
    const tools_chip = ` · tools ${builtin_tools}+${props.tools}`
    const keepTools = room - displayWidth(tools_chip) >= floor
    if (keepTools) room -= displayWidth(tools_chip)
    return {
      model,
      tools: keepTools ? tools_chip : "",
      usage: keepUsage ? usage_chip : "",
      activity: activity_chip,
      room,
    }
  })

  /**
   * The hint, in the room the line actually has: the whole reminder, then a
   * shorter one, then just the way to `/help`. A notice replaces it entirely —
   * whatever just happened outranks a reminder of which key folds a card.
   */
  const hint = () => {
    const room = layout().room
    if (props.hint !== undefined) return { text: fit(` · ${props.hint}`, room), help: false }
    for (const lead of [" · Esc cancel · Ctrl+O fold · ", " · Ctrl+O fold · ", " · "]) {
      if (room >= displayWidth(lead) + 5) return { text: lead, help: true }
    }
    return { text: "", help: false }
  }

  return (
    <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={1} paddingRight={1}>
      <box flexDirection="row" flexGrow={1} flexShrink={1} flexBasis={0}>
        {/* The model is the subject of this line and the one thing on it that
            answers to a click — it opens `/model`, the way tcode's model line
            does. The same tint every clickable thing takes under the pointer
            (`ui/rows.ts`). */}
        <box
          flexShrink={0}
          height={1}
          backgroundColor={props.onPickModel && overModel() ? style.theme.hover : undefined}
          onMouseDown={props.onPickModel ? modelClick.onMouseDown : undefined}
          onMouseUp={props.onPickModel ? modelClick.onMouseUp : undefined}
          onMouseOver={() => setOverModel(true)}
          onMouseOut={() => setOverModel(false)}
        >
          <text fg={style.theme.fg}>{layout().model}</text>
        </box>
        <text fg={style.theme.dim} flexShrink={0}>
          {layout().tools}
        </text>
        <text fg={style.theme.muted} flexShrink={0}>
          {layout().usage}
        </text>
        {/* The activity is a link only when it is the background count: that is
            the one thing on this line that stands for a screen you can open
            (`/tasks`), and everything else here is a state, not a place. */}
        <box
          flexShrink={0}
          height={1}
          backgroundColor={showingBackground() && props.onOpenTasks && overTasks() ? style.theme.hover : undefined}
          onMouseDown={showingBackground() && props.onOpenTasks ? tasksClick.onMouseDown : undefined}
          onMouseUp={showingBackground() && props.onOpenTasks ? tasksClick.onMouseUp : undefined}
          onMouseOver={() => setOverTasks(true)}
          onMouseOut={() => setOverTasks(false)}
        >
          <text fg={color()}>{layout().activity}</text>
        </box>
        <text fg={style.theme.dim} flexShrink={0}>
          {hint().text}
        </text>
        <Show when={hint().help}>
          <box
            flexShrink={0}
            height={1}
            backgroundColor={overHelp() ? style.theme.hover : undefined}
            onMouseDown={helpClick.onMouseDown}
            onMouseUp={helpClick.onMouseUp}
            onMouseOver={() => setOverHelp(true)}
            onMouseOut={() => setOverHelp(false)}
          >
            <text fg={style.theme.dim}>/help</text>
          </box>
        </Show>
      </box>
      {context() ? (
        <text fg={context()!.urgent ? style.theme.warn : style.theme.dim} flexShrink={0}>
          {contextChip()}
        </text>
      ) : null}
      {/* Scrolled away from the live end: the newest card is off screen, which
          is worth saying — otherwise a streaming answer looks like a stall. */}
      {(props.behind ?? 0) > 0 ? (
        <box
          flexShrink={0}
          height={1}
          backgroundColor={overBehind() ? style.theme.hover : undefined}
          onMouseDown={behindClick.onMouseDown}
          onMouseUp={behindClick.onMouseUp}
          onMouseOver={() => setOverBehind(true)}
          onMouseOut={() => setOverBehind(false)}
        >
          <text fg={style.theme.accent.evolve}>{behindChip()}</text>
        </box>
      ) : null}
      {/* The mode, and the click that flips it — the mouse half of `/mode`.
          `auto` is warn-coloured: it is the stance where tool calls run without
          anybody looking, and that should never be the quiet one. */}
      {modeChip().length > 0 ? (
        <box
          flexShrink={0}
          height={1}
          backgroundColor={props.onToggleMode && overMode() ? style.theme.hover : undefined}
          onMouseDown={props.onToggleMode ? modeClick.onMouseDown : undefined}
          onMouseUp={props.onToggleMode ? modeClick.onMouseUp : undefined}
          onMouseOver={() => setOverMode(true)}
          onMouseOut={() => setOverMode(false)}
        >
          <text fg={props.mode === "auto" ? style.theme.warn : style.theme.dim}>{modeChip()}</text>
        </box>
      ) : null}
      {screen().width >= 60 ? (
        <text fg={props.role === "observer" ? style.theme.warn : style.theme.dim} flexShrink={0}>
          {roleChip()}
        </text>
      ) : null}
    </box>
  )
}
