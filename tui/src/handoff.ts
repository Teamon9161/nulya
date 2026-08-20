/**
 * The model's own proposal to hand over (DESIGN §11, tui.md §5.8).
 *
 * The bundled `handoff` package contributes one tool, and that tool does exactly
 * one thing: it writes `.nulya/handoffs/<session>-<n>.md` and tells the model to
 * stop. **That file IS the proposal** — no JSON to parse, no protocol to agree
 * on, and nothing has happened to the conversation yet. Forking is a separate
 * act, and it belongs to whoever is driving: `drivers/goal.*` does it without
 * asking, this front end asks first (in `ask` mode) because there is a person
 * right there.
 *
 * So this module is one small thing: find the files. Bringing the package into
 * a session is `[extensions] session_with` like any other (`extensions.ts`), and
 * the fork itself is `/compact`'s `brief_file` branch (`compact.ts`) — the same
 * fork `/compact` always did, with the brief supplied instead of asked for.
 */
import { existsSync, readFileSync, readdirSync } from "node:fs"
import { join } from "node:path"
import type { Workspace } from "./nulya/bin.ts"

/** Where the tool writes, relative to the workspace (DESIGN §11). */
export const handoff_dir = ".nulya/handoffs"

export interface HandoffFile {
  /** Workspace-relative path — what `compact --arg brief_file=` takes. */
  path: string
  /** The `<n>` the kernel-side tool picked; monotonic per session. */
  index: number
  /** The rendered markdown brief, as written. */
  brief: string
}

/**
 * The handoff files this session has, newest last. A pure directory read: the
 * tool creates each file exclusively and never rewrites one, so a name that was
 * not there a moment ago is a new proposal and nothing else.
 */
export function handoffsFor(ws: Workspace, sessionId: string): HandoffFile[] {
  const dir = join(ws.dir, handoff_dir)
  if (!existsSync(dir)) return []
  const found: HandoffFile[] = []
  let names: string[] = []
  try {
    names = readdirSync(dir)
  } catch {
    return []
  }
  for (const name of names) {
    const match = new RegExp(`^${escapeForRegExp(sessionId)}-(\\d+)\\.md$`).exec(name)
    if (!match) continue
    const path = `${handoff_dir}/${name}`
    let brief = ""
    try {
      brief = readFileSync(join(ws.dir, path), "utf8")
    } catch {
      // Being unable to read it does not make it not a proposal; the compact
      // driver reads it again anyway and reports its own refusal.
    }
    found.push({ path, index: Number(match[1]), brief })
  }
  return found.sort((a, b) => a.index - b.index)
}

/** The newest handoff this process has not dealt with yet, or null. */
export function nextHandoff(ws: Workspace, sessionId: string, seen: ReadonlySet<string>): HandoffFile | null {
  const found = handoffsFor(ws, sessionId).filter((file) => !seen.has(file.path))
  return found.length > 0 ? found[found.length - 1]! : null
}

/** The first line worth showing: the brief's own heading, or its first words. */
export function headline(brief: string): string {
  for (const raw of brief.split("\n")) {
    const line = raw.replace(/^#+\s*/, "").trim()
    if (line.length > 0) return line.length > 80 ? `${line.slice(0, 77)}…` : line
  }
  return "a handover brief"
}

function escapeForRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}
