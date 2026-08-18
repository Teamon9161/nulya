/**
 * `/ext` (F2): the extension store as a view (tui.md §5.3).
 *
 * Three things live here that exist nowhere else on the screen:
 *
 *  - the VERSION LINE. Versions are content-addressed and immutable; `activate`
 *    and `rollback` only move the `current` pointer (physics #5). So the
 *    timeline is the extension's whole history, and rollback is a normal move
 *    along it rather than an undo.
 *  - the DRIFT. This session froze specific versions at `session new` and cannot
 *    change them mid-flight (DESIGN §7.5). When `current` has moved since, that
 *    difference is the single most useful sentence in the view:
 *    `frozen v-a · store v-b → next session`.
 *  - the USAGE table, a plain projection of `.nulya/tool-usage.jsonl`. It does
 *    NOT rank: a tool joins the model's tool face only when somebody writes a
 *    pin (the operator's `registry.pinned_native_tools`, or an evolution
 *    session's `session new --pin`), so there is no "next" for a table to
 *    predict — these counts are the evidence for that judgement, not it.
 *  - the TOOLS pane, where that pin is written (tui.md §11, T12). It manages the
 *    two axes separately (D4) and never merges them into one switch: pins decide
 *    which tools the model can call, membership (activate / deactivate) decides
 *    whose skills and system prompts are in the composition. Both take effect at
 *    the next `session new` and neither can touch this one.
 *
 * An extension id, a tool name and a store root are all as long as somebody
 * chose to make them, so every cell here is cut to its column and every sentence
 * is broken at its ` · ` joints by us. `ui/columns.ts` says why a line that
 * wraps in a list is garbled rather than merely untidy.
 */
import { For, Index, Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useScreen, useStyle } from "../../render/theme.ts"
import { columnWidth, fit, squeeze, wrapWords } from "../columns.ts"
import { createHover, onClick, rowBackground, rowGutter } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { listExtensions, readToolUsage, type ExtensionEntry, type ToolUsage } from "../../nulya/files.ts"
import { configShow, extDeactivate, extPrune, extSetCurrent, type SyncLine } from "../../nulya/cli.ts"
import { draftColumn, planStore } from "../../extensions.ts"
import {
  pinState,
  promote,
  quotaLine,
  readUserPins,
  stateLabel,
  toggle,
  toggleAll,
  toolId,
  writeUserPins,
  type PinChange,
  type PinSources,
  type PinState,
} from "../../pins.ts"
import { rememberSessionPins, sessionPins } from "../../state/tui_state.ts"
import { UsageTable } from "./UsageTable.tsx"
import type { Workspace } from "../../nulya/bin.ts"
import type { SessionHeader } from "../../nulya/ledger.ts"

type Pane = "extensions" | "versions" | "tools" | "usage"

/**
 * The four panes, in Tab order. They used to be reachable only by knowing that
 * `Tab` cycles and that `t` and `u` jump — which meant the usage table and the
 * pin panel were invisible until somebody read the footer. One strip of four
 * words costs a row and makes the whole view's shape legible (and clickable).
 */
const panes: Pane[] = ["extensions", "versions", "tools", "usage"]

/** An action waiting for `y`: pointer moves, and the two that take something away. */
type Pending =
  | { kind: "activate" | "rollback"; id: string; version: string }
  | { kind: "prune"; id: string; version: string; count: number }
  | { kind: "deactivate"; id: string }

function confirmLine(pending: Pending): string {
  if (pending.kind === "prune") {
    return `prune ${pending.id}: delete ${pending.count} version(s), keep ${pending.version}? y / Esc`
  }
  if (pending.kind === "deactivate") {
    return `deactivate ${pending.id}: its skills and prompts leave the NEXT session; versions all stay? y / Esc`
  }
  return `${pending.kind} ${pending.id} ${pending.version}? y / Esc`
}

/** One row of the tools pane: a pinnable tool, its state, and its evidence. */
export interface ToolRow {
  id: string
  extension: string
  tool: string
  state: PinState
  uses: number
  ok: number
}

