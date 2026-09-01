/**
 * `/cwd`: which directory this tab works in (goals/tui-shell.md §5.3b point 2).
 *
 * A minimal directory browser and nothing more. No file preview, no multiple
 * selection, no "new folder" — the question is "which of the directories you
 * already have", and every one of those would be a second question.
 *
 * AN OVERLAY, NOT A COMPOSER DIALOG. §6.5 draws that line at one place: a
 * dialog above the composer may never outgrow its rows, and a listing of a
 * directory obviously can. So it takes the overlay skeleton — title, a blank
 * line, the body, one dim line of keys last — and its list is a scrollbox. Its
 * title carries no glyph, because a browser is a PLACE and only a screen where
 * an identity or a level is chosen wears `◈` (§6.5, §6.3).
 *
 * ONE VERB, and it is worth writing down because two obvious ones would fight:
 * `Enter` always takes the row under the cursor — a directory row is entered,
 * a `no project` / recent / `use this directory` row is chosen. Typing does not
 * need a second confirm gesture, because typing puts the cursor ON `use this
 * directory` for whatever the typed path resolves to: "Enter in the path field"
 * and "Enter on a row" are then the same keystroke doing the same thing, rather
 * than two rules a person has to hold apart.
 *
 * The path field keeps the keyboard the whole time — it is the only control
 * here that takes text, and a browser you cannot paste a path into is a browser
 * that fails at the one thing a terminal user reaches for. The cursor moves on
 * `↑`/`↓` alone for the same reason: `j` and `k` are letters in a path.
 */
import { Index, Show, createEffect, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, ScrollBoxRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { displayWidth, fit } from "../columns.ts"
import { createHover, onClick, rowBackground, rowGutter, rowText } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { browseAt, browserRows, type DirChild, type DirRow, type DirSection, type DirSource } from "../../browsedir.ts"
import { holdsWorkspace, localDirSource } from "../../dirsource.ts"
import { homeWorkspaceDir, workspaceLabel } from "../../workspaces.ts"

export { holdsWorkspace } from "../../dirsource.ts"

/** The heading a run of rows sits under, or nothing for the standing first row. */
const section_title: Record<DirSection, string> = {
  places: "",
  recent: "recent",
  current: "",
  subdirs: "",
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
}) {
  const style = useStyle()
  const screen = useScreen()
  const [typed, setTyped] = createSignal(props.start)
  const [cursor, setCursor] = createSignal(0)
  const hover = createHover()
  const help = createKeyHelp()
  let field: InputRenderable | undefined
  let list: ScrollBoxRenderable | null = null

  const inner = () => Math.max(24, screen().width - 2)
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
  let seq = 0
  createEffect(() => {
    const input = typed()
    const src = source()
    const mine = ++seq
    void browseAt(input, props.start, src).then((result) => {
      if (mine === seq) setBrowsed(result)
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
      {/* A place, so no glyph (§6.5).
          The path here is NOT the path in the field below it, and that is the
          point: the field is what has been typed and the title is what is
          being listed. They agree until somebody types half a name, and then
          the title is the answer to "what am I looking at". */}
      <text fg={style.theme.accent.evolve} height={1} flexShrink={0}>
        {fit(`directory · ${where().dir}`, inner())}
      </text>
      <box height={1} flexShrink={0} />
      <box flexDirection="row" width="100%" height={1} flexShrink={0}>
        <text fg={style.theme.accent.evolve} flexShrink={0}>
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
            /** A heading only where a run of rows begins, never on every row. */
            const heading = () => {
              const title = section_title[row().section]
              if (title.length === 0) return ""
              return rows()[index - 1]?.section === row().section ? "" : title
            }
            /** A directory that has been worked in before (§6.3 `workspaceMark`). */
            const mark = () => (row().workspace ? ` ${style.glyphs.workspaceMark}` : "")
            return (
              <>
                <Show when={heading().length > 0}>
                  <text fg={style.theme.dim} height={1} flexShrink={0}>
                    {`  ${heading()}`}
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
                    flexGrow={1}
                    flexShrink={1}
                  >
                    {fit(row().label, Math.max(4, inner() - 4 - displayWidth(mark())))}
                  </text>
                  <Show when={mark().length > 0}>
                    <text fg={rowText(style, tone(), style.theme.accent.evolve)} flexShrink={0}>
                      {mark()}
                    </text>
                  </Show>
                </box>
              </>
            )
          }}
        </Index>
      </scrollbox>
      <OverlayFooter
        width={inner()}
        help={help}
        brief={"↑↓ move · Enter take the row · Esc close"}
        more={[
          "type or paste a path · ~ expands · the list follows what you type",
          "a directory row is entered; no project, a recent and use this directory are chosen",
          `${style.glyphs.workspaceMark} marks a directory that already has a .nulya/ in it`,
        ]}
      />
    </box>
  )
}
