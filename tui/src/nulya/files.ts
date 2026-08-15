/**
 * The `.nulya/` directory layout (DESIGN §3.4 / §5.5 / §7.2), read-only.
 *
 * The TUI never writes into `.nulya/` except through the CLI (`session append`
 * stages its text in `.nulya/scratch/`, see `cli.ts`) — the session file has
 * exactly one writer and it is `session step`.
 */
import { closeSync, existsSync, openSync, readFileSync, readSync, readdirSync, statSync } from "node:fs"
import { join } from "node:path"
import { parseEventLine, parseHeaderLine, type SessionHeader } from "./ledger.ts"
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
 * What one frozen extension version contributes (DESIGN §7.2). Only the parts
 * the transcript shows; the manifest is the schema's single truth, so nothing
 * here ever runs a binary to ask what it has.
 */
export interface Contributions {
  id: string
  version: string
  tools: string[]
  skills: string[]
}

/**
 * Read `<id>/versions/<version>/extension.json` from the store. The version is
 * the one the session FROZE (header `composition.active`), not whatever
 * `current` points at now — a mid-session `activate` moves `current` and must
 * not change what this session says it is running (DESIGN §7.5).
 */
export async function readContributions(ws: Workspace, id: string, version: string): Promise<Contributions> {
  const empty: Contributions = { id, version, tools: [], skills: [] }
  const path = join(ws.dir, extensions_dir, id, "versions", version, "extension.json")
  if (!existsSync(path)) return empty
  try {
    const value = JSON.parse(await Bun.file(path).text()) as Record<string, unknown>
    const contributes = (value["contributes"] ?? {}) as Record<string, unknown>
    const tools = Array.isArray(contributes["tools"])
      ? (contributes["tools"] as Array<Record<string, unknown>>)
          .map((tool) => (typeof tool?.["name"] === "string" ? (tool["name"] as string) : null))
          .filter((name): name is string => name !== null)
      : []
    const skills = Array.isArray(contributes["skills"])
      ? (contributes["skills"] as unknown[]).filter((skill): skill is string => typeof skill === "string")
      : []
    return { id, version, tools, skills }
  } catch {
    // A store this build cannot parse is not a reason to refuse to draw the
    // session; the header alone already names the frozen versions.
    return empty
  }
}

export async function readActiveContributions(
  ws: Workspace,
  active: readonly { id: string; version: string }[],
): Promise<Contributions[]> {
  return Promise.all(active.map((entry) => readContributions(ws, entry.id, entry.version)))
}

// --- the writer lease -------------------------------------------------------

/**
 * Whether some other process holds the session's writer lease.
 *
 * `unknown` is a first-class answer. The kernel takes an exclusive advisory lock
 * on the sibling `<id>.lock` (DESIGN §3.4); on Windows that is a byte-range lock,
 * so a read of byte 0 from any other handle fails while it is held — a probe
 * that touches nothing. On POSIX the same lease is `flock`, which reads cannot
 * see at all, so this returns `unknown` there rather than lying about it: the
 * authoritative answer in that case is the kernel's own `SessionBusy`, which a
 * `session step` reports the moment we try to drive (see `state/attach.ts`).
 */
export type LeaseState = "free" | "held" | "unknown"

export function lockPath(ws: Workspace, id: string): string {
  return join(ws.dir, sessions_dir, `${id}.lock`)
}

