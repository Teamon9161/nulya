/**
 * `edit` tool arguments → a unified diff string for OpenTUI's `diff` component.
 *
 * The kernel's `edit` is an exact-string transaction (`{path, old_string,
 * new_string, replace_all?}`, DESIGN §6.2), so the only thing the ledger knows
 * about the change is those two strings. The line numbers in the hunk header
 * are therefore relative to the replaced fragment, not to the file: the diff is
 * a faithful picture of the transaction, and inventing file offsets would be a
 * second source of truth the TUI is not allowed to have.
 */

export interface EditArgs {
  path: string
  old_string: string
  new_string: string
  replace_all: boolean
}

export function parseEditArgs(argsJson: string): EditArgs | null {
  let value: unknown
  try {
    value = JSON.parse(argsJson)
  } catch {
    return null
  }
  if (typeof value !== "object" || value === null) return null
  const record = value as Record<string, unknown>
  const path = record["path"]
  const old_string = record["old_string"]
  const new_string = record["new_string"]
  if (typeof path !== "string" || typeof old_string !== "string" || typeof new_string !== "string") return null
  return { path, old_string, new_string, replace_all: record["replace_all"] === true }
}

type Op = { tag: " " | "-" | "+"; text: string }

/** Longest-common-subsequence line diff. Edit fragments are small by design. */
function lineOps(before: string[], after: string[]): Op[] {
  const n = before.length
  const m = after.length
  const table: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      const row = table[i]!
      const next = table[i + 1]!
      row[j] = before[i] === after[j] ? next[j + 1]! + 1 : Math.max(next[j]!, row[j + 1]!)
    }
  }
  const ops: Op[] = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (before[i] === after[j]) {
      ops.push({ tag: " ", text: before[i]! })
      i++
      j++
    } else if (table[i + 1]![j]! >= table[i]![j + 1]!) {
      ops.push({ tag: "-", text: before[i]! })
      i++
    } else {
      ops.push({ tag: "+", text: after[j]! })
      j++
    }
  }
  while (i < n) ops.push({ tag: "-", text: before[i++]! })
  while (j < m) ops.push({ tag: "+", text: after[j++]! })
  return ops
}

function splitLines(text: string): string[] {
  const lines = text.split("\n")
  // A trailing newline produces one empty trailing element; it is not a line.
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop()
  return lines
}

/** Render the edit as a unified diff. Returns "" when nothing changed. */
export function unifiedDiff(args: EditArgs): string {
  const before = splitLines(args.old_string)
  const after = splitLines(args.new_string)
  const ops = lineOps(before, after)
  if (!ops.some((op) => op.tag !== " ")) return ""
  const body = ops.map((op) => `${op.tag}${op.text}`).join("\n")
  return [
    `--- a/${args.path}`,
    `+++ b/${args.path}`,
    `@@ -1,${before.length} +1,${after.length} @@`,
    body,
    "",
  ].join("\n")
}

export function diffStats(args: EditArgs): { added: number; removed: number } {
  const ops = lineOps(splitLines(args.old_string), splitLines(args.new_string))
  let added = 0
  let removed = 0
  for (const op of ops) {
    if (op.tag === "+") added++
    else if (op.tag === "-") removed++
  }
  return { added, removed }
}

/** Guess a `filetype` for syntax highlighting from the edited path. */
export function filetypeOf(path: string): string | undefined {
  const dot = path.lastIndexOf(".")
  if (dot < 0) return undefined
  const ext = path.slice(dot + 1).toLowerCase()
  const map: Record<string, string> = {
    zig: "zig",
    ts: "typescript",
    tsx: "typescriptreact",
    js: "javascript",
    jsx: "javascriptreact",
    json: "json",
    md: "markdown",
    toml: "toml",
    yaml: "yaml",
    yml: "yaml",
    sh: "bash",
    py: "python",
    rs: "rust",
    go: "go",
    c: "c",
    h: "c",
    cpp: "cpp",
    css: "css",
    html: "html",
  }
  return map[ext]
}
