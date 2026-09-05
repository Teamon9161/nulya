/**
 * The `.nulya/` directory layout, READ-ONLY. The
 * TUI never writes into `.nulya/` except through the CLI (`session append`
 * stages its text in `.nulya/scratch/`, see `cli.ts`) — the session file has
 * exactly one writer and it is `session step`.
 *
 * Un-creating a session this process made and never used used to be the one
 * exception, and it is now `sessionPrune` in `cli.ts`: the two facts that
 * forbid it are locks, and a lock can only be answered by taking it.
 */
import { closeSync, existsSync, openSync, readFileSync, readSync, readdirSync, statSync } from "node:fs"
import { isAbsolute, join } from "node:path"
import { parseHeaderLine, type SessionHeader } from "./ledger.ts"
import { extList, type PointerLayer } from "./cli.ts"
import { userConfigDir } from "../state/settings.ts"
import type { Workspace } from "./bin.ts"

export const sessions_dir = ".nulya/sessions"

export function sessionPath(ws: Workspace, id: string): string {
  return join(ws.dir, sessions_dir, `${id}.jsonl`)
}

export function sessionExists(ws: Workspace, id: string): boolean {
  return existsSync(sessionPath(ws, id))
}

/**
 * The frozen header of a session: model identity, composition, parent. Read
 * from the file's first line rather than through the CLI — `session events`
 * deliberately skips the header, and the file IS the wire format.
 */
export async function readHeader(ws: Workspace, id: string): Promise<SessionHeader | null> {
  const path = sessionPath(ws, id)
  if (!existsSync(path)) return null
  const file = Bun.file(path)
  const head = await file.slice(0, 64 * 1024).text()
  const first = head.split("\n", 1)[0]
  return first ? parseHeaderLine(first) : null
}

export const extensions_dir = ".nulya/extensions"

/**
 * The one place built version bytes live on this machine:
 * `<NULYA_HOME | ~/.nulya>/store`. A workspace holds drafts and a `current`
 * pointer of its own, never versions — so reading a frozen manifest or a
 * package directory is always this directory.
 */
export function storePath(env: Record<string, string | undefined> = process.env): string {
  return join(userConfigDir(env), "store")
}

/**
 * Where drafts live: the workspace's `.nulya/extensions`, and the store's own
 * directory (what `ext init --user` / `ext seed --user` write into).
 */
export function draftDirs(ws: Workspace, env: Record<string, string | undefined> = process.env): string[] {
  return [join(ws.dir, extensions_dir), storePath(env)]
}

/**
 * What one frozen extension version contributes. Only the parts
 * the transcript shows; the manifest is the schema's single truth, so nothing
 * here ever runs a binary to ask what it has.
 */
