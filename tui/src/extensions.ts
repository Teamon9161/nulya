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
  extBuild,
  extList,
  extSeed,
  extSetCurrent,
  extSync,
  extTrust,
  type SeedReport,
  type SyncLine,
  type SyncReport,
} from "./nulya/cli.ts"
import { modelTools, readContributions, rootsOf, type Contributions, type PackageCommand } from "./nulya/files.ts"
import { builtin_tools, toolId } from "./pins.ts"
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

/** Two paths naming the same place, as far as a remembered answer is concerned. */
export function samePath(a: string, b: string): boolean {
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

/**
 * The one-line summary a finished pass leaves behind.
 *
 * `failed` and `needs zig` are counted apart even though the kernel adds them
 * together (`SyncReport.failed`), because they are not the same news: one says
 * a draft is broken, the other says this machine cannot compile one. Told as a
 * single number, the second reads as the first — and a reader whose toolchain
 * was perfectly fine goes off to check their zig install, which is exactly what
 * happened.
 */
export function summarize(where: string, report: SyncReport): string {
  const parts = [`${report.built} built`]
  if (report.already > 0) parts.push(`${report.already} already`)
  // The kernel's total minus the ones it merged in. Never below zero: if a
  // line failed to parse the count leans towards "failed", which is the honest
  // direction — see `parseSyncReport`.
  const broken = Math.max(0, report.failed - report.needsZig)
  if (broken > 0) parts.push(`${broken} failed`)
  if (report.needsZig > 0) parts.push(`${report.needsZig} need zig`)
  return `${where}: ${parts.join(" · ")}`
}

/**
 * The ids a pass could not build, split by what would fix them.
 *
 * `3 failed` scrolling past in the status bar is how `std` stayed invisible for
 * a week (tui.md §11, T22): a count says something went wrong, a name says what
 * to go and look at. The split is the same lesson one level down — the name is
 * only actionable next to the right verb, and "not built" beside a draft that
 * merely wants a toolchain sends a person to read source that compiles fine.
 */
export function failedIds(report: SyncReport): string[] {
  return report.lines.filter((line) => line.state === "failed").map((line) => line.id)
}

/** The ids that would build here the moment this machine had a zig 0.16. */
export function needsZigIds(report: SyncReport): string[] {
  return report.lines.filter((line) => line.state === "needs zig").map((line) => line.id)
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
// The binary embeds the six drafts nulya's own repo ships, and `ext seed`
// writes them into a store root — so they are installable in ANY workspace,
// not just a nulya checkout.
//
// There used to be two hard-coded lists here saying which of them meant what:
// one for "install means active everywhere", one for "these tools are a driver
// interface". Both are gone (T34). The second is now the package's own words —
// `contributes.tools[].audience` in the frozen manifest (DESIGN §7.2.1) — which
// is the only place that knows, and works for a package this repository has
// never heard of. The first turned out to be nothing twice over: activating is
// a pointer move that composes nothing (DESIGN §5.1), and what a session
// carries is said by the person, in `[extensions] with` or in `/ext`'s Enter.
//
// Since T23 nobody is asked about any of it: the user store is the person's own
// directory, what lands in it came with the binary they ran, and the question
// that used to guard it was asked on a bare terminal before the screen existed
// and then held it there for a minute of zig. It happens on the way in, in the
// background, with the status line saying so — and one Enter in `/ext` undoes
// any of it.

/**
 * The six std tools, as the stable ids `session new --pin` takes.
 *
 * A COLD-START FALLBACK and a frozen historical record, not the truth. The
 * truth is the manifest of whichever `std` version is active on this machine
 * (`pinsOf`), because that is what the kernel will resolve the pins against.
 * This list is used in exactly two places: when no built version can be read at
 * all, and by the one-time `edit` migration below, whose whole subject is the
 * pin list people wrote when these six were the six.
 */
export const std_pins = [
  "ext:std/read",
  "ext:std/write",
  "ext:std/append",
  "ext:std/edit",
  "ext:std/grep",
  "ext:std/glob",
]

/**
 * The pins turning a package on should write: one per tool its frozen manifest
 * puts on the MODEL's face (DESIGN §7.2.1).
 *
 * This replaces `pinsOnActivate(id)`, which answered per PACKAGE from a list of
 * names in this file. Per tool is the shape the question actually has — the
 * bundled `agent` package has one model tool and three driver ones — and asking
 * the package means a driver extension from outside this repository gets the
 * same answer instead of arriving in the tools pane wearing a checkbox that
 * cannot work.
 *
 * A package with none (`compact`) yields an empty list, and that is not
 * half-anything: the switch is membership alone, and `nulya ext run` reaches
 * its tool without a pin, which is how `/compact` has always called it.
 */
export function pinsOf(what: Pick<Contributions, "id" | "tools" | "driverTools">): string[] {
  return modelTools(what).map((tool) => toolId(what.id, tool))
}

/**
 * Does turning this package on in `/ext` also mean composing it — a standing
 * entry in `tui-state.json`'s `session_with` (K8)?
 *
 * Yes exactly when the package contributes something a session can only get by
 * being a MEMBER of it: skills, system prompts, slash commands, a front-end
 * module. A pure tool package needs no such entry — its pins bring it in by
 * themselves (DESIGN §5.1) — so writing one would be a second way of saying
 * what the pins already say, and a second thing to take back.
 *
 * The switch used to be an activate alone, and that composed the package
 * because the kernel discovered every id with a `current`. It no longer does:
 * `current` says which version `<id>` means and nothing more, so a front end
 * that only moved the pointer would turn a mode "on" and change nothing a
 * person could see.
 */
/**
 * The `/<id>` a package that contributes a SYSTEM PROMPT gets for free — "wear
 * this for the next session" — or null when it neither is one nor can be named
 * that way (M4).
 *
 * The manifest does not have to declare it. A mode's whole shape already says
 * what typing its name would do: `--with <id>` is the only sensible verb for a
 * package whose contribution is a prompt, and a `commands` entry saying exactly
 * that was ceremony every such package had to copy. What a package still
 * declares is anything OTHER than the obvious — `ask` is a tool package, so
 * `/ask` is a real claim it makes; `plan` is a mode, so `/plan` needs no line
 * in its manifest.
 *
 * Null when the id is not a command name (`web.search` — command names are
 * `[a-z0-9-]+`, ids are wider): a name a person cannot type is not a command.
 * Built-ins are not checked here — `packageCommands.resolve` drops a package
 * row a built-in already holds, and this row goes through it like any other.
 */
export function derivedCommand(
  what: Pick<Contributions, "id" | "systemPrompts" | "commands">,
): PackageCommand | null {
  if (what.systemPrompts.length === 0) return null
  if (!/^[a-z0-9-]+$/.test(what.id)) return null
  // The package's own entry of the same name wins: a declaration is more
  // specific than a derivation, and it may well mean something else by it.
  if (what.commands.some((command) => command.name === what.id)) return null
  return {
    name: what.id,
    description: `a new tab wearing ${what.id}'s prompt; nothing is activated`,
    action: { with: true },
  }
}

export function standingWith(
  what: Pick<Contributions, "skills" | "systemPrompts" | "commands" | "ui">,
): boolean {
  return (
    what.skills.length > 0 ||
    what.systemPrompts.length > 0 ||
    what.commands.length > 0 ||
    what.ui !== null
  )
}

/**
 * The store root `ext sync [--user]` acts on, as a directory on this disk.
 *
 * The kernel's two write verbs take one root each — the workspace's, or the
 * user's — so a caller that just ran one of them knows exactly where the
 * version it built landed, and needs no `ext list` to find it again.
 */
export function syncRoot(ws: Workspace, user: boolean): string {
  return user ? join(userConfigDir(), "extensions") : join(ws.dir, ".nulya", "extensions")
}

/**
 * What one freshly built version in a KNOWN root contributes, or null when the
 * manifest is not there to be read.
 *
 * The root is known because the caller just ran `ext sync`/`ext build` on it
 * (`syncRoot`), so this reads one file rather than searching every root — and
 * `null` stays a first-class answer for every reader of it.
 */
export async function builtContributions(
  ws: Workspace,
  root: string,
  id: string,
  version: string,
): Promise<Contributions | null> {
  if (!existsSync(join(root, id, "versions", version, "extension.json"))) return null
  return await readContributions(ws, id, version, [root])
}

/**
 * What turning a package that contributes a SYSTEM PROMPT on (or off) actually
 * does, said out loud (tui.md §11, T31/T37, K8).
 *
 * `/ext`'s Enter is one keypress, and for this kind of package its consequence
 * reaches every session this front end opens from now on: the id goes on the
 * standing `session_with` list (`standingWith`), so the prompt is in front of
 * every model, before anybody says anything, and paid for on every step. That
 * asymmetry is the whole reason for this sentence — the switch stays one
 * keypress, nothing here asks for a `y`, but it no longer happens silently, and
 * it names the per-session way to the same thing.
 *
 * There used to be a second pair of sentences here, for a package that had
 * declared its prompt opt-in. Reach is not the package's to declare any more
 * (DESIGN §5.1), so there is one switch with one consequence, and this is it.
 */
export function promptConsequence(id: string, on: boolean): string {
  if (!on) return `${id} off · its system prompt no longer enters new sessions`
  return `${id} active · its system prompt now enters EVERY new session from this front end · /with ${id} wears it for one session instead · Enter again to turn it off`
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
 * what the build pass produced, and put the std tools on this TUI's pin list.
 *
 * Which ones get activated used to be a list of two names, then a rule about
 * system prompts. It is now every id that arrived: activating one says which
 * version it means and composes nothing (DESIGN §5.1), so there is no longer a
 * package this pass could switch on to somebody's cost. What a session actually
 * carries is `[extensions] with` and `/ext`'s Enter — a person's lines.
 *
 * Returns the parts of the sentence the status line will say.
 */
export async function adoptBundled(
  ws: Workspace,
  arrived: readonly string[],
  report: SyncReport,
  statePath?: string,
): Promise<string[]> {
  const parts: string[] = []
  const active: string[] = []
  const root = syncRoot(ws, true)
  let std: Contributions | null = null
  for (const id of arrived) {
    const line = report.lines.find((entry) => entry.id === id)
    if (!line?.version || line.state === "failed" || line.state === "needs zig") continue
    if (id === "std") std = await builtContributions(ws, root, id, line.version)
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
      (await pinStdTools(ws, std, statePath))
        ? "std tools pinned"
        : "std tools not pinned (tool face full — `/ext` to choose)",
    )
  }
  return parts
}

/**
 * Put the std tools on this TUI's session pin list, unless that would blow the
 * kernel's `max_tools` quota at the next `session new` — a session that refuses
 * to start is worse than an unpinned tool.
 *
 * WHICH tools comes from the version that was just built (`pinsOf`), so a `std`
 * that grew or lost one is followed without editing this file; the frozen list
 * is only the answer for a build whose manifest could not be read at all.
 */
async function pinStdTools(
  ws: Workspace,
  std: Contributions | null,
  statePath?: string,
): Promise<boolean> {
  const wanted = std ? pinsOf(std) : std_pins
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
  const face = new Set([...merged_config, ...current, ...wanted])
  if (builtin_tools + face.size > max_tools) return false
  const mine = new Set([...current, ...wanted])
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
 * One package this TUI composes a top-level session with (`[extensions]
 * session_with`): the exact version, and the pins its tools ask for.
 */
export interface SessionMember {
  id: string
  version: string
  /** One per tool this version puts on the model's face (`pinsOf`). */
  pins: string[]
}

/**
 * Resolve one `session_with` id to the version a `session new` should name, and
 * the pins that version's own manifest asks for.
 *
 * Two ways in, in this order:
 *
 *  - a draft this BINARY ships (`handoff`, `agent`, …) is built, every time.
 *    A version id is the hash of the draft, so an unchanged package rebuilds to
 *    the version already in the store — and an edited one is picked up without
 *    anybody remembering to rebuild. This is what `/evolve` and the handoff
 *    build have always done; it is not per-package knowledge, it is what the
 *    kernel's content addressing makes free.
 *  - anything else is taken at the store's `current`, which is what somebody
 *    activated. A package with no active version cannot be composed, and saying
 *    so is better than composing a session that is quietly missing it.
 *
 * Throws with a sentence for the notice; the caller starts the session anyway.
 */
export async function sessionMember(ws: Workspace, id: string): Promise<SessionMember> {
  const version = (await buildBundledDraft(ws, id)) ?? (await activeVersionOf(ws, id))
  if (!version) {
    throw new Error(`${id} · no active version in any store · \`nulya ext build <path> --user\` then \`nulya ext activate --user ${id} <v>\``)
  }
  return { id, version, pins: pinsOf(await readContributions(ws, id, version)) }
}

/** Build the draft this binary ships for `id`, or null when it ships none. */
async function buildBundledDraft(ws: Workspace, id: string): Promise<string | null> {
  let draft: string
  try {
    draft = await bundledDraftPath(ws, id, join("extensions", id))
  } catch {
    // `ext seed <id>` refuses an id the binary does not ship: not an error
    // here, just the answer that this one lives in a store like any other.
    return null
  }
  return await extBuild(ws, draft)
}

/**
 * The version `current` names for `id`, in the first root that has one.
 *
 * Exported for a package command's `run <tool>` action (tui-plugin D8): the
 * version has to be read again at DISPATCH time, not carried from whenever the
 * command table was harvested — the same read `/ext` itself would make.
 */
export async function activeVersionOf(ws: Workspace, id: string): Promise<string | null> {
  try {
    const entry = (await extList(ws)).find((e) => e.id === id && e.current !== null && !e.shadowed)
    return entry?.current ?? null
  } catch {
    return null
  }
}

/**
 * The slash commands of every ACTIVATED, TRUSTED package (DESIGN §7.2.1,
 * tui-plugin D1/D2/D8) — the data source `/ext` itself reads (`listExtensions`
 * → `ext list`), so this spawns no process of its own beyond that one call.
 *
 * "Activated" here is deliberately not "a member of the CURRENT session's
 * composition": a `with` command's whole point is to bring a package INTO a
 * session that does not have it yet, and that has to be typable before there
 * is anything to be a member of (a draft tab, tui.md §11 T22). So
 * the filter is exactly `ext list`'s own notion of "holding a current version,
 * not shadowed" — the same one `/with`'s picker uses.
 *
 * Trust is the one thing `ext list` does not say: a workspace store that
 * arrived with a checkout and has never been looked at (DESIGN §9) still lists
 * its `current` versions, but naming one of its commands would run headlong
 * into the kernel's own refusal at the first `session new` or `ext run`. So
 * this reads the same trust journal the start-up question does
 * (`storeTrusted`) and drops that root's entries rather than offering a
 * command that cannot work. Every other root (the user's own, or an
 * `extensions.paths` addition) needs no such gate (DESIGN §9, physics #6).
 *
 * Each package also gets whatever `derivedCommand` says its shape already
 * implies — `/<id>` for a mode — after its own declarations, so a package that
 * declared the same name keeps it.
 *
 * Returned in `ext list`'s own order — root by root, in kernel search order —
 * which is what lets a caller resolve a same-name collision between two
 * DIFFERENT packages by "first one in this list wins" (D8) without this
 * function itself having an opinion about names.
 */
export async function packageCommands(
  ws: Workspace,
  env: Record<string, string | undefined> = process.env,
): Promise<Array<{ id: string; command: PackageCommand }>> {
  let listed: Awaited<ReturnType<typeof extList>> = []
  try {
    listed = await extList(ws)
  } catch {
    // No binary, no store: an empty command table, never a crash.
    return []
  }
  const trusted = storeTrusted(workspaceStorePath(ws), env)
  const roots = rootsOf(ws, listed)
  const out: Array<{ id: string; command: PackageCommand }> = []
  for (const entry of listed) {
    if (entry.current === null || entry.shadowed) continue
    if (entry.root === workspace_root_spec && !trusted) continue
    const contributions = await readContributions(ws, entry.id, entry.current, roots)
    for (const command of contributions.commands) out.push({ id: entry.id, command })
    // A mode's own name, which it never had to declare (`derivedCommand`).
    // Last, so the package's own entries keep their scan-order positions.
    const derived = derivedCommand(contributions)
    if (derived) out.push({ id: entry.id, command: derived })
  }
  return out
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
