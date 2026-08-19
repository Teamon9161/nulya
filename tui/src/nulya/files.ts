/**
 * The `.nulya/` directory layout (DESIGN §3.4 / §5.5 / §7.2), read-only —
 * with one exception at the bottom of this file: un-creating a session this
 * process made and never used (`discardIfUntouched`).
 *
 * Otherwise the TUI never writes into `.nulya/` except through the CLI
 * (`session append` stages its text in `.nulya/scratch/`, see `cli.ts`) — the
 * session file has exactly one writer and it is `session step`.
 */
import {
  closeSync,
  existsSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  rmdirSync,
  statSync,
  unlinkSync,
} from "node:fs"
import { isAbsolute, join } from "node:path"
import { parseHeaderLine, type SessionHeader } from "./ledger.ts"
import { extList } from "./cli.ts"
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
 * The store roots, in the kernel's search order, as directories on this disk.
 *
 * Order and membership are `store.Roots` — workspace, then user, then whatever
 * `extensions.paths` adds (DESIGN §7.2) — and the kernel already prints them,
 * one per `ext list` line. Reading them off that output is how the TUI avoids
 * a second implementation of "where do extensions live", which would drift the
 * moment a config layer moved.
 */
export async function storeRoots(ws: Workspace): Promise<string[]> {
  try {
    return rootsOf(ws, await extList(ws))
  } catch {
    // No binary, no store, a build too old to list roots: the workspace root is
    // where extensions have always been, and it is still the first one searched.
    return rootsOf(ws, [])
  }
}

/**
 * The same roots, from a listing somebody already has.
 *
 * `ext list` is a subprocess, and a caller holding its answer should not spawn a
 * second one to learn what it already read (`/ext` opens by listing and then
 * needs the roots to find the ids that are only source).
 */
export function rootsOf(ws: Workspace, listed: readonly { root: string }[]): string[] {
  const roots: string[] = []
  for (const entry of listed) {
    const dir = isAbsolute(entry.root) ? entry.root : join(ws.dir, entry.root)
    if (!roots.includes(dir)) roots.push(dir)
  }
  const workspace = join(ws.dir, extensions_dir)
  if (!roots.includes(workspace)) roots.unshift(workspace)
  return roots
}

/**
 * What one frozen extension version contributes (DESIGN §7.2). Only the parts
 * the transcript shows; the manifest is the schema's single truth, so nothing
 * here ever runs a binary to ask what it has.
 */
export interface Contributions {
  id: string
  version: string
  tools: string[]
  /**
   * The subset of `tools` whose manifest claims `"readonly": true` (DESIGN
   * §7.2.1). A CLAIM, recorded by the kernel and enforced by nothing: the
   * approval policy may believe it (`approvals.ts`), and `[approvals]
   * manifest_readonly = false` stops believing it.
   */
  readonlyTools: string[]
  skills: string[]
  /**
   * Files whose text becomes a system block for any session carrying this
   * version. A `--with` package is usually nothing BUT these (DESIGN §7.1) —
   * a mode, an identity — so a view that only counted tools and skills would
   * show the most deliberate part of a composition as empty.
   */
  systemPrompts: string[]
}

/**
 * Read `<id>/versions/<version>/extension.json` from the first root that holds
 * it. The version is the one the session FROZE (header `composition.active`),
 * not whatever `current` points at now — a mid-session `activate` moves
 * `current` and must not change what this session says it is running (DESIGN
 * §7.5). Which root the bytes come from does not matter: a version id is a hash
 * of its own contents, so two roots holding one version hold the same thing.
 */
export async function readContributions(
  ws: Workspace,
  id: string,
  version: string,
  roots?: readonly string[],
): Promise<Contributions> {
  const empty: Contributions = { id, version, tools: [], readonlyTools: [], skills: [], systemPrompts: [] }
  const search = roots ?? (await storeRoots(ws))
  for (const root of search) {
    const path = join(root, id, "versions", version, "extension.json")
    if (!existsSync(path)) continue
    try {
      const value = JSON.parse(await Bun.file(path).text()) as Record<string, unknown>
      return { id, version, ...contributionsOf(value) }
    } catch {
      // A store this build cannot parse is not a reason to refuse to draw the
      // session; the header alone already names the frozen versions.
      return empty
    }
  }
  return empty
}

