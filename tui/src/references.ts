/**
 * `@path` references in the composer (tui.md §11, T13).
 *
 * Everything about matching — where a token starts, which characters belong to
 * it, how candidates are ranked — is ported from tcode's `composer.rs`
 * (`reference_boundary` / `reference_token_char` / `reference_score` /
 * `reference_match_order`), constant for constant. That interaction has been
 * used for a long time and its edge cases (an email address is not a reference,
 * root files outrank descendants, a basename prefix beats a path prefix) were
 * all learned rather than designed; re-deriving them here would only re-learn
 * them.
 *
 * The one deliberate divergence is what happens on submit (goals/tui-panel.md
 * D5): the `@path` goes into the ledger as TEXT and the file's contents do not.
 * tcode expands references into their own content blocks, which saves a
 * round-trip and is a real gain — but nulya's ledger is append-only and its
 * sessions are long-lived (fork, compaction), so an injected snapshot would sit
 * in the prefix forever, be paid for every step, and go stale. The model has
 * `read`, whose freshness journal makes a re-read cheap, and the path is the
 * part it actually needs.
 */
import { existsSync, readdirSync, statSync } from "node:fs"
import { join } from "node:path"

export type ReferenceKind = "file" | "directory"

export interface ReferenceCandidate {
  /** Always slash-separated, relative to the workspace. */
  path: string
  kind: ReferenceKind
}

/** tcode `MAX_INDEX_ENTRIES`: a bound, so a monorepo cannot stall the composer. */
export const max_index_entries = 20_000

/** How long an index is used before `@` asks for a fresh one, in the background. */
export const index_stale_ms = 30_000

/**
 * Directories that are never useful `@` candidates even outside a repository
 * with an ignore file. The same table the std extension's walker uses
 * (`extensions/std/src/walk.zig`), which is itself tcode's.
 */
export const prune_dirs = new Set([
  ".git",
  ".svn",
  ".hg",
  ".bzr",
  ".jj",
  ".sl",
  "node_modules",
  "target",
  "dist",
  "build",
  "zig-cache",
  "zig-out",
  ".zig-cache",
  ".venv",
  "venv",
  "__pycache__",
  ".pytest_cache",
  ".mypy_cache",
  ".ruff_cache",
  ".tox",
  ".nox",
  ".cargo",
  ".rustup",
  ".cache",
  ".npm",
  ".pnpm-store",
  ".yarn",
  ".gradle",
  ".m2",
  ".next",
  ".nuxt",
  ".svelte-kit",
  ".turbo",
  ".parcel-cache",
  "AppData",
])

// --- the token ---------------------------------------------------------------

/**
 * An `@` only opens a reference at a word boundary — which is exactly what
 * keeps `me@example.com` from turning half an address into a file menu.
 */
export function referenceBoundary(chars: readonly string[], at: number): boolean {
  if (at === 0) return true
  const before = chars[at - 1]!
  return !/[\p{L}\p{N}]/u.test(before) && before !== "_"
}

/** tcode `reference_token_char`: what may appear in an unquoted `@token`. */
export function referenceTokenChar(c: string): boolean {
  return !/\s/.test(c) && !"@`\"'()[]{},;:".includes(c)
}

/**
 * How well `path` answers `query`, lower being better, null being "not at all".
 *
 * Three tiers, tcode's: a basename prefix (0) is what someone typing `comp`
 * means; a path prefix (1) is the next most literal reading; anything else is a
 * subsequence scored by the gaps it had to jump (10+), so `tuiapp` still finds
 * `crates/tcode-tui/src/app.rs` but never outranks a real prefix.
 */
export function referenceScore(rawPath: string, rawQuery: string): number | null {
  const path = rawPath.toLowerCase()
  const query = rawQuery.toLowerCase()
  if (query.length === 0) return 0
  const basename = referenceBasename(path)
  if (basename.startsWith(query)) return 0
  if (path.startsWith(query)) return 1
  let next = 0
  let gaps = 0
  for (const wanted of query) {
    const found = path.indexOf(wanted, next)
    if (found < 0) return null
    gaps += found - next
    next = found + wanted.length
  }
  return 10 + gaps
}

/**
 * Root-level files outrank matching descendants before the score applies: when
 * a repository has `Cargo.toml` and `src/Cargo.toml`, the one at the top is the
 * one somebody typing `cargo` almost always means.
 */
export function referenceMatchOrder(
  leftScore: number,
  leftPath: string,
  rightScore: number,
  rightPath: string,
): number {
  const depth = Number(leftPath.includes("/")) - Number(rightPath.includes("/"))
  if (depth !== 0) return depth
  if (leftScore !== rightScore) return leftScore - rightScore
  return leftPath < rightPath ? -1 : leftPath > rightPath ? 1 : 0
}

