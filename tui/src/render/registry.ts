/**
 * The ONE place that matches on a tool name or a shell command prefix.
 *
 * Everything else in `render/` receives a `ToolPresentation` and draws it. Two
 * reasons this is a single choke point: a name match scattered over a dozen
 * card components rots, and the same registry has to serve the live stream and
 * a replay (tui.md §3) — one decision, one place, both paths.
 *
 * The evolution table (tui.md §5.2) is the interesting half. `nulya …` through
 * `shell` is how the agent grows itself, so those calls get their own glyph,
 * accent and a head line with the facts already extracted. Extraction is always
 * best effort: a command this table cannot read falls back to the plain shell
 * presentation rather than failing (tui.md §5.2, "抽不到就退回 ShellCard").
 */
import { parseEditArgs } from "../nulya/diff.ts"
import type { Glyphs } from "./theme.ts"

export type AccentRole = "tool" | "evolve"
export type BodyKind = "diff" | "output"
/** Which card draws this call. Cards dispatch on this, never on the tool name. */
export type CardKind = "shell" | "edit" | "ext" | "evolve" | "subsession"

export interface ToolPresentation {
  kind: CardKind
  glyph: string
  /** Single-line head: what this call is, at a glance. */
  head: string
  accent: AccentRole
  body: BodyKind
  /** True when the card should carry the edit's unified diff. */
  isEdit: boolean
  /** Reading, not acting: the chip counts output lines instead of ok/exit. */
  countsLines: boolean
  /** A session this call names (tui.md §5.5); T3 makes it openable. */
  sessionId: string | null
}

/** Everything the registry is allowed to look at. */
export interface ToolView {
  tool: string
  args: string
  /**
   * The recorded result, when the call has one. Some head lines are only
   * knowable from stdout — the version `ext build` sealed, the id `session new`
   * printed — and the ledger keeps both halves, so replay reads the same facts.
   */
  output: string
}

function firstLine(text: string, limit: number): string {
  const line = text.split("\n", 1)[0] ?? ""
  return line.length > limit ? `${line.slice(0, limit - 1)}…` : line
}

export function shellCommandOf(argsJson: string): string | null {
  try {
    const value = JSON.parse(argsJson)
    if (value && typeof value === "object" && typeof (value as { command?: unknown }).command === "string") {
      return (value as { command: string }).command
    }
  } catch {
    // Arguments still streaming in, or malformed; the caller shows them raw.
  }
  return null
}

/** A one-line digest of arbitrary tool arguments: top-level keys, truncated. */
function argsSummary(argsJson: string, limit: number): string {
  try {
    const value = JSON.parse(argsJson)
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const parts = Object.entries(value as Record<string, unknown>).map(([key, entry]) => {
        const text = typeof entry === "string" ? entry : JSON.stringify(entry)
        return `${key}=${firstLine(text ?? "", 40)}`
      })
      return firstLine(parts.join(" "), limit)
    }
  } catch {
    // Fall through.
  }
  return firstLine(argsJson, limit)
}

/** Split a command line into words, respecting single and double quotes. */
function splitWords(command: string): string[] {
  const out: string[] = []
  let current = ""
  let quote: string | null = null
  let started = false
  for (const ch of command.trim()) {
    if (quote) {
      if (ch === quote) quote = null
      else current += ch
      continue
    }
    if (ch === "'" || ch === '"') {
      quote = ch
      started = true
      continue
    }
    if (/\s/.test(ch)) {
      if (started || current.length > 0) out.push(current)
      current = ""
      started = false
      continue
    }
    current += ch
  }
  if (started || current.length > 0) out.push(current)
  return out
}

function isNulya(word: string | undefined): boolean {
  if (!word) return false
  return word === "nulya" || /[\\/]nulya(\.exe)?$/i.test(word)
}

function baseName(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "")
  const at = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"))
  return at < 0 ? trimmed : trimmed.slice(at + 1)
}

/** Positional arguments: flags and their `--arg k=v` style values removed. */
function positionals(words: string[], flagsWithValue: readonly string[] = []): string[] {
  const out: string[] = []
  for (let i = 0; i < words.length; i++) {
    const word = words[i]!
    if (flagsWithValue.includes(word)) {
      i++
      continue
    }
    if (word.startsWith("-")) continue
    out.push(word)
  }
  return out
}

const session_id = /^s-[A-Za-z0-9._-]+$/

function make(part: Partial<ToolPresentation> & { glyph: string; head: string }): ToolPresentation {
  return {
    kind: "evolve",
    accent: "evolve",
    body: "output",
    isEdit: false,
    countsLines: false,
    sessionId: null,
    ...part,
  }
}

/** `nulya src [path]` → `⌕ read kernel · path`; the chip counts lines. */
function srcCard(words: string[], glyphs: Glyphs): ToolPresentation {
  const path = positionals(words.slice(2))[0]
  return make({
    glyph: glyphs.readKernel,
    head: `read kernel · ${path ?? "(tree)"}`,
    countsLines: true,
  })
}