function contributionsOf(
  manifest: Record<string, unknown> | null,
): Pick<Contributions, "tools" | "readonlyTools" | "systemPrompts" | "skills"> {
  const contributes = (manifest?.["contributes"] ?? {}) as Record<string, unknown>
  const declared = Array.isArray(contributes["tools"]) ? (contributes["tools"] as Array<Record<string, unknown>>) : []
  const named = declared.filter((tool) => typeof tool?.["name"] === "string")
  return {
    tools: named.map((tool) => tool["name"] as string),
    // Absent is not false (DESIGN §7.2.1): a package that said nothing has made
    // no claim, and only an explicit `true` is one.
    readonlyTools: named.filter((tool) => tool["readonly"] === true).map((tool) => tool["name"] as string),
    skills: stringList(contributes["skills"]),
    systemPrompts: stringList(contributes["system_prompts"]),
  }
}

export async function readActiveContributions(
  ws: Workspace,
  active: readonly { id: string; version: string }[],
): Promise<Contributions[]> {
  if (active.length === 0) return []
  // One root lookup for the whole composition, not one per member.
  const roots = await storeRoots(ws)
  return Promise.all(active.map((entry) => readContributions(ws, entry.id, entry.version, roots)))
}

// --- the writer lease -------------------------------------------------------

/**
 * Whether some other process holds the session's writer lease.
 *
 * `unknown` is a first-class answer. The kernel takes an exclusive advisory lock
 * on the sibling `<id>.lock` (DESIGN §3.4); on Windows that is a byte-range lock,
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
 * session's file safe from `discardIfUntouched`.
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

// --- un-creating an unused session ------------------------------------------

function siblingPath(ws: Workspace, id: string, suffix: string): string {
  return join(ws.dir, sessions_dir, `${id}${suffix}`)
}

/**
 * Remove a session that has recorded nothing, if — and only if — nothing about
 * it says somebody still means to use it.
 *
 * The common way to get one of these is gone since T22: a TUI tab starts as a
 * draft and runs `session new` at the first message, so looking and leaving
 * creates nothing at all. What is left are the paths that DO create a session
 * before anything is recorded — a compaction whose driver never returned, a
 * `--session` this process made — and for those the file is a header and no
 * events: not a ledger, just a name. Removing it is not rewriting history —
 * there is none — but it IS the one write into `.nulya/sessions/` this program
 * makes, so the guards are strict and every one is a "no":
 *
 *   - any event line: it is a ledger now (physics #1) and stays, empty of
 *     meaning or not;
 *   - a non-empty inbox: somebody appended and no step drained it yet — a
 *     turn the user typed is in there, and the next open would drain it;
 *   - the writer lease held: a step is running this very moment;
 *   - the lease probe answering `unknown` (a POSIX without `/proc/locks`): the
 *     lock file only exists once something opened the session for writing, so
 *     when the probe cannot see who, the honest action is to leave it.
 *
 * Callers only ever pass ids THIS process created (`session new` from the
 * TUI); a session opened with `--session`, or somebody else's, is never a
 * candidate — another TUI sitting idle on its own fresh session looks exactly
 * like this from the outside, and deleting it under them would break their
 * next `append`. Returns whether the session was removed.
 */
export function discardIfUntouched(ws: Workspace, id: string): boolean {
  const path = sessionPath(ws, id)
  if (!existsSync(path)) return false
  if (probeWriterLease(ws, id) !== "free") return false
  const lock = lockPath(ws, id)
  let text: string
  try {
    text = readFileSync(path, "utf8")
  } catch {
    return false
  }
  // The header is the first line; anything after it is an event.
  const lines = text.split("\n").filter((line) => line.trim().length > 0)
  if (lines.length > 1) return false
  const inbox = siblingPath(ws, id, ".inbox")
  if (existsSync(inbox)) {
    try {
      if (readdirSync(inbox).length > 0) return false
    } catch {
      return false
    }
  }
  try {
    unlinkSync(path)
  } catch {
    // Somebody opened it between the checks and now (a Windows sharing
    // violation, say): it is in use after all, and the checks above hold.
    return false
  }
  for (const sibling of [lock, siblingPath(ws, id, ".cancel")]) {
    try {
      if (existsSync(sibling)) unlinkSync(sibling)
    } catch {
      // A stray marker next to no session is harmless.
    }
  }
  try {
    if (existsSync(inbox)) rmdirSync(inbox)
  } catch {
    // Non-empty after all, or held open; leaving an empty directory is fine.
  }
  return true
}

// --- the extension store ----------------------------------------------------

