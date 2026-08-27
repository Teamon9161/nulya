/**
 * The workspaces this front end has actually started a session in
 * (goals/tui-shell.md §5.3b point 3).
 *
 * USER LAYER, `<NULYA_HOME | ~/.nulya>/tui-recents.json`, and that is the whole
 * reason it is a second file rather than a key in `tui-state.json`: this is a
 * fact ABOUT several workspaces, and `tui-state.json` is a workspace-layer
 * file in every other respect — a project's remembered pins, its sidebar, its
 * mode. The kernel made the same call for the same reason (`trusted-stores.jsonl`
 * is user-layer because a checkout must not be able to sign for itself,
 * DESIGN §9); here it is duller but structurally identical: a list of other
 * directories cannot live inside one of them.
 *
 * Written when a SESSION IS SUCCESSFULLY CREATED, never when a directory is
 * merely browsed to or chosen. A recent is "somewhere I worked", and a picker
 * that filled itself with everywhere the cursor passed would be a history of
 * clicking rather than a list of places.
 *
 * The home workspace is never recorded: it has a standing first row of its own
 * in the browser, and a second entry for it further down would be the same
 * place offered twice.
 *
 * Unreadable, missing or malformed is an empty list. Nothing here is ever a
 * reason for the screen not to open.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { userConfigDir } from "./settings.ts"
import { homeWorkspaceDir } from "../workspaces.ts"
import { samePath } from "../extensions.ts"

/**
 * How many places the list keeps. Enough to cover the handful of repositories
 * anybody moves between in a day; short enough that the browser never needs a
 * scrollbar for its recents alone.
 */
export const max_recents = 12

export function recentsPath(env: Record<string, string | undefined> = process.env): string {
  return join(userConfigDir(env), "tui-recents.json")
}

/** The remembered workspaces, newest first. */
export function loadRecents(path = recentsPath()): string[] {
  if (!existsSync(path)) return []
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, "utf8"))
    if (typeof parsed !== "object" || parsed === null) return []
    const list = (parsed as Record<string, unknown>)["recent"]
    if (!Array.isArray(list)) return []
    return list.filter((entry): entry is string => typeof entry === "string" && entry.length > 0).slice(0, max_recents)
  } catch {
    return []
  }
}

/**
 * Put `dir` at the front, dropping any older mention of the same place.
 *
 * Read-modify-write, like every other remember in this front end: two windows
 * working in two directories must not lose each other's places.
 */
export function rememberRecent(
  dir: string,
  path = recentsPath(),
  env: Record<string, string | undefined> = process.env,
): void {
  if (samePath(dir, homeWorkspaceDir(env))) return
  const kept = loadRecents(path).filter((known) => !samePath(known, dir))
  try {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, `${JSON.stringify({ recent: [dir, ...kept].slice(0, max_recents) }, null, 2)}\n`)
  } catch {
    // Not being able to remember is not a reason to stop working.
  }
}
