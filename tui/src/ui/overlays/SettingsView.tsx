/**
 * `/settings`: the values in force right now, which file each layer came from
 * (tui.md §7), and — since T100 — the place they are changed.
 *
 * IT WRITES, AND THAT IS NOT A SECOND AUTHOR. This screen used to say
 * "read-only here, edit the file", on the reasoning that a TUI which also wrote
 * settings would be a second author of the same truth. The reasoning was about
 * a program that RE-SERIALISES a file: give the same value two writers with two
 * layouts and "where does this come from" stops having one answer. That is not
 * what happens here. There is one author — the person — and this screen is
 * their pen: an edit finds the line the key is already on and replaces it, or
 * adds one line to the table it belongs to, and leaves the file the same
 * document, comments, order and all (`state/settingsfile.ts`, following
 * `nulya/credentials.ts`). Refusing to write was also the one thing D10 says a
 * front end may not do: everything is done on the screen, and "go and find a
 * config file" is the instruction that rule exists to forbid.
 *
 * The user layer is what it writes, always. A project `tui.toml` arrives with a
 * checkout and belongs to the checkout; when one of them already sets a key,
 * that key says so and the write is refused rather than made where it would
 * have no effect.
 *
 * WHAT IT DOES LEAD TO (T92). Not every choice on this screen lives in that
 * file: the model, the permission mode, the working directory and where the
 * shell runs are chosen in the interface and remembered in `tui-state.json`,
 * which is this front end's own note to itself and not a second author of
 * anybody's settings. Those are listed FIRST, each naming the command that
 * opens it and answering to a click — so a person who came here by clicking
 * `settings` finds the things they can actually change, rather than a table
 * whose only instruction is to go and edit a file.
 *
 * WHAT THE FILE WILL TAKE (T94). Every row of the lower table names what it
 * accepts beside what it is set to, and the table is every key the parser
 * reads (`state/settings.ts`'s `setting_fields`). That vocabulary is now used
 * twice — printed in the third column, and offered by the picker Enter opens —
 * so the words a key takes are written in exactly one place.
 *
 * ONE LIST OF ROWS. The body is a flat array of rows rather than three nested
 * blocks, because a cursor needs an answer to "which line is this" that the
 * layout cannot disagree with: the row's index IS its offset in the scrollbox,
 * so keeping the cursor in view is arithmetic rather than a second model of
 * how tall the header happens to be.
 *
 * A path is the one thing on this screen with no length limit, so both tables
 * are cut to their columns and the closing sentence is broken at its joints
 * rather than wrapped by the terminal (`ui/columns.ts`).
 */
import { For, Match, Show, Switch, createEffect, createMemo, createSignal } from "solid-js"
import { existsSync } from "node:fs"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable, ScrollBoxRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { columnWidth, fit } from "../columns.ts"
import { createHover, lifted, onClick, rowBackground, rowGutter, rowText } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import {
  acceptsOf,
  editedValue,
  settingsPaths,
  setting_fields,
  default_settings,
  type SettingEdit,
  type Settings,
} from "../../state/settings.ts"
import { layerSets, readLayer, writeSetting } from "../../state/settingsfile.ts"
import type { Workspace } from "../../nulya/bin.ts"

export interface SettingRow {
  key: string
  value: string
  /** What the file will take here — empty for a key binding, whose set is open. */
  accepts: string
  changed: boolean
  /** How this screen changes it; absent for a key it will not write. */
  edit?: SettingEdit
  /** What the new value does not say about itself (`SettingField.note`). */
  note?: string
}

/**
 * Every key, what it is set to, and what it accepts.
 *
 * The list comes from `setting_fields` — the one description of what the
 * parser reads — plus a row for each key binding actually overridden. Bindings
 * are not in that table because they are not a fixed set of keys: `keys.<any
 * action>` is the shape, `/help` names the actions, and a row per action would
 * be the whole keymap listed twice. They are also the one thing this screen
 * will not write for the same reason: there is no closed list to offer and no
 * way to check a binding is one.
 */
export function settingRows(settings: Settings): SettingRow[] {
  const rows: SettingRow[] = setting_fields.map((field) => ({
    key: field.key,
    value: field.value(settings),
    accepts: acceptsOf(field),
    changed: field.value(settings) !== field.value(default_settings),
    ...(field.edit ? { edit: field.edit } : {}),
    ...(field.note ? { note: field.note } : {}),
  }))
  for (const [action, binding] of Object.entries(settings.keys)) {
    rows.push({ key: `keys.${action}`, value: binding, accepts: "", changed: true })
  }
  return rows
}

