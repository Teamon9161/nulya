/**
 * Installing what is already on disk, at start-up (tui.md §11, T11).
 *
 * The store layout has always been "a draft lives at `<root>/<id>/`, its frozen
 * versions beside it", and `nulya ext sync` builds every draft in a root. So the
 * front end's whole job here is WHEN to run it, and that splits along the one
 * line the kernel draws (DESIGN §9, physics #6):
 *
 *  - the USER store is the person's own directory. Nothing arrives in it without
 *    them putting it there, so syncing it needs no permission — it runs in the
 *    background, and the status bar says it is happening.
 *  - the PROJECT store came with a checkout. It is the first root searched, so
 *    what it holds would enter every session composed here — which is exactly
 *    the thing the kernel refuses until someone has looked once. So it is asked
 *    about, before any session exists, and only a keypress moves it.
 *
 * The question is put once per store (remembered in `tui-state.json`); saying
 * "not now" is not a permanent no — `nulya ext trust` is always there.
 */
import { existsSync, readFileSync, realpathSync } from "node:fs"
import { join } from "node:path"
import {
  configShow,
  extList,
  extSeed,
  extSetCurrent,
  extSync,
  extTrust,
  type SeedReport,
  type SyncLine,
  type SyncReport,
} from "./nulya/cli.ts"
import { readContributions } from "./nulya/files.ts"
import { builtin_tools } from "./pins.ts"
import { userConfigDir } from "./state/settings.ts"
import { loadTuiState, rememberSessionPins, saveTuiState, tuiStatePath } from "./state/tui_state.ts"
import type { Workspace } from "./nulya/bin.ts"

/** What the answer to the trust question does. */
export type StoreAnswer = "trust" | "build" | "skip"

export interface StoreAction {
  /** `nulya ext trust` first: the store may take part in sessions from now on. */
  trust: boolean
  /** Build every draft it holds. */
  sync: boolean
  /** Move `current` onto what was built. */
  activate: boolean
}

/**
 * The three keys, and what each one does. `t` is the whole answer — trust,
 * build, use. `s` builds without granting anything: on a store that held only
 * source this still ends up trusted, because a local build IS the trust
 * (DESIGN §9), which is why the two are offered separately only where they
 * differ — a checkout shipping already-built versions. `n` does nothing at all.
 */
export function answerFor(key: string): StoreAnswer | null {
  if (key === "t") return "trust"
  if (key === "s") return "build"
  if (key === "n" || key === "escape" || key === "return") return "skip"
  return null
}

export function actionFor(answer: StoreAnswer): StoreAction {
  if (answer === "trust") return { trust: true, sync: true, activate: true }
  if (answer === "build") return { trust: false, sync: true, activate: false }
  return { trust: false, sync: false, activate: false }
}

/** The absolute path of this workspace's extension store, resolved. */
export function workspaceStorePath(ws: Workspace): string {
  const path = join(ws.dir, ".nulya", "extensions")
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/**
 * Whether this machine has recorded trust for `store`, by reading the kernel's
 * own journal (`<user dir>/trusted-stores.jsonl`, DESIGN §9). A read, never a
 * write: the TUI never records trust — `nulya ext trust` does, after printing
 * what it is about to trust.
 */
export function storeTrusted(store: string, env: Record<string, string | undefined> = process.env): boolean {
  const path = join(userConfigDir(env), "trusted-stores.jsonl")
  if (!existsSync(path)) return false
  try {
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const trimmed = line.trim()
      if (trimmed.length === 0) continue
      const record = JSON.parse(trimmed) as { store?: unknown }
      if (typeof record.store === "string" && samePath(record.store, store)) return true
    }
  } catch {
    // An unreadable journal is not a trust record; the kernel's own gate will
    // have the last word when a session is created.
  }
  return false
}

function samePath(a: string, b: string): boolean {
  const norm = (s: string) => s.replace(/[\\/]+$/, "").replace(/\\/g, "/")
  const left = norm(a)
  const right = norm(b)
  return process.platform === "win32" ? left.toLowerCase() === right.toLowerCase() : left === right
}

/**
 * What a store root has in it, in the two forms that matter: source waiting to
 * be built, and versions already there.
 *
 * The second is the one the trust gate is about (DESIGN §9) — a checkout that
 * ships BUILT extensions is what the kernel refuses to compose until somebody
 * has looked. Both come from the kernel's own commands rather than a directory
 * walk here: `ext sync --dry-run` decides what a draft is, `ext list` decides
 * what "holding" means.
 */
export interface StoreInventory {
  drafts: SyncReport
  holds: string[]
}

