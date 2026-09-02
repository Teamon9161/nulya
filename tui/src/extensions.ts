/**
 * Installing what is already on disk, at start-up.
 *
 * The store layout has always been "a draft lives at `<root>/<id>/`, its frozen
 * versions beside it", and `nulya ext sync` builds every draft in a root. So the
 * front end's whole job here is WHEN to run it, and that splits along the one
 * line the kernel draws between code a person put on this machine themselves
 * and code that arrived with someone else's checkout:
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
import { readContributions, rootsOf, type Contributions, type PackageCommand } from "./nulya/files.ts"
import { builtin_tools, toolId } from "./face.ts"
import { parseWithRef, selectedToolIds } from "./with.ts"
import { userConfigDir } from "./state/settings.ts"
import { rememberSessionSelection, sessionSelection } from "./state/tui_state.ts"
import type { Workspace } from "./nulya/bin.ts"
import type { AgentTrustPlan } from "./agents.ts"

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
 * source this still ends up trusted, because a local build IS the trust,
 * which is why the two are offered separately only where they
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
 * own journal (`<user dir>/trusted-stores.jsonl`). A read, never a
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
 * The second is the one the trust gate is about — a checkout that
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
 * a week: a count says something went wrong, a name says what
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

/**
 * What a draft line says in `/ext`'s draft column: is the build of the source in
 * this store directory the one that runs, and if not, why not.
 *
 * `current` is the id's ACTIVE version, from the store listing — not the plan
 * line's own `activation`, which reports the same thing and goes stale. The
 * listing is what a keypress updates (optimistically, then from the store);
 * plans are re-read only on opening and on `b`/`p`, deliberately, because two
 * `ext sync --dry-run` passes are the most expensive calls this view makes and a
 * pointer move cannot change what a draft would BUILD to. But it does change
 * which version is current — so a row activated with Enter went on saying
 * `inactive` until the panel was closed and opened again. One question, one
 * source.
 *
 * `built` used to be the word for every version that was not the current one,
 * which put TWO states under one word. They are not the same state and they do
 * not have the same repair:
 *
 *  - `inactive` — the id has no `current` at all. The package is off; Enter
 *    turns it on.
 *  - `not current` — the package IS on, at a different version than this source
 *    builds to. Nothing is off; the source has simply moved ahead of the
 *    pointer (or somebody rolled back). `a` on the version line points `current`
 *    at the build under the cursor.
 *
 * Said as one word, the second reads as a contradiction beside the same row's
 * `standing` marker — the package is in every session and the column calls it
 * inactive. And `built`, the word before that, read as a rung on a ladder — a
 * state on the way to being done — when what it meant was "this build exists".
 */