/**
 * One live choice: what it is, what it is set to, and the way to change it.
 *
 * `command` is not decoration — it is what a keyboard reaches this by, and the
 * row would be a mouse-only control without it. `open` is the same function the
 * status line’s own chip calls, so the two entrances cannot drift.
 */
export interface SettingChoice {
  label: string
  value: string
  command: string
  open: () => void
}

/** What the input starts with when a typed row is opened: the value, editable. */
export function draftOf(row: SettingRow): string {
  if (row.edit?.kind === "list") return row.value === "—" ? "" : row.value
  return row.value
}

/** The rows of the body, in the order they are drawn — index is offset. */
interface CaptionRow {
  kind: "caption"
  text: string
}
interface BlankRow {
  kind: "blank"
}
interface ChoiceBodyRow {
  kind: "choice"
  choice: SettingChoice
}
interface PathRow {
  kind: "path"
  path: string
  applied: boolean
  present: boolean
}
interface SettingBodyRow {
  kind: "setting"
  row: SettingRow
  /** A nearer layer already sets this key, so a write here would be inert. */
  project: boolean
}
type BodyRow = CaptionRow | BlankRow | ChoiceBodyRow | PathRow | SettingBodyRow

export function SettingsView(props: {
  ws: Workspace
  onClose: () => void
  /** The choices this front end makes and remembers itself. Absent in tests. */
  choices?: readonly SettingChoice[]
  /**
   * A key was written: reload the settings this whole front end is drawn from.
   * Absent in tests, where the write itself is what is being checked.
   */
  onEdited?: () => void | Promise<void>
}) {
  const style = useStyle()
  const screen = useScreen()
  const settings = () => style.settings
  const help = createKeyHelp()
  const hover = createHover()
  /** The picker's own pointer: a second list means a second slot to clear. */
  const pickHover = createHover()
  /** The table, a value being chosen from a list, or a value being typed. */
  const [mode, setMode] = createSignal<"table" | "pick" | "type">("table")
  const [at, setAt] = createSignal(0)
  const [pickAt, setPickAt] = createSignal(0)
  const [notice, setNotice] = createSignal<string | null>(null)
  /** Bumped after a write so the layer files below are read again. */
  const [written, setWritten] = createSignal(0)
  let body: ScrollBoxRenderable | null = null
  let field: InputRenderable | null = null

  const paths = createMemo(() => settingsPaths(props.ws.dir))
  const userPath = () => paths()[0]!
  const projectPath = () => paths()[1]!
  /**
   * The project layer as it stands on disk, for one question: does it already
   * set this key? A nearer layer wins (§7), so writing the user layer under one
   * would change the file and nothing else.
   */
  const project = createMemo(() => {
    written()
    return readLayer(projectPath())
  })

  const candidates = () =>
    paths().map((path) => ({
      path,
      applied: settings().sources.includes(path),
      present: existsSync(path),
    }))

  /**
   * The columns this overlay may draw in: one of padding on each side, plus the
   * two the scrollbar's track takes out of the body (`HelpView` says why).
   */
  const inner = () => Math.max(20, screen().width - 4)
  const choices = () => props.choices ?? []
  const rows = createMemo(() => settingRows(settings()))

  const bodyRows = createMemo<BodyRow[]>(() => {
    const out: BodyRow[] = []
    if (choices().length > 0) {
      out.push({ kind: "caption", text: "chosen here and remembered in tui-state.json" })
      for (const choice of choices()) out.push({ kind: "choice", choice })
      out.push({ kind: "blank" })
    }
    for (const entry of candidates()) out.push({ kind: "path", ...entry })
    out.push({ kind: "blank" })
    for (const row of rows()) {
      out.push({ kind: "setting", row, project: layerSets(project(), row.key) })
    }
    return out
  })

  const stateCol = createMemo(() => columnWidth(["applied", "unreadable", "absent"], 2, 12))
  /** A `keys.*` name is the widest thing here, and a path is the least bounded. */
  const keyCol = createMemo(() =>
    Math.min(columnWidth(rows().map((row) => row.key), 2, 30), Math.max(10, inner() - 2 - 16)),
  )
  const valueCol = createMemo(() => columnWidth(rows().map((row) => row.value), 2, 20))
  const choiceCol = createMemo(() => columnWidth(choices().map((one) => one.label), 2, 18))
  const choiceValueCol = createMemo(() => columnWidth(choices().map((one) => one.value), 2, 24))

  /** The third column: the vocabulary, the default when it is not in force, and who wins. */
  const accepts = (entry: SettingBodyRow) => {
    const was = setting_fields.find((one) => one.key === entry.row.key)
    const back = entry.row.changed && was ? ` · default ${was.value(default_settings)}` : ""
    // FIRST, not last. It is said on the row rather than only when Enter
    // refuses — a value that cannot be changed from here should look different
    // before anybody tries — and this is the column that gets cut, so the
    // clause which has to survive a narrow terminal goes at its head.
    const wins = entry.project ? "set by the project layer · " : ""
    return `${wins}${entry.row.accepts}${back}`
  }

  /** Which body rows the cursor may land on: the settings table, nothing else. */
  const selectable = createMemo(() =>
    bodyRows().flatMap((entry, index) => (entry.kind === "setting" ? [index] : [])),
  )
  const current = () => {
    const entry = bodyRows()[at()]
    return entry?.kind === "setting" ? entry : null
  }

  /** Keep the cursor on screen: one row is one line, so the index is the offset. */
  const reveal = (index: number) => {
    if (!body) return
    const height = Math.max(1, body.viewport.height)
    if (index < body.scrollTop) body.scrollTop = index
    else if (index >= body.scrollTop + height) body.scrollTop = index - height + 1
  }
  const move = (delta: number) => {
    const list = selectable()
    if (list.length === 0) return
    const now = list.indexOf(at())
    const next = list[Math.min(Math.max((now < 0 ? 0 : now) + delta, 0), list.length - 1)]!
    setAt(next)
    reveal(next)
    // A notice is about the row it was said on; carrying it to the next row
    // would make a refusal look like it were about that one.
    setNotice(null)
  }

  createEffect(() => {
    // Open on the first key of the table rather than on row zero, which is a
    // caption: a cursor has to start somewhere it can act.
    if (at() === 0 && selectable().length > 0) setAt(selectable()[0]!)
  })

  /** What the cursor's row is being chosen from, while a picker is up. */
  const options = (): readonly string[] => {
    const edit = current()?.row.edit
    return edit?.kind === "choice" ? edit.values : []
  }

  const save = (value: ReturnType<typeof editedValue>) => {
    const entry = current()
    if (!entry) return
    if ("problem" in value) return setNotice(`${entry.row.key} ${value.problem}`)
    try {
      writeSetting(userPath(), entry.row.key, value.value)
    } catch (err) {
      // As it stands: a file that could not be written or could not be read
      // back is exactly the thing a person has to see the wording of.
      return setNotice(err instanceof Error ? err.message : String(err))
    }
    setWritten((n) => n + 1)
    setNotice(`${entry.row.key} written to ${userPath()}${entry.row.note ? ` · ${entry.row.note}` : ""}`)
    void props.onEdited?.()
  }

  /** Enter on the cursor's row: change it here, or say where it is changed. */
  const activate = () => {
    const entry = current()
    if (!entry) return
    const edit = entry.row.edit
    if (!edit) {
      return setNotice(
        entry.row.key.startsWith("keys.")
          ? `a binding is any key name · edit ${userPath()} under [keys]`
          : `this row stands for three tables · edit ${userPath()} under [env.local] / [env.wsl] / [env.remote]`,
      )
    }
    if (entry.project) {
      return setNotice(`${projectPath()} sets ${entry.row.key}; the nearer layer wins, so writing it here would do nothing`)
    }
    setNotice(null)
    if (edit.kind === "choice") {
      // Two values: Enter is the other one, because a dialog to choose between
      // two things already on the screen is ceremony. Three or more: a picker,
      // so getting somewhere is one write and not four.
      if (edit.values.length === 2) {
        const other = edit.values[(edit.values.indexOf(entry.row.value) + 1) % edit.values.length]!
        return save(editedValue(edit, other))
      }
      setPickAt(Math.max(0, edit.values.indexOf(entry.row.value)))
      return setMode("pick")
    }
    setMode("type")
  }

  // The input arrives holding the value it is about to replace: an edit starts
  // from what is there, which for a list of ids is the difference between
  // adding one and typing them all again.
  createEffect(() => {
    if (mode() !== "type") return
    const start = current()
    if (!start) return
    const fill = () => {
      if (field) field.value = draftOf(start.row)
    }
    fill()
    queueMicrotask(fill)
  })

  useKeyboard((key) => {
    if (mode() === "type") {
      // The input owns every printable key while it is up; only Esc is ours.
      if (key.name === "escape") {
        key.preventDefault()
        setMode("table")
      }
      return
    }
    if (help.consume(key)) return
    if (mode() === "pick") {
      if (key.name === "escape") return setMode("table")
      if (key.name === "j" || key.name === "down") return setPickAt((now) => Math.min(now + 1, options().length - 1))
      if (key.name === "k" || key.name === "up") return setPickAt((now) => Math.max(now - 1, 0))
      if (key.name === "return" || key.name === "space") {
        const edit = current()?.row.edit
        const chosen = options()[pickAt()]
        setMode("table")
        if (edit && chosen !== undefined) save(editedValue(edit, chosen))
      }
      return
    }
    if (key.name === "escape") return props.onClose()
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (key.name === "pagedown") return move(10)
    if (key.name === "pageup") return move(-10)
    if (key.name === "return" || key.name === "space") {
      // Consumed: a picker or an input mounts within this same dispatch and
      // would otherwise take this very key as its first one.
      key.preventDefault()
      return activate()
    }
  })

  const typed = () => (mode() === "type" ? current() : null)
  const brief = () => {
    switch (mode()) {
      case "pick":
        return "↑↓ choose · Enter write · Esc back"
      case "type":
        return typed()?.row.edit?.kind === "list"
          ? `Enter write · commas separate the entries · Esc back`
          : "Enter write · Esc back"
      default:
        return "Esc close · j/k move · Enter change"
    }
  }

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve} height={1}>
        {/* Where a write lands, in words rather than in a path: the paths are
            the next table down, user layer first, and a title is not the place
            to print the longest string on the screen. */}
        {fit("settings · tui.toml · edited here, in the user layer", inner())}
      </text>
      <box height={1} />

      <Show
        when={mode() !== "pick"}
        fallback={
          <box flexDirection="column" width="100%" flexGrow={1} flexShrink={1}>
            <text fg={style.theme.muted} height={1}>
              {fit(`${style.glyphs.picker} ${current()?.row.key ?? ""}`, inner())}
            </text>
            <For each={options()}>
              {(value, index) => {
                const tone = () => ({ selected: pickAt() === index(), hovered: pickHover.at() === index() })
                const here = () => value === current()?.row.value
                const click = onClick(() => {
                  const edit = current()?.row.edit
                  setMode("table")
                  if (edit) save(editedValue(edit, value))
                })
                return (
                  <box
                    flexDirection="row"
                    width="100%"
                    height={1}
                    flexShrink={0}
                    backgroundColor={rowBackground(style, tone())}
                    onMouseDown={click.onMouseDown}
                    onMouseUp={click.onMouseUp}
                    {...pickHover.row(index())}
                    onMouseOver={() => {
                      pickHover.row(index()).onMouseOver()
                      // The pointer is the cursor while it is over this list, as
                      // in `/mode`: a click then answers what the eye is on.
                      setPickAt(index())
                    }}
                  >
                    <text fg={rowGutter(style, tone()).fg} flexShrink={0}>
                      {rowGutter(style, tone()).text}
                    </text>
                    <text fg={rowText(style, tone(), tone().selected ? style.theme.fg : style.theme.muted)}>
                      {fit(value, Math.max(0, inner() - 4))}
                    </text>
                    <text fg={style.theme.ok} flexShrink={0}>
                      {here() ? ` ${style.glyphs.check}` : ""}
                    </text>
                  </box>
                )
              }}
            </For>
          </box>
        }
      >
        <scrollbox
          ref={(box: ScrollBoxRenderable) => (body = box)}
          flexGrow={1}
          flexShrink={1}
          flexBasis={0}
          width="100%"
          verticalScrollbarOptions={{
            trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
          }}
          contentOptions={{ flexDirection: "column", width: "100%" }}
        >
          <For each={bodyRows()}>
            {(entry, index) => (
              <Switch>
                <Match when={entry.kind === "blank"}>
                  <box height={1} flexShrink={0} />
                </Match>
                <Match when={entry.kind === "caption" ? entry : null} keyed>
                  {(caption: CaptionRow) => (
                    <text fg={style.theme.dim} height={1}>
                      {fit(caption.text, inner())}
                    </text>
                  )}
                </Match>
                <Match when={entry.kind === "choice" ? entry : null} keyed>
                  {(one: ChoiceBodyRow) => {
                    const click = onClick(() => one.choice.open())
                    const over = () => hover.at() === index()
                    return (
                      <box
                        flexDirection="row"
                        width="100%"
                        height={1}
                        flexShrink={0}
                        onMouseDown={click.onMouseDown}
                        onMouseUp={click.onMouseUp}
                        {...hover.row(index())}
                      >
                        <box width={choiceCol()} flexShrink={0}>
                          <text fg={lifted(style, over(), style.theme.fg)}>
                            {fit(one.choice.label, choiceCol() - 2)}
                          </text>
                        </box>
                        <box width={choiceValueCol()} flexShrink={0}>
                          <text fg={lifted(style, over(), style.theme.muted)}>
                            {fit(one.choice.value, choiceValueCol() - 2)}
                          </text>
                        </box>
                        <text fg={lifted(style, over(), style.theme.accent.evolve)}>
                          {fit(one.choice.command, Math.max(0, inner() - choiceCol() - choiceValueCol()))}
                        </text>
                      </box>
                    )
                  }}
                </Match>
                <Match when={entry.kind === "path" ? entry : null} keyed>
                  {(entry: PathRow) => (
                    <box flexDirection="row" width="100%" height={1} flexShrink={0}>
                      <box width={stateCol()} flexShrink={0}>
                        <text fg={entry.applied ? style.theme.ok : style.theme.dim}>
                          {fit(entry.applied ? "applied" : entry.present ? "unreadable" : "absent", stateCol() - 2)}
                        </text>
                      </box>
                      <text fg={entry.applied ? style.theme.muted : style.theme.dim}>
                        {fit(entry.path, inner() - stateCol())}
                      </text>
                    </box>
                  )}
                </Match>
                <Match when={entry.kind === "setting" ? entry : null} keyed>
                  {(entry: SettingBodyRow) => {
                    const tone = () => ({ selected: at() === index(), hovered: hover.at() === index() })
                    // Land on it, or — if it is already the row — change it.
                    // The same `activate` Enter calls, never a second path.
                    const click = onClick(() => (at() === index() ? activate() : setAt(index())))
                    return (
                      <box
                        flexDirection="row"
                        width="100%"
                        height={1}
                        flexShrink={0}
                        backgroundColor={rowBackground(style, tone())}
                        onMouseDown={click.onMouseDown}
                        onMouseUp={click.onMouseUp}
                        {...hover.row(index())}
                      >
                        {/* The shared two-column gutter (`ui/rows.ts`): the
                            cursor's band and the pointer's lift are colours,
                            and a terminal asked for none of them still has to
                            say which row Enter is about. */}
                        <text fg={rowGutter(style, tone()).fg} flexShrink={0}>
                          {rowGutter(style, tone()).text}
                        </text>
                        <box width={keyCol()} flexShrink={0}>
                          <text fg={rowText(style, tone(), tone().selected ? style.theme.muted : style.theme.dim)}>
                            {fit(entry.row.key, keyCol() - 2)}
                          </text>
                        </box>
                        <box width={valueCol()} flexShrink={0}>
                          <text fg={rowText(style, tone(), entry.row.changed ? style.theme.fg : style.theme.muted)}>
                            {fit(entry.row.value, valueCol() - 2)}
                          </text>
                        </box>
                        {/* What the file will take here — and, when this is not
                            the default any more, what it was, which is the one
                            thing a person undoing an edit needs and cannot get
                            from anywhere else. */}
                        <text fg={rowText(style, tone(), style.theme.faint)}>
                          {fit(accepts(entry), Math.max(0, inner() - 2 - keyCol() - valueCol()))}
                        </text>
                      </box>
                    )
                  }}
                </Match>
              </Switch>
            )}
          </For>
        </scrollbox>
      </Show>

      {/*
        Keyed on the ROW, so opening another key gets a fresh input rather than
        one still holding the last value (`ProviderView` learned this the hard
        way). The label and hint inside stay ordinary reactive reads.
      */}
      <Show when={typed()?.row.key} keyed>
        {(key: string) => (
          <box flexDirection="row" width="100%" flexShrink={0}>
            <text fg={style.theme.accent.evolve} flexShrink={0}>
              {key} {style.glyphs.user}{" "}
            </text>
            <input
              ref={(el: InputRenderable) => (field = el)}
              flexGrow={1}
              focused
              placeholder={typed()?.row.accepts ?? ""}
              placeholderColor={style.theme.dim}
              textColor={style.theme.fg}
              focusedTextColor={style.theme.fg}
              cursorColor={style.theme.accent.user}
              onSubmit={(value: unknown) => {
                const edit = typed()?.row.edit
                const text = typeof value === "string" ? value : (field?.value ?? "")
                setMode("table")
                if (edit) save(editedValue(edit, text))
              }}
            />
          </box>
        )}
      </Show>

      <OverlayFooter
        width={inner()}
        help={help}
        brief={brief()}
        notice={notice()}
        more={[
          "every key this front end reads is above · what it is set to, what it takes, and what the default was",
          `writes land in ${userPath()} · one line, in place; comments and order are left alone`,
          "a key set by the project layer is marked and not written from here — the nearer layer would win",
          "the kernel's own config is a different chain (`default.toml` → system → user → project) and the TUI does not read it",
        ]}
      />
    </box>
  )
}
