/**
 * The one thing `/settings` writes: a single key in the user's `tui.toml`
 * (tui.md §1.2 D10, §11 T100).
 *
 * `tui.toml` is the person's file — hand-written, commented, ordered the way
 * they ordered it — so it is never re-serialised. What an edit does is find
 * the line that key is already on and replace it, or, when the key is not
 * there yet, add one line at the end of the table it belongs to. Everything
 * else in the file comes out byte for byte as it went in: comments, blank
 * lines, key order, the newline convention, and a trailing comment on the very
 * line being changed.
 *
 * This is `nulya/credentials.ts`'s discipline (a marked block appended to the
 * kernel's config, never a rewrite) carried to a file whose values are single
 * keys. The one thing it does NOT need is credentials.ts's marker comment: a
 * TOML name is unique within its table, so the key IS its own anchor and there
 * is nothing to find again. A marker is written in only one place — above a
 * table section that did not exist before — where it says who added it.
 *
 * WHY THIS DOES NOT MAKE A SECOND AUTHOR. There is one author, the person; the
 * screen is their pen. A minimal edit leaves the file the same document, so
 * "where does this value come from" still has one answer — the same file, the
 * same line, now saying something else.
 *
 * THE SCANNER IS SMALL, SO THE WRITE IS CHECKED. It knows comments, basic and
 * literal strings, and bracket depth — enough for every value this front end
 * writes and for the files people actually keep — and it does not know
 * multi-line `"""` strings. So `writeSetting` parses what it is about to write
 * and refuses unless the key really did come back with the intended value: a
 * settings file that no longer parses would take the whole screen's
 * configuration with it, and a wrong guess must cost nothing but a message.
 *
 * TWO MORE PROPERTIES, ADDED WHEN AN EXTERNAL REVIEW ASKED FOR THEM (T103).
 * The edit is patched against a FRESH re-read of `path`, taken immediately
 * before the replacement is constructed (`patchAgainstFreshest`) — which
 * shrinks, but does not close, the window in which a person's own editor
 * saving the file loses that save: an external write landing between that
 * re-read and the rename below is still overwritten. Concurrent external
 * writes are not serialized (a lock no editor would honour is not worth its
 * complexity); the re-read is a smaller window, not a guarantee. The write
 * itself IS atomic: the new text lands in a sibling temp file and is renamed
 * over `path`, so nobody watching the file — this process's own next
 * `loadSettings` included — ever sees it half-written.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

/** The values `/settings` can put in the file. A list is always a list of strings. */
export type TomlValue = string | number | boolean | string[]

const created_marker = "# nulya: added from /settings (edit or delete freely)"