const workspace_root_spec = ".nulya/extensions"

export async function inventory(ws: Workspace, user: boolean): Promise<StoreInventory> {
  const [drafts, listed] = await Promise.all([planStore(ws, user), user ? Promise.resolve([]) : extList(ws)])
  const root = user ? "" : workspace_root_spec
  return { drafts, holds: listed.filter((entry) => entry.root === root).map((entry) => entry.id) }
}

/** One line per thing the store holds, for the prompt. */
export function describeDrafts(store: StoreInventory): string[] {
  const lines = store.drafts.lines.map((line) => {
    if (line.state === "failed") return `${line.id} · does not build (${line.detail ?? "?"})`
    if (line.state === "needs zig") return `${line.id} · needs a toolchain`
    if (line.state === "already built") return `${line.id} · ${line.version} built`
    if (line.copiedFrom) return `${line.id} · ${line.version} ready to copy`
    return `${line.id} · ${line.version ?? "?"} not built yet`
  })
  const drafted = new Set(store.drafts.lines.map((line) => line.id))
  for (const id of store.holds) {
    if (!drafted.has(id)) lines.push(`${id} · already built here, no source`)
  }
  return lines
}

/** The one-line summary a finished pass leaves behind. */
export function summarize(where: string, report: SyncReport): string {
  const parts = [`${report.built} built`]
  if (report.already > 0) parts.push(`${report.already} already`)
  if (report.failed > 0) parts.push(`${report.failed} failed`)
  return `${where}: ${parts.join(" · ")}`
}

/**
 * The ids a pass could not build. `3 failed` scrolling past in the status bar
 * is how `std` stayed invisible for a week (tui.md §11, T22): a count says
 * something went wrong, a name says what to go and look at.
 */
export function failedIds(report: SyncReport): string[] {
  return report.lines.filter((line) => line.state === "failed" || line.state === "needs zig").map((line) => line.id)
}

/** What a draft line says in `/ext`'s draft column. */
export function draftColumn(line: SyncLine | null | undefined): string {
  if (!line) return ""
  if (line.state === "failed") return "fails"
  if (line.state === "needs zig") return "needs zig"
  if (line.activation === "active") return "active"
  if (line.state === "not built") return "not built"
  return "built"
}

export interface ProjectStoreDecision {
  /** Nothing to ask and nothing to do. */
  kind: "none"
}

export interface ProjectStoreAsk {
  kind: "ask"
  store: string
  drafts: string[]
}

export interface ProjectStoreReady {
  kind: "ready"
  store: string
}

export type ProjectStorePlan = ProjectStoreDecision | ProjectStoreAsk | ProjectStoreReady

/**
 * What to do about the workspace store, from what it holds and whether this
 * machine trusts it. Pure, so the decision is readable without a filesystem.
 *
 * An empty store is nothing at all — no question, nothing to install. Anything
 * else needs trust before it can take part in a session, so an untrusted one is
 * asked about, once; a trusted one is simply built. Note that BOTH halves of
 * the inventory can trigger the question: source to build, and versions that
 * arrived already built — the second is the case the kernel's gate exists for.
 */
export function planProjectStore(
  store: string,
  what: StoreInventory,
  trusted: boolean,
  alreadyAsked: readonly string[],
): ProjectStorePlan {
  if (what.drafts.lines.length === 0 && what.holds.length === 0) return { kind: "none" }
  if (trusted) return { kind: "ready", store }
  if (alreadyAsked.some((asked) => samePath(asked, store))) return { kind: "none" }
  return { kind: "ask", store, drafts: describeDrafts(what) }
}

/**
 * The question and its three keys, one per line — the same shape as the list
 * of packages above it, so the eye reads one column of items and one column of
 * choices instead of a list and then a sentence. It ends without a newline
 * after the `›`: the answer is typed on that line and echoed there
 * (`main.tsx` `readAnswer`), so the screen never shows a bare cursor on an
 * empty row waiting for nobody knows what.
 */
export function choicesText(question: string, choices: ReadonlyArray<[key: string, what: string]>): string {
  return `${[question, ...choices.map(([key, what]) => `  ${key}  ${what}`)].join("\n")}\n› `
}

export function promptText(plan: ProjectStoreAsk): string {
  const lines = [`this checkout ships extensions in ${plan.store}:`, ...plan.drafts.map((line) => `  ${line}`)]
  return `${lines.join("\n")}\n${choicesText("trust & install?", [
    ["t", "trust + build + activate"],
    ["s", "build only"],
    ["n", "not now"],
  ])}`
}

/**
 * Run one answer. The commands are the CLI's own — nothing here decides what
 * trusting or building means.
 */
