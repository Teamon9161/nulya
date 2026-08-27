/**
 * Which directory a tab works in (goals/tui-shell.md §5.3b).
 *
 * A session belongs to the directory it was created in — the kernel has always
 * said so, and `Workspace` has always been an explicit argument to every CLI
 * call this front end makes (`nulya/cli.ts`). What changed in S1c is only where
 * that argument comes from: a tab, not the process. This module holds the two
 * facts the rest of the front end needs about a workspace that `bin.ts` does
 * not answer — which one is the HOME workspace, and what to call one on screen.
 *
 * **The home workspace** is `<NULYA_HOME | ~/.nulya>/home/`. It exists so that
 * "just ask a question, nothing to do with any project" is a real answer rather
 * than a shrug: sessions, journals and scratch land in its own `.nulya/`, and
 * everything else about such a session — model, extensions, approvals,
 * background tasks — is what it always was.
 *
 * It is deliberately NOT `~` itself, and the reason is structural rather than
 * tidiness (§5.3b point 5): `~/.nulya` is the USER layer. Making the home
 * directory a workspace would collapse the user extension store onto a
 * workspace store, and the kernel's trust gate (DESIGN §9) would then see a
 * store it never recorded a local build for and refuse to open a session at
 * all. One directory down, and the two layers stay two layers.
 */
import { mkdirSync } from "node:fs"
import { basename, join } from "node:path"
import { openWorkspace, type Workspace } from "./nulya/bin.ts"
import { samePath } from "./extensions.ts"
import { userConfigDir } from "./state/settings.ts"

/** What the sidebar, the browser and the status line call the home workspace. */
export const no_project_label = "no project"

/**
 * The directory a "no project" session lives in.
 *
 * Resolved through `userConfigDir`, which is the one place `NULYA_HOME` is
 * read — so a test that points that variable at a scratch directory moves this
 * with it, exactly as it moves `tui-state.json` and the trust journal.
 */
export function homeWorkspaceDir(env: Record<string, string | undefined> = process.env): string {
  return join(userConfigDir(env), "home")
}

export function isHomeWorkspaceDir(dir: string, env: Record<string, string | undefined> = process.env): boolean {
  return samePath(dir, homeWorkspaceDir(env))
}

/**
 * The name a workspace goes by on screen: the home one says what it is, every
 * other one is its own directory name.
 *
 * Not the full path — that is the dim second half of a group heading, cut to
 * whatever room is left (§6.1 rule 7). A person recognises `nulya` and
 * `notes`, not `/Users/…/src/nulya`.
 */
export function workspaceLabel(dir: string, env: Record<string, string | undefined> = process.env): string {
  if (isHomeWorkspaceDir(dir, env)) return no_project_label
  return basename(dir.replace(/[\\/]+$/, "")) || dir
}

/**
 * Open a workspace at `dir`, creating it when it is the home one.
 *
 * Only the home workspace is created here, and only because nothing else ever
 * creates it: it is this front end's own invention, so the first session that
 * wants it has to find a directory. Every other path a person types is a
 * directory they already have — this never conjures one, and a missing one
 * fails where it is used, with the kernel's own sentence.
 */
export function openWorkspaceAt(dir: string, env: Record<string, string | undefined> = process.env): Workspace {
  if (isHomeWorkspaceDir(dir, env)) {
    try {
      mkdirSync(homeWorkspaceDir(env), { recursive: true })
    } catch {
      // Let the failure show up where it means something: the CLI call that
      // needs the directory says so far better than a throw from here would.
    }
  }
  return openWorkspace(dir, env)
}

/** Two workspaces naming the same directory. */
export function sameWorkspace(a: Pick<Workspace, "dir">, b: Pick<Workspace, "dir">): boolean {
  return samePath(a.dir, b.dir)
}
