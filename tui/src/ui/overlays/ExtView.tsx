/**
 * `/ext` (F2): the extension store as a view (tui.md §5.3).
 *
 * Three things live here that exist nowhere else on the screen:
 *
 *  - the VERSION LINE. Versions are content-addressed and immutable; `activate`
 *    only moves the `current` pointer (physics #5). So the
 *    timeline is the extension's whole history, and going back is a normal move
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
 *  - the SWITCH. `Enter` on an id turns the extension on or off for the next
 *    session: on = point `current` at a built version AND pin every tool it
 *    declares; off = take those pins back and clear `current`. T12 §5 held the
 *    two axes apart on principle and refused to merge them — that principle is
 *    right about the kernel and was wrong about the screen, where both keys were
 *    invisible and the state they moved was drawn nowhere (tui.md §11, T22). The
 *    axes are still two: the TOOLS pane is where one tool is pinned on its own,
 *    and the version line is where one specific build is pointed at.
 *
 * An extension id, a tool name and a store root are all as long as somebody
 * chose to make them, so every cell here is cut to its column and every sentence
 * is broken at its ` · ` joints by us. `ui/columns.ts` says why a line that
 * wraps in a list is garbled rather than merely untidy.
 */
import { For, Index, Show, createMemo, createSignal, onMount } from "solid-js"
import { join } from "node:path"
import { useKeyboard } from "@opentui/solid"
import { useScreen, useStyle } from "../../render/theme.ts"
import { columnWidth, fit, squeeze, wrapWords } from "../columns.ts"
import { createHover, onClick, rowBackground, rowGutter } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import {
  draftEntries,
  listExtensions,
  readToolUsage,
  rootsOf,
  type ExtensionEntry,
  type ToolUsage,
} from "../../nulya/files.ts"
import { configShow, extBuild, extDeactivate, extPrune, extSetCurrent, type SyncLine } from "../../nulya/cli.ts"
import { draftColumn, pinsOf, planStore, promptConsequence } from "../../extensions.ts"
import {
  builtin_tools,
  faceFullLine,
  orphanPins,
  pinAll,
  pinState,
  promote,
  quotaLine,
  readUserPins,
  stateLabel,
  toggle,
  toolId,
  unpinAll,
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

/**
 * An action waiting for `y`. Only two are left, and both name a VERSION: moving
 * the pointer along the timeline by hand, and the one action here that deletes
 * something. The on/off switch asks nothing — it moves a pointer and a pin list,
 * both of which the same key puts back (tui.md §11, T22).
 */
type Pending =
  | { kind: "activate"; id: string; version: string }
  | { kind: "prune"; id: string; version: string; count: number }

function confirmLine(pending: Pending): string {
  if (pending.kind === "prune") {
    return `prune ${pending.id}: delete ${pending.count} version(s), keep ${pending.version}? y / Esc`
  }
  return `${pending.kind} ${pending.id} ${pending.version}? y / Esc`
}

/**
 * Whether an extension is ON for the next session, and — when the answer is
 * "half" — which half is missing.
 *
 * `on` means both axes agree: an active version, and every tool it declares on
 * the face. `partial` is the honest name for the states the kernel can be left
 * in — pinned but no longer active (a pointer moved back), active with only some of its
 * tools pinned (`Space` on one row) — and it is warn-coloured because the first
 * of those is what makes `session new` refuse.
 */
export type SwitchState = "on" | "partial" | "off"

export function switchState(active: boolean, tools: number, pinned: number): SwitchState {
  if (active && pinned === tools) return "on"
  if (!active && pinned === 0) return "off"
  return "partial"
}

/** The marker and its space: one glyph, always two columns, so ids line up. */
const switch_width = 2

/**
 * What a package that contributes a SYSTEM PROMPT is called in the id list
 * (tui.md §11, T31).
 *
 * It is the one contribution whose reach is the whole machine: skills wait to be
 * loaded and tools wait to be called, but a system prompt is in front of every
 * model of every session that carries the package, before anybody says anything.
 * So it gets a word of its own in the list rather than the count of prompt files
 * that used to sit at the end of the detail line, four facts in.
 */
export function modeCell(entry: { systemPrompts: string[] }): string {
  return entry.systemPrompts.length > 0 ? "mode" : ""
}

/** One row of the tools pane: a pinnable tool, its state, and its evidence. */
export interface ToolRow {
  id: string
  extension: string
  tool: string
  state: PinState
  uses: number
  ok: number
  /**
   * This tool is a DRIVER interface, not something a model calls — the
   * package's own word for it (`audience: "driver"`, DESIGN §7.2.1), where
   * until T34 it was this front end guessing from a list of bundled ids.
   *
   * It has no checkbox by default, because a pin would put it on the model's
   * face where calling it can deadlock on the session's own writer lock
   * (`SessionBusy`, DESIGN §3.4); `/compact` and the goal driver reach it with
   * `nulya ext run`, which needs no pin at all. It is still REACHABLE from this
   * pane — a tool that exists and is drawn nowhere is how `compact` became a
   * mystery — but folded (T33), because it is not an answer to the question
   * this pane asks.
   */
  driver: boolean
}

/**
 * Every tool an active extension declares, with the state each one is in.
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
        driver: entry.driverTools.includes(tool),
      })
    }
  }
  return rows.sort((a, b) => a.id.localeCompare(b.id))
}

/**
 * A row the fold hides. A driver tool that somehow HAS a pin down is not one:
 * that is a state this pane can act on (`Space` takes it back), and the one
 * wrong checkbox in the list is the last thing to hide.
 */
function isFolded(row: ToolRow): boolean {
  return row.driver && row.state === "off"
}

/** The rows a driver calls and nobody can pin (tui.md §11, T33). */
export function foldedRows(rows: readonly ToolRow[]): ToolRow[] {
  return rows.filter(isFolded)
}

/**
 * What the list draws. Collapsed, every row has a checkbox and the list means
 * one thing: here is the model's tool face, and here is what could join it.
 *
 * The driver rows were listed beside them until T33, when there were six of
 * them to five pinnable ones — and, sorted by id, they came FIRST. The pinnable
 * half is capped by `registry.max_tools`; the driver half is capped by nothing,
 * so it grows the wrong way with every bundled package. They fold behind one
 * line (`foldLine`) instead of disappearing: what each of them costs a reader
 * is a row, not the fact of its existence.
 */
export function shownRows(rows: readonly ToolRow[], expanded: boolean): ToolRow[] {
  return expanded ? [...rows] : rows.filter((row) => !isFolded(row))
}

/** The one line the folded half becomes, and the key that opens it. */
export function foldLine(count: number, expanded: boolean): string {
  const what = `${count} driver tool${count === 1 ? "" : "s"} · called with ext run, never on the model face`
  return `${what} · d ${expanded ? "folds" : "shows"}`
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

/**
 * A version id, cut to the digits an eye uses (tui.md §11, T23).
 *
 * `v-` and 24 hex digits is a CONTENT ADDRESS: it exists so two builds of the
 * same source are the same name, and nothing about it is meant to be read. So
 * PROSE mentions — the drift line, `current v-…`, a notice — always use this
 * cut. The version TIMELINE is different: there the id is the content, so its
 * rows draw the whole string whenever the pane is wide enough (`versionCols`)
 * and only fall back to this cut, plus one full line under the cursor, when it
 * is not. One truncation, one function, so two lines about the same build can
 * never disagree by a digit.
 */
export function shortVersion(version: string | null | undefined, digits = 8): string {
  if (!version) return ""
  if (!version.startsWith("v-")) return version
  return version.length <= digits + 2 ? version : version.slice(0, digits + 2)
}

export function driftLine(frozen: string | null, current: string | null): string | null {
  if (!frozen || !current || frozen === current) return null
  return `frozen ${shortVersion(frozen)} · store ${shortVersion(current)} → next session`
}

/**
 * Why the source in a store directory is not a version, and what to do about it
 * (tui.md §11, T22).
 *
 * The kernel's own sentence is the first line and carries the repair — including
 * the absolute directory a zig 0.16.0 can be unpacked into — so it is relayed
 * verbatim rather than paraphrased. The only thing added is the part the kernel
 * cannot know from where it stands: a `zig` on PATH that is a version SHIM reads
 * its version out of a `build.zig.zon` in the current directory, and a store
 * root has none, so it answers "no build.zig" and the draft looks unbuildable
 * while a perfectly good toolchain sits on the disk.
 */
export function draftHelp(line: SyncLine | null): string[] {
  if (!line) return []
  if (line.state === "needs zig") {
    return [
      line.detail ?? "needs zig",
      "if that zig is a version shim, it takes its version from a build.zig.zon in the current directory and a store root has none",
    ]
  }
  if (line.state === "failed") {
    return [`does not build · ${line.detail ?? "?"}`, "fix the source in the store directory, then `b` builds it again"]
  }
  if (line.state === "not built") return ["the source here has never been built · `b` builds it"]
  return []
}

/**
 * What authority this package asked for, or nothing at all when it asked for
 * none (tui.md §11, T23). Authority never grows implicitly (physics #6), so the
 * interesting state is a non-empty one — and a row of zeroes on every package
 * is what made it invisible on the one package that had something to say.
 */
export function permissionLine(entry: {
  permissions: { fs: string[]; network: string[]; process: string[] }
}): string | null {
  const parts: string[] = []
  if (entry.permissions.fs.length > 0) parts.push(`fs ${entry.permissions.fs.length}`)
  if (entry.permissions.network.length > 0) parts.push(`net ${entry.permissions.network.join(",")}`)
  if (entry.permissions.process.length > 0) parts.push(`proc ${entry.permissions.process.length}`)
  return parts.length === 0 ? null : `permissions ${parts.join(" · ")}`
}

/** When a version was built, to the minute — enough to order two of them. */
function stamp(mtime: number): string {
  return new Date(mtime).toISOString().slice(0, 16)
}

/**
 * What the state column says about a row. A driver tool's state is not a pin
 * state — it says who calls it, which is the answer to the question the empty
 * checkbox raises (T24).
 */
export function labelOf(row: ToolRow): string {
  if (row.driver && row.state === "off") return "driver · ext run"
  return stateLabel(row.state)
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
   * An activate / deactivate landed: what the skill catalog holds
   * may have changed (`nulya skill list` lists ACTIVE extensions), and the
   * `/name` menu reads that. Pins never fire it — they are the other axis.
   */
  onMembershipChanged?: () => void
  onClose: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  /**
   * The store's listing and the ids that are only source, kept apart because
   * they cost two different things (tui.md §11, T23).
   *
   * `ext list` is one subprocess and answers at once; the source-only half is
   * two `ext sync --dry-run` passes, which hash and plan every draft in every
   * root and are by far the most expensive calls this view makes. So the view
   * opens on the cheap half and the expensive half arrives into it — and an
   * action that moves a POINTER re-reads only the listing, because activating
   * something cannot change what a draft would build to.
   */
  const [listed, setListed] = createSignal<ExtensionEntry[]>([])
  const [sourceOnly, setSourceOnly] = createSignal<ExtensionEntry[]>([])
  const extensions = createMemo(() =>
    [...listed(), ...sourceOnly().filter((entry) => !listed().some((row) => row.id === entry.id))].sort((a, b) =>
      a.id.localeCompare(b.id),
    ),
  )
  const [usage, setUsage] = createSignal<ToolUsage[]>([])
  /**
   * Ids with a subprocess in flight.
   *
   * `ext activate` takes the better part of a second, and a person pressing
   * Enter twice inside that window means one switch, not two: the second press
   * would compute itself from a state the first has not finished writing and
   * quietly undo it. So the second press is dropped, and the row says why.
   */
  const [working, setWorking] = createSignal<readonly string[]>([])
  const busy = (id: string) => working().includes(id)
  const hold = (id: string) => setWorking([...working(), id])
  const release = (id: string) => setWorking(working().filter((entry) => entry !== id))
  const [cursor, setCursor] = createSignal(0)
  const [versionCursor, setVersionCursor] = createSignal(0)
  const [toolCursor, setToolCursor] = createSignal(0)
  /**
   * Whether the driver half of the tools pane is unfolded. Deliberately NOT in
   * `tui-state.json`: it is a moment's curiosity about what else is installed,
   * not a setting about how this front end should look.
   */
  const [driversOpen, setDriversOpen] = createSignal(false)
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

  /** The store's listing: one `ext list`, plus a manifest read per id. */
  const loadListing = async (): Promise<ExtensionEntry[]> => {
    const entries = await listExtensions(props.ws)
    setListed(entries)
    return entries
  }

  /**
   * What the SOURCE in each store directory would build to, versus what is
   * there — the one thing the store's own listing cannot say. A plan, so this
   * view never writes anything by opening; and since T22 it is also half the
   * LIST, because an id that has never built is not in `ext list` at all.
   *
   * The two dry-runs are the expensive pair, so they run when the answer can
   * actually have changed: on opening, and after `b` or `p`. An activation is
   * not one of those — a pointer move cannot change what a draft would build to.
   */
  const loadPlans = async () => {
    let plans: SyncLine[] = []
    try {
      const [ws_plan, user_plan] = await Promise.all([planStore(props.ws, false), planStore(props.ws, true)])
      plans = [...ws_plan.lines, ...user_plan.lines]
    } catch {
      return // no plan is "unknown", never a wrong column
    }
    setDrafts(plans)
    const held = listed()
    const unlisted = plans.filter((line) => !held.some((entry) => entry.id === line.id)).map((line) => line.id)
    setSourceOnly(await draftEntries(props.ws, unlisted, rootsOf(props.ws, held)))
  }

  /**
   * Check the optimistic picture against the store, after an action landed.
   *
   * Two subprocesses, in the background, with the answer already on screen: the
   * listing (did `current` really move?) and the config projection (what does
   * the merged pin list say now?). Deliberately not the plans, and not the usage
   * journal — neither can be moved by pointing `current` somewhere.
   */
  const reconcile = async () => {
    dropOrphanPins(await loadListing())
    await refreshPins()
  }

  /** Everything, plans included: opening the view, and after `b` / `p`. */
  const refresh = async () => {
    await loadListing()
    setUsage(await readToolUsage(props.ws))
    await Promise.all([refreshPins(), loadPlans()])
    dropOrphanPins(extensions())
  }

  /**
   * Pins on this TUI's list that no active extension can resolve any more.
   *
   * A `session new --pin` naming an inactive extension is refused outright
   * (`PinNamesUnknownExtension`), so a stale line here does not cost a tool — it
   * costs the whole session. This list is our own program state, so the honest
   * repair is to drop it, out loud, rather than to keep offering a session that
   * will not open.
   */
  const dropOrphanPins = (entries: readonly ExtensionEntry[]) => {
    const available = toolRows(entries, sources(), []).map((row) => row.id)
    const orphans = orphanPins(tuiPins(), available)
    if (orphans.length === 0) return
    const kept = tuiPins().filter((pin) => !orphans.includes(pin))
    rememberSessionPins(kept, props.statePath)
    setTuiPins(kept)
    setNotice(`${orphans.join(" ")} unpinned · nothing active declares them any more`)
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

  const allTools = createMemo(() => toolRows(extensions(), sources(), usage()))
  /** The rows on screen: everything, or everything with a checkbox (T33). */
  const tools = createMemo(() => shownRows(allTools(), driversOpen()))
  const folded = createMemo(() => foldedRows(allTools()))
  const selectedTool = createMemo(() => tools()[Math.min(toolCursor(), Math.max(0, tools().length - 1))] ?? null)
  /**
   * Fold and unfold. The cursor is kept ON THE SAME ROW rather than at the same
   * index — folding six rows out from under it would otherwise scroll the
   * selection somewhere nobody asked it to go.
   */
  const toggleFold = () => {
    const row = selectedTool()
    const next = !driversOpen()
    setDriversOpen(next)
    const at = shownRows(allTools(), next).findIndex((entry) => entry.id === row?.id)
    setToolCursor(at >= 0 ? at : 0)
  }
  const [foldHover, setFoldHover] = createSignal(false)
  const foldClick = onClick(toggleFold)
  const quota = createMemo(() => quotaLine(maxTools(), nextFace(sources()).length))

  /** An extension takes part in the next session: an active version, not shadowed. */
  const isActive = (entry: ExtensionEntry) => entry.current !== null && !entry.shadowed
  /** Its declared tools, as the stable ids a pin names. */
  /**
   * The tools the SWITCH pins: the ones the package puts on the MODEL's face
   * (`pinsOf`, DESIGN §7.2.1). A package whose tools are all a driver interface
   * yields none, and its switch is membership alone — the pin axis is not
   * half-anything there: `compact` is fully on with nothing on the face,
   * because that is how a driver calls it.
   */
  const pinnable = (entry: ExtensionEntry) => pinsOf(entry)
  const pinnedCount = (entry: ExtensionEntry) =>
    pinnable(entry).filter((id) => pinState(id, sources()) !== "off").length
  const stateOf = (entry: ExtensionEntry): SwitchState =>
    switchState(isActive(entry), pinnable(entry).length, pinnedCount(entry))
  /** The short cell beside a half-on package: which half. */
  const switchCell = (entry: ExtensionEntry): string => {
    if (stateOf(entry) !== "partial") return ""
    if (!isActive(entry)) return "pins only"
    return `${pinnedCount(entry)}/${pinnable(entry).length} tools`
  }
  const switchColor = (state: SwitchState) =>
    state === "on" ? style.theme.ok : state === "partial" ? style.theme.warn : style.theme.faint

  /** The columns this overlay may draw in: the box pads one on each side. */
  const inner = () => Math.max(24, screen().width - 2)

  /**
   * The id list, sized from the ids it actually holds rather than from the 34
   * it used to be fixed at — and never allowed past half the screen, because
   * the detail beside it is the half that explains what the cursor is on.
   *
   * Four columns, and each one answers the list's only question — should I move
   * this? (tui.md §11, T23). The `3v comp` cell that used to sit beside the id
   * answered a different one: how many builds are behind it and what kind of
   * package it is are facts about a package somebody has already walked up to,
   * and they are in the detail pane and on the version line, where walking up to
   * it puts them.
   */
  const idCols = createMemo(() => {
    const list = extensions()
    const [id, mode, on, draft, shadow] = squeeze(
      [
        columnWidth(list.map((entry) => entry.id), 2, 24),
        columnWidth(list.map(modeCell), 2, 6),
        columnWidth(list.map(switchCell), 2, 12),
        columnWidth(list.map((entry) => draftColumn(draftOf(entry.id))), 2, 11),
        columnWidth(list.map((entry) => (entry.shadowed ? "shadowed" : "")), 0, 9),
      ],
      [8, 0, 0, 0, 0],
      Math.max(16, Math.floor(inner() / 2)) - 2,
    )
    return { id: id!, mode: mode!, on: on!, draft: draft!, shadow: shadow! }
  })
  /** The whole left pane: the cursor gutter, the switch, and the five columns. */
  const idWidth = () =>
    2 + switch_width + idCols().id + idCols().mode + idCols().on + idCols().draft + idCols().shadow
  /** What is left for the detail beside it, less its own two-column pad. */
  const detailWidth = () => Math.max(16, inner() - idWidth() - 2)

  /**
   * The version line, allocated by priority rather than evenly. The two markers
   * come first — which build runs and which one this session froze are the
   * line's two facts — then the id takes its WHOLE width whenever the pane has
   * room beside them: hiding digits the terminal has space for buys nothing.
   * Only a pane too narrow for both falls back to `shortVersion`, and then the
   * full string appears on one line under the cursor. The timestamp only orders
   * builds the list already shows in order, so it takes what is left and on a
   * narrow pane takes no room at all.
   */
  const versionCols = createMemo(() => {
    const list = versions()
    const frozen = props.header ? frozenVersion(props.header, selected()?.id ?? "") : null
    const budget = Math.max(8, detailWidth() - 2)
    const current_w = columnWidth([selected()?.current ? `${style.glyphs.capability} current` : ""], 2, 12)
    const mine_w = columnWidth([frozen ? `${style.glyphs.bar} this session` : ""], 0, 15)
    const full_w = columnWidth(list.map((entry) => entry.version), 2, 28)
    const full = full_w + current_w + mine_w <= budget
    const version = Math.min(
      full ? full_w : columnWidth(list.map((entry) => shortVersion(entry.version)), 2, 14),
      budget,
    )
    const [current, mine] = squeeze([current_w, mine_w], [0, 0], Math.max(0, budget - version))
    const spare = budget - version - current! - mine!
    const when = spare >= 8 ? Math.min(columnWidth(list.map((entry) => stamp(entry.mtime)), 2, 18), spare) : 0
    return { version, when, current: current!, mine: mine!, full }
  })

  /** The pin panel's rows: a checkbox, the tool id, its state, its evidence. */
  const toolCols = createMemo(() => {
    const list = tools()
    const [id, state, uses, ok] = squeeze(
      [
        columnWidth(list.map((row) => row.id), 2, 34),
        columnWidth(list.map(labelOf), 2, 26),
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

  /** Walk the pane strip, wrapping at both ends. */
  const step = (delta: number) => {
    const at = panes.indexOf(pane())
    setPane(panes[(at + delta + panes.length) % panes.length]!)
  }

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
  const applyPin = async (change: PinChange, options: { reconcile?: boolean } = {}): Promise<boolean> => {
    try {
      if (change.user) {
        if (userPath().length === 0) throw new Error("config show did not say where the user config lives")
        writeUserPins(userPath(), change.user)
      }
      if (change.session) rememberSessionPins(change.session, props.statePath)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
      return false
    }
    // An empty notice is not news: `pinAll` / `unpinAll` have nothing of their
    // own to say and the caller's sentence is the one worth reading, so wiping
    // its "…" here would only make the switch look idle while it works.
    if (change.notice.length > 0) setNotice(change.notice)
    // Take the write as read straight away. `refreshPins` spawns `config show`,
    // and until it answers `sources()` would still describe the world before
    // this change — so a second toggle arriving in that window (two clicks in a
    // row) would compute itself from a stale state and undo nothing. The file
    // is already written; this only stops the screen from lagging behind it.
    if (change.session) setTuiPins(change.session)
    if (change.user) setUserPins(change.user)
    if (options.reconcile !== false) await refreshPins()
    return true
  }

  /**
   * One tool's pin, from wherever the decision came: `Space`, `Enter`, the
   * checkbox, a second click on the row.
   *
   * A DRIVER tool has no pin to move — the answer is a sentence, not a state
   * change — unless one is somehow already down, in which case taking it back is
   * exactly what this should do.
   */
  const toggleTool = (row: ToolRow) => {
    if (row.driver && row.state === "off") {
      setNotice(`${row.id} is called by a driver with ext run · a pin would put it on the model face, where it cannot run`)
      return
    }
    void applyPin(toggle(row.id, sources()))
  }

  /** `Space` on a tool row: that one tool. `A`: promote it to the config file. */
  const pinKey = (verb: "toggle" | "promote") => {
    if (pane() === "tools") {
      const row = selectedTool()
      if (!row) return
      if (verb === "toggle") return toggleTool(row)
      if (row.driver) {
        setNotice(`${row.id} is a driver tool · there is nothing to promote · /compact and drivers call it with ext run`)
        return
      }
      return void applyPin(promote(row.id, sources()))
    }
    if (verb === "promote") {
      // Deliberately one at a time: `always` costs a slot and prefix tokens in
      // every session on this machine, and a whole package at once is not a
      // decision anybody makes by holding a key down.
      setNotice("A promotes one tool · Tab to the tools pane and pick it")
      return
    }
    setNotice("Enter turns the whole extension on or off · Space pins one tool, in the tools pane")
  }

  /**
   * The switch: `Enter` on an id, or a click on its marker (tui.md §11, T22).
   *
   * ON is both axes at once — point `current` at a built version so its skills
   * and system prompts join the composition, and pin every tool it declares so
   * the model can call them. OFF is both back. Nothing here is irreversible and
   * nothing here reaches the session already on screen (physics #2), which is
   * why neither direction asks for a `y`.
   *
   * Both directions are OPTIMISTIC (tui.md §11, T23): the row moves on the
   * keypress, the notice says the work is in flight, and the subprocess that
   * takes the better part of a second confirms or puts it back. The alternative
   * — and what this used to be — is three seconds of a screen that has not
   * acknowledged the key at all, which reads as a broken switch.
   */
  const toggleExtension = async () => {
    const entry = selected()
    if (!entry) return
    const ids = pinnable(entry)
    if (entry.shadowed) {
      setNotice(`${entry.id} is shadowed by an earlier root · that copy is the one that runs`)
      return
    }
    // A second Enter inside the first one's flight is the same decision pressed
    // twice, not two decisions.
    if (busy(entry.id)) {
      setNotice(`${entry.id} · still working on the last press`)
      return
    }
    if (stateOf(entry) === "on") {
      await switchOff(entry, ids)
      return
    }
    await switchOn(entry, ids)
  }

  /**
   * Both pin lists exactly as they are, so a write whose companion kernel action
   * then failed can be put back byte for byte — `unpinAll` would also take away
   * pins that were already there before this press.
   */
  const pinSnapshot = () => ({ user: [...userPins()], session: [...tuiPins()] })

  const restorePins = async (before: { user: string[]; session: string[] }) => {
    await applyPin({ user: before.user, session: before.session, notice: "" }, { reconcile: false })
  }

  const switchOn = async (entry: ExtensionEntry, ids: string[]) => {
    // The version to point at: what the draft would build to when the plan says
    // it is there, else the newest build in the store. `not built` names a
    // version that does not exist yet, which is what `b` is for.
    const planned = draftOf(entry.id)
    const fromDraft =
      planned && (planned.state === "built" || planned.state === "already built") ? planned.version : null
    const version = entry.current ?? fromDraft ?? entry.versions[entry.versions.length - 1]?.version ?? null
    if (!version) {
      const why = draftColumn(planned)
      setNotice(`${entry.id} has no built version${why ? ` · ${why}` : ""} · b builds the source in its store directory`)
      return
    }
    /*
     * A full tool face stops the PINS, never the activation (tui.md §11, T23).
     *
     * The two axes are independent, and only one of them has a quota: an
     * extension can be active with nothing on the native face at all, and
     * `nulya ext run` calls its tools there — which is how `/compact` has always
     * called `compact`. Refusing the whole switch because the eighth slot was
     * taken is what made `compact` un-turn-on-able with six pins already down,
     * with `2+9/8 · nothing changed` as the entire explanation.
     */
    const face = nextFace(sources())
    const added = ids.filter((id) => !face.includes(id))
    const room = builtin_tools + face.length + added.length <= maxTools()

    const change = room && ids.length > 0 ? pinAll(ids, sources()) : null
    hold(entry.id)
    const before = { current: entry.current, pins: pinSnapshot() }
    setNotice(`${entry.id} on…`)
    // Optimistic on the SCREEN, and only there: both halves of the switch move
    // now, and neither is written until the kernel has agreed to the half it
    // owns. A pin naming an extension with no `current` is what makes
    // `session new` refuse to start at all, so it must never outlive a failed
    // activate — which is the same reason OFF writes its pins first.
    setLocalCurrent(entry.id, version)
    if (change?.session) setTuiPins(change.session)
    if (change?.user) setUserPins(change.user)
    try {
      if (before.current !== version) {
        // The one change in this panel a running model can act on: with the
        // session named, the kernel deposits a capability note and the model
        // learns at its next step boundary that `ext run` reaches a new version
        // (DESIGN §5.3). A draft tab has no session to tell.
        await extSetCurrent(props.ws, "activate", entry.id, version, { session: props.sessionFile })
      }
    } catch (error) {
      setLocalCurrent(entry.id, before.current)
      setTuiPins(before.pins.session)
      setUserPins(before.pins.user)
      setNotice(error instanceof Error ? error.message : String(error))
      release(entry.id)
      return
    }
    // Agreed: now the pin lists are written where the next `session new` reads.
    if (change) await applyPin(change, { reconcile: false })
    release(entry.id)
    props.onMembershipChanged?.()
    setNotice(
      // A package that contributes a system prompt gets the sentence about what
      // that actually costs, instead of a version and a pin count (T31): one
      // keypress here reaches every session this machine opens from now on, and
      // that is the fact worth the line.
      entry.systemPrompts.length > 0
        ? promptConsequence(entry.id, true)
        : `${entry.id} on · ${version}` +
          (ids.length > 0
            ? room
              ? ` · ${ids.length} tool(s) pinned`
              : ` · ${faceFullLine(maxTools(), face.length, added.length)}`
            : entry.tools.length > 0
              ? // A package whose tools are a driver interface: it is fully on,
                // and none of it is on the model's face by design.
                ` · its ${entry.tools.length} tool(s) stay off the model face · /compact and drivers call them with ext run`
              : ""),
    )
    // The store has the last word, but it says it after the screen already moved.
    void reconcile()
  }

  const switchOff = async (entry: ExtensionEntry, ids: string[]) => {
    // Pins first. A pin naming an extension with no `current` is refused by
    // `session new` outright, so the order that leaves a legal world at every
    // point is: take the pins away, then the pointer.
    hold(entry.id)
    const before = { current: entry.current, pins: pinSnapshot() }
    setNotice(`${entry.id} off…`)
    let stuck = ""
    if (ids.length > 0) {
      const change = unpinAll(ids, sources())
      if (change.user || change.session) await applyPin(change, { reconcile: false })
      stuck = change.notice
    }
    setLocalCurrent(entry.id, null)
    try {
      if (before.current) await extDeactivate(props.ws, entry.id)
    } catch (error) {
      setLocalCurrent(entry.id, before.current)
      await restorePins(before.pins)
      setNotice(error instanceof Error ? error.message : String(error))
      release(entry.id)
      return
    }
    release(entry.id)
    props.onMembershipChanged?.()
    setNotice(
      (entry.systemPrompts.length > 0
        ? promptConsequence(entry.id, false)
        : `${entry.id} off · its skills leave the composition`) +
        ` · versions all stay${stuck ? ` · ${stuck}` : ""}`,
    )
    void reconcile()
  }

  /**
   * Move one row's `current` on the screen, before the store has been asked.
   *
   * The pointer is what the switch marker draws, so this is the whole of the
   * optimism: `reconcile` replaces the row with the store's own answer a second
   * later, and a failure puts the old value straight back.
   */
  const setLocalCurrent = (id: string, version: string | null) => {
    const patch = (list: ExtensionEntry[]) =>
      list.map((entry) => (entry.id === id ? { ...entry, current: version } : entry))
    setListed(patch(listed()))
    setSourceOnly(patch(sourceOnly()))
  }

  /**
   * `b` — build the source sitting in this id's store directory.
   *
   * `ext build <root>/<id>` lands in the root that holds the draft (the kernel
   * picks the destination from the path), so this is the same command `ext sync`
   * runs for that one id, and the refusal it prints is the kernel's own.
   */
  const buildDraft = async () => {
    const entry = selected()
    if (!entry) return
    if (!draftOf(entry.id)) {
      setNotice(`${entry.id} has no source in ${entry.root} · nothing to build`)
      return
    }
    if (busy(entry.id)) {
      setNotice(`${entry.id} · still working on the last press`)
      return
    }
    hold(entry.id)
    setNotice(`building ${entry.id}…`)
    try {
      const version = await extBuild(props.ws, join(entry.root, entry.id))
      release(entry.id)
      // A build is the one action that changes what a PLAN says, so this is one
      // of the two places the two dry-runs are worth their seconds again.
      await refresh()
      setNotice(`${entry.id} ${version} built · Enter turns it on`)
    } catch (error) {
      release(entry.id)
      setNotice(error instanceof Error ? error.message : String(error))
      await refresh()
    }
  }

  /**
   * `a` on the version line: point `current` at exactly this build.
   *
   * One verb, both directions — going back is activating an older version
   * (DESIGN §7.4), and the CLI has no separate `rollback` for it to mirror.
   */
  const act = () => {
    const entry = selected()
    if (!entry) return
    // The timeline's own keys: they name ONE build. Turning an extension on is
    // Enter's job and picks the version itself.
    if (pane() !== "versions") {
      setNotice("Enter turns this extension on or off · Tab to the version line to point at one build")
      return
    }
    const version = selectedVersion()?.version
    if (!version) {
      setNotice("no version to point at · this id has never been built")
      return
    }
    setConfirm({ kind: "activate", id: entry.id, version })
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

  const runConfirmed = async () => {
    const pending = confirm()
    setConfirm(null)
    if (!pending) return
    if (busy(pending.id)) {
      setNotice(`${pending.id} · still working on the last press`)
      return
    }
    hold(pending.id)
    const previous = selected()?.id === pending.id ? (selected()?.current ?? null) : null
    setNotice(`${pending.kind} ${pending.id} ${pending.version}…`)
    // A pointer move draws itself at once, like the switch above it; prune
    // deletes directories and has nothing to draw until the store is re-read.
    if (pending.kind !== "prune") setLocalCurrent(pending.id, pending.version)
    try {
      if (pending.kind === "prune") {
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
      if (pending.kind !== "prune") setLocalCurrent(pending.id, previous)
      setNotice(error instanceof Error ? error.message : String(error))
    }
    release(pending.id)
    if (pending.kind !== "prune") {
      props.onMembershipChanged?.()
      // A pointer moved and nothing else: the plans still say what they said.
      void reconcile()
      return
    }
    // Versions went away, so what the SOURCE beside them would build to can have
    // changed from `already built` to `not built`: the plans are re-read.
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
    // The pane strip is a row of four, so the keys that walk it are the ones
    // that mean sideways: h/l beside j/k, ←/→ beside ↑/↓, and Tab because a
    // strip of panes is a strip of tabs (T24). Shift+Tab and h go back — a
    // cycle you can only go forwards round is three presses to undo one.
    if (key.name === "tab") return step(key.shift ? -1 : 1)
    if (key.name === "l" || key.name === "right") return step(1)
    if (key.name === "h" || key.name === "left") return step(-1)
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    // Enter is the row's action, the same one a second click performs (T18): on
    // an id it is the switch, on a tool row it is that tool's pin.
    if (key.name === "return") {
      if (pane() === "tools") return pinKey("toggle")
      if (pane() === "extensions") return void toggleExtension()
      return
    }
    if (key.name === "space") return pinKey("toggle")
    // Shift+A, not `a`: promotion writes a config file, and it must not be one
    // keystroke away from the activate that sits beside it.
    if (key.name === "a" && key.shift) return pinKey("promote")
    if (key.name === "a") return act()
    if (key.name === "b") return void buildDraft()
    // Only where there is something to fold: `d` elsewhere in this view is a
    // key that appears to do nothing, which is worse than a key that is unbound.
    if (key.name === "d" && pane() === "tools" && (driversOpen() || folded().length > 0)) return toggleFold()
    if (key.name === "p") return prune()
    if (key.name === "t") return setPane(pane() === "tools" ? "extensions" : "tools")
    if (key.name === "u") return setPane(pane() === "usage" ? "extensions" : "usage")
  })

  /**
   * The pin panel. One row per tool, three states, and the quota above them —
   * `1+N/8`, because the builtin counts and a refused pin is otherwise a
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
          // Same two-step as the id list: land on the row, then act on it.
          const click = onClick(() => {
            const again = toolCursor() === index
            setToolCursor(index)
            if (again) pinKey("toggle")
          })
          // The checkbox is its own target inside the row: a click on it is the
          // Space key, a click anywhere else on the row is only the cursor.
          // Nested targets, so it has to claim the event or the row acts too.
          const check = onClick(() => {
            setToolCursor(index)
            toggleTool(row())
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
                {/* The same three colours the id list's switch uses: `ok` for on
                    and ours, `warn` for on but written somewhere we may not
                    edit, `faint` for off. One meaning, one colour (tui.md §6).
                    A driver tool has no box at all: there is no state here for a
                    checkbox to be wrong about. */}
                <text
                  fg={
                    row().state === "other"
                      ? style.theme.warn
                      : on()
                        ? style.theme.ok
                        : style.theme.faint
                  }
                >
                  {row().driver && !on() ? " ·  " : on() ? "[x] " : "[ ] "}
                </text>
              </box>
              <box width={toolCols().id} flexShrink={0}>
                <text fg={on() || here() ? style.theme.fg : style.theme.muted}>
                  {fit(row().id, toolCols().id - 2)}
                </text>
              </box>
              <box width={toolCols().state} flexShrink={0}>
                <text fg={row().state === "other" ? style.theme.warn : style.theme.dim}>
                  {fit(labelOf(row()), toolCols().state - 2)}
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
      {/* An empty list has two different reasons now, and the older sentence —
          "build something first" — is wrong about the second one: those
          extensions are active, they just have nothing a model may call. */}
      <Show when={tools().length === 0}>
        <Show
          when={folded().length === 0}
          fallback={
            <Lines
              text="nothing on the model face · every active extension here declares driver tools only"
              fg={style.theme.muted}
            />
          }
        >
          <Lines
            text="nothing can be pinned yet · a tool reaches the model only through an extension with an active version"
            fg={style.theme.muted}
          />
          <Lines text="put its source in a store directory, then `b` builds it and Enter turns it on" />
        </Show>
      </Show>
      {/*
        The folded half, as one line that answers to `d` and to a click. It sits
        UNDER the list rather than in it: it has no checkbox and no cursor, and
        a row the cursor walks onto but cannot act on is the shape T33 took out.
      */}
      <Show when={driversOpen() || folded().length > 0}>
        <box height={1} />
        <box
          flexDirection="row"
          width="100%"
          height={1}
          flexShrink={0}
          backgroundColor={foldHover() ? style.theme.hover : undefined}
          onMouseOver={() => setFoldHover(true)}
          onMouseOut={() => setFoldHover(false)}
          onMouseDown={foldClick.onMouseDown}
          onMouseUp={foldClick.onMouseUp}
        >
          <box width={4} height={1} flexShrink={0}>
            <text fg={style.theme.faint}>{` ${driversOpen() ? style.glyphs.foldOpen : style.glyphs.foldClosed}  `}</text>
          </box>
          <text fg={style.theme.dim}>{fit(foldLine(folded().length, driversOpen()), inner() - 4)}</text>
        </box>
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
            {/*
              `Index`, not `For`, for the reason the tools pane gives: an
              optimistic switch replaces the row's object on the keypress and the
              reconcile replaces it again a second later, and `For` would tear
              down and rebuild every row both times — taking any click that
              happened to be mid-press with it. `Index` keeps one renderable per
              POSITION and only updates what it says.
            */}
            <Index each={extensions()}>
              {(row, index) => {
                const entry = row
                const here = () => index === cursor()
                const draft = () => draftColumn(draftOf(entry().id))
                const tone = () => ({
                  selected: here() && pane() === "extensions",
                  hovered: idHover.at() === index,
                })
                const gutter = () => rowGutter(style, tone())
                const on = () => stateOf(entry())
                // Clicking an id both moves the cursor and says which pane the
                // cursor is in — the same two facts `Tab` and `j/k` set apart.
                // Walking up to a row and acting on it are two decisions, and a
                // pointer only has one button — so the FIRST click on a row is
                // the cursor and a second click on the row the cursor is already
                // on is Enter (T18's rule, T24 applies it here). It makes the
                // switch reachable without hitting the two-column marker, which
                // is a target the size of a full stop.
                const click = onClick(() => {
                  const again = pane() === "extensions" && cursor() === index
                  setPane("extensions")
                  setCursor(index)
                  setVersionCursor(0)
                  if (again) void toggleExtension()
                })
                // The marker is its own target inside the row, like the tools
                // pane's `[x]`: a click on it is Enter, a click anywhere else on
                // the row only moves the cursor.
                const flip = onClick(() => {
                  setPane("extensions")
                  setCursor(index)
                  setVersionCursor(0)
                  void toggleExtension()
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
                    {...idHover.row(index)}
                  >
                    <text fg={gutter().fg} flexShrink={0}>
                      {gutter().text}
                    </text>
                    {/* Is this extension on for the next session? Two shapes and
                        three colours, so the answer survives a terminal with no
                        colour at all (tui.md §11, T22). */}
                    <box
                      width={switch_width}
                      height={1}
                      flexShrink={0}
                      onMouseDown={flip.onMouseDown}
                      onMouseUp={flip.onMouseUp}
                    >
                      <text fg={switchColor(on())}>
                        {on() === "off" ? style.glyphs.switchOff : style.glyphs.switchOn}{" "}
                      </text>
                    </box>
                    <box width={idCols().id} flexShrink={0}>
                      <text
                        fg={
                          entry().shadowed
                            ? style.theme.dim
                            : on() === "on" || here()
                              ? style.theme.fg
                              : style.theme.muted
                        }
                      >
                        {fit(entry().id, idCols().id - 2)}
                      </text>
                    </box>
                    {/* A package that contributes a system prompt is a MODE, and
                        turning it on reaches every session this machine opens
                        (T31). Warn-coloured while it is on: that is the state
                        somebody has to be able to spot without reading a
                        detail pane. */}
                    <box width={idCols().mode} flexShrink={0}>
                      <text fg={on() === "off" ? style.theme.faint : style.theme.warn}>
                        {fit(modeCell(entry()), Math.max(0, idCols().mode - 2))}
                      </text>
                    </box>
                    {/* Half on: which half. `3/5 tools` and `pins only` are the
                        two ways the kernel's two axes come apart. */}
                    <box width={idCols().on} flexShrink={0}>
                      <text fg={style.theme.warn}>{fit(switchCell(entry()), Math.max(0, idCols().on - 2))}</text>
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
                      <text fg={style.theme.warn}>{entry().shadowed ? fit("shadowed", idCols().shadow) : ""}</text>
                    </box>
                  </box>
                )
              }}
            </Index>
            {/* An empty store is normal — nulya ships one builtin and nothing
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
                  {/* The switch, in words. Its first fact is the one the row's
                      marker draws, so the two can never disagree. */}
                  <Lines
                    text={`${entry.id} · ${entry.kind} · ${isActive(entry) ? "active" : "inactive"}${
                      entry.tools.length === 0
                        ? ""
                        : pinnable(entry).length > 0
                          ? ` · tools ${pinnedCount(entry)}/${entry.tools.length} pinned`
                          : ` · tools ${entry.tools.length} · called with ext run, never on the model face`
                    } · current ${entry.current ? shortVersion(entry.current) : "(none)"}`}
                    width={detailWidth()}
                    fg={style.theme.fg}
                  />
                  {/* An id with source and no version: what stopped it, in the
                      kernel's own words, and the two ways out. */}
                  <For each={draftHelp(draftOf(entry.id))}>
                    {(line) => <Lines text={line} width={detailWidth()} fg={style.theme.warn} />}
                  </For>
                  {/* Which directory holds this copy: needed when two roots have
                      the same id, and noise the rest of the time — so it is drawn
                      in the quietest colour there is unless it is the reason this
                      copy never runs. */}
                  <Lines
                    text={`root ${entry.root}${entry.shadowed ? " · shadowed by an earlier root · never runs" : ""}`}
                    width={detailWidth()}
                    fg={entry.shadowed ? style.theme.warn : style.theme.faint}
                  />
                  <Lines
                    text={`tools ${entry.tools.join(" ") || "—"} · skills ${
                      entry.skills.map((skill: string) => skill.split("/").pop()).join(" ") || "—"
                    } · prompts ${entry.systemPrompts.length || "—"}`}
                    width={detailWidth()}
                    fg={style.theme.muted}
                  />
                  {/* …and what that prompt count MEANS, because a `1` at the end
                      of the line above is the most consequential fact in this
                      panel written as the quietest one (T31). */}
                  <Show when={entry.systemPrompts.length > 0}>
                    <Lines
                      text={`a mode · turning it on puts its system prompt in every new session on this machine · ${
                        entry.id === "evolution" ? "/evolve" : `/as ${entry.id}`
                      } wears it for one session instead`}
                      width={detailWidth()}
                      fg={style.theme.warn}
                    />
                  </Show>
                  {/* Authority, only where there is any. `fs 0 · net — · proc 0`
                      is three cells saying nothing, on every package that asked
                      for nothing — and it read as data, which is how the one
                      package that DID ask for something stopped standing out. */}
                  <Show when={permissionLine(entry)}>
                    <Lines text={permissionLine(entry)!} width={detailWidth()} />
                  </Show>
                  <Show when={drift()}>
                    <Lines text={drift()!} width={detailWidth()} fg={style.theme.warn} />
                  </Show>
                  <box height={1} />

                  <text fg={style.theme.dim} height={1}>
                    {fit(`versions · ${entry.versions.length}`, detailWidth())}
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
                              {fit(
                                versionCols().full ? version.version : shortVersion(version.version),
                                versionCols().version - 2,
                              )}
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
                  {/* Only when the rows had to shorten: the build the cursor is
                      on, in full. Reading a version id is only ever the prelude
                      to typing it after `ext activate`, and on a pane wide
                      enough the rows themselves already answer that. */}
                  <Show when={!versionCols().full && selectedVersion()}>
                    <text fg={style.theme.faint} height={1}>
                      {fit(`  ${selectedVersion()!.version}`, detailWidth())}
                    </text>
                  </Show>
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
          pointer or a pin, and physics #2 says none of them can reach a session
          that has already started. On a tab that has NOT started one, the very
          same fact is good news and reads the other way round (T22). */}
      <OverlayFooter
        width={inner()}
        help={help}
        notice={confirm() ? null : notice()}
        warning={
          // A frozen header IS a started session; without one this tab is still
          // a draft, and then the very same fact reads the other way round.
          props.header
            ? "changes apply to the NEXT session — this one froze its tools at start"
            : "changes apply to the session this tab is about to start"
        }
        brief="Enter on/off · j/k move · h/l pane · Esc close"
        more={[
          "Enter activates the extension and pins its tools, again turns both off · a click on the row the cursor is already on does the same",
          "h/l ←/→ Tab move across the panes · j/k ↑/↓ move down a list",
          "Space pin one tool · A promote it to always · d fold the driver tools in or out · b build the source · p prune old versions",
          "a activate one named version, on the version line — an older one is the rollback · t tools · u usage",
        ]}
      />
    </box>
  )
}