export async function applyAnswer(ws: Workspace, answer: StoreAnswer): Promise<SyncReport | null> {
  const action = actionFor(answer)
  if (action.trust) await extTrust(ws)
  if (!action.sync) return null
  return extSync(ws, { activate: action.activate })
}

/** A store root's drafts, without writing anything. */
export function planStore(ws: Workspace, user: boolean): Promise<SyncReport> {
  return extSync(ws, { user, dryRun: true })
}

// ── The bundled extensions (DESIGN §7.8) ────────────────────────────────────
//
// The binary embeds the five drafts nulya's own repo ships, and `ext seed`
// writes them into a store root — so they are installable in ANY workspace,
// not just a nulya checkout. What is policy here is only which of them mean
// "active everywhere" when someone says install: `std` and `guide` are the two
// whose documented install is activate-and-use; `compact` / `evolution` /
// `handoff` are built on demand by /compact, /evolve and the goal driver, and
// deliberately stay out of every composition until one of those brings them in.
//
// Since T23 nobody says install: the user store is the person's own directory,
// what lands in it came with the binary they ran, and the question that used to
// guard it was asked on a bare terminal before the screen existed and then held
// it there for a minute of zig. It happens on the way in, in the background,
// with the status line saying so — and one Enter in `/ext` undoes any of it.

/** The six std tools, as the stable ids `session new --pin` takes. */
export const std_pins = [
  "ext:std/read",
  "ext:std/write",
  "ext:std/append",
  "ext:std/edit",
  "ext:std/grep",
  "ext:std/glob",
]

/** The bundled ids whose install means "active in every next session". */
export const bundled_active = ["std", "guide"]

/**
 * Bundled ids whose declared tools are a DRIVER interface, not a model tool.
 *
 * `compact`'s tool drives the session it is called about — it appends to it and
 * steps it — so a model calling it from inside that very session meets the
 * kernel's single-writer lock and fails every time (`SessionBusy`, DESIGN §3.4).
 * `handoff`'s tool IS meant for a model, but for the one session a driver brings
 * it into with `--with … --pin`, not for every session this TUI opens. Either
 * way, activating these must move membership only: `nulya ext run` reaches their
 * tools without a pin, which is how `/compact` has always called `compact`.
 *
 * A hard-coded list is the temporary criterion. The durable one is a per-tool
 * `audience` in the manifest — the package saying what its own tool is for,
 * which is the only place that knows (kernel side, not yet).
 */
export const bundled_driver_only = ["compact", "evolution", "handoff"]

/** Whether turning this extension on should pin its tools as well. */
export function pinsOnActivate(id: string): boolean {
  return !bundled_driver_only.includes(id)
}

/**
 * Write the bundled drafts into the user store — source only (DESIGN §7.8).
 *
 * The kernel leaves an id that already has a draft there alone, so this is safe
 * on every start and the ids it REPORTS are exactly the ones that arrived this
 * time. That list is the whole consent model since T23: what arrived just now
 * is installed and turned on, what was already there was already somebody's
 * decision — including the decision to turn it off in `/ext`, which no later
 * start may undo.
 */
export function seedBundled(ws: Workspace): Promise<SeedReport> {
  return extSeed(ws, { user: true })
}

/**
 * Finish the install for the ids that ARRIVED in this run: point `current` at
 * what the build pass produced for `std` and `guide`, and put the five std
 * tools on this TUI's pin list.
 *
 * Never the other three. `compact` / `evolution` / `handoff` are brought into
 * one session by `/compact`, `/evolve` and the goal driver; activating them
 * would put `evolution`'s system prompt in front of every model this machine
 * ever runs. Returns the parts of the sentence the status line will say.
 */
export async function adoptBundled(
  ws: Workspace,
  arrived: readonly string[],
  report: SyncReport,
  statePath?: string,
): Promise<string[]> {
  const parts: string[] = []
  const active: string[] = []
  for (const id of bundled_active) {
    if (!arrived.includes(id)) continue
    const line = report.lines.find((entry) => entry.id === id)
    if (!line?.version || line.state === "failed" || line.state === "needs zig") continue
    if (line.activation === "active") {
      active.push(id)
      continue
    }
    try {
      await extSetCurrent(ws, "activate", id, line.version, { user: true })
      active.push(id)
    } catch {
      // The version is built either way, and `/ext`'s Enter still points at it;
      // a pointer that would not move is not news for the status line.
    }
  }
  if (active.length > 0) parts.push(`${active.join(" & ")} active`)
  if (active.includes("std")) {
    parts.push(
      (await pinStdTools(ws, statePath))
        ? "std tools pinned"
        : "std tools not pinned (tool face full — `/ext` to choose)",
    )
  }
  return parts
}