/** A TOML basic string: only `\` and `"` have to be escaped. */
function quoted(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`
}

export function literalOf(value: TomlValue): string {
  if (typeof value === "boolean" || typeof value === "number") return String(value)
  if (typeof value === "string") return quoted(value)
  return `[${value.map(quoted).join(", ")}]`
}

/** Index just past the string starting at `at`; the line's end when it is unterminated. */
function endOfString(line: string, at: number): number {
  const quote = line[at]!
  let i = at + 1
  while (i < line.length) {
    const ch = line[i]!
    // Escapes exist in basic strings only; a literal string has none.
    if (quote === '"' && ch === "\\") {
      i += 2
      continue
    }
    if (ch === quote) return i + 1
    i++
  }
  return line.length
}

/**
 * One line of TOML from `from`, carrying `depth` open brackets in: how many are
 * open at the end of it, and where a comment begins outside any string.
 */
function scanLine(line: string, from: number, depth: number): { depth: number; comment: number | null } {
  let at = from
  let now = depth
  while (at < line.length) {
    const ch = line[at]!
    if (ch === "#") return { depth: now, comment: at }
    if (ch === '"' || ch === "'") {
      at = endOfString(line, at)
      continue
    }
    if (ch === "[" || ch === "{") now++
    else if (ch === "]" || ch === "}") now--
    at++
  }
  return { depth: now, comment: null }
}

/** The `=` of a `name = value` line, or -1 when the line is not one. */
function keyEq(line: string): number {
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]!
    if (ch === '"' || ch === "'") {
      i = endOfString(line, i) - 1
      continue
    }
    if (ch === "#") return -1
    if (ch === "=") return i
  }
  return -1
}

/**
 * The table a `[header]` line names — null for `[[an array of tables]]`, which
 * is never one of ours and must not be mistaken for the table of the same name.
 */
function headerName(trimmed: string): string | null {
  if (trimmed.startsWith("[[")) return null
  const close = trimmed.indexOf("]")
  return close < 0 ? null : trimmed.slice(1, close).trim()
}

/**
 * `text` with `<table>.<key>` set to `literal`: the line it is already on
 * replaced, else one line added at the end of that table, else a new table
 * section at the end of the file.
 *
 * A value spanning several lines (an array written out one entry per line) is
 * replaced as a whole, which is the one place a comment can be lost — a comment
 * INSIDE a value we are about to overwrite has nothing left to be about.
 */
export function placeSetting(text: string, table: string, key: string, literal: string): string {
  if (table.length === 0) throw new Error("a settings key belongs to a table")
  const nl = text.includes("\r\n") ? "\r\n" : "\n"
  const lines = text.length === 0 ? [] : text.split(/\r?\n/)

  // A key is only ours while the header in force names our table; `inTarget`
  // starts false because every key this front end writes lives under one.
  let inTarget = false
  let tableStart = -1
  /** The last line of the last VALUE in the target table: where a new key goes. */
  let lastValue = -1
  let keyStart = -1
  let keyEnd = -1
  let indent = ""
  let trailing = ""

  let i = 0
  while (i < lines.length) {
    const line = lines[i]!
    const trimmed = line.trim()
    if (trimmed.length === 0 || trimmed.startsWith("#")) {
      i++
      continue
    }
    if (trimmed.startsWith("[")) {
      const name = headerName(trimmed)
      inTarget = name === table
      if (inTarget && tableStart < 0) tableStart = i
      i++
      continue
    }
    const eq = keyEq(line)
    if (eq < 0) {
      // Not a shape this scanner understands; leave it exactly where it is.
      i++
      continue
    }
    let end = i
    let scan = scanLine(line, eq + 1, 0)
    while (scan.depth > 0 && end + 1 < lines.length) {
      end++
      scan = scanLine(lines[end]!, 0, scan.depth)
    }
    const name = line.slice(0, eq).trim().replace(/^["']|["']$/g, "")
    if (inTarget && name === key && keyStart < 0) {
      keyStart = i
      keyEnd = end
      indent = line.slice(0, line.length - line.trimStart().length)
      // A comment on the line being replaced is about this key and survives it
      // — with the spacing it was written with, since that is how a person
      // lines a column of comments up.
      if (scan.comment !== null) {
        const last = lines[end]!
        let from = scan.comment
        while (from > 0 && (last[from - 1] === " " || last[from - 1] === "\t")) from--
        trailing = last.slice(from).trimEnd()
        if (!trailing.startsWith(" ") && !trailing.startsWith("\t")) trailing = ` ${trailing}`
      }
    }
    if (inTarget) lastValue = end
    i = end + 1
  }

  const out = [...lines]
  const written = `${key} = ${literal}`
  if (keyStart >= 0) {
    out.splice(keyStart, keyEnd - keyStart + 1, `${indent}${written}${trailing}`)
    return out.join(nl)
  }
  if (tableStart >= 0) {
    // After the table's last value, so blank lines and the comments that
    // introduce whatever follows stay with what they were written for.
    out.splice((lastValue >= 0 ? lastValue : tableStart) + 1, 0, written)
    return out.join(nl)
  }
  while (out.length > 0 && out[out.length - 1]!.trim().length === 0) out.pop()
  if (out.length > 0) out.push("")
  out.push(created_marker, `[${table}]`, written, "")
  return out.join(nl)
}

/** The value at a dotted path in a parsed layer, or undefined. */
export function valueAt(layer: unknown, dotted: string): unknown {
  let at: unknown = layer
  for (const step of dotted.split(".")) {
    if (typeof at !== "object" || at === null) return undefined
    at = (at as Record<string, unknown>)[step]
  }
  return at
}

/** One layer of `tui.toml`, parsed — null when it is absent or unreadable. */
export function readLayer(path: string): Record<string, unknown> | null {
  if (!existsSync(path)) return null
  try {
    return Bun.TOML.parse(readFileSync(path, "utf8")) as Record<string, unknown>
  } catch {
    return null
  }
}

/** Does this layer set that key itself? (A nearer layer that does wins, §7.) */
export function layerSets(layer: Record<string, unknown> | null, dotted: string): boolean {
  return layer !== null && valueAt(layer, dotted) !== undefined
}

/**
 * The patch-and-validate half of `writeSetting`, with the disk read handed
 * in as a function (T103, an external review point).
 *
 * `read` is called TWICE on purpose: once to compute the edit, once more
 * right before it is accepted. Re-patching against a second, later answer
 * costs nothing (`placeSetting` is a pure function of the text it is given),
 * while committing against a copy that stopped being what is on disk would
 * silently drop whatever changed it — a person's own editor saving `tui.toml`
 * in the moment between the two, most concretely. The second answer always
 * wins when it differs. This is NOT a compare-and-swap: nothing re-checks at
 * the moment the rename lands, so a save arriving after the second read is
 * still lost. It narrows the window; the file-level comment says so.
 *
 * A seam rather than folded into `writeSetting` also because it is what
 * makes the race TESTABLE: a `read` that answers differently the second time
 * is a fake, not a timing accident to chase on a real filesystem.
 */
export function patchAgainstFreshest(
  read: () => string,
  table: string,
  key: string,
  value: TomlValue,
): string {
  const literal = literalOf(value)
  const first = read()
  let against = first
  let after = placeSetting(against, table, key, literal)
  const latest = read()
  if (latest !== first) {
    against = latest
    after = placeSetting(against, table, key, literal)
  }
  let parsed: unknown
  try {
    parsed = Bun.TOML.parse(after)
  } catch (err) {
    throw new Error(`would not parse after the edit (${err instanceof Error ? err.message : String(err)})`)
  }
  if (JSON.stringify(valueAt(parsed, `${table}.${key}`)) !== JSON.stringify(value)) {
    throw new Error(`${table}.${key} could not be edited in place; change it there by hand`)
  }
  return after
}

/**
 * Set one key in the file at `path`, creating it and its directory when
 * absent. Returns the text written; throws with the reason when it cannot,
 * which the screen shows as it stands.
 *
 * The write is ATOMIC: the new text lands in a sibling temp file in the same
 * directory (so the rename is same-volume, which is what makes it one
 * operation) and is renamed over `path`. A reader of `path` — this process's
 * own next `loadSettings`, or a person's editor watching the file — never
 * observes a half-written file; on Windows, `renameSync` replaces an
 * existing destination the same way POSIX `rename(2)` does.
 */
export function writeSetting(path: string, dotted: string, value: TomlValue): string {
  const cut = dotted.lastIndexOf(".")
  if (cut <= 0) throw new Error(`'${dotted}' is not a <table>.<key> name`)
  const table = dotted.slice(0, cut)
  const key = dotted.slice(cut + 1)
  const read = () => (existsSync(path) ? readFileSync(path, "utf8") : "")
  let after: string
  try {
    after = patchAgainstFreshest(read, table, key, value)
  } catch (err) {
    throw new Error(`${path}: ${err instanceof Error ? err.message : String(err)}`)
  }
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.tmp-${process.pid}-${Math.random().toString(36).slice(2, 8)}`
  writeFileSync(tmp, after)
  renameSync(tmp, path)
  return after
}