/**
 * Every tool that could be pinned, with the state each one is in.
 *
 * Only extensions with an ACTIVE, un-shadowed version are here: a pin naming
 * anything else is refused by `session new` (`PinNamesUnknownExtension`), so
 * offering it would be offering a session that will not start.
 */
export function toolRows(
  extensions: readonly ExtensionEntry[],
  sources: PinSources,
  usage: readonly ToolUsage[],
): ToolRow[] {
  const rows: ToolRow[] = []
  for (const entry of extensions) {
    if (!entry.current || entry.shadowed) continue
    for (const tool of entry.tools) {
      const id = toolId(entry.id, tool)
      const row = usage.find((u) => u.toolId === id)
      rows.push({
        id,
        extension: entry.id,
        tool,
        state: pinState(id, sources),
        uses: row?.uses ?? 0,
        ok: row?.ok ?? 0,
      })
    }
  }
  return rows.sort((a, b) => a.id.localeCompare(b.id))
}

/** What the NEXT session's face would carry: the merged config plus our own. */
export function nextFace(sources: PinSources): string[] {
  const face = [...sources.merged]
  for (const pin of sources.session) if (!face.includes(pin)) face.push(pin)
  return face
}

/** What the running session froze for this extension, if anything. */
export function frozenVersion(header: SessionHeader | null | undefined, id: string): string | null {
  return header?.composition.active.find((entry) => entry.id === id)?.version ?? null
}

export function driftLine(frozen: string | null, current: string | null): string | null {
  if (!frozen || !current || frozen === current) return null
  return `frozen ${frozen} · store ${current} → next session`
}

/** How many versions an id has, and what kind it is: one short cell. */
function metaOf(entry: ExtensionEntry): string {
  return `${entry.versions.length}v ${entry.kind.slice(0, 4)}`
}

/** When a version was built, to the minute — enough to order two of them. */
function stamp(mtime: number): string {
  return new Date(mtime).toISOString().slice(0, 16)
}

/** Uses and success rate, as the two cells of the evidence column. */
function usesOf(row: { uses: number } | null): string {
  return `${row?.uses ?? 0} uses`
}

function okOf(row: { uses: number; ok: number } | null): string {
  return row && row.uses > 0 ? `${Math.round((row.ok / row.uses) * 100)}% ok` : "—"
}

