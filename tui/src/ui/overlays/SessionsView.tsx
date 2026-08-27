/**
 * `/sessions` (F3): every durable session in the workspace (tui.md §5.4).
 *
 * The rows are `nulya session list --json` — the kernel's own read-only
 * projection of `.nulya/sessions/` plus the outcome journal (DESIGN §14), newest
 * first, nested by `parent`. The TUI does not parse headers for this any more:
 * composition and verdict arrive already decided, and the verdict in particular
 * lives in a second journal the front end has no business reading. The opening
 * user turn arrives ready to print too — the kernel caps it at 120 bytes and
 * turns its newlines and tabs into spaces (`session_list.zig` `summarize`),
 * which is why nothing here has to.
 *
 * A ROW IS THE SENTENCE THAT STARTED IT (T47). Everything else a session file
 * knows — how many events, which packages it wore, what it cost, on which model
 * — has been on this line at some point and is gone: none of it is how a person
 * recognises the conversation they want back, and a column that separates
 * nothing is not information (§4.5). The id went with them; it is the one thing
 * here nobody can read but everybody occasionally has to paste, so it is
 * printed once, in the title line, for the row the cursor is on.
 *
 * Two things stay ours. `● live` means some other process holds the writer lease
 * right now — a fact about this instant, not about the file, and the same one
 * that decides driver or observer mode. And there is still no delete: a ledger
 * is append-only, and a view that offered to erase one would be lying about what
 * the system is.
 */
