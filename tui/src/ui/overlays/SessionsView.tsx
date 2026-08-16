/**
 * `/sessions` (F3): every durable session in the workspace (tui.md §5.4).
 *
 * The rows are `nulya session list --json` — the kernel's own read-only
 * projection of `.nulya/sessions/` plus the outcome journal (DESIGN §14), newest
 * first, nested by `parent`. The TUI does not parse headers for this any more:
 * composition, cost and verdict arrive already decided, and the verdict in
 * particular lives in a second journal the front end has no business reading.
 *
 * Two things stay ours. `● live` means some other process holds the writer lease
 * right now — a fact about this instant, not about the file, and the same one
 * that decides driver or observer mode. And there is still no delete: a ledger
 * is append-only, and a view that offered to erase one would be lying about what
 * the system is.
 */
import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useScreen, useStyle } from "../../render/theme.ts"
import { visibleRows, windowRange } from "../list.ts"
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

/** `2026-08-16T09:12:44Z` → `08-16 09:12`; anything else is left alone. */
export function when(created: string): string {
  const at = Date.parse(created)
  if (created.length === 0 || Number.isNaN(at)) return "—"
  const date = new Date(at)
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}

function modelOf(entry: SessionListEntry): string {
  return entry.model_id.length > 0 ? `${entry.provider}/${entry.model_id}` : entry.model || "?"
}

function tokens(n: number): string {
  if (n < 1000) return String(n)
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`
  return `${(n / 1_000_000).toFixed(1)}M`
}

/** What one session cost, or nothing at all when no step was ever priced. */
export function costOf(entry: SessionListEntry): string {
  const { input_tokens, output_tokens, cache_read_tokens, cache_write_tokens } = entry.usage
  if (input_tokens + output_tokens + cache_read_tokens + cache_write_tokens === 0) return ""
  return `↑${tokens(input_tokens + cache_read_tokens + cache_write_tokens)} ↓${tokens(output_tokens)}`
}

const verdict_glyph: Record<Verdict, string> = { success: "+", partial: "~", failure: "!" }

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

  const rows = () => sessionRows(entries())
  // A workspace collects sessions; without a window the list draws straight
  // through the rows below it once there are more than a screenful.
  const range = createMemo(() => windowRange(rows().length, cursor(), visibleRows(screen().height)))
  createEffect(() => {
    const count = rows().length
    if (cursor() >= count) setCursor(Math.max(0, count - 1))
  })

  const move = (delta: number) => {
    const count = rows().length
    if (count === 0) return
    setCursor(Math.min(Math.max(cursor() + delta, 0), count - 1))
  }

  useKeyboard((key) => {
    if (key.name === "escape") return props.onClose()
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (key.name === "n") return props.onNew()
    if (key.name === "r") return void refresh().then(probe)
    if (key.name === "return") {
      const row = rows()[cursor()]
      if (row) props.onOpen(row.entry.id)
    }
  })

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve}>sessions · {entries().length}</text>
      <box height={1} />
      <box flexDirection="column" flexGrow={1} flexShrink={1}>
        <Show when={range().start > 0}>
          <text fg={style.theme.dim}>
            {"  "}
            {style.glyphs.foldClosed} {range().start} newer above
          </text>
        </Show>
        <For each={rows().slice(range().start, range().end)}>
          {(row, offset) => {
            const index = () => range().start + offset()
            const selected = () => index() === cursor()
            const live = () => leases()[row.entry.id] === "held"
            const verdict = () => row.entry.outcome?.verdict ?? null
            const cost = () => costOf(row.entry)
            return (
              <box flexDirection="row" width="100%" backgroundColor={selected() ? style.theme.selection : undefined}>
                <text fg={selected() ? style.theme.fg : style.theme.dim} flexShrink={0}>
                  {selected() ? style.glyphs.foldOpen : " "}{" "}
                  {"  ".repeat(row.depth)}
                </text>
                <text fg={row.entry.id === props.currentId ? style.theme.accent.user : style.theme.fg} flexShrink={0}>
                  {row.entry.id}
                </text>
                <box flexGrow={1} flexShrink={1} flexBasis={0} paddingLeft={1}>
                  <text fg={style.theme.dim}>
                    {when(row.entry.created)} · {modelOf(row.entry)} · {row.entry.events} events
                    {cost() ? ` · ${cost()}` : ""}
                    {row.entry.composition.active.length > 0
                      ? ` · with ${row.entry.composition.active.map((ref) => ref.split("@")[0]).join(" ")}`
                      : ""}
                    {row.entry.first_user_text.length > 0 ? ` · ${row.entry.first_user_text.slice(0, 40)}` : ""}
                  </text>
                </box>
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
              </box>
            )
          }}
        </For>
        <Show when={range().end < rows().length}>
          <text fg={style.theme.dim}>
            {"  "}
            {style.glyphs.foldOpen} {rows().length - range().end} older below
          </text>
        </Show>
        <Show when={rows().length === 0}>
          <text fg={style.theme.dim}>no sessions yet · n to start one</text>
        </Show>
      </box>
      <Show when={notice()}>
        <text fg={style.theme.err}>{notice()}</text>
      </Show>
      <text fg={style.theme.dim}>j/k move · Enter open · n new · r refresh · /outcome judges this one · Esc close</text>
    </box>
  )
}