export function ExtView(props: {
  ws: Workspace
  header: SessionHeader | null
  /**
   * The session file the screen is following, relative to the workspace. Passed
   * to `ext activate` as `NULYA_SESSION` so the kernel deposits its capability
   * note where the model will see it (DESIGN §5.3) — the one action in this view
   * that a running session can do anything about.
   */
  sessionFile?: string
  /** Where `session_pins` is remembered; tests point it elsewhere. */
  statePath?: string
  /**
   * An activate / rollback / deactivate landed: what the skill catalog holds
   * may have changed (`nulya skill list` lists ACTIVE extensions), and the
   * `/name` menu reads that. Pins never fire it — they are the other axis.
   */
  onMembershipChanged?: () => void
  onClose: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [extensions, setExtensions] = createSignal<ExtensionEntry[]>([])
  const [usage, setUsage] = createSignal<ToolUsage[]>([])
  const [cursor, setCursor] = createSignal(0)
  const [versionCursor, setVersionCursor] = createSignal(0)
  const [toolCursor, setToolCursor] = createSignal(0)
  const [pane, setPane] = createSignal<Pane>("extensions")
  const [notice, setNotice] = createSignal<string | null>(null)
  const [drafts, setDrafts] = createSignal<SyncLine[]>([])
  const [confirm, setConfirm] = createSignal<Pending | null>(null)
  // The three places a pin can be written, plus the quota the kernel enforces.
  // `userPath` comes from the kernel's own projection: we write where it reads.
  const [maxTools, setMaxTools] = createSignal(8)
  const [merged, setMerged] = createSignal<string[]>([])
  const [userPath, setUserPath] = createSignal("")
  const [userPins, setUserPins] = createSignal<string[]>([])
  const [tuiPins, setTuiPins] = createSignal<string[]>(sessionPins(props.statePath))
  // One hover slot per list: the four panes are never on screen together, so
  // sharing one would be a highlight that follows the pointer into the wrong
  // column.
  const idHover = createHover()
  const versionHover = createHover()
  const toolHover = createHover()
  const paneHover = createHover()
  const help = createKeyHelp()

  const sources = createMemo<PinSources>(() => ({
    user: userPins(),
    session: tuiPins(),
    merged: merged(),
  }))

  const refreshPins = async () => {
    setTuiPins(sessionPins(props.statePath))
    try {
      const view = await configShow(props.ws)
      setMaxTools(view.registry.max_tools)
      setMerged(view.registry.pinned_native_tools)
      setUserPath(view.paths.user)
      setUserPins(readUserPins(view.paths.user))
    } catch {
      // No projection is "unknown", never a wrong state: with `merged` empty
      // the panel simply shows nothing as pinned from a config layer, and the
      // kernel still has the last word at `session new`.
    }
  }

  const refresh = async () => {
    setExtensions(await listExtensions(props.ws))
    setUsage(await readToolUsage(props.ws))
    await refreshPins()
    // What the SOURCE in each store directory would build to, versus what is
    // there — the one thing the store's own listing cannot say. A plan, so this
    // view never writes anything by opening.
    try {
      const [ws_plan, user_plan] = await Promise.all([planStore(props.ws, false), planStore(props.ws, true)])
      setDrafts([...ws_plan.lines, ...user_plan.lines])
    } catch {
      setDrafts([]) // no plan is "unknown", never a wrong column
    }
  }

  onMount(() => void refresh())

  const selected = createMemo(() => extensions()[Math.min(cursor(), Math.max(0, extensions().length - 1))] ?? null)
  const versions = createMemo(() => selected()?.versions ?? [])
  const selectedVersion = createMemo(() => versions()[Math.min(versionCursor(), Math.max(0, versions().length - 1))] ?? null)
  const drift = createMemo(() => {
    const entry = selected()
    return entry ? driftLine(frozenVersion(props.header, entry.id), entry.current) : null
  })
  const usageOf = (entry: ExtensionEntry, tool: string) =>
    usage().find((row) => row.toolId === `ext:${entry.id}/${tool}`) ?? null
  /** The sync plan's line for an id, when that id still has a draft. */
  const draftOf = (id: string) => drafts().find((line) => line.id === id) ?? null

  const tools = createMemo(() => toolRows(extensions(), sources(), usage()))
  const selectedTool = createMemo(() => tools()[Math.min(toolCursor(), Math.max(0, tools().length - 1))] ?? null)
  const quota = createMemo(() => quotaLine(maxTools(), nextFace(sources()).length))

  /** The columns this overlay may draw in: the box pads one on each side. */
  const inner = () => Math.max(24, screen().width - 2)

  /**
   * The id list, sized from the ids it actually holds rather than from the 34
   * it used to be fixed at — and never allowed past half the screen, because
   * the detail beside it is the half that explains what the cursor is on.
   */
  const idCols = createMemo(() => {
    const list = extensions()
    const [id, meta, draft, shadow] = squeeze(
      [
        columnWidth(list.map((entry) => entry.id), 2, 24),
        columnWidth(list.map(metaOf), 2, 12),
        columnWidth(list.map((entry) => draftColumn(draftOf(entry.id))), 2, 11),
        columnWidth(list.map((entry) => (entry.shadowed ? "shadowed" : "")), 0, 9),
      ],
      [8, 0, 0, 0],
      Math.max(16, Math.floor(inner() / 2)) - 2,
    )
    return { id: id!, meta: meta!, draft: draft!, shadow: shadow! }
  })
  /** The whole left pane: the cursor gutter plus its four columns. */
  const idWidth = () => 2 + idCols().id + idCols().meta + idCols().draft + idCols().shadow
  /** What is left for the detail beside it, less its own two-column pad. */
  const detailWidth = () => Math.max(16, inner() - idWidth() - 2)

  /**
   * The version line, allocated by priority rather than evenly. A version id is
   * `v-` and 24 hex digits and it is what somebody reads off this line to pass
   * to `ext activate`, so it is never cut; the two markers say which build runs
   * and which one this session froze; and the timestamp only orders builds that
   * the list already shows in order — so it takes what is left, and on a pane
   * with nothing left it takes no room at all.
   */
  const versionCols = createMemo(() => {
    const list = versions()
    const frozen = props.header ? frozenVersion(props.header, selected()?.id ?? "") : null
    const budget = Math.max(8, detailWidth() - 2)
    const version = Math.min(columnWidth(list.map((entry) => entry.version), 2, 28), budget)
    const [current, mine] = squeeze(
      [
        columnWidth([selected()?.current ? `${style.glyphs.capability} current` : ""], 2, 12),
        columnWidth([frozen ? `${style.glyphs.bar} this session` : ""], 0, 15),
      ],
      [0, 0],
      Math.max(0, budget - version),
    )
    const spare = budget - version - current! - mine!
    const when = spare >= 8 ? Math.min(columnWidth(list.map((entry) => stamp(entry.mtime)), 2, 18), spare) : 0
    return { version, when, current: current!, mine: mine! }
  })

  /** The pin panel's rows: a checkbox, the tool id, its state, its evidence. */
  const toolCols = createMemo(() => {
    const list = tools()
    const [id, state, uses, ok] = squeeze(
      [
        columnWidth(list.map((row) => row.id), 2, 34),
        columnWidth(list.map((row) => stateLabel(row.state)), 2, 26),
        columnWidth(list.map(usesOf), 2, 12),
        columnWidth(list.map(okOf), 0, 8),
      ],
      [10, 0, 0, 0],
      inner() - 4,
    )
    return { id: id!, state: state!, uses: uses!, ok: ok! }
  })

  /** A sentence we break ourselves, one `<text>` per line. */
  const Lines = (line: { text: string; width?: number; fg?: string }) => (
    <For each={wrapWords(line.text, line.width ?? inner())}>
      {(part) => (
        <text fg={line.fg ?? style.theme.dim} height={1}>
          {part}
        </text>
      )}
    </For>
  )

  const move = (delta: number) => {
    if (pane() === "extensions") {
      const count = extensions().length
      if (count === 0) return
      setCursor(Math.min(Math.max(cursor() + delta, 0), count - 1))
      setVersionCursor(0)
      return
    }
    if (pane() === "versions") {
      const count = versions().length
      if (count === 0) return
      setVersionCursor(Math.min(Math.max(versionCursor() + delta, 0), count - 1))
      return
    }
    if (pane() === "tools") {
      const count = tools().length
      if (count === 0) return
      setToolCursor(Math.min(Math.max(toolCursor() + delta, 0), count - 1))
    }
  }

  /**
   * Carry out one pin decision. The config file is written by text surgery that
   * re-reads and checks itself (`pins.ts`), so a failure here means nothing
   * changed on disk and the sentence says which file to look at.
   */
  const applyPin = async (change: PinChange) => {
    try {
      if (change.user) {
        if (userPath().length === 0) throw new Error("config show did not say where the user config lives")
        writeUserPins(userPath(), change.user)
      }
      if (change.session) rememberSessionPins(change.session, props.statePath)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
      return
    }
    setNotice(change.notice)
    // Take the write as read straight away. `refreshPins` spawns `config show`,
    // and until it answers `sources()` would still describe the world before
    // this change — so a second toggle arriving in that window (two clicks in a
    // row) would compute itself from a stale state and undo nothing. The file
    // is already written; this only stops the screen from lagging behind it.
    if (change.session) setTuiPins(change.session)
    if (change.user) setUserPins(change.user)
    await refreshPins()
  }

  /** `Space` / `A`: on a tool row it is that tool, on an id row the whole package. */
  const pinKey = (verb: "toggle" | "promote") => {
    if (pane() === "tools") {
      const row = selectedTool()
      if (!row) return
      return void applyPin(verb === "toggle" ? toggle(row.id, sources()) : promote(row.id, sources()))
    }
    const entry = selected()
    if (!entry) return
    const ids = tools()
      .filter((row) => row.extension === entry.id)
      .map((row) => row.id)
    if (ids.length === 0) {
      setNotice(`${entry.id} declares no tools · nothing to pin (its skills and prompts are the membership axis)`)
      return
    }
    if (verb === "promote") {
      // Deliberately one at a time: `always` costs a slot and prefix tokens in
      // every session on this machine, and a whole package at once is not a
      // decision anybody makes by holding a key down.
      setNotice("A promotes one tool · Tab to the tools pane and pick it")
      return
    }
    void applyPin(toggleAll(ids, sources()))
  }

  const act = (verb: "activate" | "rollback") => {
    const entry = selected()
    if (!entry) return
    // On the version line the selection IS the answer; on the id list the
    // draft's own version is — which is what makes an id just built by a sync
    // one key away from being the current one.
    const version = pane() === "versions" ? selectedVersion()?.version : draftOf(entry.id)?.version
    if (!version) {
      setNotice("no version to point at · Tab to the version line and pick one")
      return
    }
    setConfirm({ kind: verb, id: entry.id, version })
  }

  const prune = () => {
    const entry = selected()
    if (!entry) return
    if (!entry.current) {
      setNotice(`${entry.id} has no current version · nothing can say which one to keep`)
      return
    }
    const others = entry.versions.length - 1
    if (others <= 0) {
      setNotice(`${entry.id} has only the current version`)
      return
    }
    setConfirm({ kind: "prune", id: entry.id, version: entry.current, count: others })
  }

  /**
   * `d` — the membership axis (D4). Deactivating takes an extension's skills and
   * system prompts out of the next composition; its tools leave the face with
   * them, because a pin can only resolve through an active version. Nothing is
   * deleted and nothing about this session moves.
   */
  const deactivate = () => {
    const entry = selected()
    if (!entry) return
    if (!entry.current) {
      setNotice(`${entry.id} has no current version · it is already out of every composition`)
      return
    }
    setConfirm({ kind: "deactivate", id: entry.id })
  }

  const runConfirmed = async () => {
    const pending = confirm()
    setConfirm(null)
    if (!pending) return
    try {
      if (pending.kind === "deactivate") {
        setNotice(await extDeactivate(props.ws, pending.id))
      } else if (pending.kind === "prune") {
        // Deleting a version is the one action here that cannot be undone by
        // moving a pointer, so the kernel's own sentence about the cost is what
        // gets shown rather than a cheerful count of freed bytes.
        const output = await extPrune(props.ws, { id: pending.id })
        setNotice(output.split("\n").slice(-2).join(" · "))
      } else {
        // A store action, not a session event: it changes what the NEXT session
        // freezes and nothing about this one (DESIGN §7.5), so it never touches
        // the ledger and its output stays here.
        //
        // The one exception is the note: an activation is the single change here
        // the running model CAN act on — `ext run <id>@<version>` reaches a new
        // version through the shell without any composition moving — so the
        // session is named and the kernel deposits its capability note. Anything
        // it prints on stderr (the `--user`-inside-a-session warning) is not our
        // news to relay.
        setNotice(
          await extSetCurrent(props.ws, pending.kind, pending.id, pending.version, {
            session: pending.kind === "activate" ? props.sessionFile : undefined,
          }),
        )
      }
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
    if (pending.kind !== "prune") props.onMembershipChanged?.()
    await refresh()
  }

  useKeyboard((key) => {
    if (confirm()) {
      if (key.name === "y" || key.name === "return") return void runConfirmed()
      setConfirm(null)
      return
    }
    if (help.consume(key)) return
    if (key.name === "escape") return props.onClose()
    if (key.name === "tab") {
      const next: Record<Pane, Pane> = {
        extensions: "versions",
        versions: "tools",
        tools: "usage",
        usage: "extensions",
      }
      setPane(next[pane()])
      return
    }
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (key.name === "space") return pinKey("toggle")
    // Shift+A, not `a`: promotion writes a config file, and it must not be one
    // keystroke away from the activate that sits beside it.
    if (key.name === "a" && key.shift) return pinKey("promote")
    if (key.name === "a") return act("activate")
    if (key.name === "r") return act("rollback")
    if (key.name === "p") return prune()
    if (key.name === "d") return deactivate()
    if (key.name === "t") return setPane(pane() === "tools" ? "extensions" : "tools")
    if (key.name === "u") return setPane(pane() === "usage" ? "extensions" : "usage")
  })

  /**
   * The pin panel. One row per tool, three states, and the quota above them —
   * `2+N/8`, because the builtins count and a refused pin is otherwise a
   * mystery (DESIGN §5.1).
   *
   * A pin written by a project or system config layer is shown and not touched:
   * this view writes one key in one file (D3), and quietly editing somebody
   * else's layer to make a checkbox look right would be the worse lie.
   */
  const ToolsPane = () => (
    <box flexDirection="column" width="100%" flexGrow={1}>
      <text fg={style.theme.fg} height={1}>
        {fit(quota(), inner())}
      </text>
      <text fg={style.theme.dim} height={1}>
        {fit(`user config ${userPath() || "(unknown)"}`, inner())}
      </text>
      <box height={1} />
      {/*
        `Index`, not `For`: `toolRows` builds fresh objects on every refresh, so
        `For` would tear down and rebuild every row each time the pin state is
        re-read — and a renderable destroyed between a press and its release
        takes the click with it. `Index` keeps one renderable per POSITION and
        only updates what it says, which is both cheaper and the reason a second
        click on a checkbox lands while `config show` is still in flight.
      */}
      <Index each={tools()}>
        {(row, index) => {
          const here = () => index === toolCursor()
          const tone = () => ({ selected: here(), hovered: toolHover.at() === index })
          const on = () => row().state !== "off"
          const click = onClick(() => setToolCursor(index))
          // The checkbox is its own target inside the row: a click on it is the
          // Space key, a click anywhere else on the row is only the cursor.
          // Nested targets, so it has to claim the event or the row acts too.
          const check = onClick(() => {
            setToolCursor(index)
            void applyPin(toggle(row().id, sources()))
          }, true)
          return (
            <box
              flexDirection="row"
              width="100%"
              height={1}
              flexShrink={0}
              backgroundColor={rowBackground(style, tone())}
              onMouseDown={click.onMouseDown}
              onMouseUp={click.onMouseUp}
              {...toolHover.row(index)}
            >
              {/* A box, not the `<text>` itself: mouse props on a text node do
                  not reach the renderable, so the target has to be a box that
                  is exactly as wide as the checkbox it holds. */}
              <box
                width={4}
                height={1}
                flexShrink={0}
                onMouseDown={check.onMouseDown}
                onMouseUp={check.onMouseUp}
              >
                <text fg={on() ? style.theme.accent.evolve : style.theme.faint}>{on() ? "[x] " : "[ ] "}</text>
              </box>
              <box width={toolCols().id} flexShrink={0}>
                <text fg={on() ? style.theme.accent.evolve : here() ? style.theme.fg : style.theme.muted}>
                  {fit(row().id, toolCols().id - 2)}
                </text>
              </box>
              <box width={toolCols().state} flexShrink={0}>
                <text fg={row().state === "other" ? style.theme.warn : style.theme.dim}>
                  {fit(stateLabel(row().state), toolCols().state - 2)}
                </text>
              </box>
              <box width={toolCols().uses} flexShrink={0}>
                <text fg={style.theme.dim}>{fit(usesOf(row()), toolCols().uses - 2)}</text>
              </box>
              <box width={toolCols().ok} flexShrink={0}>
                <text fg={style.theme.dim}>{fit(okOf(row()), toolCols().ok)}</text>
              </box>
            </box>
          )
        }}
      </Index>
      <Show when={tools().length === 0}>
        <Lines
          text="nothing can be pinned yet · a tool reaches the model only through an extension with an active version"
          fg={style.theme.muted}
        />
        <Lines text="build one with `nulya ext build <path>`, then `a` on its row here to make it current" />
      </Show>
    </box>
  )

  /**
   * The four panes as a strip. It is the view's own table of contents: which
   * pane is up, which others exist, and — since each word answers to a click —
   * how to get to them without knowing that `Tab` cycles.
   */
  const PaneStrip = () => (
    <box flexDirection="row" width="100%" height={1} flexShrink={0}>
      <For each={panes}>
        {(name, index) => {
          const here = () => pane() === name
          const click = onClick(() => setPane(name))
          return (
            <>
              <Show when={index() > 0}>
                <text fg={style.theme.faint}>{"  "}</text>
              </Show>
              <box
                flexShrink={0}
                height={1}
                backgroundColor={
                  here() ? style.theme.selection : paneHover.at() === index() ? style.theme.hover : undefined
                }
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                {...paneHover.row(index())}
              >
                <text fg={here() ? style.theme.accent.evolve : style.theme.dim}>{name}</text>
              </box>
            </>
          )
        }}
      </For>
    </box>
  )

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <box flexDirection="row" width="100%" height={1} flexShrink={0}>
        <text fg={style.theme.accent.evolve} flexShrink={0}>
          {fit(`extensions · ${extensions().length}`, inner())}
        </text>
        <text fg={style.theme.dim}>{fit(` · ${quota()}`, Math.max(0, inner() - 20))}</text>
      </box>
      <PaneStrip />
      <box height={1} />

      {/* Two of the four panes share the id list / detail split; the other two
          are whole-width tables of their own. */}
      <Show
        when={pane() === "extensions" || pane() === "versions"}
        fallback={pane() === "tools" ? <ToolsPane /> : <UsageTable rows={usage()} width={inner()} />}
      >
        <box flexDirection="row" width="100%" flexGrow={1}>
          <box flexDirection="column" width={idWidth()} flexShrink={0}>
            <For each={extensions()}>
              {(entry, index) => {
                const here = () => index() === cursor()
                const draft = () => draftColumn(draftOf(entry.id))
                const tone = () => ({
                  selected: here() && pane() === "extensions",
                  hovered: idHover.at() === index(),
                })
                const gutter = () => rowGutter(style, tone())
                // Clicking an id both moves the cursor and says which pane the
                // cursor is in — the same two facts `Tab` and `j/k` set apart.
                const click = onClick(() => {
                  setPane("extensions")
                  setCursor(index())
                  setVersionCursor(0)
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
                    {...idHover.row(index())}
                  >
                    <text fg={gutter().fg} flexShrink={0}>
                      {gutter().text}
                    </text>
                    <box width={idCols().id} flexShrink={0}>
                      <text fg={entry.shadowed ? style.theme.dim : here() ? style.theme.fg : style.theme.muted}>
                        {fit(entry.id, idCols().id - 2)}
                      </text>
                    </box>
                    <box width={idCols().meta} flexShrink={0}>
                      <text fg={style.theme.dim}>{fit(metaOf(entry), idCols().meta - 2)}</text>
                    </box>
                    {/* What the SOURCE beside those versions would build to. An
                        id whose draft has moved on shows `not built` here while
                        its old version is still current — the difference `ext
                        sync` is for. */}
                    <box width={idCols().draft} flexShrink={0}>
                      <text fg={draft() === "active" ? style.theme.dim : style.theme.warn}>
                        {fit(draft(), idCols().draft - 2)}
                      </text>
                    </box>
                    {/* An id an earlier root already has active: this copy never
                        runs (DESIGN §7.2). Saying so is the whole point — a
                        silently omitted duplicate is how it becomes a mystery. */}
                    <box width={idCols().shadow} flexShrink={0}>
                      <text fg={style.theme.warn}>{entry.shadowed ? fit("shadowed", idCols().shadow) : ""}</text>
                    </box>
                  </box>
                )
              }}
            </For>
            {/* An empty store is normal — nulya ships two builtins and nothing
                else — so this says what an extension is FOR and the one command
                that makes one, rather than reporting a count of zero. */}
            <Show when={extensions().length === 0}>
              <text fg={style.theme.muted} height={1}>
                {fit("no extensions built yet", idWidth())}
              </text>
              <Lines
                text="an extension is how the agent adds a tool, a skill or a system prompt to a later session"
                width={idWidth()}
              />
              <Lines text="`nulya ext init <id>` writes a draft · `ext build <path>` freezes a version" width={idWidth()} />
            </Show>
          </box>

          <box flexDirection="column" width={detailWidth() + 2} flexShrink={0} paddingLeft={2}>
            <Show when={selected()} keyed>
              {(entry: ExtensionEntry) => (
                <box flexDirection="column" width="100%">
                  <Lines
                    text={`${entry.id} · ${entry.kind} · current ${entry.current ?? "(none)"}`}
                    width={detailWidth()}
                    fg={style.theme.fg}
                  />
                  <Lines
                    text={`root ${entry.root}${entry.shadowed ? " · shadowed by an earlier root · never runs" : ""}`}
                    width={detailWidth()}
                    fg={entry.shadowed ? style.theme.warn : style.theme.dim}
                  />
                  <Lines
                    text={`tools ${entry.tools.join(" ") || "—"} · skills ${
                      entry.skills.map((skill: string) => skill.split("/").pop()).join(" ") || "—"
                    } · prompts ${entry.systemPrompts.length || "—"}`}
                    width={detailWidth()}
                    fg={style.theme.muted}
                  />
                  <Lines
                    text={`permissions fs ${entry.permissions.fs.length} · net ${
                      entry.permissions.network.join(",") || "—"
                    } · proc ${entry.permissions.process.length}`}
                    width={detailWidth()}
                  />
                  <Show when={drift()}>
                    <Lines text={drift()!} width={detailWidth()} fg={style.theme.warn} />
                  </Show>
                  <box height={1} />

                  <text fg={style.theme.dim} height={1}>
                    versions
                  </text>
                  <For each={entry.versions}>
                    {(version, index) => {
                      const here = () => index() === versionCursor() && pane() === "versions"
                      const isCurrent = () => version.version === entry.current
                      const isFrozen = () => version.version === frozenVersion(props.header, entry.id)
                      const tone = () => ({ selected: here(), hovered: versionHover.at() === index() })
                      const gutter = () => rowGutter(style, tone())
                      const click = onClick(() => {
                        setPane("versions")
                        setVersionCursor(index())
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
                          {...versionHover.row(index())}
                        >
                          <text fg={gutter().fg} flexShrink={0}>
                            {gutter().text}
                          </text>
                          <box width={versionCols().version} flexShrink={0}>
                            <text fg={isCurrent() ? style.theme.accent.evolve : here() ? style.theme.fg : style.theme.muted}>
                              {fit(version.version, versionCols().version - 2)}
                            </text>
                          </box>
                          <box width={versionCols().when} flexShrink={0}>
                            <text fg={style.theme.dim}>{fit(stamp(version.mtime), versionCols().when - 2)}</text>
                          </box>
                          <box width={versionCols().current} flexShrink={0}>
                            <text fg={style.theme.accent.evolve}>
                              {isCurrent() ? fit(`${style.glyphs.capability} current`, versionCols().current - 2) : ""}
                            </text>
                          </box>
                          <box width={versionCols().mine} flexShrink={0}>
                            <text fg={style.theme.accent.user}>
                              {isFrozen() ? fit(`${style.glyphs.bar} this session`, versionCols().mine) : ""}
                            </text>
                          </box>
                        </box>
                      )
                    }}
                  </For>
                  <box height={1} />

                  <text fg={style.theme.dim} height={1}>
                    usage
                  </text>
                  <For each={entry.tools}>
                    {(tool) => (
                      <text fg={style.theme.dim} height={1}>
                        {"  "}
                        {fit(
                          `${tool} · ${usesOf(usageOf(entry, tool))} · ${okOf(usageOf(entry, tool))}`,
                          detailWidth() - 2,
                        )}
                      </text>
                    )}
                  </For>
                </box>
              )}
            </Show>
          </box>
        </box>
      </Show>

      <Show when={confirm()} keyed>
        {(pending: Pending) => <Lines text={confirmLine(pending)} fg={style.theme.warn} />}
      </Show>
      {/* The sister sentence of the drift line: every key in this view moves a
          pointer or a pin, and physics #2 says none of them can reach the
          session already on screen. Said once, permanently, rather than after
          each action — and it stays even while the key list is folded away,
          because it is not a key. */}
      <OverlayFooter
        width={inner()}
        help={help}
        notice={confirm() ? null : notice()}
        warning="changes apply to the NEXT session — this one froze its tools at start"
        brief="j/k move · Tab pane · Space pin · Esc close"
        more={[
          "a activate · r rollback · d deactivate · p prune old versions",
          "A promote a pin to always · t tools · u usage · click a pane name or a row",
        ]}
      />
    </box>
  )
}
