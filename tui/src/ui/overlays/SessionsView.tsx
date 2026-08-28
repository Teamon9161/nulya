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
import { workspaceLabel } from "../../workspaces.ts"
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
 *
 * There is a third kind, and it is not a conversation of either sort: a session
 * whose ledger has NO events. A header exists and nothing was ever said into
 * it — a process that was killed before `discardIfUntouched` could take its
 * empty session back. Opening one shows an empty screen, and since T22 a new
 * message freezes a new session anyway, so nothing is lost by leaving it out.
 * It is counted rather than silently dropped (a list quietly shorter than the
 * store is a list that is lying), but unlike the delegated ones there is no key
 * to reveal them: the key would uncover rows with nothing in them.
 */
export type SessionKind = "own" | "delegated" | "empty"

export function sessionKind(entry: SessionListEntry): SessionKind {
  if (entry.events === 0) return "empty"
  return personaOf(entry.composition.prompts) === null ? "own" : "delegated"
}

export function partitionSessions(entries: readonly SessionListEntry[]): {
  own: SessionListEntry[]
  delegated: SessionListEntry[]
  empty: SessionListEntry[]
} {
  const own: SessionListEntry[] = []
  const delegated: SessionListEntry[] = []
  const empty: SessionListEntry[] = []
  for (const entry of entries) {
    const into = { own, delegated, empty }[sessionKind(entry)]
    into.push(entry)
  }
  return { own, delegated, empty }
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
 * The keys are only true while the rail holds the keyboard; the counts are true
 * either way, because a list that is quietly shorter than the store is a list
 * that is lying, focused or not. `empty` has no key beside it — nothing is
 * withheld that anybody could want back (`partitionSessions`) — so it is the
 * first thing given up when the rail is narrow.
 */
export function railFooter(width: number, focused: boolean, hidden: number, empty = 0): string {
  const keys = focused ? "j/k · Enter · Esc" : ""
  // Longest first; each entry is a line somebody reads, so they are written
  // out rather than assembled. `a` rides with the agent count because that is
  // the key that undoes it; the empty count has none.
  const candidates =
    hidden > 0 && empty > 0
      ? focused
        ? [
            `${keys} · ${hidden} agent · a · ${empty} empty`,
            `${hidden} agent · a · ${empty} empty`,
            `${hidden} agent · a`,
          ]
        : [`${hidden} agent hidden · ${empty} empty`, `${hidden} agent · ${empty} empty`, `${hidden} agent`]
      : hidden > 0
        ? focused
          ? [`${keys} · ${hidden} agent · a`, `${hidden} agent hidden · a`, `${hidden} agent · a`]
          : [`${hidden} agent hidden`, `${hidden} agent`]
        : empty > 0
          ? focused
            ? [`j/k · Enter go · t tab · Esc · ${empty} empty`, `${keys} · ${empty} empty`, keys, `${empty} empty`]
            : [`${empty} empty`]
          : focused
            ? ["j/k · Enter go · t tab · Esc", keys]
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

/** One workspace's sessions, as the list holds them (§5.3b point 4). */
export interface SessionGroup {
  readonly ws: Workspace
  readonly entries: readonly SessionListEntry[]
}

/**
 * A row of the list: a workspace heading, or a session under one.
 *
 * Sessions carry their own workspace because that is what acting on one needs
 * — a session in another directory is opened with THAT directory's cwd or it
 * is not opened at all.
 */
export type ListRow =
  | { readonly kind: "group"; readonly ws: Workspace }
  | { readonly kind: "session"; readonly ws: Workspace; readonly entry: SessionListEntry; readonly depth: number }

/**
 * Every row, in order: the front tab's workspace first, and a heading per
 * group ONLY when there is more than one.
 *
 * The condition is the whole of how this feature stays invisible until it is
 * used (§6.1 rule 4: what is not there does not take a row). With one
 * workspace open — which is every session anybody has had until they open a
 * second directory — this returns exactly what it returned before S1c, so the
 * screen is unchanged down to the cell.
 *
 * A group with no sessions still gets its heading: a directory somebody just
 * walked into and has not said anything in yet is precisely the one they need
 * to see is there.
 */
export function groupedRows(groups: readonly SessionGroup[], showAgents: boolean): ListRow[] {
  const many = groups.length > 1
  const out: ListRow[] = []
  for (const group of groups) {
    const shown = group.entries.filter((entry) => {
      const kind = sessionKind(entry)
      return kind === "own" || (kind === "delegated" && showAgents)
    })
    if (many) out.push({ kind: "group", ws: group.ws })
    for (const row of sessionRows(shown)) {
      out.push({ kind: "session", ws: group.ws, entry: row.entry, depth: row.depth })
    }
  }
  return out
}

/**
 * The next row the cursor may land on, walking in `delta`'s direction.
 *
 * Headings are drawn but never selected: `Enter` on one has nothing to do, and
 * a cursor that stops on rows it cannot act on is a cursor that has to be
 * pressed twice. Returns `at` unchanged when there is nothing further that way,
 * which is what makes `j` at the bottom a no-op rather than a wrap.
 */
export function nextSelectable(rows: readonly ListRow[], at: number, delta: number): number {
  const step = delta > 0 ? 1 : -1
  let index = at
  for (let moved = 0; moved < Math.abs(delta) || rows[index]?.kind !== "session"; ) {
    const candidate = index + step
    if (candidate < 0 || candidate >= rows.length) break
    index = candidate
    if (rows[index]?.kind === "session") moved += 1
  }
  return rows[index]?.kind === "session" ? index : at
}

/** The first row a cursor may sit on, or 0 when the list has none. */
export function firstSelectable(rows: readonly ListRow[]): number {
  const at = rows.findIndex((row) => row.kind === "session")
  return at < 0 ? 0 : at
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

/**
 * A row's session, and its depth, for the two row bodies below.
 *
 * A heading row has neither, and both bodies read the fields unconditionally —
 * they are inside a `<Show>` that never draws them for a heading, but Solid's
 * accessors are still evaluated while the fallback is chosen. An empty session
 * rather than a guard at every field: nothing is drawn from it, and the
 * alternative is twenty `row().kind === "session" &&` in a row that already
 * knows what it is.
 */
const no_session: SessionListEntry = {
  id: "",
  created: "",
  first_user_text: "",
  events: 0,
  composition: { active: [], native_tools: [], prompts: [] },
} as unknown as SessionListEntry

function sessionOf(row: ListRow): SessionListEntry {
  return row.kind === "session" ? row.entry : no_session
}

function depthOf(row: ListRow): number {
  return row.kind === "session" ? row.depth : 0
}

/**
 * A workspace heading (§5.3b point 4): its name, then its path in the room
 * that is left.
 *
 * Drawn ONLY when more than one workspace is open (`groupedRows`), so a screen
 * with one directory has never seen this row. The name is what a person
 * recognises; the path is the disambiguation for the day two checkouts of the
 * same repository are open, which is why it is dim and cut rather than absent.
 * The gutter is two blank columns like every other row's, so the name starts on
 * the same column the sentences below it do (§6.5).
 */
/**
 * The narrowest a path may be cut to and still be worth its columns.
 *
 * On the rail there is room for the NAME and nothing else, and a five-column
 * stub of a path is not a disambiguation — it is noise in front of the one
 * word that does the work. Under this the path is not drawn at all (§6.1 rule
 * 4), which is the same "give up cells from the outside in" rule
 * `sidebarRowPlan` follows one screen over.
 */
const min_path = 16

/**
 * A visible, clickable way to start a new tab from the sessions list (T84).
 *
 * Before this row the only way to reach `onNew` from here was `n` on the
 * keyboard — a key nobody who has not already read the footer knows about —
 * or the tab strip's own `+`, which draws nothing at all while a single tab
 * is open (`TabBar.tsx`, `Show when={props.tabs.length > 1}`): the ordinary
 * state for anybody who has not yet split their work into two conversations.
 * Somebody who opened this list — the one place in the front end whose whole
 * job is "which conversation next" — is squarely in "or a new one" territory,
 * so the list gets its own row for it rather than assuming the key is known.
 *
 * Styled like every other row this file draws (`onClick`, a hover
 * background) rather than as a button, because it sits directly above rows
 * that already look exactly like this — a fourth visual language for "you
 * can press this" would be the thing that stood out, not the thing that
 * belongs.
 */
function NewTabRow(props: { onNew: () => void; width: number }) {
  const style = useStyle()
  const [hovered, setHovered] = createSignal(false)
  const click = onClick(() => props.onNew())
  return (
    <box
      flexDirection="row"
      width="100%"
      height={1}
      flexShrink={0}
      backgroundColor={hovered() ? style.theme.hover : undefined}
      onMouseDown={click.onMouseDown}
      onMouseUp={click.onMouseUp}
      onMouseOver={() => setHovered(true)}
      onMouseOut={() => setHovered(false)}
    >
      <text fg={style.theme.faint} flexShrink={0}>
        {"  "}
      </text>
      <text fg={hovered() ? style.theme.accent.user : style.theme.fg} flexShrink={0}>
        {fit(`${style.glyphs.newTab} new tab`, Math.max(0, props.width - 2))}
      </text>
    </box>
  )
}

function GroupHeading(props: { ws: Workspace; width: number }) {
  const style = useStyle()
  const name = () => workspaceLabel(props.ws.dir)
  const room = () => Math.max(0, props.width - 2 - displayWidth(name()) - 2)
  return (
    <box flexDirection="row" width="100%" height={1} flexShrink={0}>
      <text fg={style.theme.faint} flexShrink={0}>
        {"  "}
      </text>
      <text fg={style.theme.accent.evolve} flexShrink={0}>
        {name()}
      </text>
      <text fg={style.theme.dim} flexShrink={1}>
        {room() >= min_path ? `  ${fit(props.ws.dir, room())}` : ""}
      </text>
    </box>
  )
}

export function SessionsView(props: {
  /**
   * The workspaces to list, the front tab's first (§5.3b point 4).
   *
   * A LIST rather than one workspace, because a tab is (workspace, session)
   * now and the point of the sessions list is finding the conversation you
   * want — which is as likely to be in the other repository you have a tab in.
   * Each group is its own `session list --json`: the kernel projects one
   * `.nulya/sessions/` at a time, and nothing here merges two directories into
   * one store.
   */
  workspaces: readonly Workspace[]
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
  onSwitch: (id: string, ws: Workspace) => void
  /** …and the deliberate one: keep what is here and give that session a tab too. */
  onOpenTab: (id: string, ws: Workspace) => void
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
  const [groups, setGroups] = createSignal<SessionGroup[]>([])
  const entries = () => groups().flatMap((group) => group.entries)
  const [leases, setLeases] = createSignal<Record<string, LeaseState>>({})
  const [cursor, setCursor] = createSignal(0)
  const [notice, setNotice] = createSignal<string | null>(null)
  /** `a`: show the delegated sessions too, this mount only (T70). */
  const [showAgents, setShowAgents] = createSignal(false)
  let list: ScrollBoxRenderable | null = null
  const hover = createHover()
  const help = createKeyHelp()

  /**
   * One `session list --json` per workspace. A directory that will not answer
   * becomes an empty group and a notice rather than an empty screen: the other
   * groups are still true, and losing all of them because one path went away
   * (an unmounted drive, a deleted checkout) is the wrong trade.
   */
  const refresh = async () => {
    const found: SessionGroup[] = []
    const failures: string[] = []
    for (const one of props.workspaces) {
      try {
        found.push({ ws: one, entries: await sessionList(one) })
      } catch (error) {
        found.push({ ws: one, entries: [] })
        failures.push(`${workspaceLabel(one.dir)}: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
    setGroups(found)
    setNotice(failures[0] ?? null)
  }

  /** A lease is per (workspace, session): the lock file is beside the session file. */
  const leaseKey = (ws: Workspace, id: string) => `${ws.dir}|${id}`

  /** Cheap, file-only, and the one thing the projection cannot carry: who is writing now. */
  const probe = () => {
    const seen: Record<string, LeaseState> = {}
    for (const group of groups()) {
      for (const entry of group.entries) seen[leaseKey(group.ws, entry.id)] = probeWriterLease(group.ws, entry.id)
    }
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
    const now = `${props.currentId}|${props.workspaces.map((one) => one.dir).join("|")}`
    // …and the same beat for a workspace arriving or leaving: a tab that just
    // walked into a directory adds a whole group, and waiting twenty seconds
    // for it would make the sidebar look like it had not noticed.
    if (seen !== undefined && seen !== now) void refresh().then(probe)
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
  const rows = createMemo(() => groupedRows(groups(), showAgents()))
  /** Positional, because `<Index>` is: one renderable per slot, contents change. */
  const rowId = (index: number) => `session-row:${index}`
  createEffect(() => {
    const list_rows = rows()
    if (list_rows[cursor()]?.kind !== "session") setCursor(firstSelectable(list_rows))
  })
  createEffect(() => {
    if (rows()[cursor()]) list?.scrollChildIntoView(rowId(cursor()))
  })

  /**
   * One width for every `ago` on screen, so they line up as a column instead of
   * a ragged edge. Measured from the mounted rows; ScrollBox decides which of
   * them are visible.
   */
  const clock = createMemo(() => {
    const now = Date.now()
    let widest = 0
    for (const row of rows()) {
      if (row.kind === "session") widest = Math.max(widest, displayWidth(ago(row.entry.created, now)))
    }
    return widest
  })

  /** The id of the row the cursor is on: unreadable, occasionally needed, printed once. */
  const pointed = () => {
    const row = rows()[cursor()]
    return row?.kind === "session" ? row.entry.id : ""
  }

  /**
   * What the full view's key line adds about the rows it is not drawing (T70),
   * or nothing at all when there are none to speak of (§6.1 rule 4). Both
   * states name the key, because "these are showing" is as worth undoing as
   * "these are hidden".
   */
  const asideText = () => {
    const nothing = split().empty.length
    // Said whichever way `a` is set: an empty session is not one of the two
    // kinds that key switches between, it is a row with nothing in it.
    const aside = nothing > 0 ? ` · ${nothing} empty ${nothing === 1 ? "session" : "sessions"} not listed` : ""
    if (showAgents()) return (split().delegated.length > 0 ? " · a hides delegated sessions" : "") + aside
    const n = hidden()
    return (n > 0 ? ` · ${n} agent ${n === 1 ? "session" : "sessions"} hidden · a shows` : "") + aside
  }

  const move = (delta: number) => {
    if (rows().length === 0) return
    setCursor(nextSelectable(rows(), cursor(), delta))
  }

  const act = (index: number, take: (id: string, ws: Workspace) => void) => {
    const row = rows()[index]
    if (row?.kind === "session") take(row.entry.id, row.ws)
  }
  const go = () => act(cursor(), (id, where) => props.onSwitch(id, where))
  const goToTab = () => act(cursor(), (id, where) => props.onOpenTab(id, where))

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
    if (rows()[index]?.kind !== "session") return
    setCursor(index)
    const twice = pending?.index === index
    forget()
    if (twice) return act(index, (id, where) => props.onOpenTab(id, where))
    const timer = setTimeout(() => {
      pending = null
      act(index, (id, where) => props.onSwitch(id, where))
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
      <NewTabRow onNew={props.onNew} width={inner()} />
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
            const entry = () => sessionOf(row())
            const tone = () => ({ selected: owns_keys() && index === cursor(), hovered: hover.at() === index })
            const gutter = () => rowGutter(style, tone())
            const here = () => entry().id === props.currentId
            const verdict = () => entry().outcome?.verdict ?? null
            const click = onClick(() => clickRow(index))
            const persona = () => personaOf(entry().composition.prompts)
            const plan = () =>
              sidebarRowPlan(rowInner(), {
                indent: depthOf(row()) * 2,
                // The glyph alone: at eighteen columns a persona's name would
                // be taken out of the sentence, and what the rail has to say
                // is that this row is a different KIND of thing. The full view
                // beside it names which one.
                persona: persona() ? ` ${style.glyphs.picker}` : "",
                here: here() ? ` ${style.glyphs.bar}` : "",
                live: leases()[leaseKey(row().ws, entry().id)] === "held" ? ` ${style.glyphs.assistant}` : "",
                verdict: verdict() ? ` ${verdict_glyph[verdict()!]}` : "",
                // Padded to the width of the widest one on screen, the same
                // way the full view does it: a clock that starts in a
                // different column on every row is not a column (§6.1 rule 2).
                clock: ` ${ago(entry().created).padStart(clock())}`,
              })
            return (
              <Show when={row().kind === "session"} fallback={<GroupHeading ws={row().ws} width={rowInner()} />}>
              <box
                id={rowId(index)}
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
                  {"  ".repeat(depthOf(row()))}
                </text>
                <box flexDirection="row" flexGrow={1} flexShrink={1} flexBasis={0}>
                  <text
                    fg={
                      entry().first_user_text.length === 0
                        ? style.theme.faint
                        : here()
                          ? style.theme.accent.user
                          : style.theme.fg
                    }
                  >
                    {fit(title(entry()), plan().said)}
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
              </Show>
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
      <Show when={railFooter(inner(), owns_keys(), hidden(), split().empty.length).length > 0}>
        <text fg={style.theme.dim} height={1} flexShrink={0}>
          {railFooter(inner(), owns_keys(), hidden(), split().empty.length)}
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
      <NewTabRow onNew={props.onNew} width={inner()} />
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
            const entry = () => sessionOf(row())
            const tone = () => ({ selected: selected(), hovered: hover.at() === index })
            const gutter = () => rowGutter(style, tone())
            const live = () => leases()[leaseKey(row().ws, entry().id)] === "held"
            const here = () => entry().id === props.currentId
            const verdict = () => entry().outcome?.verdict ?? null
            const click = onClick(() => clickRow(index))
            const clock_cell = () => ` ${ago(entry().created).padStart(clock())}`
            const persona = () => personaOf(entry().composition.prompts)
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
              Math.max(0, rowInner() - 2 - depthOf(row()) * 2 - displayWidth(clock_cell()) - displayWidth(chips()))
            return (
              <Show when={row().kind === "session"} fallback={<GroupHeading ws={row().ws} width={rowInner()} />}>
              <box
                id={rowId(index)}
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
                  {"  ".repeat(depthOf(row()))}
                </text>
                {/* The subject of the row, and the reason the row exists. */}
                <box flexDirection="row" flexGrow={1} flexShrink={1} flexBasis={0}>
                  <text
                    fg={
                      entry().first_user_text.length === 0
                        ? style.theme.faint
                        : here()
                          ? style.theme.accent.user
                          : style.theme.fg
                    }
                  >
                    {fit(title(entry()), said())}
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
              </Show>
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