export function draftColumn(line: SyncLine | null | undefined, current: string | null): string {
  // No source in this store directory, and that is an ordinary way for a
  // package to arrive: `ext build <path>` outside a root, or a version copied
  // from another machine, leaves `versions/` and `current` with nothing beside
  // them. The column still has an answer, and it is the one that matters most —
  // the pointer. It used to print nothing at all for these, so `kong` and
  // `dogfood` were the only rows in the list with no state word on them, and a
  // reader comparing them against a seeded package read the blank as "off".
  if (!line) return current === null ? "inactive" : "active"
  if (line.state === "failed") return "fails"
  if (line.state === "needs zig") return "needs zig"
  // Before the pointer questions: whether a build is the current one is not a
  // question about a source that has no build.
  if (line.state === "not built") return "not built"
  if (current === null) return "inactive"
  if (current === line.version) return "active"
  return "not current"
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

/** The keys `promptText`'s question offers — reused, unchanged, by the merged question below. */
const store_choices: ReadonlyArray<[key: string, what: string]> = [
  ["t", "trust + build + activate"],
  ["s", "build only"],
  ["n", "not now"],
]

export function promptText(plan: ProjectStoreAsk): string {
  const lines = [`this checkout ships extensions in ${plan.store}:`, ...plan.drafts.map((line) => `  ${line}`)]
  return `${lines.join("\n")}\n${choicesText("trust & install?", store_choices)}`
}

/**
 * Run one answer. The commands are the CLI's own — nothing here decides what
 * trusting or building means.
 */
export async function applyAnswer(ws: Workspace, answer: StoreAnswer): Promise<SyncReport | null> {
  return applyStoreAction(ws, actionFor(answer))
}

/**
 * Run one store action directly — the same commands `applyAnswer` runs, but
 * from the ACTION rather than a raw `t`/`s`/`n` key. `planCheckout`'s merged
 * question needs this: on the combined question its own `t`/`s` keys do not
 * always mean the same `StoreAnswer` the store's own question would have made
 * of them (its `t` also trusts the agent definitions, which is not a
 * `StoreAnswer` at all).
 */
export async function applyStoreAction(ws: Workspace, action: StoreAction): Promise<SyncReport | null> {
  if (action.trust) await extTrust(ws)
  if (!action.sync) return null
  return extSync(ws, { activate: action.activate })
}

// ── merging the two start-up questions into one ─────────────────────────────

const agents_choices: ReadonlyArray<[key: string, what: string]> = [
  ["t", "trust these definitions"],
  ["n", "not now"],
]

const both_choices: ReadonlyArray<[key: string, what: string]> = [
  ["t", "trust everything: extensions + agent definitions"],
  ["s", "build the extensions only, trust neither"],
  ["n", "not now"],
]

/** What no store action at all looks like — the answer for a key that never touches the store. */
const no_store_action: StoreAction = { trust: false, sync: false, activate: false }

/** What one answer to the merged (or single) start-up question does, in full. */
export interface CheckoutAction {
  store: StoreAction
  agentsTrust: boolean
}

export interface CheckoutAsk {
  kind: "ask"
  text: string
  choices: ReadonlyArray<[key: string, what: string]>
  /** What a raw key means here, or null when it answers nothing (the question stays open). */
  apply: (key: string) => CheckoutAction | null
}

export type CheckoutPlan = { kind: "none" } | CheckoutAsk

/**
 * The one start-up question a checkout actually needs.
 *
 * Two different things can each need a look before a session may compose
 * them — the workspace extension store (`planProjectStore`) and
 * the agent definitions beside it (`planProjectAgents`) — and
 * they share everything but the file they are about: the same "only a
 * keypress moves it" shape, the same "not now is a real answer, asked once"
 * rule, even the same reason (a local build is how the kernel records trust,
 * so the question has to come before the first one). Stacked as
 * two separate prompts on a bare terminal, that resemblance read as
 * repetition instead of the single fact it is.
 *
 * `none` when neither needs asking. When only one does, this hands back
 * EXACTLY today's question for that one, unchanged — the sentence, the keys,
 * what `apply` does with them. Only when BOTH need a look does the shape
 * change: one paragraph naming what each holds, three answers that now speak
 * for both — `t` trusts and installs everything, `s` builds the extensions
 * without trusting either side, `n` leaves both alone.
 *
 * Pure: `apply` says what a key MEANS, not what happens on disk — no
 * filesystem, no process, nothing awaited. The caller (`main.tsx`
 * `askAboutCheckout`) is the one with a terminal: it prints `text`, reads a
 * key until `apply` accepts one, then runs the resulting `CheckoutAction`
 * (`applyStoreAction`) and remembers the answer on whichever side(s) were
 * actually part of this question.
 */
export function planCheckout(store: ProjectStorePlan, agents: AgentTrustPlan): CheckoutPlan {
  const storeAsk = store.kind === "ask" ? store : null
  const agentsAsk = agents.kind === "ask" ? agents : null
  if (!storeAsk && !agentsAsk) return { kind: "none" }

  if (storeAsk && !agentsAsk) {
    return {
      kind: "ask",
      text: promptText(storeAsk),
      choices: store_choices,
      apply: (key) => {
        const answer = answerFor(key)
        return answer ? { store: actionFor(answer), agentsTrust: false } : null
      },
    }
  }

  if (!storeAsk && agentsAsk) {
    return {
      kind: "ask",
      text: agentsPromptText(agentsAsk),
      choices: agents_choices,
      apply: (key) => {
        if (key === "t") return { store: no_store_action, agentsTrust: true }
        if (key === "n" || key === "escape" || key === "return") return { store: no_store_action, agentsTrust: false }
        return null
      },
    }
  }

  // Neither branch above returned, so by elimination both asked — TypeScript
  // cannot see that across two independent `if`s, but the three conditions
  // together are exhaustive over "which of the two is non-null".
  return {
    kind: "ask",
    text: bothPromptText(storeAsk!, agentsAsk!),
    choices: both_choices,
    apply: (key) => {
      if (key === "t") return { store: actionFor("trust"), agentsTrust: true }
      if (key === "s") return { store: actionFor("build"), agentsTrust: false }
      if (key === "n" || key === "escape" || key === "return") return { store: no_store_action, agentsTrust: false }
      return null
    },
  }
}

function agentsPromptText(plan: Extract<AgentTrustPlan, { kind: "ask" }>): string {
  const lines = [`this checkout defines agents in ${plan.dir}:`, ...plan.names.map((line) => `  ${line}`)]
  return `${lines.join("\n")}\n${choicesText(
    "each one is a system prompt a session here would run with. use them?",
    agents_choices,
  )}`
}

function bothPromptText(store: ProjectStoreAsk, agents: Extract<AgentTrustPlan, { kind: "ask" }>): string {
  const lines = [
    `this checkout ships extensions in ${store.store}:`,
    ...store.drafts.map((line) => `  ${line}`),
    `and defines agents in ${agents.dir}:`,
    ...agents.names.map((line) => `  ${line}`),
  ]
  return `${lines.join("\n")}\n${choicesText("trust & use all of it?", both_choices)}`
}

/**
 * What to say once an answer has been carried out, for whichever side(s) it
 * left untouched — the two "left alone" sentences the individual questions
 * always had, unchanged, and only for a side this run actually asked about (a
 * checkout that never showed the agents question does not get told its
 * agents were left alone).
 */
export function checkoutFollowUp(action: CheckoutAction, storeAsked: boolean, agentsAsked: boolean): string[] {
  const lines: string[] = []
  const storeDidNothing = !action.store.trust && !action.store.sync && !action.store.activate
  if (storeAsked && storeDidNothing) lines.push("left alone · `nulya ext trust` whenever you mean to")
  if (agentsAsked && !action.agentsTrust) lines.push("left alone · /agent still lists them, and starts none")
  return lines
}

/** A store root's drafts, without writing anything. */
export function planStore(ws: Workspace, user: boolean): Promise<SyncReport> {
  return extSync(ws, { user, dryRun: true })
}

// ── The bundled extensions ────────────────────────────────────
//
// The binary embeds the six drafts nulya's own repo ships, and `ext seed`
// writes them into a store root — so they are installable in ANY workspace,
// not just a nulya checkout.
//
// Which of them mean what is the package's own words in the frozen manifest:
// `contributes.tools[].surface` for whether a tool is a driver interface, and
// top-level `apply` for whether installing it means active everywhere. That is
// the only place that knows, and it works for a package this repository has
// never heard of.
//
// Nobody is asked about any of it: the user store is the person's own
// directory, what lands in it came with the binary they ran, and syncing it
// happens on the way in, in the background, with the status line saying so —
// and one Enter in `/ext` undoes any of it.

/**
 * The six std tools, as the stable ids a member's selection resolves to.
 *
 * A COLD-START FALLBACK, not the truth. The truth is the manifest of whichever
 * `std` version is active on this machine (`selectableToolsOf`), because that
 * is what the kernel resolves a selection against. This list is read in exactly
 * one place: when no built version can be read at all.
 */
export const std_tools = [
  "ext:std/read",
  "ext:std/write",
  "ext:std/append",
  "ext:std/edit",
  "ext:std/grep",
  "ext:std/glob",
]

/**
 * The tool ids a member entry for this package would have to SELECT: one per
 * `surface:"manual"` tool it declares.
 *
 * Per tool, not per package: the bundled `agent` package has one manual tool
 * and three internal ones, and asking the package means an extension from
 * outside this repository gets the same answer instead of arriving in the tools
 * pane wearing a checkbox that cannot work.
 *
 * An empty list is a perfectly ordinary answer, and it has two shapes.
 * `compact` declares only `internal` tools: `nulya ext run` reaches them
 * without any selection, which is how `/compact` has always called it.
 * `handoff` declares `auto` ones: they reach the model face through membership
 * alone, so naming them would be a no-op.
 */
export function selectableToolsOf(what: Pick<Contributions, "id" | "manualTools">): string[] {
  return what.manualTools.map((tool) => toolId(what.id, tool))
}

/**
 * The one declared way to wear this package for a session — its first
 * `{with: true}` command — or null when it declares none.
 *
 * A slash command exists exactly when the manifest declares it; nothing is
 * derived. `/<id>` used to be handed to every prompt package for free (M4's
 * `derivedCommand`), which meant the front end was inventing names the
 * manifest never claimed and a package could end up with two equivalent
 * commands (`/evolve` and a derived `/evolution`). The manifest is the single
 * source of truth about a package, so the obvious three-line
 * entry is now simply written where it is wanted — `plan` and `evolution`
 * declare theirs — and a prompt package that declares nothing is still one
 * `/with <id>` away.
 */
export function wearCommand(
  what: Pick<Contributions, "commands">,
): PackageCommand | null {
  return what.commands.find((command) => command.action.with === true) ?? null
}

/** What an unattended pass did with one built version. */
export type UnattendedOutcome =
  /** `current` now points at it. */
  | "activated"
  /** The manifest could not be read, so the pointer stands. */
  | "held"
  /** The kernel refused the move. */
  | "failed"

/**
 * THE door every unattended pointer move goes through — the start-up sync, the
 * ids `ext seed` just dropped, and anything later that builds in the background.
 *
 * It carries no policy: activating a package that declares `apply: "auto"` is
 * allowed even unattended, because reaching every session is a decision the
 * manifest itself makes, not one this pass second-guesses. Every route into
 * this function already passes a person: installing this binary, writing
 * source into their own store, or answering the checkout trust question,
 * which offers "build but do not activate" in as many words.
 *
 * What stands in for a gate is VISIBILITY, the `warnUserScope` precedent: the
 * pass says which packages now reach every session, and `/ext`'s `standing`
 * column and Enter take one back.
 *
 * An unreadable manifest is still `held`, and that is not policy: a pass that
 * cannot read what it is about to point at has no business pointing at it.
 */
export async function activateUnattended(
  ws: Workspace,
  what: { id: string; version: string; root: string; user: boolean },
): Promise<{ outcome: UnattendedOutcome; built: Contributions | null }> {
  const built = await builtContributions(ws, what.root, what.id, what.version)
  if (!built) return { outcome: "held", built }
  try {
    await extSetCurrent(ws, "activate", what.id, what.version, { user: what.user })
  } catch {
    // The version is built either way, and `/ext`'s Enter still points at it;
    // a pointer that would not move is not news for the status line.
    return { outcome: "failed", built }
  }
  return { outcome: "activated", built }
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
 * Write the bundled drafts into the user store — source only.
 *
 * The kernel leaves an id that already has a draft there alone, so this is safe
 * on every start and the ids it REPORTS are exactly the ones that arrived this
 * time. That list is the whole consent model: what arrived just now
 * is installed and turned on, what was already there was already somebody's
 * decision — including the decision to turn it off in `/ext`, which no later
 * start may undo.
 */
export function seedBundled(ws: Workspace): Promise<SeedReport> {
  return extSeed(ws, { user: true })
}

/**
 * Finish the install for the ids that ARRIVED in this run: point `current` at
 * what the build pass produced, and select the std tools on this TUI's member list.
 *
 * Which ones get activated goes through the same `activateUnattended` the
 * start-up sync uses, because "these ids arrived with the binary" says where
 * a candidate came from and nothing about whether moving a pointer would
 * change what every session here carries.
 *
 * Returns the parts of the sentence the status line will say.
 */
export async function adoptBundled(
  ws: Workspace,
  arrived: readonly string[],
  report: SyncReport,
  statePath?: string,
  /**
   * The ids that already had a `current` before this pass. Only an id absent
   * from it is an INSTALL, and only an install may have a selection written for it
   * (`adoptInstalled`). Omitted means "not known", which counts every id as
   * already installed: a pass that cannot tell must not write over choices.
   */
  hadCurrent?: ReadonlySet<string>,
): Promise<string[]> {
  const parts: string[] = []
  const active: string[] = []
  const held: string[] = []
  const installed: Contributions[] = []
  const root = syncRoot(ws, true)
  for (const id of arrived) {
    const line = report.lines.find((entry) => entry.id === id)
    if (!line?.version || line.state === "failed" || line.state === "needs zig") continue
    if (line.activation === "active") {
      active.push(id)
      continue
    }
    const { outcome, built } = await activateUnattended(ws, { id, version: line.version, root, user: true })
    if (outcome === "activated") {
      active.push(id)
      if (built && hadCurrent !== undefined && !hadCurrent.has(id)) installed.push(built)
    } else if (outcome === "held") held.push(id)
  }
  if (active.length > 0) parts.push(`${active.join(" & ")} active`)
  // Named, not counted: an id is held because the store could not answer what it
  // was about to point at, and `/ext` is the one screen that says so on the row.
  if (held.length > 0) parts.push(`${held.join(" & ")} built, not activated · /ext`)
  parts.push(...(await adoptInstalled(ws, installed, statePath)))
  return parts
}

/**
 * What a pass says about the packages it just INSTALLED: the tools they put
 * within one keypress of the model.
 *
 * A first `current` is the one time a package's `manual` tools may be selected
 * for somebody (`selectInstalled`); a pass that merely moved a package FORWARD
 * must not touch the list, because by then the list is a person's — a tool they
 * took off with `Space` would come back on the next rebuild, and a switch that
 * undoes itself is not a switch.
 */
export async function adoptInstalled(
  ws: Workspace,
  installed: readonly Contributions[],
  statePath?: string,
): Promise<string[]> {
  const selected = await selectInstalled(ws, installed, statePath)
  return selected.length > 0 ? [`${selected.join(" & ")} tools selected`] : []
}

/**
 * Put the `manual` tools of packages this pass just INSTALLED on this TUI's
 * session member list, and report which packages got any.
 *
 * WHICH tools is the package's own word (`selectableToolsOf` → `surface`), so a
 * package that grew or lost one is followed without editing this file. The
 * quota is checked against the whole prospective face at once: a `session new`
 * that refuses to start is worse than a tool left off, so if the lot will not
 * fit, none of it is written and `/ext` is where the choosing happens.
 */
async function selectInstalled(
  ws: Workspace,
  installed: readonly Contributions[],
  statePath?: string,
): Promise<string[]> {
  const wanted = installed.flatMap((what) => selectableToolsOf(what))
  if (wanted.length === 0) return []
  const current = sessionSelection(statePath)
  let merged_config: string[] = []
  let max_tools = 8
  try {
    const view = await configShow(ws)
    merged_config = selectedToolIds(view.extensions.with)
    max_tools = view.registry.max_tools
  } catch {
    // No projection is "unknown": assume the defaults and let `session new`
    // have the last word.
  }
  const face = new Set([...merged_config, ...current, ...wanted])
  if (builtin_tools + face.size > max_tools) return []
  rememberSessionSelection([...new Set([...current, ...wanted])], statePath)
  return installed.filter((what) => selectableToolsOf(what).length > 0).map((what) => what.id)
}

/**
 * One package this TUI composes a top-level session with (`[extensions]
 * session_with`): the exact version, and the tools its member entry selects.
 *
 * Both halves are needed because membership is not a tool face. A version whose
 * tools are `surface: "auto"` reaches the model through the bare member
 * (`handoff`, `agent`); one that declares `manual` does not, and the selection
 * has to ride on the same entry. Every package on this list happens to be
 * `auto` today, so `tools` is usually empty — it stays because a package that
 * moves a tool to `manual` must be followed without an edit here.
 */
export interface SessionMember {
  id: string
  version: string
  /** The `surface: "manual"` tool ids this exact version declares. */
  tools: string[]
}

/**
 * Resolve one `session_with` id to the version a `session new` should name, and
 * the tools that version's own manifest offers a selection.
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
export async function sessionMember(ws: Workspace, spec: string): Promise<SessionMember> {
  const asked = parseWithRef(spec)
  const id = asked?.id ?? spec
  const version = (await buildBundledDraft(ws, id)) ?? (await activeVersionOf(ws, id))
  if (!version) {
    throw new Error(`${id} · no active version in any store · \`nulya ext build <path> --user\` then \`nulya ext activate --user ${id} <v>\``)
  }
  // A spec that names its own tools is taken at its word; otherwise the tools
  // come off THAT version's frozen manifest, never from a list here — a package
  // that moves a tool between surfaces is followed without an edit.
  const tools = asked?.tools
    ? asked.tools.map((tool) => toolId(id, tool))
    : selectableToolsOf(await readContributions(ws, id, version))
  return { id, version, tools }
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
 * The slash commands of every ACTIVATED, TRUSTED package — the data source
 * `/ext` itself reads (`listExtensions` → `ext list`), so this spawns no
 * process of its own beyond that one call.
 *
 * "Activated" here is deliberately not "a member of the CURRENT session's
 * composition": a `with` command's whole point is to bring a package INTO a
 * session that does not have it yet, and that has to be typable before there
 * is anything to be a member of (a draft tab). So
 * the filter is exactly `ext list`'s own notion of "holding a current version,
 * not shadowed" — the same one `/with`'s picker uses.
 *
 * Trust is the one thing `ext list` does not say: a workspace store that
 * arrived with a checkout and has never been looked at still lists
 * its `current` versions, but naming one of its commands would run headlong
 * into the kernel's own refusal at the first `session new` or `ext run`. So
 * this reads the same trust journal the start-up question does
 * (`storeTrusted`) and drops that root's entries rather than offering a
 * command that cannot work. Every other root (the user's own, or an
 * `extensions.paths` addition) needs no such gate: nothing arrives there
 * without a person putting it there themselves.
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
