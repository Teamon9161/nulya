import { Show, createMemo, createSignal } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { onClick } from "./rows.ts"
import { displayWidth, fit } from "./columns.ts"
import { builtin_tools } from "../pins.ts"
import type { SessionSnapshot } from "../state/session.ts"
import type { Role } from "../state/attach.ts"
import type { PermissionMode } from "../approvals.ts"

/**
 * The one line under the composer (tui.md §4.1, §4.5, §11 T22): a standing
 * description of this session — what it runs on, what its face carries, what
 * it has cost, and how it is being driven.
 *
 * It replaced a header line whose subject was the session id — a string a
 * person never reads and cannot use — and it sits under the input box for the
 * same reason tcode's does: the model is the answer to "what am I talking to",
 * which is a question you ask while typing, not while scrolling.
 *
 * What is HAPPENING is not here (T38). It moved to its own line above the
 * composer (`WorkingStatus`), because an activity and a description are read at
 * different rates: this row is read once and then trusted, and a live fact
 * parked at the end of it had the least room and the least contrast on the
 * screen. What went with it: `idle` (a word whose only content is that there
 * was nothing to say) and the keyboard hints, which are now tips on the opening
 * screen — a reminder shown forever stops being read.
 *
 * The running cost went the same way (T42). A total that changes is a live
 * fact, and it belongs on the line that is only there while something is
 * changing it; standing here it was six columns of arithmetic that nobody was
 * reading between steps, and it pushed the model id — the answer to "what am I
 * talking to" — into being cut first on a narrow terminal. `/usage` still has
 * every number, and `ctx N%` still appears here when the window fills, because
 * that one is not a total but a warning.
 */
