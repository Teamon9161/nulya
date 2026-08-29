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
 *  - the SWITCH. `Enter` on an id makes the extension active or inactive for
 *    the next session: active = point `current` at a built version AND pin
 *    every `surface:"manual"` tool it declares; inactive = take those pins
 *    back and clear `current`. Those are the only two things it writes (T52).
 *    "Active" names what THIS store root points at, not whether the next
 *    session actually carries it — a `manual` package still needs naming
 *    (`/with`, a declared command, `[extensions] with`) to reach one; only
 *    `standing` (`apply: "auto"`) answers that (T55). T12 §5 held the
 *    two axes apart on principle and refused to merge them — that principle is
 *    right about the kernel and was wrong about the screen, where both keys were
 *    invisible and the state they moved was drawn nowhere (tui.md §11, T22). The
 *    axes are still two: the TOOLS pane is where one tool is pinned on its own,
 *    and the version line is where one specific build is pointed at.
 *
 * An extension id, a tool name and a store root are all as long as somebody
 * chose to make them, so every cell here is cut to its column and every sentence
 * is broken at its ` · ` joints by us rather than the terminal (`ui/columns.ts`).
 */
import { For, Index, Show, createEffect, createMemo, createSignal, on, onMount } from "solid-js"
import { join } from "node:path"
import { useKeyboard } from "@opentui/solid"
import { useScreen, useStyle } from "../../render/theme.ts"
import { columnWidth, fit, squeeze, wrapWords } from "../columns.ts"
import { createHover, lifted, onClick, rowBackground, rowGutter, rowText } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import {
  draftEntries,
  listExtensions,
  readToolUsage,
  rootsOf,
  type ExtensionEntry,
  type ToolUsage,
} from "../../nulya/files.ts"
import {
  configShow,
  extBuild,
  extDeactivate,
  extPrune,
  extSeed,
  extSetCurrent,
  type SyncLine,
} from "../../nulya/cli.ts"
import { draftColumn, pinsOf, planStore, wearCommand } from "../../extensions.ts"
import {
  builtin_tools,
  faceFullLine,
  orphanPins,
  pinAll,
  pinState,
  promote,
  quotaLine,
  readUserPins,
  resolvableStandingPins,
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

type VisiblePane = Exclude<Pane, "versions">

/**
 * The visible panes, in Tab order. They used to be reachable only by knowing
 * that `Tab` cycles and that `t` and `u` jump — which meant the usage table and
 * the pin panel were invisible until somebody read the footer. The version
 * timeline now lives in the extension detail itself, where the id is already
 * selected; `versions` remains only as an internal focus for that timeline.
 */
const panes: VisiblePane[] = ["extensions", "tools", "usage"]

/**
 * An action waiting for `y`. Only two are left, and both name a VERSION: moving
 * the pointer along the timeline by hand, and the one action here that deletes
 * something. The active/inactive switch asks nothing — it moves a pointer and a
 * pin list, both of which the same key puts back (tui.md §11, T22).
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
 * Whether an extension is ACTIVE for the next session, and — when the answer
 * is "half" — which half is missing.
 *
 * `active` means both axes agree: an active version, and every tool it
 * declares on the face. `partial` is the honest name for the states the
 * kernel can be left in — pinned but no longer active (a pointer moved back),
 * active with only some of its tools pinned (`Space` on one row) — and it is
 * warn-coloured because the first of those is what makes `session new`
 * refuse.
 */
export type SwitchState = "active" | "partial" | "inactive"

export function switchState(active: boolean, tools: number, pinned: number): SwitchState {
  if (active && pinned === tools) return "active"
  if (!active && pinned === 0) return "inactive"
  return "partial"
}

/** The marker and its space: one glyph, always two columns, so ids line up. */
const switch_width = 2

/**
 * The one word in the id list that is about REACH rather than contents (T52):
 * the kernel composes this package into every fresh session on this machine
 * (DESIGN §5.1), so the row is not "available", it is "in everything".
 *
 * Read from the kernel's record (`ext list`'s `standing` marker) rather than
 * from the current version's `apply` (T56). The manifest field is what a
 * VERSION declares; the record is what the activation verified and what
 * sessions actually get, and only the second is a state this column can report.
 * A package that declares `apply: "auto"` and has no `current` is standing in
 * nothing — the detail pane says what activating it would do instead.
 *
 * The column used to say `mode`, meaning "contributes a system prompt". That
 * was the best guess available while nothing could state its own reach: a
 * prompt is the contribution whose cost is paid in every session, so a package
 * with one was the package worth flagging. It reads the wrong package now — a
 * `manual` prompt package is one declared command or `/with` away and costs
 * nothing until then, while an `apply: "auto"` package of pure tools is in
 * front of every model here. The fact the old column carried is still on
 * screen: the detail pane lists prompts and the package's declared commands.
 */
export function standingCell(entry: { standing: boolean }): string {
  return entry.standing ? "standing" : ""
}

/** One row of the tools pane: a declared tool, its placement, state, and evidence. */
export interface ToolRow {
  id: string
  extension: string
  tool: string
  state: PinState
  uses: number
  ok: number
  /** `surface:"auto"`: exposed by package membership, not by a checkbox. */
  auto: boolean
  /** `surface:"internal"`: an `ext run` interface, never model-facing. */
  internal: boolean
}

/**
 * Every tool an active extension declares, with the state each one is in.
 *
 * Only extensions with an ACTIVE, un-shadowed version are here: a pin on a
 * package with no `current` is refused by `session new` (a pin brings its
 * package in, and there is nothing to bring), which is not something a checkbox
 * should offer.
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
        auto: entry.autoTools.includes(tool),
        internal: entry.internalTools.includes(tool),
      })
    }
  }
  return rows.sort((a, b) => a.id.localeCompare(b.id))
}

/**
 * A row the fold hides: one this pane cannot switch.
 *
 * `Space` writes and takes back PINS, and a pin is the way in for exactly one
 * surface (`manual`, DESIGN §5.1). So the rows with a working checkbox are the
 * `manual` ones — plus any row that somehow HAS a pin down, whatever its
 * surface, because taking that back is a thing this pane can do and the one
 * wrong checkbox in the list is the last thing to hide.
 *
 * Everything else is a row whose answer was decided elsewhere: an `auto` tool
 * is on because its package is in the session, an `internal` one is never on
 * the model face at all. Offering either a checkbox that does nothing is worse
 * than not drawing it — the kernel refuses a pin naming them outright
 * (`PinToolNotPinnable`), so there is no state here for a person to be in.
 */
function isFolded(row: ToolRow): boolean {
  if (!row.auto && !row.internal) return false
  return row.state === "off" || row.state === "composed"
}

/** The rows nobody can switch here (tui.md §11, T33, T59). */
export function foldedRows(rows: readonly ToolRow[]): ToolRow[] {
  return rows.filter(isFolded)
}

/**
 * What the list draws. Collapsed, the list is the switches and nothing else.
 *
 * The internal rows were listed beside them until T33, when there were six of
 * them to five pinnable ones — and, sorted by id, they came FIRST. The pinnable
 * half is capped by `registry.max_tools`; the internal half is capped by
 * nothing, so it grows the wrong way with every bundled package. The `auto`
 * rows joined them at T59 for a different reason: they are not noise, they are
 * MISLEADING — a row in a column of checkboxes, sitting in the list a person
 * came here to toggle things in, that no key in this pane can change.
 *
 * Both fold behind one line (`foldLine`) instead of disappearing: what each of
 * them costs a reader is a row, not the fact of its existence.
 */
export function shownRows(rows: readonly ToolRow[], expanded: boolean): ToolRow[] {
  return expanded ? [...rows] : rows.filter((row) => !isFolded(row))
}

/**
 * The one line the folded half becomes, and the key that opens it.
 *
 * Grouped by the package's own word (`auto` / `internal`, T52) and each with
 * what that word means, because the word alone is a manifest field and the
 * sentence is the reason the rows have no checkbox. Two groups, one line and
 * one key: the fold is a single control, and a reader deciding whether to open
 * it is asking one question.
 *
 * The reasons are short on purpose — the line is `fit` to the pane, and the
 * counts have to survive a narrow terminal. Anyone who opens it gets the longer
 * answer per row, where `stateLabel` already says `with the package`.
 */
export function foldLine(rows: readonly ToolRow[], expanded: boolean): string {
  const parts: string[] = []
  const autos = rows.filter((row) => row.auto).length
  const internals = rows.filter((row) => row.internal).length
  if (autos > 0) parts.push(`${autos} auto · with their package`)
  if (internals > 0) parts.push(`${internals} internal · ext run only`)
  return `${parts.join(" · ")} · d ${expanded ? "folds" : "shows"}`
}

  /**
   * What the NEXT session's face would carry: merged config pins, this TUI's
   * own pins, and `surface:"auto"` tools from packages composed every session.
   * It is the same face the draft status counts, even though the last group is
   * derived from membership rather than written as `--pin`.
   */
export function nextFace(sources: PinSources): string[] {
  const face = [...sources.merged]
  for (const pin of sources.session) if (!face.includes(pin)) face.push(pin)
  for (const pin of sources.composed ?? []) if (!face.includes(pin)) face.push(pin)
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
export function draftHelp(line: SyncLine | null, current?: string | null): string[] {
  if (!line) return []
  // Not a fault, and the one row-state whose repair is neither `b` nor Enter:
  // the package runs, at another build than the source here would produce.
  if (
    current !== undefined &&
    current !== null &&
    line.version !== null &&
    current !== line.version &&
    (line.state === "built" || line.state === "already built")
  ) {
    return ["this source builds to a version that is not the one in use · `a` on a version line points current at it"]
  }
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

/** When a version was built, to the minute — enough to order two of them. */
function stamp(mtime: number): string {
  return new Date(mtime).toISOString().slice(0, 16)
}

/**
 * What the state column says about a row. An `internal` tool's state is not a
 * pin state — it says who calls it, which is the answer to the question the
 * empty checkbox raises (T24). An `auto` one says what puts it on the face.
 */
export function labelOf(row: ToolRow): string {
  if (row.auto && row.state === "off") return "auto · with the package"
  if (row.internal && row.state === "off") return "internal · ext run"
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
   * Bumped by the host whenever something outside this view wrote to the store
   * or the pin list. Every read here is a file read, so a number that changes
   * is the only thing that can tell an open view to look again.
   */
  tick?: number
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
   * Whether the unswitchable half of the tools pane is unfolded. Deliberately
   * NOT in `tui-state.json`: it is a moment's curiosity about what else is
   * installed, not a setting about how this front end should look.
   */
  const [foldOpen, setFoldOpen] = createSignal(false)
  const [pane, setPane] = createSignal<Pane>("extensions")
  const [notice, setNotice] = createSignal<string | null>(null)
  const [drafts, setDrafts] = createSignal<SyncLine[]>([])
  const [confirm, setConfirm] = createSignal<Pending | null>(null)
  // The three places a pin can be written, plus the quota the kernel enforces.
  // `userPath` comes from the kernel's own projection: we write where it reads.
  const [maxTools, setMaxTools] = createSignal(8)
  const [merged, setMerged] = createSignal<string[]>([])
  /**
   * The kernel's own standing membership list (`[extensions] with`, DESIGN
   * §5.1), read from the same projection the pins come from. This front end
   * never writes it — since T52 it keeps no standing list of its own at all —
   * but a package config already composes is one whose row must not read as
   * "inactive".
   */
  const [configWith, setConfigWith] = createSignal<string[]>([])
  const [userPath, setUserPath] = createSignal("")
  const [userPins, setUserPins] = createSignal<string[]>([])
  const [tuiPins, setTuiPins] = createSignal<string[]>(sessionPins(props.statePath))
  /**
   * `surface:"auto"` tool ids from packages that every session started here is
   * composed with. They are native tools, but not pins; the kernel derives them
   * from membership at `session new`.
   */
  const [composedTools, setComposedTools] = createSignal<string[]>([])
  /**
   * Bundled ids whose draft in the user store is NOT what this binary ships and
   * that `ext seed` will not touch on its own — someone edited it, or an older
   * nulya (one from before seed kept a record) wrote it (DESIGN §7.2, T42).
   *
   * It belongs on this screen and not only in a start-up notice: the state is
   * durable — it is a fact about a directory, true until somebody acts on it —
   * and a line that scrolls off the status bar six seconds after a person walked
   * away to make coffee is not where a durable fact lives. `s` on the row is the
   * action; the notice now just points here.
   */
  const [outdated, setOutdated] = createSignal<readonly string[]>([])
  // One hover slot per list: panes replace each other, so sharing one would be
  // a highlight that follows the pointer into the wrong column.
  const idHover = createHover()
  const versionHover = createHover()
  const toolHover = createHover()
  const paneHover = createHover()
  const help = createKeyHelp()

  const sources = createMemo<PinSources>(() => ({
    user: userPins(),
    session: tuiPins(),
    merged: merged(),
    composed: composedTools(),
  }))

  const refreshPins = async () => {
    setTuiPins(sessionPins(props.statePath))
    try {
      const view = await configShow(props.ws)
      setMaxTools(view.registry.max_tools)
      setMerged(view.registry.pinned_native_tools)
      setConfigWith(view.extensions.with)
      const named = new Set([...view.extensions.with, ...style.settings.extensions.session_with])
      setComposedTools(
        listed()
          .filter((entry) => isActive(entry) && (named.has(entry.id) || entry.standing))
          .flatMap((entry) => entry.autoTools.map((tool) => toolId(entry.id, tool))),
      )
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
    setComposedTools(
      entries
        .filter((entry) => isActive(entry) && composedEverySession(entry))
        .flatMap((entry) => entry.autoTools.map((tool) => toolId(entry.id, tool))),
    )
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
    // The third dry-run, and the cheapest: no compiler, just digests of the
    // bundled drafts against what this binary carries.
    try {
      setOutdated((await extSeed(props.ws, { user: true, dryRun: true })).mine)
    } catch {
      // A binary too old to have `ext seed` ships nothing to compare against.
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
   * A `session new --pin` naming a package with no `current` is refused
   * outright (the pin brings its package in, and there is nothing to bring), so
   * a stale line here does not cost a tool — it costs the whole session. This list is our own program state, so the honest
   * repair is to drop it, out loud, rather than to keep offering a session that
   * will not open.
   */
  const dropOrphanPins = (entries: readonly ExtensionEntry[]) => {
    const available = resolvableStandingPins(entries)
    const orphans = orphanPins(tuiPins(), available)
    if (orphans.length === 0) return
    const kept = tuiPins().filter((pin) => !orphans.includes(pin))
    rememberSessionPins(kept, props.statePath)
    setTuiPins(kept)
    setNotice(`${orphans.join(" ")} unpinned · nothing active declares them any more`)
  }

  onMount(() => void refresh())

  // Somebody else wrote to the store while this view was open — in practice the
  // start-up pass, which can still be building when a person opens `/ext` to
  // watch it. Without this the view kept the plan it read on mount, so a draft
  // that had since been built went on saying `not built` and the pass looked
  // broken; the repair people found was to build it again by hand. Deferred, so
  // opening does not immediately refresh what `onMount` just read.
  createEffect(on(() => props.tick ?? 0, () => void refresh(), { defer: true }))

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
  /** The rows on screen: everything, or everything except folded driver rows. */
  const tools = createMemo(() => shownRows(allTools(), foldOpen()))
  const folded = createMemo(() => foldedRows(allTools()))
  const selectedTool = createMemo(() => tools()[Math.min(toolCursor(), Math.max(0, tools().length - 1))] ?? null)
  /**
   * Fold and unfold. The cursor is kept ON THE SAME ROW rather than at the same
   * index — folding six rows out from under it would otherwise scroll the
   * selection somewhere nobody asked it to go.
   */
  const toggleFold = () => {
    const row = selectedTool()
    const next = !foldOpen()
    setFoldOpen(next)
    const at = shownRows(allTools(), next).findIndex((entry) => entry.id === row?.id)
    setToolCursor(at >= 0 ? at : 0)
  }
  const [foldHover, setFoldHover] = createSignal(false)
  const foldClick = onClick(toggleFold)
  const quota = createMemo(() => quotaLine(maxTools(), nextFace(sources()).length))

  /** An extension takes part in the next session: an active version, not shadowed. */
  const isActive = (entry: ExtensionEntry) => entry.current !== null && !entry.shadowed
  /**
   * …and one that is a MEMBER of every session opened here, from any of the
   * three things that can say so (T52): the package asked and the kernel
   * recorded it (`standing`), the kernel's `[extensions] with`, and `tui.toml`'s
   * `session_with` (the packages this front end always brings, T42).
   *
   * The first is new and the reason the list is no longer four: this front end
   * kept a `standing_with` of its own until T52, written by Enter, and a
   * package that wants to be everywhere says so itself now — one fact, honoured
   * by the kernel for every driver rather than by each front end separately.
   * Which is why it is read from the kernel's record and not from the current
   * version's `apply` (T56): re-deriving it here would be a second answer to a
   * question that has one.
   *
   * Three sources and one question, because the row is drawn once. Which one a
   * given id came from is in the detail pane below, where the answer differs.
   */
  const composedEverySession = (entry: ExtensionEntry) =>
    entry.standing ||
    configWith().includes(entry.id) ||
    style.settings.extensions.session_with.includes(entry.id)
  /**
   * The pins this pane's switch writes for a row: one per `surface:"manual"`
   * tool. `auto` tools come with membership, and `internal` tools stay off the
   * model face unless an old pin is being removed.
   */
  const pinnable = (entry: ExtensionEntry) => pinsOf(entry)
  const pinnedCount = (entry: ExtensionEntry) =>
    pinnable(entry).filter((id) => pinState(id, sources()) !== "off").length
  const stateOf = (entry: ExtensionEntry): SwitchState =>
    switchState(isActive(entry), pinnable(entry).length, pinnedCount(entry))
  /** The short cell beside a half-active package: which half. */
  const switchCell = (entry: ExtensionEntry): string => {
    if (stateOf(entry) !== "partial") return ""
    if (!isActive(entry)) return "pins only"
    return `${pinnedCount(entry)}/${pinnable(entry).length} tools`
  }
  const switchColor = (state: SwitchState) =>
    state === "active" ? style.theme.ok : state === "partial" ? style.theme.warn : style.theme.faint

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
    const [id, standing, on, draft, shadow] = squeeze(
      [
        columnWidth(list.map((entry) => entry.id), 2, 24),
        columnWidth(list.map(standingCell), 2, 10),
        columnWidth(list.map(switchCell), 2, 12),
        columnWidth(
          list.map((entry) => (outdated().includes(entry.id) ? "differs" : draftColumn(draftOf(entry.id), entry.current))),
          2,
          11,
        ),
        columnWidth(list.map((entry) => (entry.shadowed ? "shadowed" : "")), 0, 9),
      ],
      [8, 0, 0, 0, 0],
      Math.max(16, Math.floor(inner() / 2)) - 2,
    )
    return { id: id!, standing: standing!, on: on!, draft: draft!, shadow: shadow! }
  })
  /** The whole left pane: the cursor gutter, the switch, and the five columns. */
  const idWidth = () =>
    2 + switch_width + idCols().id + idCols().standing + idCols().on + idCols().draft + idCols().shadow
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
    const current_w = columnWidth([selected()?.current ? `${style.glyphs.check} current` : ""], 2, 12)
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

  /** The pin panel's rows: placement glyph, tool id, state, and evidence. */
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

  /** Walk the visible pane strip, wrapping at both ends. */
  const step = (delta: number) => {
    const current = pane()
    const visible: VisiblePane = current === "versions" ? "extensions" : current
    const at = panes.indexOf(visible)
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
   * An INTERNAL tool has no pin to move — the answer is a sentence, not a state
   * change — unless one is somehow already down, in which case taking it back is
   * exactly what this should do.
   */
  const toggleTool = (row: ToolRow) => {
    if (row.auto && (row.state === "off" || row.state === "composed")) {
      setNotice(`${row.id} comes with sessions that compose ${row.extension} · use /${row.extension} or /with, not a pin`)
      return
    }
    if (row.internal && row.state === "off") {
      setNotice(`${row.id} is called with ext run · a pin would put it on the model face, where it cannot run`)
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
      if (row.auto) {
        setNotice(`${row.id} is an auto-surface tool · it reaches the model when ${row.extension} is composed`)
        return
      }
      if (row.internal) {
        setNotice(`${row.id} is an internal tool · there is nothing to promote · /compact and drivers call it with ext run`)
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
    setNotice("Enter activates or deactivates the whole extension · Space pins one tool, in the tools pane")
  }

  /**
   * The switch: `Enter` on an id, or a click on its marker (tui.md §11, T22).
   *
   * ACTIVE is both axes at once — point `current` at a built version, and pin
   * every `manual` tool it declares so the model can call them. What
   * `current` then MEANS is the package's own word: `manual` makes it
   * nameable (a declared command, `/with`, a pin), `auto` makes the kernel
   * compose it into every fresh session here (DESIGN §5.1). INACTIVE is both
   * back. Nothing here is irreversible and nothing here reaches the session
   * already on screen (physics #2), which is why neither direction asks for a
   * `y`.
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
    if (stateOf(entry) === "active") {
      await deactivateExtension(entry, ids)
      return
    }
    await activateExtension(entry, ids)
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

  const activateExtension = async (entry: ExtensionEntry, ids: string[]) => {
    // The version to point at: what the draft would build to when the plan says
    // it is there, else the newest build in the store. `not built` names a
    // version that does not exist yet, which is what `b` is for.
    const planned = draftOf(entry.id)
    const fromDraft =
      planned && (planned.state === "built" || planned.state === "already built") ? planned.version : null
    const version = entry.current ?? fromDraft ?? entry.versions[entry.versions.length - 1]?.version ?? null
    if (!version) {
      // Only the SOURCE has anything to add here: with no version at all, the
      // pointer word `draftColumn` now falls back to says `inactive`, which is
      // the sentence's own first clause said twice.
      const why = planned ? draftColumn(planned, entry.current) : ""
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
    setNotice(`activating ${entry.id}…`)
    // Optimistic on the SCREEN, and only there: both halves of the switch move
    // now, and neither is written until the kernel has agreed to the half it
    // owns. A pin naming an extension with no `current` is what makes
    // `session new` refuse to start at all, so it must never outlive a failed
    // activate — which is the same reason deactivating writes its pins first.
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
    // And that is the whole of it. Enter wrote a THIRD thing until T52 — an id
    // on this front end's own `standing_with`, so that a package with skills or
    // commands would actually be in a session — because `activate` alone
    // composes nothing (DESIGN §5.1). A package says that for itself now
    // (`apply: "auto"`), the kernel honours it for every driver, and a front
    // end keeping a private membership list beside it would be a second answer
    // to a question that now has one.
    release(entry.id)
    props.onMembershipChanged?.()
    setNotice(
      // Three shapes, and each one names what Enter just made reachable: a
      // package that asked to be everywhere is everywhere now; a mode is worn
      // through its own declared command, or `/with` when it declared none;
      // everything else gets the version and what its tools did.
      //
      // `apply`, not `standing`: this sentence is about the version just
      // pointed at, and the kernel's record for it does not exist until the
      // activation that is finishing right now. `reconcile()` below brings the
      // store's own answer back for the row to draw.
      entry.apply === "auto"
        ? `${entry.id} active · ${version} · composed into every session on this machine · Enter again takes it back`
        : entry.systemPrompts.length > 0
          ? `${entry.id} active · /${wearCommand(entry)?.name ?? `with ${entry.id}`} opens a new tab wearing it for one session · Enter again takes that away`
          : `${entry.id} active · ${version}` +
            (ids.length > 0
              ? room
                ? ` · ${ids.length} tool(s) pinned`
                : ` · ${faceFullLine(maxTools(), face.length, added.length)}`
              : entry.autoTools.length > 0
                ? ` · ${entry.autoTools.length} tool(s) come with sessions that compose it`
                : entry.tools.length > 0
                  ? // A package whose tools are an `ext run` interface: it is
                    // fully active, and none of it is on the model's face by design.
                    ` · its ${entry.tools.length} tool(s) stay off the model face · /compact and drivers call them with ext run`
                  : ""),
    )
    // The store has the last word, but it says it after the screen already moved.
    void reconcile()
  }

  const deactivateExtension = async (entry: ExtensionEntry, ids: string[]) => {
    // Pins first. A pin naming an extension with no `current` is refused by
    // `session new` outright, so the order that leaves a legal world at every
    // point is: take the pins away, then the pointer.
    hold(entry.id)
    const before = { current: entry.current, pins: pinSnapshot() }
    setNotice(`deactivating ${entry.id}…`)
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
      // What actually leaves, per shape. `ext deactivate` is the ONE way back
      // for a standing package (DESIGN §5.1) — with no `current` it is in
      // nothing — so that is the sentence its row gets. Read from the kernel's
      // record: what this takes away is what the package HAD, and a manifest
      // declaring `apply: "auto"` that no activation recorded was taking part
      // in nothing to begin with.
      (entry.standing
        ? `${entry.id} inactive · it leaves every session composed here`
        : entry.systemPrompts.length > 0
          ? `${entry.id} inactive · ${wearCommand(entry) ? `/${wearCommand(entry)!.name} is gone` : `it can no longer be worn`}`
          : `${entry.id} inactive · its skills leave the composition`) +
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
   * `s` — take this binary's own copy of a bundled draft, and make it the one
   * that runs (T42).
   *
   * The one thing `ext seed` will not do by itself: this draft is either
   * somebody's edit or an older nulya's copy, and only a person knows which. So
   * the whole gesture is here, on the row that says `differs`, and it is the
   * three commands a person would otherwise have to find in a status line that
   * has already scrolled away — `seed --force`, `build`, and (only if this id
   * was already the active one) `activate`.
   *
   * Nothing is lost that was ever built: a frozen version keeps its source in
   * `package/`, so the copy this replaces is still on disk under its own hash.
   */
  const updateDraft = async () => {
    const entry = selected()
    if (!entry) return
    if (!outdated().includes(entry.id)) {
      setNotice(`${entry.id} is already this build's copy`)
      return
    }
    if (busy(entry.id)) {
      setNotice(`${entry.id} · still working on the last press`)
      return
    }
    const was_active = entry.current !== null
    hold(entry.id)
    setNotice(`updating ${entry.id} to this build…`)
    try {
      await extSeed(props.ws, { user: true, ids: [entry.id], force: true })
      const version = await extBuild(props.ws, join(entry.root, entry.id))
      if (was_active) await extSetCurrent(props.ws, "activate", entry.id, version, { user: true })
      release(entry.id)
      await refresh()
      setNotice(
        was_active
          ? `${entry.id} ${version} · this build's copy, active`
          : `${entry.id} ${version} built · Enter turns it on`,
      )
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
    // The timeline lives in the extension detail. It names ONE build; turning an
    // extension on is Enter's job and picks a version itself.
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
    // The visible pane strip is a row, so the keys that walk it are the ones
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
    if (key.name === "s") return void updateDraft()
    // Only where there is something to fold: `d` elsewhere in this view is a
    // key that appears to do nothing, which is worse than a key that is unbound.
    if (key.name === "d" && pane() === "tools" && (foldOpen() || folded().length > 0)) return toggleFold()
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
                    An internal or auto-surface tool has no box: there is no
                    pin state this checkbox can honestly change. */}
                <text
                  fg={rowText(
                    style,
                    tone(),
                    row().state === "other"
                      ? style.theme.warn
                      : on()
                      ? style.theme.ok
                      : style.theme.faint,
                  )}
                >
                  {row().internal || row().auto ? " ·  " : on() ? "[x] " : "[ ] "}
                </text>
              </box>
              <box width={toolCols().id} flexShrink={0}>
                <text fg={rowText(style, tone(), on() || here() ? style.theme.fg : style.theme.muted)}>
                  {fit(row().id, toolCols().id - 2)}
                </text>
              </box>
              <box width={toolCols().state} flexShrink={0}>
                <text fg={rowText(style, tone(), row().state === "other" ? style.theme.warn : style.theme.dim)}>
                  {fit(labelOf(row()), toolCols().state - 2)}
                </text>
              </box>
              <box width={toolCols().uses} flexShrink={0}>
                <text fg={rowText(style, tone(), style.theme.dim)}>{fit(usesOf(row()), toolCols().uses - 2)}</text>
              </box>
              <box width={toolCols().ok} flexShrink={0}>
                <text fg={rowText(style, tone(), style.theme.dim)}>{fit(okOf(row()), toolCols().ok)}</text>
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
              text="nothing pinnable or auto-surfaced here · every active extension in this list declares internal tools only"
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
      <Show when={foldOpen() || folded().length > 0}>
        <box height={1} />
        <box
          flexDirection="row"
          width="100%"
          height={1}
          flexShrink={0}
          onMouseOver={() => setFoldHover(true)}
          onMouseOut={() => setFoldHover(false)}
          onMouseDown={foldClick.onMouseDown}
          onMouseUp={foldClick.onMouseUp}
        >
          <box width={4} height={1} flexShrink={0}>
            <text fg={lifted(style, foldHover(), style.theme.faint)}>
              {` ${foldOpen() ? style.glyphs.foldOpen : style.glyphs.foldClosed}  `}
            </text>
          </box>
          <text fg={lifted(style, foldHover(), style.theme.dim)}>{fit(foldLine(folded(), foldOpen()), inner() - 4)}</text>
        </box>
      </Show>
    </box>
  )

  /**
   * The panes as a strip. It is the view's own table of contents: which pane is
   * up, which others exist, and — since each word answers to a click — how to
   * get to them without knowing that `Tab` cycles.
   */
  const PaneStrip = () => (
    <box flexDirection="row" width="100%" height={1} flexShrink={0}>
      <For each={panes}>
        {(name, index) => {
          const here = () => pane() === name || (name === "extensions" && pane() === "versions")
          const click = onClick(() => setPane(name))
          return (
            <>
              <Show when={index() > 0}>
                <text fg={style.theme.faint}>{"  "}</text>
              </Show>
              <box
                flexShrink={0}
                height={1}
                backgroundColor={here() ? style.theme.selection : undefined}
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                {...paneHover.row(index())}
              >
                <text
                  fg={lifted(
                    style,
                    paneHover.at() === index(),
                    here() ? style.theme.accent.evolve : style.theme.dim,
                  )}
                >
                  {name}
                </text>
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

      {/* The extension pane is the id list plus its detail; `versions` is that
          same pane with the timeline focused. The other panes are whole-width
          tables of their own. */}
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
                // `differs` outranks the sync word: an id whose draft is not
                // this binary's is usually `active` there — the quiet, true,
                // useless answer — while the fact worth acting on is that the
                // code running is older than the binary running it (T42).
                const draft = () =>
                  outdated().includes(entry().id) ? "differs" : draftColumn(draftOf(entry().id), entry().current)
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
                    {/* Is this extension active for the next session? Two shapes
                        and three colours, so the answer survives a terminal with
                        no colour at all (tui.md §11, T22). */}
                    <box
                      width={switch_width}
                      height={1}
                      flexShrink={0}
                      onMouseDown={flip.onMouseDown}
                      onMouseUp={flip.onMouseUp}
                    >
                      <text fg={rowText(style, tone(), switchColor(on()))}>
                        {on() === "inactive" ? style.glyphs.switchOff : style.glyphs.switchOn}{" "}
                      </text>
                    </box>
                    <box width={idCols().id} flexShrink={0}>
                      <text
                        fg={rowText(
                          style,
                          tone(),
                          entry().shadowed
                            ? style.theme.dim
                            : on() === "active" || here()
                            ? style.theme.fg
                            : style.theme.muted,
                        )}
                      >
                        {fit(entry().id, idCols().id - 2)}
                      </text>
                    </box>
                    {/* `apply: "auto"`: activating this package composes it into
                        every session on this machine (T52). Warn-coloured while
                        it is active — that is the state somebody has to be able
                        to spot without reading a detail pane. */}
                    <box width={idCols().standing} flexShrink={0}>
                      <text fg={rowText(style, tone(), on() === "inactive" ? style.theme.faint : style.theme.warn)}>
                        {fit(standingCell(entry()), Math.max(0, idCols().standing - 2))}
                      </text>
                    </box>
                    {/* Half active: which half. `3/5 tools` and `pins only` are
                        the two ways the kernel's two axes come apart. */}
                    <box width={idCols().on} flexShrink={0}>
                      <text fg={rowText(style, tone(), style.theme.warn)}>
                        {fit(switchCell(entry()), Math.max(0, idCols().on - 2))}
                      </text>
                    </box>
                    {/* What the SOURCE beside those versions would build to. An
                        id whose draft has moved on shows `not built` here while
                        its old version is still current — the difference `ext
                        sync` is for. */}
                    <box width={idCols().draft} flexShrink={0}>
                      <text fg={rowText(style, tone(), draft() === "active" ? style.theme.dim : style.theme.warn)}>
                        {fit(draft(), idCols().draft - 2)}
                      </text>
                    </box>
                    {/* An id an earlier root already has active: this copy never
                        runs (DESIGN §7.2). Saying so is the whole point — a
                        silently omitted duplicate is how it becomes a mystery. */}
                    <box width={idCols().shadow} flexShrink={0}>
                      <text fg={rowText(style, tone(), style.theme.warn)}>
                        {entry().shadowed ? fit("shadowed", idCols().shadow) : ""}
                      </text>
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
                          : entry.autoTools.length > 0
                            ? ` · tools ${entry.autoTools.length}/${entry.tools.length} with the package`
                            : ` · tools ${entry.tools.length} · called with ext run, never on the model face`
                    } · current ${entry.current ? shortVersion(entry.current) : "(none)"}`}
                    width={detailWidth()}
                    fg={style.theme.fg}
                  />
                  {/* An id with source and no version: what stopped it, in the
                      kernel's own words, and the two ways out. */}
                  <For each={draftHelp(draftOf(entry.id), entry.current)}>
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
                  {/* …and what that prompt count MEANS. For a `manual`
                      package: Enter moves `current`, and the way to wear the
                      prompt for one session is the command the package itself
                      declared — or `/with` when it declared none — and nothing
                      here composes it standing (T1, ext-review-2 §3b). Keyed on
                      the DECLARATION, because this sentence is about what Enter
                      would do; a package declaring `apply: "auto"` has one of
                      the two sentences below instead, whether or not it is
                      standing yet. */}
                  <Show when={entry.systemPrompts.length > 0 && entry.apply !== "auto"}>
                    <Lines
                      text={`a mode · once on, \`/${wearCommand(entry)?.name ?? `with ${entry.id}`}\` wears its prompt for one session · nothing here composes it standing`}
                      width={detailWidth()}
                      fg={style.theme.muted}
                    />
                  </Show>
                  {/* A package every session started here is composed with.
                      Its tools reach the model without ever being pinned here,
                      so the row's `0/4 tools` is true about THIS list and false
                      about what the model can call — and that gap is exactly
                      what made `agent` look switched off on a machine where
                      every session had it. WHICH of the three said so is the
                      part worth printing, because they are undone in three
                      different places (T52). */}
                  {/* The draft in the store is not the source this binary
                      carries, and seeding will not overwrite it on its own
                      (DESIGN §7.2): only a person knows whether that is their
                      edit or a copy an older nulya left behind. Said here,
                      where it stays true, with the key that resolves it. */}
                  <Show when={outdated().includes(entry.id)}>
                    <Lines
                      text={`differs from the source this binary ships · your edit, or a copy an older nulya seeded · \`s\` replaces it with this build's (older source stays inside its frozen versions)`}
                      width={detailWidth()}
                      fg={style.theme.warn}
                    />
                  </Show>
                  {/* Declared `apply: "auto"` and NOT standing: inactive, or a
                      `current` written before the record existed. The column
                      and the sentence below both report the kernel's answer
                      about now, which is "in nothing" — but what Enter would do
                      is the thing worth knowing before it is pressed. */}
                  <Show when={entry.apply === "auto" && !entry.standing}>
                    <Lines
                      text={'`apply: "auto"` in its own manifest · activating it composes it into every session started here'}
                      width={detailWidth()}
                      fg={style.theme.muted}
                    />
                  </Show>
                  <Show when={composedEverySession(entry)}>
                    <Lines
                      text={`composed into every session started here · ${
                        entry.standing
                          ? "`apply: \"auto\"` in its own manifest · the kernel composes it while it has a current · Enter again takes it back"
                          : configWith().includes(entry.id)
                            ? "`[extensions] with` in config — `nulya config show`"
                            : "`[extensions] session_with` in tui.toml · its tools are on the face there, not from this list"
                      }`}
                      width={detailWidth()}
                      fg={style.theme.muted}
                    />
                  </Show>
                  <Show when={drift()}>
                    <Lines text={drift()!} width={detailWidth()} fg={style.theme.warn} />
                  </Show>
                  <box height={1} />

                  <text fg={style.theme.dim} height={1}>
                    {fit(`versions · ${entry.versions.length}${entry.versions.length > 1 ? " · oldest → newest" : ""}`, detailWidth())}
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
                            <text
                              fg={rowText(
                                style,
                                tone(),
                                isCurrent() ? style.theme.accent.evolve : here() ? style.theme.fg : style.theme.muted,
                              )}
                            >
                              {fit(
                                versionCols().full ? version.version : shortVersion(version.version),
                                versionCols().version - 2,
                              )}
                            </text>
                          </box>
                          <box width={versionCols().when} flexShrink={0}>
                            <text fg={rowText(style, tone(), style.theme.dim)}>
                              {fit(stamp(version.mtime), versionCols().when - 2)}
                            </text>
                          </box>
                          <box width={versionCols().current} flexShrink={0}>
                            {/* `✓ current` is the same mark in the same colour as
                                `/model`'s (tui.md §6): one glyph, one colour, one
                                meaning — "this is the one in force". It used to be
                                `⚡`, which is what an extension GAINED, not which
                                build it points at. */}
                            <text fg={rowText(style, tone(), style.theme.ok)}>
                              {isCurrent() ? fit(`${style.glyphs.check} current`, versionCols().current - 2) : ""}
                            </text>
                          </box>
                          <box width={versionCols().mine} flexShrink={0}>
                            <text fg={rowText(style, tone(), style.theme.accent.user)}>
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
      <OverlayFooter
        width={inner()}
        help={help}
        notice={confirm() ? null : notice()}
        brief="Enter active/inactive · j/k move · h/l pane · Esc close"
        more={[
          "Enter activates the extension and pins its tools, again makes both inactive · a click on the row the cursor is already on does the same",
          "h/l ←/→ Tab move across the panes · j/k ↑/↓ move down a list",
          "Space pin one tool · A promote it to always · d fold the internal tools in or out · b build the source · s take this binary's copy of a bundled draft (`differs`) · p prune old versions",
          "a activate one named version, on the version line — an older one is the rollback · t tools · u usage",
        ]}
      />
    </box>
  )
}