export function referenceBasename(path: string): string {
  const at = path.lastIndexOf("/")
  return at < 0 ? path : path.slice(at + 1)
}

/** A path with a space in it has to be quoted, or the token ends at the space. */
export function referenceMarker(path: string): string {
  return /\s/.test(path) ? `@"${path}"` : `@${path}`
}

export function candidatePath(candidate: ReferenceCandidate): string {
  return candidate.kind === "directory" ? `${candidate.path}/` : candidate.path
}

/** tcode `format_bytes`, for the size beside a file candidate. */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`
}

export interface ActiveReference {
  /** Character offsets of the whole `@token`, replacement bounds. */
  start: number
  end: number
  /** What has been typed after the `@` (and the opening quote), up to the cursor. */
  query: string
}

/**
 * The `@token` the cursor is inside, if any — the whole trigger.
 *
 * Scans back from the cursor for an `@` at a boundary, then forward for the end
 * of the token, quoted or not. The cursor has to be within the typed part: past
 * the end of the token it is no longer completing it, which is what lets a
 * finished `@src/app.ts more words` stop opening a menu.
 */
export function activeReference(text: string, cursor: number): ActiveReference | null {
  const chars = [...text]
  const at = Math.min(cursor, chars.length)
  let start = -1
  for (let i = at - 1; i >= 0; i--) {
    const c = chars[i]!
    if (c === "@" && referenceBoundary(chars, i)) {
      start = i
      break
    }
    // A quoted reference may hold spaces; an unquoted one cannot, so anything
    // that could not be in the token means there is no token here.
    if (!referenceTokenChar(c) && c !== '"' && c !== " ") return null
  }
  if (start < 0) return null

  const quoted = chars[start + 1] === '"'
  const contentStart = start + 1 + (quoted ? 1 : 0)
  let end = contentStart
  if (quoted) {
    while (end < chars.length && chars[end] !== '"') end += 1
    if (end < chars.length) end += 1
  } else {
    while (end < chars.length && referenceTokenChar(chars[end]!)) end += 1
  }
  if (at < contentStart || at > end) return null
  return { start, end, query: chars.slice(contentStart, Math.min(at, end)).join("") }
}

export interface ReferenceMatch {
  /** What goes in the box: `@path`, quoted when it has to be. */
  replacement: string
  /** What the menu shows — a basename, unless two candidates share one. */
  label: string
  description: string
}

/**
 * The best candidates for `query`, tcode's ranking and its eight-row menu.
 *
 * A basename is shown rather than a path because that is what was typed; the
 * exception is a basename two candidates share, where showing `app.ts` twice
 * would make the menu unusable, so both get their full path.
 */
export function referenceCompletions(
  index: readonly ReferenceCandidate[],
  query: string,
  limit = 8,
  sizeOf?: (candidate: ReferenceCandidate) => number | null,
): ReferenceMatch[] {
  const scored: { score: number; candidate: ReferenceCandidate }[] = []
  for (const candidate of index) {
    const score = referenceScore(candidate.path, query)
    if (score !== null) scored.push({ score, candidate })
  }
  scored.sort((a, b) => referenceMatchOrder(a.score, a.candidate.path, b.score, b.candidate.path))

  const shared = new Map<string, number>()
  for (const { candidate } of scored) {
    const name = referenceBasename(candidate.path)
    shared.set(name, (shared.get(name) ?? 0) + 1)
  }

  return scored.slice(0, limit).map(({ candidate }) => {
    const path = candidatePath(candidate)
    const ambiguous = (shared.get(referenceBasename(candidate.path)) ?? 0) > 1
    const label = ambiguous
      ? path
      : candidate.kind === "directory"
        ? `${referenceBasename(candidate.path)}/`
        : referenceBasename(candidate.path)
    const bytes = candidate.kind === "file" ? (sizeOf?.(candidate) ?? null) : null
    return {
      replacement: referenceMarker(path),
      label: referenceMarker(label),
      description: candidate.kind === "file" ? `file${bytes === null ? "" : ` · ${formatBytes(bytes)}`}` : "directory",
    }
  })
}

/**
 * The character ranges of `@markers` that name something in the index —
 * the accent in the input box (tcode `input_spans` / `known_reference_marker`).
 *
 * Only KNOWN references light up. An `@` in front of an unrecognised word is
 * ordinary prose and stays that way, which is what makes the accent mean
 * something: it says "this one resolves", not "you typed an at-sign".
 */
export function knownReferenceRanges(
  text: string,
  index: readonly ReferenceCandidate[],
): { start: number; end: number }[] {
  const known = new Set(index.map((candidate) => candidate.path))
  const chars = [...text]
  const ranges: { start: number; end: number }[] = []
  let index_ = 0
  while (index_ < chars.length) {
    if (chars[index_] !== "@" || !referenceBoundary(chars, index_)) {
      index_ += 1
      continue
    }
    let end = index_ + 1
    if (chars[end] === '"') {
      end += 1
      while (end < chars.length && chars[end] !== '"') end += 1
      if (end < chars.length) end += 1
    } else {
      while (end < chars.length && referenceTokenChar(chars[end]!)) end += 1
    }
    const marker = chars.slice(index_, end).join("")
    const raw = marker.startsWith('@"') && marker.endsWith('"') ? marker.slice(2, -1) : marker.slice(1)
    if (raw.length > 0 && (known.has(raw) || known.has(raw.replace(/\/$/, "")))) {
      ranges.push({ start: index_, end })
    }
    index_ = end > index_ ? end : index_ + 1
  }
  return ranges
}

// --- the index ---------------------------------------------------------------

/**
 * Every path the workspace offers, bounded.
 *
 * `git ls-files --cached --others --exclude-standard` is the whole listing in a
 * repository: it is the ignore semantics, exactly, without a second
 * implementation of `.gitignore` living here. Outside a repository the fallback
 * is a small walk with the prune table — enough for a scratch directory, and
 * never the place where correctness is decided.
 */
export async function indexProject(dir: string): Promise<ReferenceCandidate[]> {
  const files = (await gitFiles(dir)) ?? walkFiles(dir)
  return withDirectories(files.slice(0, max_index_entries))
}

async function gitFiles(dir: string): Promise<string[] | null> {
  try {
    const proc = Bun.spawn({
      cmd: ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
      cwd: dir,
      stdout: "pipe",
      stderr: "ignore",
    })
    const [text, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited])
    if (code !== 0) return null
    return text.split("\0").filter((path) => path.length > 0)
  } catch {
    // No git on this machine, or not a repository: the walk answers instead.
    return null
  }
}

function walkFiles(dir: string): string[] {
  const out: string[] = []
  const queue: string[] = [""]
  while (queue.length > 0 && out.length < max_index_entries) {
    const relative = queue.shift()!
    let entries
    try {
      entries = readdirSync(join(dir, relative), { withFileTypes: true })
    } catch {
      continue
    }
    for (const entry of entries) {
      const path = relative.length === 0 ? entry.name : `${relative}/${entry.name}`
      if (entry.isDirectory()) {
        if (!prune_dirs.has(entry.name)) queue.push(path)
      } else if (entry.isFile()) {
        if (out.length >= max_index_entries) break
        out.push(path)
      }
    }
  }
  return out
}

/**
 * Directories are not listed by `git ls-files`, so they are derived from the
 * file paths — which also means a directory only appears when it holds
 * something the index would offer.
 */
export function withDirectories(files: readonly string[]): ReferenceCandidate[] {
  const dirs = new Set<string>()
  for (const path of files) {
    let at = path.indexOf("/")
    while (at >= 0) {
      dirs.add(path.slice(0, at))
      at = path.indexOf("/", at + 1)
    }
  }
  const candidates: ReferenceCandidate[] = [
    ...files.map((path): ReferenceCandidate => ({ path, kind: "file" })),
    ...[...dirs].map((path): ReferenceCandidate => ({ path, kind: "directory" })),
  ]
  return candidates.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))
}

/**
 * One index per workspace, rebuilt in the background when it goes stale.
 *
 * Never awaited by a keystroke: the first `@` before the first build finishes
 * shows nothing and the next one shows everything, which is the right trade
 * against a composer that stops accepting characters while git walks a
 * monorepo.
 */
export interface ProjectIndex {
  candidates(): readonly ReferenceCandidate[]
  /** Note that the index is being looked at; refresh it if it has gone stale. */
  touch(): void
  size(candidate: ReferenceCandidate): number | null
}

export function createProjectIndex(dir: string, staleMs = index_stale_ms): ProjectIndex {
  let candidates: ReferenceCandidate[] = []
  let builtAt = 0
  let building = false

  const build = () => {
    if (building) return
    building = true
    void indexProject(dir)
      .then((next) => {
        candidates = next
        builtAt = Date.now()
      })
      .catch(() => {
        // An index that could not be built is an empty menu, never a crash.
      })
      .finally(() => {
        building = false
      })
  }

  build()
  return {
    candidates: () => candidates,
    touch: () => {
      if (Date.now() - builtAt > staleMs) build()
    },
    size: (candidate) => {
      if (candidate.kind !== "file") return null
      const path = join(dir, candidate.path)
      try {
        return existsSync(path) ? statSync(path).size : null
      } catch {
        return null
      }
    },
  }
}