export interface Contributions {
  id: string
  version: string
  tools: string[]
  /** The subset of `tools` whose surface is `manual`: model-facing only when a member selects it. */
  manualTools: string[]
  /**
   * The subset of `manualTools` an INSTALL should switch on — the package's own
   * `recommended` word (absent reads as yes). What a manual tool that opted out
   * says is "an extra, off until somebody names it", so a pass that writes a
   * selection reads this list and a pane that offers checkboxes reads
   * `manualTools`.
   */
  recommendedTools: string[]
  /** The subset of `tools` whose surface is `auto`: model-facing as soon as its package is a member. */
  autoTools: string[]
  /** The subset of `tools` whose surface is `internal`: callable with `ext run`, never on the model face. */
  internalTools: string[]
  skills: string[]
  /**
   * Files whose text becomes a system block for any session carrying this
   * version. A `--with` package is usually nothing BUT these —
   * a mode, an identity — so a view that only counted tools and skills would
   * show the most deliberate part of a composition as empty.
   */
  systemPrompts: string[]
  /**
   * This package's slash commands (`manifest.Command`).
   * Absent reads as empty, the same convention as
   * `skills` / `system_prompts`. `action` is kept as WRITTEN — an open verb
   * vocabulary the kernel does not police beyond one reference check (a `run`
   * command must name a tool this same manifest declares) — so a verb this
   * build does not recognise is this reader's decision
   * (`packageCommands.ts`), not a parse failure.
   */
  commands: PackageCommand[]
  /**
   * This package's approval-policy narrowing (`manifest.Policy`, DESIGN
   * §7.2.1, tui-plugin D2/D3), or null when the package states no policy at
   * all. An explicit `{}` parses to a policy with nothing in it; for the
   * kernel that is not a contribution (it narrows nothing), and nothing here
   * treats it differently from null either.
   */
  policy: PackagePolicy | null
  /**
   * `ToolSpec.ui.render`, by tool name — a rendering hint from an OPEN
   * vocabulary (`"checklist"`, `"markdown"`, more later).
   * A tool absent from this map made no claim; `render/
   * registry.ts` is the one place that reads it and decides whether it
   * recognises the word.
   */
  toolRender: Record<string, string>
  /**
   * The subset of `tools` whose manifest says `ui.panel: true` (DESIGN
   * §7.2.1, tui-plugin D12) — the package's request that the latest call
   * also be projected as a persistent widget above the composer.
   */
  panelTools: string[]
  /**
   * `contributes.ui.tui`: a package-relative
   * path to THIS front end's module and the plugin-host API major version it
   * was written against, or null when the package ships no code layer for it.
   *
   * The manifest keys `ui` by host, because the kernel's schema must not name
   * one front end. This is the one key that concerns this one — a package with
   * modules for other hosts and none for `tui` reads as null, which is an
   * ordinary answer, not a warning.
   *
   * The kernel freezes each entry's bytes with the version and never loads any
   * of them (`manifest.UiHost`); who loads one, and whether this build's API
   * version matches, is a front end's decision — `src/plugins/host.ts`.
   */
  ui: PackageUi | null
}

/** One front end's module declaration (`manifest.UiHost`), for this host. */
export interface PackageUi {
  /** Package-relative, checked safe by the kernel at build time. */
  entry: string
  /** The plugin-host API major version. The kernel refuses 0. */
  api: number
}

/** The host key this front end reads out of `contributes.ui`. */
export const ui_host = "tui"

/** A package's own slash command (`manifest.Command`). */
export interface PackageCommand {
  name: string
  description: string
  /**
   * The verb, kept exactly as the manifest wrote it: an object with exactly one
   * key (`{"with": true}` / `{"run": "<tool>"}` / `{"skill": "<ref>"}`).
   * `packageCommands.parseAction` is the one reader, and an unrecognised verb is
   * its decision — the vocabulary is open, so this side never filters.
   */
  action: PackageActionValue
}

/** An action object, unread (`PackageCommand.action`). */
export type PackageActionValue = Record<string, unknown>

/**
 * A package's approval-policy narrowing (`manifest.Policy`). One field, and it
 * can only narrow: a shape that is a single optional bool cannot widen
 * anything, which is why the kernel needs no rule saying so (physics #6).
 */
export interface PackagePolicy {
  /** Absent is null, not `false` — the package said nothing (same discipline as `tools[].readonly`). */
  readonly: boolean | null
}

/**
 * Read `<id>/versions/<version>/extension.json` from the store. The version is
 * the one the session FROZE (header `composition.active`), not whatever
 * `current` points at now — a mid-session `activate` moves `current` and must
 * not change what this session says it is running.
 */
export async function readContributions(
  _ws: Workspace,
  id: string,
  version: string,
  store?: string,
): Promise<Contributions> {
  const empty: Contributions = {
    id,
    version,
    tools: [],
    manualTools: [],
    recommendedTools: [],
    autoTools: [],
    internalTools: [],
    skills: [],
    systemPrompts: [],
    commands: [],
    policy: null,
    toolRender: {},
    panelTools: [],
    ui: null,
  }
  const path = join(store ?? storePath(), id, "versions", version, "extension.json")
  if (!existsSync(path)) return empty
  try {
    const value = JSON.parse(await Bun.file(path).text()) as Record<string, unknown>
    return { id, version, ...contributionsOf(value) }
  } catch {
    // A store this build cannot parse is not a reason to refuse to draw the
    // session; the header alone already names the frozen versions.
    return empty
  }
}