function extCard(words: string[], output: string, glyphs: Glyphs): ToolPresentation | null {
  const verb = words[2]
  const rest = words.slice(3)
  switch (verb) {
    case "init": {
      const sealed = /^initialized (?:script )?extension '([^']+)' at (.+)$/m.exec(output)
      const id = sealed?.[1] ?? positionals(rest)[0] ?? "?"
      const where = sealed?.[2]
      return make({ glyph: glyphs.build, head: `ext init · ${id}${where ? ` → ${where}` : ""}` })
    }
    case "build": {
      // `<dir>: <version> (built|already built)` — id and version in one line.
      const sealed = /^(.+): (v-[0-9a-zA-Z]+) \((?:already )?built\)$/m.exec(output)
      const path = positionals(rest)[0]
      const id = sealed ? baseName(sealed[1]!) : path ? baseName(path) : "?"
      const version = sealed?.[2]
      return make({ glyph: glyphs.build, head: `ext build · ${id}${version ? ` → ${version}` : ""}` })
    }
    case "activate":
    case "rollback": {
      const args = positionals(rest)
      const id = args[0] ?? "?"
      const version = args[1]
      return make({
        glyph: verb === "activate" ? glyphs.capability : glyphs.rollback,
        head: `${verb} · ${id}${version ? `@${version}` : ""}`,
      })
    }
    case "deactivate":
      return make({ glyph: glyphs.rollback, head: `deactivate · ${positionals(rest)[0] ?? "?"}` })
    case "run": {
      // `ext run <id> [tool] (<json> | --arg k=v …)`: the JSON blob is the one
      // positional that is not a name, so a leading `{` ends the name list.
      const args = positionals(rest, ["--arg"]).filter((word) => !word.startsWith("{"))
      const id = args[0] ?? "?"
      const tool = args[1]
      return make({ glyph: glyphs.ext, head: `ext run · ${id}${tool ? `/${tool}` : ""}` })
    }
    case "list":
    case "inspect":
    case "api":
      return make({ glyph: glyphs.build, head: `ext ${verb}${rest.length > 0 ? ` · ${rest.join(" ")}` : ""}` })
    default:
      return null
  }
}

function skillCard(words: string[], glyphs: Glyphs): ToolPresentation | null {
  const verb = words[2]
  if (verb === "load") return make({ glyph: glyphs.skill, head: `skill · ${positionals(words.slice(3))[0] ?? "?"}` })
  if (verb === "list") return make({ glyph: glyphs.skill, head: "skill list", countsLines: true })
  return null
}

/**
 * `nulya session …` inside a step is the agent driving another session — the
 * sub-agent primitive (tui.md §5.5). v1 only makes it visible; the id comes
 * from the arguments, or for `session new` from what it printed.
 */
function sessionCard(words: string[], output: string, glyphs: Glyphs): ToolPresentation | null {
  const verb = words[2]
  if (verb === undefined) return null
  if (verb === "new") {
    const printed = output
      .split("\n")
      .map((line) => line.trim())
      .find((line) => session_id.test(line))
    return make({
      kind: "subsession",
      glyph: glyphs.subSession,
      head: `sub-session · ${printed ?? "(pending)"}`,
      sessionId: printed ?? null,
    })
  }
  if (verb !== "step" && verb !== "append" && verb !== "events" && verb !== "cancel") return null
  const id = positionals(words.slice(3), ["--file", "--since", "--max-steps"])[0] ?? null
  return make({
    kind: "subsession",
    glyph: glyphs.subSession,
    head: `sub-session ${verb} · ${id ?? "?"}`,
    sessionId: id && session_id.test(id) ? id : null,
  })
}

/** `nulya …` through shell is how the agent evolves itself — it reads differently. */
function evolvePresentation(command: string, output: string, glyphs: Glyphs): ToolPresentation | null {
  const words = splitWords(command)
  if (!isNulya(words[0])) return null
  switch (words[1]) {
    case "src":
      return srcCard(words, glyphs)
    case "ext":
      return extCard(words, output, glyphs)
    case "skill":
      return skillCard(words, glyphs)
    case "session":
      return sessionCard(words, output, glyphs)
    default:
      // `toolchain`, or a subcommand newer than this build: a plain shell card
      // is always correct, so nothing here can fail on an unknown verb.
      return null
  }
}

function shellPresentation(head: string, glyphs: Glyphs): ToolPresentation {
  return {
    kind: "shell",
    glyph: glyphs.shell,
    head,
    accent: "tool",
    body: "output",
    isEdit: false,
    countsLines: true,
    sessionId: null,
  }
}

export function describeTool(view: ToolView, glyphs: Glyphs): ToolPresentation {
  if (view.tool === "shell") {
    const command = shellCommandOf(view.args)
    if (command === null) return shellPresentation(firstLine(view.args, 200), glyphs)
    return evolvePresentation(command, view.output, glyphs) ?? shellPresentation(firstLine(command, 200), glyphs)
  }
  if (view.tool === "edit") {
    const args = parseEditArgs(view.args)
    return {
      kind: "edit",
      glyph: glyphs.edit,
      head: args ? args.path : firstLine(view.args, 200),
      accent: "tool",
      body: args ? "diff" : "output",
      isEdit: args !== null,
      countsLines: false,
      sessionId: null,
    }
  }
  // Anything else is an extension tool promoted onto the model's tool face
  // (DESIGN §5.1). The ledger records the tool NAME; `ext:<id>/<tool>` is the
  // stable id and only shows up if a caller passes one, so both are accepted.
  const name = view.tool.startsWith("ext:") ? (view.tool.split("/").pop() ?? view.tool) : view.tool
  const summary = argsSummary(view.args, 120)
  return {
    kind: "ext",
    glyph: glyphs.ext,
    head: summary.length > 0 && summary !== "{}" ? `${name || "tool"} · ${summary}` : name || "tool",
    accent: "tool",
    body: "output",
    isEdit: false,
    countsLines: false,
    sessionId: null,
  }
}