/**
 * Put the six std tools on this TUI's session pin list, unless that would blow
 * the kernel's `max_tools` quota at the next `session new` — a session that
 * refuses to start is worse than an unpinned tool.
 */
async function pinStdTools(ws: Workspace, statePath?: string): Promise<boolean> {
  const current = loadTuiState(statePath).session_pins ?? []
  let merged_config: string[] = []
  let max_tools = 8
  try {
    const view = await configShow(ws)
    merged_config = view.registry.pinned_native_tools
    max_tools = view.registry.max_tools
  } catch {
    // No projection is "unknown": assume the defaults and let `session new`
    // have the last word.
  }
  const face = new Set([...merged_config, ...current, ...std_pins])
  if (builtin_tools + face.size > max_tools) return false
  const mine = new Set([...current, ...std_pins])
  rememberSessionPins([...mine], statePath)
  return true
}

/**
 * What the one-time `edit` pin migration should do, given the pin list on disk
 * and the tools the ACTIVE `std` on this machine declares (`null` = no active
 * std, or one this build could not read).
 *
 * - `done`: nothing to migrate — no std pins here, or `edit` already on the
 *   list. Mark it so this is never looked at again.
 * - `adopt`: the other std tools are pinned and the active std declares
 *   `edit` — add it and mark done.
 * - `wait`: the other std tools are pinned but the std that is active does
 *   not declare `edit` yet (an older build of the draft, a machine that has not
 *   rebuilt). A pin the kernel cannot resolve refuses the next `session new`
 *   outright (`PinToolNotDeclared`), so do nothing and look again next start.
 */
export function stdEditPinDecision(
  pins: readonly string[],
  activeStdTools: readonly string[] | null,
): "done" | "adopt" | "wait" {
  const others = std_pins.filter((pin) => pin !== "ext:std/edit")
  const wants = others.every((pin) => pins.includes(pin)) && !pins.includes("ext:std/edit")
  if (!wants) return "done"
  return activeStdTools?.includes("edit") ? "adopt" : "wait"
}

/**
 * One-time: put `ext:std/edit` on a pin list written before `edit` moved out of
 * the kernel and into `std`. Somebody who already had the other std tools
 * pinned asked for that face; the tool they used to get for free is now part of
 * it, and nothing else would ever add it for them.
 *
 * Once, and only once — the marker outlives the pins, so unpinning `edit`
 * afterwards sticks. Nothing to migrate (no state file, no std pins, `edit`
 * already there) still marks it done. But never before the active `std` can
 * honour the pin (`stdEditPinDecision`): a pin list that names a tool the
 * frozen version lacks stops every session from starting. Returns true when the
 * list changed.
 */
export async function adoptStdEditPin(ws: Workspace, statePath?: string): Promise<boolean> {
  const path = statePath ?? tuiStatePath()
  if (!existsSync(path)) return false
  const state = loadTuiState(path)
  if (state.adopted_std_edit_pin) return false
  const pins = state.session_pins ?? []
  // Only consulted when there is something to migrate: a fresh state file must
  // not cost an `ext list` on every start.
  const needs_std = stdEditPinDecision(pins, null) !== "done"
  let active_tools: string[] | null = null
  if (needs_std) {
    try {
      const entry = (await extList(ws)).find((e) => e.id === "std" && e.current !== null && !e.shadowed)
      if (entry?.current) active_tools = (await readContributions(ws, "std", entry.current)).tools
    } catch {
      // No listing is "unknown": the decision below waits, and tries again.
    }
  }
  switch (stdEditPinDecision(pins, active_tools)) {
    case "done":
      saveTuiState({ ...state, adopted_std_edit_pin: true }, path)
      return false
    case "wait":
      return false
    case "adopt":
      saveTuiState({ ...state, adopted_std_edit_pin: true, session_pins: [...pins, "ext:std/edit"] }, path)
      return true
  }
}

/**
 * Where a bundled draft is on THIS machine: the workspace's own copy when the
 * workspace is nulya's source tree, else the user store's — seeded first if it
 * has to be (a no-op when already there). This is what lets `/compact` and
 * `/evolve` work outside the nulya repository.
 */
export async function bundledDraftPath(ws: Workspace, id: string, repoRel: string): Promise<string> {
  if (existsSync(join(ws.dir, repoRel, "extension.json"))) return repoRel
  await extSeed(ws, { user: true, ids: [id] })
  return join(userConfigDir(), "extensions", id)
}