/** DESIGN §7.4: what goes into a version id, and therefore what a build needs. */
export type ImplementationKind = "compiled" | "script" | "data"

export interface ExtensionVersion {
  version: string
  mtime: number
}

export interface ExtensionEntry {
  id: string
  /** `current` pointer: the version the NEXT session would freeze (DESIGN §7.5). */
  current: string | null
  versions: ExtensionVersion[]
  kind: ImplementationKind
  tools: string[]
  skills: string[]
  systemPrompts: string[]
  permissions: { fs: string[]; network: string[]; process: string[] }
  /** Which store root holds this copy (DESIGN §7.2). */
  root: string
  /** An earlier root has the same id active: this copy is never the one that runs. */
  shadowed: boolean
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

function manifestFacts(manifest: Record<string, unknown> | null): Pick<
  ExtensionEntry,
  "kind" | "tools" | "skills" | "systemPrompts" | "permissions"
> {
  const runtime = manifest?.["runtime"] as Record<string, unknown> | undefined
  const entry = typeof runtime?.["entry"] === "string" ? (runtime["entry"] as string) : null
  const permissions = (manifest?.["permissions"] ?? {}) as Record<string, unknown>
  return {
    // `bin/` means the kernel compiles it, anything else is frozen as-is; no
    // runtime at all is a pure skill/prompt package (DESIGN §7.1).
    kind: entry === null ? "data" : entry.startsWith("bin/") ? "compiled" : "script",
    ...contributionsOf(manifest),
    permissions: {
      fs: stringList(permissions["fs"]),
      network: stringList(permissions["network"]),
      process: stringList(permissions["process"]),
    },
  }
}

/**
 * Every extension directory in every store root: id, `current`, the immutable
 * version line, and what the current version contributes. Versions are
 * content-addressed and never disappear (physics #5), so the timeline is the
 * extension's history.
 *
 * The set of directories and the shadowing come from `ext list` — root order is
 * kernel policy and "first active holder wins" is its consequence — and the
 * detail of each one is read from the root the kernel named. An id can appear
 * twice (a user-level copy behind a workspace one); the second is marked
 * `shadowed`, because a stale copy that is silently omitted is exactly how it
 * becomes a mystery.
 */
export async function listExtensions(ws: Workspace): Promise<ExtensionEntry[]> {
  const out: ExtensionEntry[] = []
  for (const entry of await extList(ws)) {
    const root = isAbsolute(entry.root) ? entry.root : join(ws.dir, entry.root)
    const home = join(root, entry.id)
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
      readManifest(join(home, "extension.json"))
    out.push({
      id: entry.id,
      current: entry.current,
      versions,
      root: entry.root,
      shadowed: entry.shadowed,
      ...manifestFacts(manifest),
    })
  }
  // Alphabetical for the eye; the sort is stable, so a shadowed copy still sits
  // under the root that wins it.
  return out.sort((a, b) => a.id.localeCompare(b.id))
}

/**
 * The ids that exist only as SOURCE (tui.md §11, T22).
 *
 * `ext list` lists what a root holds — a directory with a built version — so a
 * draft that has never built is not in it. That is right for the kernel and
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
  /** The roots, when the caller already listed them (`rootsOf`): one fewer `ext list`. */
  known?: readonly string[],
): Promise<ExtensionEntry[]> {
  if (ids.length === 0) return []
  const roots = known ?? (await storeRoots(ws))
  const workspace = join(ws.dir, extensions_dir)
  const out: ExtensionEntry[] = []
  for (const id of ids) {
    for (const root of roots) {
      const manifest = readManifest(join(root, id, "extension.json"))
      if (!manifest) continue
      out.push({
        id,
        current: null,
        versions: [],
        // The same spec `ext list` prints, so two rows of one table do not name
        // the same directory two different ways.
        root: root === workspace ? extensions_dir : root,
        shadowed: false,
        ...manifestFacts(manifest),
      })
      break
    }
  }
  return out
}

// --- the usage journal ------------------------------------------------------

/**
 * The projection of `.nulya/tool-usage.jsonl` (DESIGN §5.5) — counts only.
 *
 * Deliberately NOT a ranking. Nothing ranks: a tool reaches the model's tool
 * face because somebody wrote a pin (`registry.pinned_native_tools`, or
 * `session new --pin`), and this journal is the evidence they read, never the
 * decision. Sorting it into "who is next" here would invent an order the kernel
 * does not have (tui.md §2.1).
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
