/**
 * The directory browser's arithmetic (goals/tui-shell.md §5.3b point 2).
 *
 * Everything here is a pure function of a path, a directory listing and the
 * remembered recents — so what the browser will show at any typed prefix is
 * answerable without a terminal and without a disk. The view above it
 * (`ui/overlays/DirBrowser.tsx`) reads directories and draws rows; it decides
 * nothing.
 *
 * Three rules the shape encodes, all of them from §5.3b:
 *
 *  - `no project` is ALWAYS the first row, ahead of the recents. It is not a
 *    directory somebody browsed to, it is a standing answer (`workspaces.ts`),
 *    so it has a standing place rather than a spot in a list that reorders.
 *  - Only directories, never files, and never a dot-directory except `..`.
 *    This is a workspace picker: a file is not an answer to the question, and
 *    `.git` / `.venv` are noise in every repository anybody would open.
 *  - `..` heads the subdirectory section. It is the one row whose meaning is
 *    "leave here", and a row that moves as the listing changes is a row people
 *    click by accident.
 */
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path"

/** What a browsed directory holds, as the view reads it off disk. */
export interface DirChild {
  readonly name: string
  /** Whether it already has a `.nulya/` — "this one is already a workspace". */
  readonly workspace: boolean
}

export type DirRowKind = "home" | "recent" | "use" | "parent" | "child"

/** Which run of rows a row belongs to. The view draws a heading when it changes. */
export type DirSection = "places" | "recent" | "current" | "subdirs"

export interface DirRow {
  readonly kind: DirRowKind
  readonly section: DirSection
  /** The absolute directory this row is about. */
  readonly path: string
  /** What the row says. */
  readonly label: string
  /** Already holds a `.nulya/`; drawn as a mark, never as a second column. */
  readonly workspace: boolean
  /**
   * What taking this row does. `enter` browses into it and `choose` selects it
   * as the tab's workspace — the distinction §5.3b asks for, spelled as data so
   * that the click handler and the `Enter` handler cannot disagree about it.
   */
  readonly action: "enter" | "choose"
}

/**
 * Expand what somebody typed into an absolute directory.
 *
 * `~` and `~/x` come first because they are the one form a terminal user
 * expects to work everywhere. A Windows drive letter (`D:`, `D:\src`) is
 * absolute even when it looks relative to `path.isAbsolute` on POSIX, which is
 * why it is tested here rather than left to `resolve`: this function has to
 * give the same answer about a pasted path on both platforms, since the paste
 * usually comes from the other one.
 */
export function expandPath(
  input: string,
  base: string,
  env: Record<string, string | undefined> = process.env,
): string {
  const raw = input.trim()
  if (raw.length === 0) return base
  const home = env["HOME"] ?? env["USERPROFILE"] ?? ""
  if (raw === "~" || raw === "~/" || raw === "~\\") return home || base
  if ((raw.startsWith("~/") || raw.startsWith("~\\")) && home.length > 0) {
    return join(home, raw.slice(2))
  }
  if (/^[a-zA-Z]:$/.test(raw)) return `${raw}${sep}`
  if (/^[a-zA-Z]:[\\/]/.test(raw)) return raw.replace(/[\\/]+$/, "") || raw
  if (isAbsolute(raw)) return resolve(raw)
  return resolve(base, raw)
}

/**
 * Where a typed line points, and what is left over as a filter.
 *
 * Typing narrows the listing rather than emptying it: `~/src/nul` shows what is
 * in `~/src` whose name starts with `nul`, which is the behaviour that makes
 * "type a bit, then click" work. Whether the expansion is itself a directory is
 * the caller's to answer (`exists`), so this stays pure.
 */