import { Index, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { ScrollBoxRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { displayWidth, fit } from "../columns.ts"
import { createHover, onClick, rowBackground, rowGutter } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { personaOf } from "../../agents.ts"
import { sessionList, type SessionListEntry, type Verdict } from "../../nulya/cli.ts"
import { probeWriterLease, type LeaseState } from "../../nulya/files.ts"
import type { Workspace } from "../../nulya/bin.ts"

interface Row {
  entry: SessionListEntry
  depth: number
}

/** Children under their parent, everything else at the root, newest first. */
export function sessionRows(entries: readonly SessionListEntry[]): Row[] {
  const byId = new Map(entries.map((entry) => [entry.id, entry]))
  const children = new Map<string, SessionListEntry[]>()
  const roots: SessionListEntry[] = []
  for (const entry of entries) {
    const parent = entry.parent?.session
    if (parent && byId.has(parent) && parent !== entry.id) {
      children.set(parent, [...(children.get(parent) ?? []), entry])
    } else {
      roots.push(entry)
    }
  }
  const rows: Row[] = []
  const walk = (entry: SessionListEntry, depth: number) => {
    rows.push({ entry, depth })
    for (const child of children.get(entry.id) ?? []) walk(child, depth + 1)
  }
  for (const root of roots) walk(root, 0)
  return rows
}

/**
 * How long ago, in the words a person answers that question with.
 *
 * `08-16 09:12` was a timestamp: correct, and something the reader had to
 * subtract from today's date to learn the only thing they were after — whether
 * this is the one from ten minutes ago. Inside a week the answer is the
 * distance; past that the distance stops being memorable and the date takes
 * over.
 */
export function ago(created: string, now: number = Date.now()): string {
  const at = Date.parse(created)
  if (created.length === 0 || Number.isNaN(at)) return "—"
  const seconds = Math.max(0, Math.round((now - at) / 1000))
  if (seconds < 60) return "just now"
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  if (days < 7) return `${days}d ago`
  const date = new Date(at)
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
}

const verdict_glyph: Record<Verdict, string> = { success: "+", partial: "~", failure: "!" }

/**
 * How long two presses may be apart and still be one gesture (T70).
 *
 * The number every desktop uses, and the one thing about a double click that
 * is not ours to invent — a terminal sends two independent releases and
 * nothing else, so the window IS the gesture.
 */
export const double_click_ms = 350

/**
 * The sessions a person is HAVING, and the ones an agent was given (T70).
 *
 * A delegated session is a real session with a real ledger, and `session list`
 * is right to project it — but it is not a conversation anybody chose to start,
 * nobody should send it a message from here (its runner is driving it), and in
 * a workspace that delegates at all they outnumber the real rows several to
 * one. So the list is about the first kind by default and says how many of the
 * second it is not showing.
 *
 * The test is `personaOf`, the one the front end already uses for "what is this
 * session wearing" — a delegated session is exactly one whose frozen header
 * carries an `agent-<name>` prompt, and this side does not get a second opinion
 * about that. It is a filter over a projection: nothing is hidden from the
 * kernel, from `session list`, or from `/sessions <id>`.
 */
export function partitionSessions(entries: readonly SessionListEntry[]): {
  own: SessionListEntry[]
  delegated: SessionListEntry[]
} {
  const own: SessionListEntry[] = []
  const delegated: SessionListEntry[] = []
  for (const entry of entries) {
    ;(personaOf(entry.composition.prompts) === null ? own : delegated).push(entry)
  }
  return { own, delegated }
}

/**
 * The one dim line at the bottom of the rail (§6.1 rule 8), at whatever width
 * the rail happens to be.
 *
 * Eighteen columns at 80 and twenty-eight at 120, so this cannot be one string
 * cut with `fit` — a truncated key list teaches the wrong key. Candidates,
 * longest first, and the first that fits wins: the same "give up cells from the
 * outside in" rule `sidebarRowPlan` follows one function up.
 *
 * The keys are only true while the rail holds the keyboard; the hidden count is
 * true either way, because a list that is quietly shorter than the store is a
 * list that is lying, focused or not.
 */
export function railFooter(width: number, focused: boolean, hidden: number): string {
  const candidates =
    hidden > 0
      ? focused
        ? [`j/k · Enter · Esc · ${hidden} agent · a`, `${hidden} agent hidden · a`, `${hidden} agent · a`]
        : [`${hidden} agent hidden`, `${hidden} agent`]
      : focused
        ? ["j/k · Enter go · t tab · Esc", "j/k · Enter · Esc"]
        : []
  // When both cannot fit, the count wins: a key that is missing from this line
  // is still in `/sessions` and in `/help`, while a list that is quietly
  // shorter than the store has nowhere else to say so.
  return candidates.find((line) => displayWidth(line) <= width) ?? ""
}

/**
 * The line that makes a row recognisable: what was asked of it first.
 *
 * A session with nothing in it says so in words. It is the one row whose
 * emptiness the event count used to carry (`0 events`), and that count is gone.
 */
export function title(entry: SessionListEntry): string {
  return entry.first_user_text.length > 0 ? entry.first_user_text : "nothing said yet"
}

/**
 * What fits in one row of the narrow variant, from the outside in (T69).
 *
 * The sidebar is eighteen columns at 80 and twenty-eight at 120, so its layout
 * cannot be a smaller copy of the overlay's — it has to be a decision about
 * what a row is FOR. A row is the sentence that started the session (T47), so
 * the sentence is the one thing that never yields: the cells around it are
 * dropped, in this order, until it has at least `min_said` columns.
 *
 * The order is an argument about what a person is looking at a docked list for.
 * The clock goes first: it orders rows, and they are already in order. Then the
 * verdict, then `live` — facts about a session that the full view still tells
 * in full. Last two: `◈`, which is the only thing saying a row is a delegation
 * rather than a conversation (T70, and it is only ever present in the mode a
 * person turned on), and `▎ this one`, because a list of conversations that
 * cannot say which one you are in is not a list of your conversations.
 *
 * Every cell arrives with its own leading space, so an absent one costs nothing
 * (§6.1 rule 4) and this function never has to know which glyph it is holding.
 */
export const min_said = 8

interface RowCells {
  here: string
  live: string
  verdict: string
  clock: string
  /** `◈ ` — this row is a session an agent was handed, not one somebody started. */
  persona: string
}

export function sidebarRowPlan(
  inner: number,
  cells: RowCells & { indent: number },
): RowCells & { said: number } {
  const plan: RowCells = {
    here: cells.here,
    live: cells.live,
    verdict: cells.verdict,
    clock: cells.clock,
    persona: cells.persona,
  }
  // Two for the gutter every row in this front end starts with (§6.5).
  const room = () =>
    inner -
    2 -
    cells.indent -
    displayWidth(plan.here) -
    displayWidth(plan.live) -
    displayWidth(plan.verdict) -
    displayWidth(plan.clock) -
    displayWidth(plan.persona)
  for (const cell of ["clock", "verdict", "live", "persona", "here"] as const) {
    if (room() >= min_said) break
    plan[cell] = ""
  }
  return { ...plan, said: Math.max(0, room()) }
}

export function SessionsView(props: {
  ws: Workspace
  /** The session in front, so the list can say which one that is. */
  currentId: string
  /**
   * Go to that session HERE: this view's primary action, and what a single
   * click and `Enter` both do (T70).
   *
   * It used to be `onOpen`, and it used to mean "a tab of its own" — which is
   * the wrong default for the gesture people make most. Clicking a row in a
   * list of conversations means "show me that one", the way clicking a mail
   * folder or a chat does; growing the tab strip by one every time somebody
   * looks at an old session is the thing a person then has to undo.
   */
  onSwitch: (id: string) => void
  /** …and the deliberate one: keep what is here and give that session a tab too. */
  onOpenTab: (id: string) => void
  onNew: () => void
  onClose: () => void
  /**
   * Which of the two presentations this is (T69). `overlay` is the full-screen
   * view F3 opens; `sidebar` is the rail docked beside the transcript. One
   * component, because they are one list read two ways — the rows, the cursor,
   * the refresh beat and what a click does are the same, and two components
   * would be two answers to all of it.
   */
  variant?: "overlay" | "sidebar"
  /**
   * Whether this mount holds the keyboard. Both presentations can be on screen
   * at once — the sidebar open with `/sessions` in front of the transcript —
   * and `useKeyboard` is global, so a mount that is not the focused pane must
   * not answer `j`.
   */
  focused?: boolean
  /** The pane's own width, for the sidebar; the overlay measures the screen. */
  width?: number
}) {
  const style = useStyle()
  const screen = useScreen()
  const [entries, setEntries] = createSignal<SessionListEntry[]>([])
  const [leases, setLeases] = createSignal<Record<string, LeaseState>>({})
  const [cursor, setCursor] = createSignal(0)
  const [notice, setNotice] = createSignal<string | null>(null)
  /** `a`: show the delegated sessions too, this mount only (T70). */
  const [showAgents, setShowAgents] = createSignal(false)
  let list: ScrollBoxRenderable | null = null
  const hover = createHover()
  const help = createKeyHelp()

  const refresh = async () => {
    try {
      setEntries(await sessionList(props.ws))
      setNotice(null)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
  }

  /** Cheap, file-only, and the one thing the projection cannot carry: who is writing now. */
  const probe = () => {
    const seen: Record<string, LeaseState> = {}
    for (const entry of entries()) seen[entry.id] = probeWriterLease(props.ws, entry.id)
    setLeases(seen)
  }

  const docked = () => props.variant === "sidebar"
  const owns_keys = () => props.focused !== false

  onMount(() => {
    void refresh().then(probe)
    // The live marker is re-read often; the list itself costs a process and a
    // read of every session file, so it refreshes on a slower beat (and on `r`).
    //
    // The sidebar's beat is slower still, and for a reason the overlay does not
    // have: an overlay is up for as long as somebody is looking at it, while a
    // rail is up all day. A process every eight seconds forever is a cost this
    // screen would be paying whether or not anyone glanced at it.
    const live = setInterval(probe, docked() ? 3000 : 1500)
    const full = setInterval(() => void refresh().then(probe), docked() ? 20_000 : 8000)
    onCleanup(() => {
      clearInterval(live)
      clearInterval(full)
    })
  })

  // …and the one moment the slow beat would be felt: the tab in front changed,
  // so a session was just started or opened and the list is a beat behind the
  // thing it is a list of.
  createEffect((seen: string | undefined) => {
    const now = props.currentId
    if (seen !== undefined && seen !== now && docked()) void refresh().then(probe)
    return now
  })

  /**
   * The columns this view may draw in: the box pads one on each side.
   *
   * The overlay measures the terminal; the sidebar is told its pane's width,
   * because a pane is not the screen and there is nothing on screen it could
   * infer that from. The floor differs for the same reason the layout does —
   * 24 columns is the narrowest a full screen is ever asked to be, and a rail
   * is narrower than that by construction.
   */
  const outer = () => (docked() ? Math.max(0, props.width ?? 0) : screen().width)
  /**
   * The rail pads two on the right rather than one: those two columns are the
   * seam. Nothing is drawn between two panes — this front end groups with
   * whitespace and indentation and keeps box-drawing for the one bordered
   * thing on the screen (§6.1 rule 5) — so the boundary has to be air, and one
   * column of it is not a boundary, it is a row of text ending next to another
   * row of text.
   */
  const inner = () => Math.max(docked() ? 10 : 24, outer() - (docked() ? 3 : 2))
  /** Rows leave one column for ScrollBox's vertical track and one for air beside it. */
  const rowInner = () => Math.max(docked() ? 10 : 24, inner() - 2)
  const split = createMemo(() => partitionSessions(entries()))
  /** How many rows the list is not drawing — 0 while `a` is on. */
  const hidden = () => (showAgents() ? 0 : split().delegated.length)
  /**
   * Filtered BEFORE the tree is built, not after: `sessionRows` nests a child
   * under its parent only when the parent is in the same list, so a hidden
   * parent leaves its children as roots rather than as an indent under nothing.
   */
  const rows = createMemo(() => sessionRows(showAgents() ? entries() : split().own))
  const rowId = (id: string) => `session-row:${id}`
  createEffect(() => {
    const count = rows().length
    if (cursor() >= count) setCursor(Math.max(0, count - 1))
  })
  createEffect(() => {
    const row = rows()[cursor()]
    if (row) list?.scrollChildIntoView(rowId(row.entry.id))
  })

  /**
   * One width for every `ago` on screen, so they line up as a column instead of
   * a ragged edge. Measured from the mounted rows; ScrollBox decides which of
   * them are visible.
   */
  const clock = createMemo(() => {
    const now = Date.now()
    let widest = 0
    for (const row of rows()) widest = Math.max(widest, displayWidth(ago(row.entry.created, now)))
    return widest
  })

  /** The id of the row the cursor is on: unreadable, occasionally needed, printed once. */
  const pointed = () => rows()[cursor()]?.entry.id ?? ""

  /**
   * What the full view's key line adds about the rows it is not drawing (T70),
   * or nothing at all when there are none to speak of (§6.1 rule 4). Both
   * states name the key, because "these are showing" is as worth undoing as
   * "these are hidden".
   */
  const asideText = () => {
    if (showAgents()) return split().delegated.length > 0 ? " · a hides delegated sessions" : ""
    const n = hidden()
    return n > 0 ? ` · ${n} agent ${n === 1 ? "session" : "sessions"} hidden · a shows` : ""
  }

  const move = (delta: number) => {
    const count = rows().length
    if (count === 0) return
    setCursor(Math.min(Math.max(cursor() + delta, 0), count - 1))
  }

  const act = (index: number, take: (id: string) => void) => {
    const row = rows()[index]
    if (row) take(row.entry.id)
  }
  const go = () => act(cursor(), props.onSwitch)
  const goToTab = () => act(cursor(), props.onOpenTab)

  /**
   * ONE CLICK GOES THERE, TWO GIVE IT A TAB (T70).
   *
   * A terminal has no double click, only two releases and a clock, so the
   * window is ours to draw (`double_click_ms`). What is NOT free is the order:
   * the single-click action is deferred until the window closes, and it has to
   * be.
   *
   * The tempting alternative is to switch at once and let a second press "also
   * open a tab" — no wait, snappier. It cannot work here, and not because of
   * feel: switching in place CONSUMES the tab the second press is trying to
   * preserve. After the first click this tab already holds that session, so
   * `onOpenTab` finds it open and merely selects it; to make the pair mean
   * anything the view would have to put back what it had just replaced, which
   * for a draft tab is not restorable at all and for a session tab costs a
   * fresh `session events` replay. One gesture, one action, neither undoing the
   * other — so the switch waits, and what does not wait is the cursor, which
   * lands on the press so the click is acknowledged in the same frame.
   *
   * A third press inside a window starts a new one rather than firing again:
   * repeated clicking is somebody who has not seen anything happen yet, and
   * opening a tab per press is the least helpful reading of that.
   */
  let pending: { index: number; timer: ReturnType<typeof setTimeout> } | null = null
  const forget = () => {
    if (pending) clearTimeout(pending.timer)
    pending = null
  }
  onCleanup(forget)
  const clickRow = (index: number) => {
    setCursor(index)
    const twice = pending?.index === index
    forget()
    if (twice) return act(index, props.onOpenTab)
    const timer = setTimeout(() => {
      pending = null
      act(index, props.onSwitch)
    }, double_click_ms)
    pending = { index, timer }
  }

  /**
   * The docked list (T69).
   *
   * The same rows, the same cursor and the same `clickRow`; what changes is the
   * width, and therefore what is on a row (`sidebarRowPlan`). It keeps the
   * overlay's skeleton — title, a blank line, the list, the footer last (§6.5)
   * — because a second density would be this front end saying the sidebar is a
   * different product from the screen it is docked to.
   *
   * The cursor is drawn only while this pane holds the keyboard. It is not
   * decoration withheld: a highlighted row in an unfocused pane says `Enter`
   * would act on it, and it would not. A click focuses the pane on the way down
   * (`PaneHost`), so the first click on a row is also the one that makes the
   * cursor appear.
   */
  const dockedBody = () => (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={2}>
      <text fg={style.theme.accent.evolve} height={1} flexShrink={0}>
        {fit(`sessions · ${entries().length}`, inner())}
      </text>
      <box height={1} flexShrink={0} />
      <scrollbox
        ref={(box: ScrollBoxRenderable) => (list = box)}
        flexGrow={1}
        flexShrink={1}
        flexBasis={0}
        width="100%"
        scrollX={false}
        viewportCulling
        verticalScrollbarOptions={{
          trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
        }}
        contentOptions={{ flexDirection: "column", width: "100%" }}
      >
        <Index each={rows()}>
          {(item, index) => {
            const row = () => item()
            const tone = () => ({ selected: owns_keys() && index === cursor(), hovered: hover.at() === index })
            const gutter = () => rowGutter(style, tone())
            const here = () => row().entry.id === props.currentId
            const verdict = () => row().entry.outcome?.verdict ?? null
            const click = onClick(() => clickRow(index))
            const persona = () => personaOf(row().entry.composition.prompts)
            const plan = () =>
              sidebarRowPlan(rowInner(), {
                indent: row().depth * 2,
                // The glyph alone: at eighteen columns a persona's name would
                // be taken out of the sentence, and what the rail has to say
                // is that this row is a different KIND of thing. The full view
                // beside it names which one.
                persona: persona() ? ` ${style.glyphs.picker}` : "",
                here: here() ? ` ${style.glyphs.bar}` : "",
                live: leases()[row().entry.id] === "held" ? ` ${style.glyphs.assistant}` : "",
                verdict: verdict() ? ` ${verdict_glyph[verdict()!]}` : "",
                // Padded to the width of the widest one on screen, the same
                // way the full view does it: a clock that starts in a
                // different column on every row is not a column (§6.1 rule 2).
                clock: ` ${ago(row().entry.created).padStart(clock())}`,
              })
            return (
              <box
                id={rowId(row().entry.id)}
                flexDirection="row"
                width="100%"
                height={1}
                flexShrink={0}
                backgroundColor={rowBackground(style, tone())}
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                {...hover.row(index)}
              >
                <text fg={gutter().fg} flexShrink={0}>
                  {gutter().text}
                  {"  ".repeat(row().depth)}
                </text>
                <box flexDirection="row" flexGrow={1} flexShrink={1} flexBasis={0}>
                  <text
                    fg={
                      row().entry.first_user_text.length === 0
                        ? style.theme.faint
                        : here()
                          ? style.theme.accent.user
                          : style.theme.fg
                    }
                  >
                    {fit(title(row().entry), plan().said)}
                  </text>
                </box>
                <Show when={plan().persona.length > 0}>
                  <text fg={style.theme.accent.evolve} flexShrink={0}>
                    {plan().persona}
                  </text>
                </Show>
                <Show when={plan().here.length > 0}>
                  <text fg={style.theme.accent.user} flexShrink={0}>
                    {plan().here}
                  </text>
                </Show>
                <Show when={plan().verdict.length > 0}>
                  <text
                    fg={
                      verdict() === "failure"
                        ? style.theme.err
                        : verdict() === "success"
                          ? style.theme.ok
                          : style.theme.warn
                    }
                    flexShrink={0}
                  >
                    {plan().verdict}
                  </text>
                </Show>
                <Show when={plan().live.length > 0}>
                  <text fg={style.theme.warn} flexShrink={0}>
                    {plan().live}
                  </text>
                </Show>
                <Show when={plan().clock.length > 0}>
                  <text fg={style.theme.muted} flexShrink={0}>
                    {plan().clock}
                  </text>
                </Show>
              </box>
            )
          }}
        </Index>
        <Show when={rows().length === 0 && !notice()}>
          <text fg={style.theme.muted}>{fit("no sessions yet", inner())}</text>
        </Show>
      </scrollbox>
      <Show when={notice()}>
        <text fg={style.theme.err}>{fit(notice()!, inner())}</text>
      </Show>
      {/* The one dim line saying what can be done here (§6.1 rule 8), chosen
          for this width and this state by `railFooter`. The keys are only true
          while the keyboard is here; the count of what is not being shown is
          true either way (T70). */}
      <Show when={railFooter(inner(), owns_keys(), hidden()).length > 0}>
        <text fg={style.theme.dim} height={1} flexShrink={0}>
          {railFooter(inner(), owns_keys(), hidden())}
        </text>
      </Show>
    </box>
  )

  useKeyboard((key) => {
    // Not the focused pane: `useKeyboard` is global, and with a sidebar open
    // there can be two of these listening at once (T69).
    if (!owns_keys()) return
    if (help.consume(key)) return
    if (key.name === "escape") return props.onClose()
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (key.name === "n") return props.onNew()
    if (key.name === "r") return void refresh().then(probe)
    // The two halves of the mouse's one-and-two, on the keyboard: `Enter` is
    // the single click and `t` is the double, so neither input is a second
    // path to a behaviour the other cannot reach (T70).
    if (key.name === "t") return goToTab()
    if (key.name === "a") return setShowAgents((now) => !now)
    if (key.name === "return") return go()
  })

  // The docked variant, chosen once — a mount is one presentation or the other
  // for its whole life. Below `useKeyboard` on purpose: an early return above
  // it would leave the rail unable to answer a single key, which is a bug this
  // file has already had once (T69).
  if (docked()) return dockedBody()

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      {/* The title line carries the id of the pointed row: the list itself is
          made of sentences now, and this is where the machine's name for the one
          under the cursor stays reachable — to paste into `nulya session
          events`, into `/outcome`, into a message to somebody else. Beside the
          count rather than off at the right margin: an id's hash is not a fixed
          length, so a right-aligned one moves the whole line every time the
          cursor does (tui.md §11, T12 — the same shape of bug, one line up). */}
      <box flexDirection="row" width="100%" height={1}>
        <text fg={style.theme.accent.evolve} flexShrink={0}>
          sessions · {entries().length}
        </text>
        <text fg={style.theme.faint} flexShrink={1}>
          {"   "}
          {fit(pointed(), Math.max(0, inner() - 16))}
        </text>
      </box>
      <box height={1} />
      <scrollbox
        ref={(box: ScrollBoxRenderable) => (list = box)}
        flexGrow={1}
        flexShrink={1}
        flexBasis={0}
        width="100%"
        scrollX={false}
        viewportCulling
        verticalScrollbarOptions={{
          trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
        }}
        contentOptions={{ flexDirection: "column", width: "100%" }}
      >
        {/*
          `Index`, not `For`: the list is re-read on a timer and `sessionRows`
          builds fresh objects each time, so `For` would destroy and rebuild
          every row every eight seconds — and a renderable that goes away
          between a press and its release takes the click with it. One
          renderable per POSITION, and only what it says changes. ScrollBox owns
          the viewport; the rows stay mounted by position and the cursor row is
          scrolled into view.
        */}
        <Index each={rows()}>
          {(item, index) => {
            const row = () => item()
            // Only while this pane holds the keyboard: a cursor row in a pane
            // that would not answer `Enter` is a promise the screen cannot keep
            // (T69, and the same reason the docked variant withholds it).
            const selected = () => owns_keys() && index === cursor()
            const tone = () => ({ selected: selected(), hovered: hover.at() === index })
            const gutter = () => rowGutter(style, tone())
            const live = () => leases()[row().entry.id] === "held"
            const here = () => row().entry.id === props.currentId
            const verdict = () => row().entry.outcome?.verdict ?? null
            const click = onClick(() => clickRow(index))
            const clock_cell = () => ` ${ago(row().entry.created).padStart(clock())}`
            const persona = () => personaOf(row().entry.composition.prompts)
            /** The chips that sit at the end of the row, when they apply. */
            const chips = () =>
              (persona() ? ` ${style.glyphs.picker} ${persona()}` : "") +
              (here() ? ` ${style.glyphs.bar} this tab` : "") +
              (verdict() ? ` ${verdict_glyph[verdict()!]} ${verdict()}` : "") +
              (live() ? ` ${style.glyphs.assistant} live` : "")
            /**
             * What is left for the sentence after the fixed ends. This row was
             * the last one in the front end still trusting the terminal with its
             * own wrapping (tui.md §11, T16 "仍未迁"); a long first line and a
             * chip together are exactly the second row that garbles the first.
             */
            const said = () =>
              Math.max(0, rowInner() - 2 - row().depth * 2 - displayWidth(clock_cell()) - displayWidth(chips()))
            return (
              <box
                id={rowId(row().entry.id)}
                flexDirection="row"
                width="100%"
                height={1}
                flexShrink={0}
                backgroundColor={rowBackground(style, tone())}
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                {...hover.row(index)}
              >
                <text fg={gutter().fg} flexShrink={0}>
                  {gutter().text}
                  {"  ".repeat(row().depth)}
                </text>
                {/* The subject of the row, and the reason the row exists. */}
                <box flexDirection="row" flexGrow={1} flexShrink={1} flexBasis={0}>
                  <text
                    fg={
                      row().entry.first_user_text.length === 0
                        ? style.theme.faint
                        : here()
                          ? style.theme.accent.user
                          : style.theme.fg
                    }
                  >
                    {fit(title(row().entry), said())}
                  </text>
                </box>
                {/* Which persona this session was handed, when it is one an
                    agent was given rather than a conversation (T70). `◈` is
                    already "the identity this one is running as" (§6.3) — the
                    same mark the status bar wears it with. */}
                <Show when={persona()}>
                  <text fg={style.theme.accent.evolve} flexShrink={0}>
                    {" "}
                    {style.glyphs.picker} {persona()}
                  </text>
                </Show>
                {/* Which one is on screen right now: a colour alone cannot say it
                    where there are no colours (NO_COLOR, a mono terminal). */}
                <Show when={here()}>
                  <text fg={style.theme.accent.user} flexShrink={0}>
                    {" "}
                    {style.glyphs.bar} this tab
                  </text>
                </Show>
                {/* No verdict is "not judged", which is NOT failure (DESIGN §3.3):
                    an unjudged session shows nothing rather than a neutral chip. */}
                <Show when={verdict()}>
                  <text
                    fg={verdict() === "failure" ? style.theme.err : verdict() === "success" ? style.theme.ok : style.theme.warn}
                    flexShrink={0}
                  >
                    {" "}
                    {verdict_glyph[verdict()!]} {verdict()}
                  </text>
                </Show>
                <Show when={live()}>
                  <text fg={style.theme.warn} flexShrink={0}>
                    {" "}
                    {style.glyphs.assistant} live
                  </text>
                </Show>
                {/* Last, so that it is a column: chips come and go, and a clock
                    that moves left when one appears is not one. */}
                <text fg={style.theme.muted} flexShrink={0}>
                  {clock_cell()}
                </text>
              </box>
            )
          }}
        </Index>
        {/* An empty store is the one moment this view can teach something: what
            a session IS here, and that leaving is free. */}
        <Show when={rows().length === 0 && !notice()}>
          <text fg={style.theme.muted}>{fit("no sessions in this workspace yet", inner())}</text>
          <text fg={style.theme.dim}>
            {fit("n starts one · a session freezes its model and tools at birth · nothing is ever deleted", inner())}
          </text>
        </Show>
      </scrollbox>
      <Show when={notice()}>
        <text fg={style.theme.err}>{fit(notice()!, inner())}</text>
      </Show>
      {/* One dim line, and the count of what is not on it rides in it rather
          than taking a second (T70): `wrapWords` folds at the ` · ` joints, so
          a narrow terminal gets whole phrases instead of a second footer. */}
      <OverlayFooter
        width={inner()}
        help={help}
        brief={`j/k move · Enter go there · t new tab · Esc close${asideText()}`}
        more={[
          "n new · r refresh · click a row to go there, twice for a tab of its own",
          "a shows the sessions agents were delegated — they are driven by their runner, not from here",
          "/outcome records how this one went",
        ]}
      />
    </box>
  )
}
