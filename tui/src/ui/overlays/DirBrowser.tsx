/**
 * A workspace browser shared by local and remote directory selection.
 * Enter takes the cursor's row: folders are entered, workspaces are chosen.
 * Typing moves the cursor to `use this directory` after the listing resolves.
 * The path field keeps focus throughout; only arrow keys move the row cursor,
 * since j/k must remain ordinary path characters.
 */
import { Index, Show, createEffect, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, ScrollBoxRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { columnWidth, displayWidth, fit } from "../columns.ts"
import { ascii_border } from "../Composer.tsx"
import { createHover, onClick, rowBackground, rowGutter, rowText } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { browseAt, browserRows, type DirChild, type DirRow, type DirSection, type DirSource } from "../../browsedir.ts"
import { holdsWorkspace, localDirSource } from "../../dirsource.ts"
import { homeWorkspaceDir, workspaceLabel } from "../../workspaces.ts"

export { holdsWorkspace } from "../../dirsource.ts"

/** The heading a run of rows sits under, or nothing for the standing first row. */
const section_title: Record<DirSection, string> = {
  places: "",
  recent: "recent workspaces",
  current: "current directory",
  subdirs: "folders",
}

export function DirBrowser(props: {
  /** Where the browser opens: the workspace the tab is in right now. */
  start: string
  /** Remembered workspaces, newest first (`state/recents.ts`). Meaningless for a remote `source` — pass `[]`. */
  recents: readonly string[]
  /** Take this directory as the tab's workspace. */
  onChoose: (dir: string) => void
  onClose: () => void
  /**
   * Where listings and existence checks come from — this machine's disk by
   * default (`dirsource.ts`'s `localDirSource`), or a channel to another one
   * (`remoteDirSource`) when this browser is choosing a `remote:` `/env`
   * target's workspace rather than this tab's own directory.
   */
  source?: DirSource
  /** The standing first row's target and what it says — `no project` locally; meaningless (and omittable) for a remote source, which has no such answer. */
  homeDir?: string
  /** How a row's directory is drawn. Defaults to `workspaceLabel` (trust wording, `.nulya/` mentions) — none of which apply to a machine this process cannot inspect that way. */
  label?: (dir: string) => string
  /** Whether a directory already holds a `.nulya/`. Defaults to `holdsWorkspace` (a local `stat`); omit for a remote source, which cannot answer this without a round trip per row it has no use for (`remoteDirSource`'s own doc). */
  isWorkspace?: (dir: string) => boolean
  /**
   * WHICH MACHINE these directories are on, when it is not this one. A remote
   * listing looks exactly like a local one — same paths, same names, often the
   * same home directory — so without this the one thing a person needs to know
   * before choosing is the one thing the screen does not say.
   */
  on?: string
}) {
  const style = useStyle()
  const screen = useScreen()
  const [typed, setTyped] = createSignal(props.start)
  const [cursor, setCursor] = createSignal(0)
  const hover = createHover()
  const help = createKeyHelp()
  let field: InputRenderable | undefined
  let list: ScrollBoxRenderable | null = null

  const inner = () => Math.max(1, screen().width - 2)
  const ascii = () => style.settings.transcript.ascii
  /** Reserve the machine and loading state before fitting the title. */
  const titleSuffix = () => `${props.on ? ` · on ${props.on}` : ""}${listing() ? " · listing…" : ""}`
  const source = () => props.source ?? localDirSource()
  const home = props.homeDir ?? homeWorkspaceDir()

  /**
   * What `typed()` resolves to against `source()`, refetched every time
   * either changes. A signal rather than a memo: the read is async, so there
   * is no synchronous value for a memo to hold between the input changing and
   * the round trip answering it — `browsed` starts each pass holding what it
   * last knew and only moves once the newest request settles, so typing
   * ahead of a slow remote answer never shows a directory nobody asked for.
   *
   * `seq` guards against exactly that: a stale reply from an earlier
   * keystroke landing after a newer one already changed what should be on
   * screen (`browseAt` for `remote:` targets is a real round trip and pays no
   * attention to arrival order on its own).
   */
  const [browsed, setBrowsed] = createSignal<{ dir: string; filter: string; children: DirChild[] }>({
    dir: props.start,
    filter: "",
    children: [],
  })
  /**
   * Whether a listing is in flight. Over a channel that is a whole ssh
   * connection per directory, so the difference between "empty" and "not back
   * yet" is seconds long and the screen must not read as the first while it is
   * the second. Locally it settles within a microtask and nobody sees it.
   */
  const [listing, setListing] = createSignal(false)
  let seq = 0
  createEffect(() => {
    const input = typed()
    const src = source()
    const mine = ++seq
    setListing(true)
    void browseAt(input, props.start, src).then((result) => {
      if (mine !== seq) return
      setBrowsed(result)
      setListing(false)
    })
  })
  const where = () => ({ dir: browsed().dir, filter: browsed().filter })
  const children = () => browsed().children
  const rows = createMemo(() =>
    browserRows({
      dir: where().dir,
      children: children(),
      filter: where().filter,
      recents: props.recents,
      homeDir: home,
      label: props.label ?? ((dir) => workspaceLabel(dir)),
      isWorkspace: props.isWorkspace ?? holdsWorkspace,
      join: source().join,
      dirname: source().dirname,
    }),
  )

  /**
   * The row `Enter` lands on after a re-resolve: `use this directory`.
   *
   * This is the whole of "Enter in the path field confirms" (§5.3b). Typing a
   * path and pressing Enter selects it, and it does so through the same code
   * path a click on that row uses, so the two can never mean different things.
   */
  const useRow = () => Math.max(0, rows().findIndex((row) => row.kind === "use"))
  createEffect(() => {
    // A new listing: the cursor from the old one means nothing.
    where().dir
    where().filter
    setCursor(useRow())
  })
  createEffect(() => {
    const at = rows()[cursor()]
    if (at) list?.scrollChildIntoView(rowId(cursor()))
  })
  const rowId = (index: number) => `dir-row:${index}`
  const selected = () => rows()[cursor()]
  const actionLabel = (row: DirRow) => row.kind === "parent" ? "up" : row.action === "enter" ? "open" : "choose"
  const actionWidth = () => columnWidth(rows().map(actionLabel), 0)
  const nameWidth = () => columnWidth(rows().filter((row) => row.kind === "recent").map((row) => row.label))
  const folderCount = () => rows().filter((row) => row.kind === "child").length
  const foldersHeading = () => listing() ? "folders" : `folders · ${folderCount()}${where().filter ? ` · starts with ${where().filter}` : ""}`

  onMount(() => field?.focus())

  const move = (delta: number) => {
    const count = rows().length
    if (count === 0) return
    setCursor(Math.min(Math.max(cursor() + delta, 0), count - 1))
  }

  /** Browse into a directory: the path field follows, so the two never disagree. */
  const enter = (dir: string) => {
    setTyped(dir)
    if (field) field.value = dir
  }

  const take = (row: DirRow | undefined) => {
    if (!row) return
    if (row.action === "enter") return enter(row.path)
    props.onChoose(row.path)
  }

  const clickRow = (index: number) => {
    setCursor(index)
    take(rows()[index])
  }

  useKeyboard((key) => {
    if (help.consume(key)) return
    if (key.name === "escape") return props.onClose()
    if (key.name === "up") return move(-1)
    if (key.name === "down") return move(1)
    if (key.name === "pageup") return move(-8)
    if (key.name === "pagedown") return move(8)
    if (key.name === "return") return take(rows()[cursor()])
    // Everything else is text: the field has the focus and OpenTUI delivers it
    // there once this listener declines the key.
  })

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <box flexDirection="row" width="100%" height={1} flexShrink={0}>
        <text fg={style.theme.accent.evolve} flexShrink={1}>
          {fit("  directory · choose a workspace", Math.max(1, inner() - displayWidth(titleSuffix())))}
        </text>
        {/* The machine, in the warn colour every other surface uses for
            "not here" — a path on somebody else's disk reads identically to
            one on this one. */}
        <Show when={props.on}>
          <text fg={style.theme.warn} flexShrink={0}>{` · on ${props.on}`}</text>
        </Show>
        <Show when={listing()}>
          <text fg={style.theme.dim} flexShrink={0}>{" · listing…"}</text>
        </Show>
      </box>
      <box height={1} flexShrink={0} />
      <box
        flexDirection="row"
        width="100%"
        height={3}
        flexShrink={0}
        border
        borderStyle={ascii() ? "single" : "rounded"}
        customBorderChars={ascii() ? ascii_border : undefined}
        borderColor={style.theme.accent.user}
        paddingLeft={1}
        paddingRight={1}
        onMouseDown={() => field?.focus()}
      >
        <text fg={style.theme.accent.user} flexShrink={0}>
          {`${style.glyphs.user} `}
        </text>
        <input
          ref={(el: InputRenderable) => (field = el)}
          flexGrow={1}
          focused
          value={props.start}
          placeholder="type or paste a path · ~ works"
          placeholderColor={style.theme.dim}
          textColor={style.theme.fg}
          focusedTextColor={style.theme.fg}
          cursorColor={style.theme.accent.user}
          onInput={(value: unknown) => setTyped(typeof value === "string" ? value : (field?.value ?? ""))}
        />
      </box>
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
            const tone = () => ({ selected: index === cursor(), hovered: hover.at() === index })
            const gutter = () => rowGutter(style, tone())
            const click = onClick(() => clickRow(index))
            const heading = () => {
              if (rows()[index - 1]?.section === row().section) return ""
              return row().section === "subdirs" ? foldersHeading() : section_title[row().section]
            }
            const mark = () => (row().workspace ? ` ${style.glyphs.workspaceMark}` : "")
            const available = () => Math.max(1, inner() - 2 - displayWidth(mark()) - actionWidth() - 2)
            // Recent names can collide; show their paths only when there is
            // room for a useful column. The selected path stays in the footer.
            const pathWidth = () => row().kind === "recent" && available() - nameWidth() - 2 >= 24
              ? available() - nameWidth() - 2 : 0
            const labelWidth = () => pathWidth() > 0 ? nameWidth() : available()
            const label = () => row().kind === "child" || row().kind === "parent" ? `${row().label}/` : row().label
            return (
              <>
                <Show when={heading().length > 0}>
                  <box height={1} flexShrink={0} />
                  <text fg={style.theme.dim} height={1} flexShrink={0}>
                    {fit(`  ${heading()}`, inner())}
                  </text>
                </Show>
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
                  </text>
                  <text
                    fg={rowText(
                      style,
                      tone(),
                      row().kind === "use" || row().kind === "home"
                        ? style.theme.accent.evolve
                        : row().kind === "parent"
                        ? style.theme.faint
                        : style.theme.fg,
                    )}
                    width={labelWidth()}
                    flexShrink={0}
                  >
                    {fit(label(), labelWidth())}
                  </text>
                  <Show when={pathWidth() > 0}>
                    <text fg={rowText(style, tone(), style.theme.dim)} width={pathWidth() + 2} flexShrink={0}>
                      {`  ${fit(row().path, pathWidth())}`}
                    </text>
                  </Show>
                  <Show when={mark().length > 0}>
                    <text fg={rowText(style, tone(), style.theme.accent.evolve)} flexShrink={0}>
                      {mark()}
                    </text>
                  </Show>
                  <text
                    fg={rowText(style, tone(), tone().selected ? style.theme.fg : style.theme.dim)}
                    width={actionWidth() + 2}
                    flexShrink={0}
                  >
                    {`  ${actionLabel(row()).padStart(actionWidth())}`}
                  </text>
                </box>
              </>
            )
          }}
        </Index>
        <Show when={listing() || folderCount() === 0}>
          <text fg={style.theme.dim} height={1} flexShrink={0}>
            {fit(`  ${listing() ? "listing folders…" : where().filter ? "no matching folders" : "no visible subdirectories"}`, inner())}
          </text>
        </Show>
      </scrollbox>
      <box height={1} flexShrink={0} />
      <box width="100%" paddingLeft={2} flexShrink={0}>
        <OverlayFooter
          width={Math.max(1, inner() - 2)}
          help={help}
          notice={selected() ? fit(selected()!.path, inner() - 2) : null}
          brief={`↑↓ move · Enter ${selected() ? actionLabel(selected()!) : "choose"} · Esc close`}
          more={[
            "type or paste a path · ~ expands · the list follows what you type",
            "a directory row is entered; no project, a recent and use this directory are chosen",
            `${style.glyphs.workspaceMark} marks a directory that already has a .nulya/ in it`,
          ]}
        />
      </box>
    </box>
  )
}