/**
 * Where a frozen version's PACKAGE files are on this disk — the directory the
 * kernel copies the sealed snapshot into (`integrity.package_dir`), which is
 * what a `contributes.ui.entry` / `system_prompts` path is relative to. Null
 * when the store does not hold that version.
 */
export function packageDirOf(
  store: string,
  id: string,
  version: string,
): string | null {
  const dir = join(store, id, "versions", version, "package")
  return existsSync(dir) ? dir : null
}

function contributionsOf(
  manifest: Record<string, unknown> | null,
): Pick<
  Contributions,
  | "tools"
  | "manualTools"
  | "recommendedTools"
  | "autoTools"
  | "internalTools"
  | "systemPrompts"
  | "skills"
  | "commands"
  | "policy"
  | "toolRender"
  | "panelTools"
  | "ui"
> {
  const contributes = (manifest?.["contributes"] ?? {}) as Record<string, unknown>
  const declared = Array.isArray(contributes["tools"]) ? (contributes["tools"] as Array<Record<string, unknown>>) : []
  const named = declared.filter((tool) => typeof tool?.["name"] === "string")
  const toolRender: Record<string, string> = {}
  for (const tool of named) {
    // Kept as WRITTEN (D12): an unrecognised word is the reader's decision
    // (`render/registry.ts`), never something this projection filters out.
    const render = toolUiOf(tool)["render"]
    if (typeof render === "string") toolRender[tool["name"] as string] = render
  }
  const tools = named.map((tool) => tool["name"] as string)
  const surfaces = new Map(named.map((tool) => [tool["name"] as string, toolSurfaceOf(tool)]))
  const recommended = new Map(named.map((tool) => [tool["name"] as string, tool["recommended"] !== false]))
  return {
    tools,
    manualTools: tools.filter((tool) => surfaces.get(tool) === "manual"),
    recommendedTools: tools.filter((tool) => surfaces.get(tool) === "manual" && recommended.get(tool) === true),
    autoTools: tools.filter((tool) => surfaces.get(tool) === "auto"),
    internalTools: tools.filter((tool) => surfaces.get(tool) === "internal"),
    skills: stringList(contributes["skills"]),
    systemPrompts: promptPathList(contributes["system_prompts"]),
    commands: commandsOf(contributes["commands"]),
    policy: policyOf(contributes["policy"]),
    toolRender,
    panelTools: named.filter((tool) => toolUiOf(tool)["panel"] === true).map((tool) => tool["name"] as string),
    ui: uiOf(contributes["ui"]),
  }
}

/**
 * Where a tool sits, given that its package is already a member of the session
 * (`manifest.Surface`). All three words answer that one
 * question, which is why none of them names a CLI flag any more:
 *
 *   - `auto`     — on the model's face as soon as the package is composed in.
 *   - `manual`   — on it only when the member selects the tool by name
 *                  (`[extensions] with`, `session new --with <id>:<tool>`).
 *   - `internal` — never on it; `nulya ext run` is how it is called.
 *
 * `auto` is also the DEFAULT, and matching the kernel there is the whole point
 * of this function: a package somebody deliberately composed means its tools to
 * be usable, and the front end that read a missing field as "selectable" would
 * draw an empty checkbox beside a tool the model can already call.
 */
export type ToolSurface = "auto" | "manual" | "internal"

function toolSurfaceOf(tool: Record<string, unknown>): ToolSurface {
  const surface = tool["surface"]
  if (surface === "manual" || surface === "internal") return surface
  return "auto"
}

/** A tool's `ui` object (`ToolSpec.ui`), or `{}` when absent or malformed. */
function toolUiOf(tool: Record<string, unknown>): Record<string, unknown> {
  const value = tool["ui"]
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {}
}