export function resolveTyped(
  input: string,
  base: string,
  exists: (path: string) => boolean,
  env: Record<string, string | undefined> = process.env,
): { dir: string; filter: string } {
  const raw = input.trim()
  const expanded = expandPath(raw, base, env)
  // An explicit trailing separator means "inside this one", even before it
  // exists — otherwise the last component would flicker into a filter on the
  // keystroke that finishes it.
  if (/[\\/]$/.test(raw) || raw.length === 0) return { dir: expanded, filter: "" }
  if (exists(expanded)) return { dir: expanded, filter: "" }
  const parent = dirname(expanded)
  if (parent === expanded) return { dir: expanded, filter: "" }
  return { dir: parent, filter: basename(expanded) }
}

/** Whether a directory name is one this picker hides (dot-directories). */
export function hiddenDir(name: string): boolean {
  return name.startsWith(".")
}

/** Sort and filter a raw listing into the children this picker offers. */
export function visibleChildren(children: readonly DirChild[], filter = ""): DirChild[] {
  const needle = filter.toLowerCase()
  return children
    .filter((child) => !hiddenDir(child.name))
    .filter((child) => needle.length === 0 || child.name.toLowerCase().startsWith(needle))
    .slice()
    .sort((a, b) => a.name.localeCompare(b.name))
}

export interface BrowserInput {
  /** The directory being browsed, absolute. */
  readonly dir: string
  readonly children: readonly DirChild[]
  /** What the person has typed since the last resolved component. */
  readonly filter?: string
  /** Remembered workspaces, newest first (`state/recents.ts`). */
  readonly recents: readonly string[]
  /** `<NULYA_HOME | ~/.nulya>/home` — the standing "no project" answer. */
  readonly homeDir: string
  /** How a recent's directory name is drawn; the home one says `no project`. */
  readonly label: (dir: string) => string
  /** Whether a recent still holds a `.nulya/`. Unknown is fine: it only marks. */
  readonly isWorkspace?: (dir: string) => boolean
  /**
   * Path arithmetic for whichever machine `dir` lives on — defaults to this
   * host's own (`node:path`'s `join`/`dirname`). A remote listing passes
   * POSIX ones (`node:path/posix`), since the far side of a `remote:` target
   * is not necessarily this host's platform and `node:path`'s `join` on a
   * Windows host hands back backslashes no shell over there would understand
   * (`state/dirsource.ts`, goals/remote-env.md §3.9).
   */
  readonly join?: (dir: string, name: string) => string
  readonly dirname?: (dir: string) => string
}

/**
 * Every row the browser draws, in order.
 *
 * The recents drop the home workspace (it has its own standing row above them)
 * and the directory currently being browsed (it has one below them), so no
 * place is ever offered twice on one screen — §6.1 rule 4 read as "a row that
 * repeats a row is a row that is not information".
 */
export function browserRows(input: BrowserInput): DirRow[] {
  const marks = input.isWorkspace ?? (() => false)
  const j = input.join ?? join
  const d = input.dirname ?? dirname
  const rows: DirRow[] = []
  rows.push({
    kind: "home",
    section: "places",
    path: input.homeDir,
    label: input.label(input.homeDir),
    workspace: false,
    action: "choose",
  })
  for (const dir of input.recents) {
    if (samePlace(dir, input.homeDir) || samePlace(dir, input.dir)) continue
    rows.push({
      kind: "recent",
      section: "recent",
      path: dir,
      label: input.label(dir),
      workspace: marks(dir),
      action: "choose",
    })
  }
  rows.push({
    kind: "use",
    section: "current",
    path: input.dir,
    label: "use this directory",
    workspace: marks(input.dir),
    action: "choose",
  })
  const up = d(input.dir)
  if (up !== input.dir) {
    rows.push({ kind: "parent", section: "subdirs", path: up, label: "..", workspace: false, action: "enter" })
  }
  for (const child of visibleChildren(input.children, input.filter ?? "")) {
    rows.push({
      kind: "child",
      section: "subdirs",
      path: j(input.dir, child.name),
      label: child.name,
      workspace: child.workspace,
      action: "enter",
    })
  }
  return rows
}

