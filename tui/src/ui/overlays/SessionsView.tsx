/**
 * `/sessions` (F3): every durable session in the workspace (tui.md §5.4).
 *
 * The list is the `.nulya/sessions/` directory, newest first, nested by the
 * header's `parent`. `● live` means some other process holds the writer lease
 * right now — the same fact that decides whether opening one lands in driver or
 * observer mode. There is no delete: a ledger is append-only, and a view that
 * offered to erase one would be lying about what the system is.
 */
import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useScreen, useStyle } from "../../render/theme.ts"
import { visibleRows, windowRange } from "../list.ts"
import { listSessions, type SessionEntry } from "../../nulya/files.ts"
import type { Workspace } from "../../nulya/bin.ts"

interface Row {
  entry: SessionEntry
  depth: number
}

/** Children under their parent, everything else at the root, newest first. */
export function sessionRows(entries: readonly SessionEntry[]): Row[] {
  const byId = new Map(entries.map((entry) => [entry.id, entry]))
  const children = new Map<string, SessionEntry[]>()
  const roots: SessionEntry[] = []
  for (const entry of entries) {
    const parent = entry.header?.parent?.session
    if (parent && byId.has(parent) && parent !== entry.id) {
      children.set(parent, [...(children.get(parent) ?? []), entry])
    } else {
      roots.push(entry)
    }
  }
  const rows: Row[] = []
  const walk = (entry: SessionEntry, depth: number) => {
    rows.push({ entry, depth })
    for (const child of children.get(entry.id) ?? []) walk(child, depth + 1)
  }
  for (const root of roots) walk(root, 0)
  return rows
}

function when(mtime: number): string {
  const date = new Date(mtime)
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}

function modelOf(entry: SessionEntry): string {
  const identity = entry.header?.model_identity
  if (identity && identity.model.length > 0) return `${identity.provider}/${identity.model}`
  return entry.header?.model ?? "?"
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
  const [entries, setEntries] = createSignal<SessionEntry[]>([])
  const [cursor, setCursor] = createSignal(0)

  const refresh = async () => setEntries(await listSessions(props.ws))

  onMount(() => {
    void refresh()
    // The live marker is a fact about right now, so it has to be re-read; the
    // rest of a session file only changes when its writer steps.
    const timer = setInterval(() => void refresh(), 1500)
    onCleanup(() => clearInterval(timer))
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
    if (key.name === "r") return void refresh()
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
            const live = () => row.entry.lease === "held"
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
                    {when(row.entry.mtime)} · {modelOf(row.entry)} · {row.entry.events} events
                    {row.entry.title.length > 0 ? ` · ${row.entry.title.slice(0, 40)}` : ""}
                  </text>
                </box>
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
      <text fg={style.theme.dim}>j/k move · Enter open · n new · r refresh · Esc close</text>
    </box>
  )
}