/**
 * This host's entry in `contributes.ui`, or null.
 *
 * The manifest keys the block by front end (`{"tui": {entry, api}}`), so a
 * package with no key for this one has no module here — read as "no code
 * layer", never as a warning. Both fields are required by the kernel's own
 * parse, so half a declaration reads the same way.
 */
function uiOf(value: unknown): PackageUi | null {
  if (typeof value !== "object" || value === null) return null
  const mine = (value as Record<string, unknown>)[ui_host]
  if (typeof mine !== "object" || mine === null) return null
  const host = mine as Record<string, unknown>
  const entry = host["entry"]
  const api = host["api"]
  if (typeof entry !== "string" || entry.length === 0) return null
  if (typeof api !== "number" || !Number.isFinite(api)) return null
  return { entry, api }
}

function commandsOf(value: unknown): PackageCommand[] {
  if (!Array.isArray(value)) return []
  const out: PackageCommand[] = []
  for (const entry of value) {
    if (typeof entry !== "object" || entry === null) continue
    const record = entry as Record<string, unknown>
    const action = record["action"]
    const written =
      typeof action === "object" && action !== null && !Array.isArray(action) ? (action as PackageActionValue) : null
    if (typeof record["name"] !== "string" || written === null) continue
    out.push({
      name: record["name"],
      description: typeof record["description"] === "string" ? record["description"] : "",
      action: written,
    })
  }
  return out
}

function policyOf(value: unknown): PackagePolicy | null {
  // Null and "present but empty" are different facts: the
  // package writing `contributes.policy` at all is what counts, even `{}`.
  if (typeof value !== "object" || value === null) return null
  const record = value as Record<string, unknown>
  return { readonly: typeof record["readonly"] === "boolean" ? record["readonly"] : null }
}

/**
 * The model-facing tools of a package: the ones that arrive with membership and
 * the ones a member has to name, together. For readers that only need "not
 * internal"; `manualTools` is the answer for anything that WRITES a selection.
 */
export function modelTools(what: Pick<Contributions, "tools" | "internalTools">): string[] {
  return what.tools.filter((tool) => !what.internalTools.includes(tool))
}

/**
 * A tool's `render` claim (`ToolSpec.ui.render`),
 * read from whichever member of the frozen composition declares
 * `tool`. Null when nothing declares it, or when the declaring package said
 * nothing — "absent" and "not a member" are the same answer to a reader that
 * only wants to know whether to draw a hinted card.
 */
export function renderHintOf(contributions: readonly Pick<Contributions, "tools" | "toolRender">[], tool: string): string | null {
  for (const c of contributions) {
    if (c.tools.includes(tool)) return c.toolRender[tool] ?? null
  }
  return null
}

/**
 * The tools with `panel: true`, across the frozen composition, in package
 * order and de-duplicated by name — the row order a panel strip stacks in
 * (tui-plugin U2 §5, open question 3: v1 stacks by package order).
 */
export function panelToolsOf(contributions: readonly Pick<Contributions, "panelTools">[]): string[] {
  const out: string[] = []
  for (const c of contributions) for (const tool of c.panelTools) if (!out.includes(tool)) out.push(tool)
  return out
}

export async function readActiveContributions(
  ws: Workspace,
  active: readonly { id: string; version: string }[],
): Promise<Contributions[]> {
  if (active.length === 0) return []
  const store = storePath()
  return Promise.all(active.map((entry) => readContributions(ws, entry.id, entry.version, store)))
}

// --- the writer lease -------------------------------------------------------

