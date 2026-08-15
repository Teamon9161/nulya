/**
 * The `.nulya/` directory layout (DESIGN §3.4 / §5.5 / §7.2), read-only.
 *
 * The TUI never writes into `.nulya/` except through the CLI (`session append`
 * stages its text in `.nulya/scratch/`, see `cli.ts`) — the session file has
 * exactly one writer and it is `session step`.
 */
import { existsSync } from "node:fs"
import { join } from "node:path"
import { parseHeaderLine, type SessionHeader } from "./ledger.ts"
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