/**
 * Path equality for the "do not offer the same place twice" rule above.
 *
 * Deliberately its own comparison rather than `extensions.samePath`: that one
 * answers "is this the store a person already answered a trust question for",
 * and importing it here would make a de-duplication rule in a picker share a
 * definition with a security record. They agree today; they are allowed to
 * stop agreeing.
 */
function samePlace(a: string, b: string): boolean {
  const norm = (s: string) => s.replace(/[\\/]+$/, "").replace(/\\/g, "/")
  return process.platform === "win32" ? norm(a).toLowerCase() === norm(b).toLowerCase() : norm(a) === norm(b)
}

// ── DirSource: local disk or a channel to another machine ──────────────────

/**
 * Where a browser's listing and existence checks actually come from — this
 * machine's disk for `/cwd`, or a channel to another machine for the
 * directory a `remote:` `/env` target will use as its workspace
 * (`state/dirsource.ts`'s two implementations, goals/remote-env.md §3.9).
 *
 * Every method answers one question about ONE path; nothing here reads a
 * directory SPECULATIVELY (no walking ahead, no stat-every-child-of-every-
 * child) — a remote implementation pays a round trip per call, and a browser
 * that made more of them than a person's own clicks and keystrokes would be
 * slow for a reason nobody asked for.
 */
export interface DirSource {
  /**
   * `dir`'s subdirectories, or an empty list — a directory this source
   * cannot read is a shorter listing, never a thrown error (both
   * implementations follow the rule `browserRows` already lives by: a
   * listing that came back short still draws).
   */
  list(dir: string): Promise<DirChild[]>
  /** Whether `path` is itself a directory this source can see. */
  exists(path: string): Promise<boolean>
  /** How this source's filesystem joins a directory and one child's name. */
  join(dir: string, name: string): string
  /** This source's filesystem's parent of `dir` (its own fixed point at the root — same contract as `node:path`'s `dirname`). */
  dirname(dir: string): string
  /** The last component of a path, in this source's filesystem. */
  basename(path: string): string
  /**
   * What a typed line resolves to before it is checked against `exists` — the
   * local source expands `~` and drive letters (`expandPath`); a remote
   * source has no host environment to expand against, so it can only
   * recognise what already looks absolute to it and otherwise reads the
   * input as relative to `base`, the directory being browsed.
   */
  expand(input: string, base: string): string
}

/**
 * `resolveTyped`, for a source that can only answer "does this exist" over a
 * round trip. The same three-way read of a typed line — a trailing separator
 * or an empty line means "inside this one", already-exists means "this is
 * the place", otherwise the last segment is a filter on its parent — just
 * awaited, and every path operation routed through `source` rather than
 * `node:path` directly.
 */
export async function resolveTypedAsync(
  input: string,
  base: string,
  source: Pick<DirSource, "expand" | "exists" | "dirname" | "basename">,
): Promise<{ dir: string; filter: string }> {
  const raw = input.trim()
  const expanded = source.expand(raw, base)
  if (/[\\/]$/.test(raw) || raw.length === 0) return { dir: expanded, filter: "" }
  if (await source.exists(expanded)) return { dir: expanded, filter: "" }
  const parent = source.dirname(expanded)
  if (parent === expanded) return { dir: expanded, filter: "" }
  return { dir: parent, filter: source.basename(expanded) }
}

/**
 * What one browser screen shows for `input`, read through `source` — the
 * single function local and remote browsing both call, so "what does this
 * typed line mean" and "what is in this directory" cannot be answered two
 * different ways for the two machines (`ui/overlays/DirBrowser.tsx`).
 */
export async function browseAt(
  input: string,
  base: string,
  source: DirSource,
): Promise<{ dir: string; filter: string; children: DirChild[] }> {
  const resolved = await resolveTypedAsync(input, base, source)
  const children = await source.list(resolved.dir)
  return { ...resolved, children }
}
