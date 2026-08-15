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
