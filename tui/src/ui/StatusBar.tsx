import { Show, createMemo, createSignal } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { onClick } from "./rows.ts"
import { displayWidth, fit } from "./columns.ts"
import type { SessionSnapshot } from "../state/session.ts"
import type { DriverStatus } from "../state/driver.ts"
import type { Role } from "../state/attach.ts"

function compact(n: number): string {
  if (n < 1000) return String(n)
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`
  return `${(n / 1_000_000).toFixed(1)}M`
}

/**
 * One line: what this session has cost, what is happening right now, and the
 * three keys worth knowing. The totals are the ledger's — every step records
 * what it cost (DESIGN §3.1) — so they survive a reopen and are the same
 * numbers whoever is driving.
 */
export function StatusBar(props: {
  snapshot: SessionSnapshot
  status: DriverStatus
  /** Who holds the writer lease: us, or somebody else (tui.md §5.6). */
  role: Role
  takeoverReady: boolean
  spinnerFrame: string
  hint?: string
  /** Rows of transcript below the viewport: >0 means somebody is reading back. */
  behind?: number
  /**
   * The model's context window, from the `[[models]]` catalog. Absent whenever
   * the catalog does not say — an unlisted model id, a bare endpoint — and then
   * no fullness is shown at all rather than a made-up denominator.
   */
  contextWindow?: number | null
  /** Clicking the "N more below" marker: the mouse half of Shift+End. */
  onScrollEnd?: () => void
  /** Clicking `/help` in the default hint: the mouse half of typing it. */
  onHelp?: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [overBehind, setOverBehind] = createSignal(false)
  const [overHelp, setOverHelp] = createSignal(false)
  const behindClick = onClick(() => props.onScrollEnd?.())
  const helpClick = onClick(() => props.onHelp?.())

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

  const activity = createMemo(() => {
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
   * drawn at full brightness — and only while something is actually happening.
   * An idle bar has nothing to shout about and drops back a level.
   */
  const color = () => {
    if (props.snapshot.error) return style.theme.err
    if (props.snapshot.lastStopped === "budget" || props.snapshot.lastStopped === "max_tokens") return style.theme.warn
    if (props.status !== "idle" || props.takeoverReady) return style.theme.fg
    return style.theme.muted
  }

  /** The right-hand chips, as strings first, so the hint can be cut to what they leave. */
  const contextChip = () => (context() ? ` ctx ${context()!.percent}% · /compact` : "")
  const behindChip = () =>
    (props.behind ?? 0) > 0 ? ` ${style.glyphs.foldOpen} ${props.behind} more below · Shift+End` : ""
  const roleChip = () =>
    screen().width >= 60
      ? ` step ${props.snapshot.steps} · ${props.role === "observer" ? "observer · driven elsewhere" : "driver"}`
      : ""

  /**
   * The hint, cut to the room the line actually has. It is the one part of
   * this bar with no fixed width, and a `<text>` that runs out of box does not
   * stop at the last whole word — the screenshot that motivated this ended in
   * `Ctrl+O fold · /` with `help` gone. When the default hint is up, `/help` is
   * its own box so it can be clicked; a notice replaces the whole hint.
   */
  const hint = () => {
    const taken =
      displayWidth(usage()) +
      displayWidth(` · ${activity()}`) +
      displayWidth(contextChip()) +
      displayWidth(behindChip()) +
      displayWidth(roleChip())
    const room = Math.max(0, screen().width - 2 - taken)
    if (props.hint !== undefined) return { text: fit(` · ${props.hint}`, room), help: false }
    const lead = " · Esc cancel · Ctrl+O fold · "
    if (room >= displayWidth(lead) + 5) return { text: lead, help: true }
    return { text: fit(" · Esc cancel · Ctrl+O fold", room), help: false }
  }

  return (
    <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={1} paddingRight={1}>
      {/* Three tiers on one line: what it cost (secondary), what is happening
          (the subject), which keys (a caption). One `<text>` in one colour was
          the whole bar reading as a single grey sentence. */}
      <box flexDirection="row" flexGrow={1} flexShrink={1} flexBasis={0}>
        <text fg={style.theme.muted} flexShrink={0}>
          {usage()}
        </text>
        <text fg={color()} flexShrink={0}>
          {" · "}
          {activity()}
        </text>
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
          is worth saying — otherwise a streaming answer looks like a stall. It
          is also the only thing on this line worth clicking, so it is the only
          thing on this line that lights up under the pointer. */}
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
      {screen().width >= 60 ? (
        <text fg={props.role === "observer" ? style.theme.warn : style.theme.dim} flexShrink={0}>
          {roleChip()}
        </text>
      ) : null}
    </box>
  )
}