export function StatusBar(props: {
  snapshot: SessionSnapshot
  /** Who holds the writer lease: us, or somebody else (tui.md §5.6). */
  role: Role
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
  /**
   * Clicking the mode chip: the mouse half of `/mode`, which opens the picker
   * (tui.md §11, T31). It used to flip the mode straight from here, which is the
   * one gesture that cannot say what the other side is — so the two words had to
   * be explained in a notice on this very line, every time.
   */
  onPickMode?: () => void
  /**
   * Packages whose system prompt this tab carries (`--with`, T31). Usually
   * empty; when it is not, it is the fact that decides what the model thinks it
   * is, and nothing else on a started session says it once the composition card
   * is folded.
   */
  wearing?: string[]
  /** Clicking what this session wears: the mouse half of `/ext`. */
  onOpenExt?: () => void
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
  /**
   * The sessions sidebar's handle (T69): the standing, clickable way in and out
   * of it, beside `/sidebar` and its key.
   *
   * It leads the line, in the two columns every list row in this front end
   * gives its gutter (§6.5) — and at the far left because that is where the
   * thing it opens appears. Position is one of the four things a terminal has
   * to build order out of, so a handle for a left-hand pane belongs at the left
   * hand edge and nowhere else. It is also deliberately AHEAD of everything a
   * package will ever be able to put on this line (goals/tui-shell.md §4's chip
   * strip): host chrome does not queue behind extensions for a slot.
   */
  sidebarOpen?: boolean
  onToggleSidebar?: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [overBehind, setOverBehind] = createSignal(false)
  const [overModel, setOverModel] = createSignal(false)
  const [overMode, setOverMode] = createSignal(false)
  const behindClick = onClick(() => props.onScrollEnd?.())
  const modelClick = onClick(() => props.onPickModel?.())
  const [overWearing, setOverWearing] = createSignal(false)
  const [overTools, setOverTools] = createSignal(false)
  const modeClick = onClick(() => props.onPickMode?.())
  const extClick = onClick(() => props.onOpenExt?.())
  const toolsClick = onClick(() => props.onOpenExt?.())
  const [overSidebar, setOverSidebar] = createSignal(false)
  const sidebarClick = onClick(() => props.onToggleSidebar?.())
  /**
   * The handle is there whenever the sidebar could be. Under 60 columns it
   * cannot open at all (`sidebar_min_width`, the same width the chips on the
   * right give up at), and a control for something that cannot happen is two
   * columns saying nothing (§6.1 rule 4).
   */
  const sidebarHandle = () => Boolean(props.onToggleSidebar) && screen().width >= 60
  /**
   * …and on a wide terminal it says its own name (T70).
   *
   * A bare `◧` was two columns of a glyph nobody had met, at the one edge of
   * the screen the eye does not sweep, for a pane that had never been on it —
   * the first person to use it reported never finding the sidebar at all. A
   * word is what makes a control findable; the glyph alone only works once you
   * know what it opens.
   *
   * Only where there is room to spend: 100 columns is where `layout()` below
   * still has slack after the model, the mode and the chips, so the label is
   * never bought with the model id. Under it the handle goes back to the glyph,
   * which is exactly the fallback `sidebarRowPlan` uses one pane over — the
   * thing that must survive every width is the thing the row is FOR.
   *
   * The trailing gap is inside the target on purpose — a handle is easier to
   * hit than it is to read — and it is two columns rather than the ` · ` the
   * rest of the line joins with, because this is not one of those chips: it is
   * host chrome sitting ahead of everything a package will ever be allowed to
   * put here (goals/tui-shell.md §4). Air says "different thing"; a joint would
   * say "next thing".
   */
  const sidebar_label_width = 100
  const sidebarChip = () =>
    !sidebarHandle()
      ? ""
      : screen().width >= sidebar_label_width
        ? `${style.glyphs.sidebar} sessions  `
        : `${style.glyphs.sidebar} `

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

  /**
   * The model, and the effort only when this tab has chosen one — `auto` is the
   * kernel's default for that model and saying so costs seven columns of the
   * one line that has none to spare.
   */
  const modelText = () => `${props.model || "…"}${props.effort ? ` (${props.effort})` : ""}`

  /** The right-hand chips, as strings first, so the middle can be cut to what they leave. */
  const contextChip = () => (context() ? ` ctx ${context()!.percent}% · /compact` : "")
  const behindChip = () =>
    (props.behind ?? 0) > 0 ? ` ${style.glyphs.below} ${props.behind} more below · Shift+End` : ""
  /**
   * `ask` / `unsafe`, at the head of the line (T35).
   *
   * It used to sit at the far right, past the cost and the chips, which is
   * where a line puts the things it is willing to lose. This one is the stance
   * every tool call on the screen is judged by; it reads first, before the
   * model, for the same reason the model reads before the cost.
   */
  const modeChip = () => (props.mode && screen().width >= 60 ? props.mode : "")
  /** The separator belongs outside the clickable box, so the chip is the word. */
  const modeLead = () => (modeChip() ? `${modeChip()} · ` : "")
  /** ` ◈ evolution` — the mode this session is WEARING, not the permission one. */
  const wearingChip = () => {
    const worn = props.wearing ?? []
    return worn.length > 0 && screen().width >= 60 ? ` ${style.glyphs.picker} ${worn.join(" ")}` : ""
  }
  /**
   * Being the writer is the ordinary case and the word `driver` was on this
   * line in every session anybody ever had — a chip that is always the same is
   * not information (T35). Only the exception says itself. The step count goes
   * the same way before there is a session to count steps of.
   */
  const roleChip = () => {
    if (screen().width < 60) return ""
    if (props.role === "observer") return ` step ${props.snapshot.steps} · observer · driven elsewhere`
    return props.snapshot.steps > 0 ? ` step ${props.snapshot.steps}` : ""
  }

  /**
   * Who gives up columns first, when there are not enough.
   *
   * A `<text>` that runs out of box does not stop at the last whole word, so
   * every segment on this line is measured and cut by us (`ui/columns.ts`). The
   * order is a judgement about what this line is FOR: the model — what you are
   * talking to — survives every width, and `tools 1+N` gives up first, because
   * the composition card above says the same thing at length.
   */
  const layout = createMemo(() => {
    const budget = Math.max(0, screen().width - 2 - displayWidth(sidebarChip()) - displayWidth(modeLead()))
    const right =
      displayWidth(contextChip()) +
      displayWidth(behindChip()) +
      displayWidth(wearingChip()) +
      displayWidth(roleChip())
    // Cut too, not just measured. A model id is as long as whoever named it
    // made it, and a segment that overflows its row does not stop at the edge —
    // it runs into the chips beside it and both become one unreadable word
    // (`nasknstep 1`, T27).
    const model = fit(modelText(), Math.max(8, budget - right))
    const room = Math.max(0, budget - displayWidth(model) - right)
    // The word alone — the ` · ` in front of it is drawn outside the clickable
    // box, so it is measured here and carried nowhere else.
    const tools_chip = `tools ${builtin_tools}+${props.tools}`
    return {
      model,
      tools: room >= displayWidth(tools_chip) + 3 ? tools_chip : "",
    }
  })

  /**
   * A notice takes the whole line for as long as it is up (T35).
   *
   * It used to be one more segment competing for the leftovers, which put the
   * news of the moment — `Ctrl+C again to quit` — in the last few columns of a
   * row that already carried the model, the cost, the mode and the step count,
   * and let it sit there afterwards as if it were still true. News is not a
   * chip: it covers the line, and `App` takes it away again on its own clock.
   */
  const noticeText = () => (props.hint === undefined ? null : fit(props.hint, Math.max(0, screen().width - 2)))

  return (
    <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={1} paddingRight={1}>
      {noticeText() !== null ? (
        <text fg={style.theme.fg}>{noticeText()}</text>
      ) : (
        <box flexDirection="row" width="100%" height={1}>
          {/* The sessions sidebar's handle, in this line's own two-column
              gutter — the left edge of the screen, which is where the pane it
              opens appears (T69). Lit while the sidebar is up and furniture
              while it is not; the shape never changes, because the sidebar
              being on screen is already the state and a glyph that repeated it
              would be a second answer to a question the screen has answered at
              full size (§6.1 rule 1's shape rule is about facts that would
              OTHERWISE be invisible).

              What DOES change with width is whether it says its own name
              (T70): a glyph nobody has met, at the one edge of the line the
              eye does not sweep, is a control that is never found. Under the
              pointer it takes `hover`, like every other clickable thing in
              this front end. */}
          {sidebarChip().length > 0 ? (
            <box
              flexShrink={0}
              height={1}
              backgroundColor={overSidebar() ? style.theme.hover : undefined}
              onMouseDown={sidebarClick.onMouseDown}
              onMouseUp={sidebarClick.onMouseUp}
              onMouseOver={() => setOverSidebar(true)}
              onMouseOut={() => setOverSidebar(false)}
            >
              <text fg={props.sidebarOpen ? style.theme.accent.evolve : style.theme.faint}>{sidebarChip()}</text>
            </box>
          ) : null}
          {/* The permission mode leads the line, and the click opens its picker
              — the mouse half of `/mode`. `unsafe` is warn-coloured: it is the
              stance where tool calls run without anybody looking, and that
              should never be the quiet one. */}
          {modeChip().length > 0 ? (
            <box
              flexShrink={0}
              height={1}
              backgroundColor={props.onPickMode && overMode() ? style.theme.hover : undefined}
              onMouseDown={props.onPickMode ? modeClick.onMouseDown : undefined}
              onMouseUp={props.onPickMode ? modeClick.onMouseUp : undefined}
              onMouseOver={() => setOverMode(true)}
              onMouseOut={() => setOverMode(false)}
            >
              <text fg={props.mode === "unsafe" ? style.theme.warn : style.theme.dim}>{modeChip()}</text>
            </box>
          ) : null}
          <Show when={modeChip().length > 0}>
            <text fg={style.theme.dim} flexShrink={0}>
              {" · "}
            </text>
          </Show>
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
            {/* An empty segment is not rendered at all: a `<text>` with nothing
                in it still takes a column, and two of them side by side is how
                `tools 1+0  · idle` grew the gap that made this line look
                mis-aligned once the cost chip learned to be absent (T35). */}
            {/* `tools 1+N` is a count of a thing that has a screen — `/ext`'s
                tools pane is where each one of those N is switched on and off —
                so it answers to a click, like the model and the mode beside it.
                The separator stays outside the target: the chip is the fact,
                not the punctuation that joins it to the model. */}
            <Show when={layout().tools.length > 0}>
              <text fg={style.theme.dim} flexShrink={0}>
                {" · "}
              </text>
              <box
                flexShrink={0}
                height={1}
                backgroundColor={props.onOpenExt && overTools() ? style.theme.hover : undefined}
                onMouseDown={props.onOpenExt ? toolsClick.onMouseDown : undefined}
                onMouseUp={props.onOpenExt ? toolsClick.onMouseUp : undefined}
                onMouseOver={() => setOverTools(true)}
                onMouseOut={() => setOverTools(false)}
              >
                <text fg={style.theme.dim}>{layout().tools}</text>
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
          {/* What this session is WEARING — a `--with` package's system prompt, the
              one thing that changes who the model thinks it is (T31). It opens
              `/ext`, where it is turned on and off. */}
          {wearingChip().length > 0 ? (
            <box
              flexShrink={0}
              height={1}
              backgroundColor={props.onOpenExt && overWearing() ? style.theme.hover : undefined}
              onMouseDown={props.onOpenExt ? extClick.onMouseDown : undefined}
              onMouseUp={props.onOpenExt ? extClick.onMouseUp : undefined}
              onMouseOver={() => setOverWearing(true)}
              onMouseOut={() => setOverWearing(false)}
            >
              <text fg={style.theme.accent.evolve}>{wearingChip()}</text>
            </box>
          ) : null}
          {roleChip().length > 0 ? (
            <text fg={props.role === "observer" ? style.theme.warn : style.theme.dim} flexShrink={0}>
              {roleChip()}
            </text>
          ) : null}
        </box>
      )}
    </box>
  )
}