/**
 * Whether some other process holds the session's writer lease.
 *
 * `unknown` is a first-class answer. The kernel takes an exclusive advisory lock
 * on the sibling `<id>.lock`; on Windows that is a byte-range lock,
 * so a read of byte 0 from any other handle fails while it is held — a probe
 * that touches nothing. On POSIX the same lease is `flock(2)` (Zig's std takes
 * it wherever `O_EXLOCK` is not an open flag), which reads cannot see — but on
 * Linux the kernel publishes every flock in `/proc/locks`, so matching the lock
 * file's device and inode against that table is an equally read-only probe.
 * Trying to *acquire* the lock instead would be a probe that touches: for the
 * moment it holds the lease, a real writer's non-blocking `flock` turns into a
 * spurious `SessionBusy`. Where neither works (macOS has no `/proc`), this
 * returns `unknown` rather than lying: the authoritative answer there is the
 * kernel's own `SessionBusy`, which a `session step` reports the moment we try
 * to drive (see `state/attach.ts`).
 */
export type LeaseState = "free" | "held" | "unknown"

export function lockPath(ws: Workspace, id: string): string {
  return join(ws.dir, sessions_dir, `${id}.lock`)
}

export function probeWriterLease(ws: Workspace, id: string): LeaseState {
  const path = lockPath(ws, id)
  // No lock file at all: nobody has ever opened this session for writing.
  if (!existsSync(path)) return "free"
  if (process.platform === "win32") return probeByteRangeRead(path)
  return probeProcLocks(path)
}

/** Windows: the lease is a mandatory byte-range lock, so a read of byte 0 is denied while it is held. */
function probeByteRangeRead(path: string): LeaseState {
  let fd: number
  try {
    fd = openSync(path, "r")
  } catch {
    // Opening is denied only if something holds it far more tightly than the
    // kernel does; treat that as "someone is in there".
    return "held"
  }
  try {
    readSync(fd, Buffer.alloc(1), 0, 1, 0)
    return "free"
  } catch {
    return "held"
  } finally {
    closeSync(fd)
  }
}

/**
 * POSIX: look the lock file up in `/proc/locks` by device and inode. Any lock
 * on that inode counts as held — the kernel only ever takes `flock`, but if a
 * future std switched lock flavors, "held" is the direction that keeps a live
 * session's file safe from `sessionPrune`.
 */
function probeProcLocks(path: string): LeaseState {
  let dev: bigint
  let ino: bigint
  try {
    const stat = statSync(path, { bigint: true })
    dev = stat.dev
    ino = stat.ino
  } catch {
    // Present a moment ago (existsSync) and gone now: somebody is mid-cleanup;
    // with the lock file gone there is nothing left to hold.
    return "free"
  }
  let table: string
  try {
    table = readFileSync("/proc/locks", "utf8")
  } catch {
    // No /proc (macOS, BSDs): flock stays invisible here, and the honest
    // answer is "don't know", never "free".
    return "unknown"
  }
  // Split st_dev the way glibc's gnu_dev_major/minor do; /proc/locks prints
  // `... <pid> <maj>:<min>:<ino> <start> <end>` with maj/min in hex.
  const major = ((dev >> 8n) & 0xfffn) | ((dev >> 32n) & 0xfffff000n)
  const minor = (dev & 0xffn) | ((dev >> 12n) & 0xffffff00n)
  for (const line of table.split("\n")) {
    for (const field of line.split(/\s+/)) {
      const match = /^([0-9a-f]+):([0-9a-f]+):([0-9]+)$/.exec(field)
      if (!match) continue
      if (BigInt(parseInt(match[1]!, 16)) === major && BigInt(parseInt(match[2]!, 16)) === minor && BigInt(match[3]!) === ino) {
        return "held"
      }
    }
  }
  return "free"
}

// --- the inbox --------------------------------------------------------------

function siblingPath(ws: Workspace, id: string, suffix: string): string {
  return join(ws.dir, sessions_dir, `${id}${suffix}`)
}

/**
 * Is there anything in this session's inbox waiting for a step boundary?
 *
 * The one question the wake-up policy asks. A deposit is one file per event,
 * written `.tmp` then renamed, so a `.json` in there is a whole event nobody has drained — a finished
 * background task, a turn appended from another terminal, a capability note.
 * WHAT is in there is deliberately not read: the kernel drains it, and stepping
 * because the inbox is non-empty is true of every depositor there will ever be.
 *
 * Cheap and read-only, like `probeWriterLease`: one directory listing, no
 * process, nothing written.
 */
