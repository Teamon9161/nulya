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
 * The line that makes a row recognisable: what was asked of it first.
 *
 * A session with nothing in it says so in words. It is the one row whose
 * emptiness the event count used to carry (`0 events`), and that count is gone.
 */
export function title(entry: SessionListEntry): string {
  return entry.first_user_text.length > 0 ? entry.first_user_text : "nothing said yet"
}

export function SessionsView(props: {
  ws: Workspace
  /** The session in front, so the list can say which one that is. */
  currentId: string
  onOpen: (id: string) => void
  onNew: () => void
  onClose: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [entries, setEntries] = createSignal<SessionListEntry[]>([])
  const [leases, setLeases] = createSignal<Record<string, LeaseState>>({})
  const [cursor, setCursor] = createSignal(0)
  const [notice, setNotice] = createSignal<string | null>(null)
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

  onMount(() => {
    void refresh().then(probe)
    // The live marker is re-read often; the list itself costs a process and a
    // read of every session file, so it refreshes on a slower beat (and on `r`).
    const live = setInterval(probe, 1500)
    const full = setInterval(() => void refresh().then(probe), 8000)
    onCleanup(() => {
      clearInterval(live)
      clearInterval(full)
    })
  })

  /** The columns this overlay may draw in: the box pads one on each side. */
  const inner = () => Math.max(24, screen().width - 2)
  /** Rows leave one column for ScrollBox's vertical track and one for air beside it. */
  const rowInner = () => Math.max(24, screen().width - 4)
  const rows = () => sessionRows(entries())
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

  const move = (delta: number) => {
    const count = rows().length
    if (count === 0) return
    setCursor(Math.min(Math.max(cursor() + delta, 0), count - 1))
  }

  const open = () => {
    const row = rows()[cursor()]
    if (row) props.onOpen(row.entry.id)
  }

  /**
   * A click lands the cursor; a click on the row the cursor is already on does
   * what Enter does. Two presses for something irreversible-ish (a second tab,
   * a second attachment) rather than one, and the same `open` either way — the
   * mouse must not be a second path to a second behaviour.
   */
  const clickRow = (index: number) => {
    if (cursor() === index) return open()
    setCursor(index)
  }

  useKeyboard((key) => {
    if (help.consume(key)) return
    if (key.name === "escape") return props.onClose()
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (key.name === "n") return props.onNew()
    if (key.name === "r") return void refresh().then(probe)
    if (key.name === "return") return open()
  })

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
            const selected = () => index === cursor()
            const tone = () => ({ selected: selected(), hovered: hover.at() === index })
            const gutter = () => rowGutter(style, tone())
            const live = () => leases()[row().entry.id] === "held"
            const here = () => row().entry.id === props.currentId
            const verdict = () => row().entry.outcome?.verdict ?? null
            const click = onClick(() => clickRow(index))
            const clock_cell = () => ` ${ago(row().entry.created).padStart(clock())}`
            /** The chips that sit at the end of the row, when they apply. */
            const chips = () =>
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
      <OverlayFooter
        width={inner()}
        help={help}
        brief="j/k move · Enter open · Esc close"
        more={["n new · r refresh · click a row to select it, again to open it", "/outcome records how this one went"]}
      />
    </box>
  )
}
