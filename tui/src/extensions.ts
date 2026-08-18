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
import { extList, extSync, extTrust, type SyncLine, type SyncReport } from "./nulya/cli.ts"
import { userConfigDir } from "./state/settings.ts"
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

export function promptText(plan: ProjectStoreAsk): string {
  const lines = [
    `this checkout ships extensions in ${plan.store}:`,
    ...plan.drafts.map((line) => `  ${line}`),
    "trust & install? (t) trust + build + activate   (s) build only   (n) not now",
  ]
  return `${lines.join("\n")}\n`
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