export function inboxPending(ws: Workspace, id: string): boolean {
  const inbox = siblingPath(ws, id, ".inbox")
  try {
    return readdirSync(inbox).some((name) => name.endsWith(".json"))
  } catch {
    // No inbox directory means nothing was ever deposited.
    return false
  }
}

// --- background task logs ---------------------------------------------------

/** How much of a task log `/tasks` reads: the end of it, and no more. */
export const task_log_tail_bytes = 64 * 1024

/**
 * The tail of a background task's `output.log`.
 *
 * Not a live tail — it is re-read on the panel's own poll, which is honest about
 * what it is and costs nothing between reads. The path comes from `task list
 * --json`, so this never composes a scratch path of its own.
 */
export async function readTaskLog(ws: Workspace, path: string, bytes = task_log_tail_bytes): Promise<string> {
  const full = isAbsolute(path) ? path : join(ws.dir, path)
  try {
    const file = Bun.file(full)
    const size = file.size
    return await (size > bytes ? file.slice(size - bytes) : file).text()
  } catch {
    // Not written yet, or removed under us: an empty log reads the same way.
    return ""
  }
}

// --- the extension store ----------------------------------------------------

/** What goes into a version id, and therefore what a build needs. */
export type ImplementationKind = "compiled" | "script" | "data"

export interface ExtensionVersion {
  version: string
  mtime: number
}

export interface ExtensionEntry {
  id: string
  /** `current` pointer: the version the NEXT session would freeze. */
  current: string | null
  versions: ExtensionVersion[]
  kind: ImplementationKind
  tools: string[]
  /** The declared `manual`-surface subset of `tools`. */
  manualTools: string[]
  /** The declared `auto`-surface subset of `tools`. */
  autoTools: string[]
  /** The declared `internal`-surface subset of `tools`. */
  internalTools: string[]
  skills: string[]
  systemPrompts: string[]
  /**
   * The two things only a MEMBER of a session can give: this package's slash
   * commands, and its front-end module. Already computed by `contributionsOf`;
   * named here so `/ext` can say what a row's Enter is actually turning on.
   */
  commands: PackageCommand[]
  ui: PackageUi | null
  /** Which pointer layer names the current version, or null when none does. */
  layer: PointerLayer | null
}

function readManifest(path: string): Record<string, unknown> | null {
  if (!existsSync(path)) return null
  try {
    // Read synchronously: a store scan stays one call for its callers, and the
    // files are a few hundred bytes each.
    return JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>
  } catch {
    return null
  }
}

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string") : []
}

/**
 * `contributes.system_prompts`, whose entries are a bare path or an object
 * carrying `path` plus an optional `position` (`manifest.SystemPromptSpec`).
 * Only the path is projected: `position` orders one session's
 * system blocks, and this front end counts prompt files and names their source
 * — it never assembles the blocks itself.
 */
function promptPathList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  const out: string[] = []
  for (const entry of value) {
    if (typeof entry === "string") out.push(entry)
    else if (entry !== null && typeof entry === "object") {
      const path = (entry as Record<string, unknown>)["path"]
      if (typeof path === "string") out.push(path)
    }
  }
  return out
}

function manifestFacts(manifest: Record<string, unknown> | null): Pick<
  ExtensionEntry,
  | "kind"
  | "tools"
  | "manualTools"
  | "autoTools"
  | "internalTools"
  | "skills"
  | "systemPrompts"
  | "commands"
  | "ui"
> {
  const runtime = manifest?.["runtime"] as Record<string, unknown> | undefined
  // `runtime.entry` is a string, or an object keyed by OS for a script that
  // ships one file per platform; the kind is the same question
  // asked of every variant, as `manifest.isScript` asks it.
  const rawEntry = runtime?.["entry"]
  const entries =
    typeof rawEntry === "string"
      ? [rawEntry]
      : typeof rawEntry === "object" && rawEntry !== null
        ? Object.values(rawEntry as Record<string, unknown>).filter((v): v is string => typeof v === "string")
        : []
  return {
    // `bin/` means the kernel compiles it, anything else is frozen as-is; no
    // runtime at all is a pure skill/prompt package.
    kind: entries.length === 0 ? "data" : entries.some((e) => e.startsWith("bin/")) ? "compiled" : "script",
    ...contributionsOf(manifest),
  }
}