export function probeWriterLease(ws: Workspace, id: string): LeaseState {
  const path = lockPath(ws, id)
  // No lock file at all: nobody has ever opened this session for writing.
  if (!existsSync(path)) return "free"
  if (process.platform !== "win32") return "unknown"
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

// --- the session store ------------------------------------------------------

export interface SessionEntry {
  id: string
  /** Last write to the session FILE — only `session step` writes it. */
  mtime: number
  header: SessionHeader | null
  /** Number of ledger events (lines after the header). */
  events: number
  /** First `user_text`, truncated — the closest thing a session has to a title. */
  title: string
  lease: LeaseState
}

function firstUserText(lines: string[]): string {
  for (const line of lines) {
    const event = parseEventLine(line)
    if (event && event.kind === "user_text") {
      const text = (event as { text?: unknown }).text
      if (typeof text === "string") return text.split("\n", 1)[0] ?? ""
    }
  }
  return ""
}

/**
 * Every durable session in the workspace, newest first. Reads the files
 * directly: `session events` skips the header and would cost a process per
 * session, and the file IS the wire format (DESIGN §3.4).
 */
export async function listSessions(ws: Workspace): Promise<SessionEntry[]> {
  const dir = join(ws.dir, sessions_dir)
  if (!existsSync(dir)) return []
  const entries: SessionEntry[] = []
  for (const name of readdirSync(dir)) {
    if (!name.endsWith(".jsonl")) continue
    const id = name.slice(0, -".jsonl".length)
    const path = join(dir, name)
    let mtime = 0
    try {
      mtime = statSync(path).mtimeMs
    } catch {
      continue
    }
    let lines: string[] = []
    try {
      lines = (await Bun.file(path).text()).split("\n").filter((line) => line.trim().length > 0)
    } catch {
      // A session being written right now can still be listed; it just has no
      // detail yet.
    }
    entries.push({
      id,
      mtime,
      header: lines.length > 0 ? parseHeaderLine(lines[0]!) : null,
      events: Math.max(0, lines.length - 1),
      title: firstUserText(lines.slice(1)),
      lease: probeWriterLease(ws, id),
    })
  }
  return entries.sort((a, b) => b.mtime - a.mtime)
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
  permissions: { fs: string[]; network: string[]; process: string[] }
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
  "kind" | "tools" | "skills" | "permissions"
> {
  const contributes = (manifest?.["contributes"] ?? {}) as Record<string, unknown>
  const runtime = manifest?.["runtime"] as Record<string, unknown> | undefined
  const entry = typeof runtime?.["entry"] === "string" ? (runtime["entry"] as string) : null
  const permissions = (manifest?.["permissions"] ?? {}) as Record<string, unknown>
  return {
    // `bin/` means the kernel compiles it, anything else is frozen as-is; no
    // runtime at all is a pure skill/prompt package (DESIGN §7.1).
    kind: entry === null ? "data" : entry.startsWith("bin/") ? "compiled" : "script",
    tools: Array.isArray(contributes["tools"])
      ? (contributes["tools"] as Array<Record<string, unknown>>)
          .map((tool) => (typeof tool?.["name"] === "string" ? (tool["name"] as string) : null))
          .filter((name): name is string => name !== null)
      : [],
    skills: stringList(contributes["skills"]),
    permissions: {
      fs: stringList(permissions["fs"]),
      network: stringList(permissions["network"]),
      process: stringList(permissions["process"]),
    },
  }
}

/**
 * The whole extension store: id, `current`, the immutable version line, and what
 * the current version contributes. Versions are content-addressed and never
 * disappear (physics #5), so the timeline is the extension's history.
 */
export function listExtensions(ws: Workspace): ExtensionEntry[] {
  const dir = join(ws.dir, extensions_dir)
  if (!existsSync(dir)) return []
  const out: ExtensionEntry[] = []
  for (const id of readdirSync(dir)) {
    const home = join(dir, id)
    try {
      if (!statSync(home).isDirectory()) continue
    } catch {
      continue
    }
    let current: string | null = null
    const currentPath = join(home, "current")
    if (existsSync(currentPath)) {
      try {
        current = readFileSync(currentPath, "utf8").trim() || null
      } catch {
        current = null
      }
    }
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
    // The manifest of the CURRENT version if there is one, else the draft: both
    // are the schema's single truth, never the binary (DESIGN §7.2).
    const manifest =
      (current ? readManifest(join(versionsDir, current, "extension.json")) : null) ??
      readManifest(join(home, "extension.json"))
    out.push({ id, current, versions, ...manifestFacts(manifest) })
  }
  return out.sort((a, b) => a.id.localeCompare(b.id))
}

// --- the usage journal ------------------------------------------------------

/**
 * The projection of `.nulya/tool-usage.jsonl` (DESIGN §5.5) — counts only.
 *
 * Deliberately NOT a ranking: which tool gets promoted into the next session is
 * `tool_selection.rank`, a kernel policy, and reimplementing it here would be a
 * second truth that silently drifts (tui.md §2.1).
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