/**
 * Every extension this machine holds: id, `current`, which pointer layer named
 * it, the immutable version line, and what the current version contributes.
 * Versions are content-addressed and never disappear (physics #5), so the
 * timeline is the extension's history.
 *
 * The ids and the layer come from `ext list`; the detail of each one is read
 * from the store, which is where every version's bytes are.
 */
export async function listExtensions(ws: Workspace): Promise<ExtensionEntry[]> {
  const out: ExtensionEntry[] = []
  const store = storePath()
  for (const entry of await extList(ws)) {
    const home = join(store, entry.id)
    const versions: ExtensionVersion[] = []
    const versionsDir = join(home, "versions")
    if (existsSync(versionsDir)) {
      for (const version of readdirSync(versionsDir)) {
        if (!version.startsWith("v-")) continue
        try {
          versions.push({ version, mtime: statSync(join(versionsDir, version)).mtimeMs })
        } catch {
          // Ignore a version directory that vanished mid-scan.
        }
      }
    }
    versions.sort((a, b) => a.mtime - b.mtime)
    // The manifest of the CURRENT version, else the newest build, else the
    // draft — all three are the schema's single truth, never the binary (DESIGN
    // §7.2). The middle one matters: a package meant to be worn with `--with`
    // rather than activated has no `current` for its whole life, and describing
    // it as empty would hide exactly the packages M5 made possible.
    const newest = versions.length > 0 ? versions[versions.length - 1]!.version : null
    const manifest =
      (entry.current ? readManifest(join(versionsDir, entry.current, "extension.json")) : null) ??
      (newest ? readManifest(join(versionsDir, newest, "extension.json")) : null) ??
      readManifest(join(home, "extension.json")) ??
      readManifest(join(ws.dir, extensions_dir, entry.id, "extension.json"))
    out.push({
      id: entry.id,
      current: entry.current,
      versions,
      layer: entry.layer,
      ...manifestFacts(manifest),
    })
  }
  return out.sort((a, b) => a.id.localeCompare(b.id))
}

/**
 * The ids that exist only as SOURCE.
 *
 * `ext list` lists what this machine holds — a built version, a pointer, or
 * both — so a draft that has never built is not in it. That is right for the kernel and
 * wrong for a panel: `std` sitting in the user store, unbuildable on a machine
 * with no usable zig, was invisible in `/ext` and the only trace was a status
 * line saying `3 failed` as it scrolled past.
 *
 * So the panel unions `ext list` with `ext sync --dry-run`, and this reads the
 * manifest of each id the listing did not name. No versions and no `current`:
 * that is exactly what such an id is.
 */
export async function draftEntries(
  ws: Workspace,
  ids: readonly string[],
): Promise<ExtensionEntry[]> {
  if (ids.length === 0) return []
  const out: ExtensionEntry[] = []
  for (const id of ids) {
    for (const dir of draftDirs(ws)) {
      const manifest = readManifest(join(dir, id, "extension.json"))
      if (!manifest) continue
      out.push({
        id,
        current: null,
        versions: [],
        // Nothing points at it yet, so no layer claims it either.
        layer: null,
        ...manifestFacts(manifest),
      })
      break
    }
  }
  return out
}

// --- the usage journal ------------------------------------------------------

/**
 * The projection of `.nulya/tool-usage.jsonl` — counts only.
 *
 * Deliberately NOT a ranking. Nothing ranks: a tool reaches the model's tool
 * face because somebody composed its package with the tool named
 * (`[extensions] with`, or `session new --with`), and this journal is the
 * evidence they read, never the
 * decision. Sorting it into "who is next" here would invent an order the kernel
 * does not have.
 */
export interface ToolUsage {
  toolId: string
  uses: number
  ok: number
}

export const usage_journal = ".nulya/tool-usage.jsonl"

export async function readToolUsage(ws: Workspace): Promise<ToolUsage[]> {
  const path = join(ws.dir, usage_journal)
  if (!existsSync(path)) return []
  let text = ""
  try {
    text = await Bun.file(path).text()
  } catch {
    return []
  }
  const counts = new Map<string, ToolUsage>()
  for (const line of text.split("\n")) {
    const trimmed = line.trim()
    if (trimmed.length === 0) continue
    try {
      const record = JSON.parse(trimmed) as { tool_id?: unknown; ok?: unknown }
      if (typeof record.tool_id !== "string") continue
      const entry = counts.get(record.tool_id) ?? { toolId: record.tool_id, uses: 0, ok: 0 }
      entry.uses += 1
      if (record.ok === true) entry.ok += 1
      counts.set(record.tool_id, entry)
    } catch {
      // A torn last line is expected while a step is writing; skip it.
    }
  }
  return [...counts.values()].sort((a, b) => b.uses - a.uses || a.toolId.localeCompare(b.toolId))
}

// --- delegations (goals/agent-runner.md ar-a) -------------------------------

export const delegations_dir = ".nulya/delegations"

/** A delegation id: `d-<12 hex>` (`extensions/agent/src/record.zig`'s `isPlainId`). */
export const delegation_id = /^d-[0-9a-f]{12}$/

export function isDelegationId(id: string): boolean {
  return delegation_id.test(id)
}

/**
 * The one row a delegation's record opens with — what the package decided ONCE
 * about who drives it and what it opened (`extensions/agent/src/record.zig`'s
 * `Created`). This front end never writes here: it is the fallback for a
 * follow-up receipt, whose text never repeats the remote conversation
 * (`sendTurn`'s reply only names the delegation and the task it started, not
 * what the delegation opened) — the first delegate() receipt is the only one
 * that says "session <remote>" out loud (ar-t2).
 */
export interface DelegationRecord {
  agent: string
  runner: string
  /** What the runner opened to hold this conversation — an `s-…` id only for the `nulya` runner. */
  remote: string
  readonly: boolean
}

/**
 * Read `.nulya/delegations/<id>/record.jsonl` back, the same discipline
 * `readToolUsage` above follows for the other append-only journal in this
 * file — and the one `extensions/agent/src/record.zig` itself follows: a torn
 * last line (an append in flight, or cut short by a crash) is dropped by
 * finding the last `\n` rather than trusting the file's length, and a line
 * that will not parse is skipped rather than failing the whole read. This side
 * never writes the journal, so there is no lease to take for reading it.
 */
export async function readDelegationRecord(ws: Workspace, id: string): Promise<DelegationRecord | null> {
  if (!isDelegationId(id)) return null
  const path = join(ws.dir, delegations_dir, id, "record.jsonl")
  let text: string
  try {
    text = await Bun.file(path).text()
  } catch {
    return null
  }
  const end = text.lastIndexOf("\n")
  const whole = end === -1 ? "" : text.slice(0, end + 1)
  for (const line of whole.split("\n")) {
    const trimmed = line.trim()
    if (trimmed.length === 0) continue
    let value: unknown
    try {
      value = JSON.parse(trimmed)
    } catch {
      continue
    }
    if (typeof value !== "object" || value === null) continue
    const row = value as Record<string, unknown>
    // One delegation, one opening (`record.zig`'s own rule) — the first
    // `created` row is the only one there will ever be.
    if (row["kind"] !== "created") continue
    const agent = row["agent"]
    const runner = row["runner"]
    const remote = row["remote"]
    if (typeof agent !== "string" || typeof runner !== "string" || typeof remote !== "string") return null
    return { agent, runner, remote, readonly: row["readonly"] === true }
  }
  return null
}
