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
export type BodyKind = "diff" | "output" | "markdown"
/** Which card draws this call. Cards dispatch on this, never on the tool name. */
export type CardKind = "shell" | "edit" | "ext" | "evolve" | "subsession" | "checklist" | "markdown"

export type ChecklistState = "todo" | "doing" | "done"
export interface ChecklistItem {
  text: string
  state: ChecklistState
}

/**
 * How a checklist item's state reads, in plain text (`ChecklistCard.tsx`,
 * `ui/PanelStrip.tsx` — the transcript card and the panel projection draw the
 * same convention, so the marker is written once). Not a new glyph: the
 * theme's glyph set is unicode/ascii dual (tui.md §6) and none of its
 * existing entries mean "todo" — these three read the same in both modes.
 */
export function checklistMarker(state: ChecklistState): string {
  if (state === "done") return "[x]"
  if (state === "doing") return "[~]"
  return "[ ]"
}

/** `done/total`, the chip both checklist presentations share. */
export function checklistChip(items: readonly ChecklistItem[]): string {
  return `${items.filter((item) => item.state === "done").length}/${items.length}`
}

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
  /** Present only when `kind === "checklist"`: the parsed `items` (D12). */
  checklist?: ChecklistItem[]
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

/**
 * A manifest's per-tool rendering claim, as far as the registry is concerned
 * (`ToolSpec.ui.render`, DESIGN §7.2.1, tui-plugin D12) — resolved by the CALLER
 * from the session's frozen composition (`ui/App.tsx`, since only it has both
 * the tool name and the composition to look it up in) and handed in here so
 * `describeTool` itself stays a pure function of "one call, one hint".
 */
export interface RenderHint {
  /** Absent or null: the package made no claim, or this call is not an extension tool at all. */
  render?: string | null
}

/**
 * `items: [{text, state}]` — the `"checklist"` convention (D12) — tried in the
 * call's ARGUMENTS first, then its recorded OUTPUT, because a checklist tool
 * might declare its plan up front (`todo{items}`) or only know it once it has
 * run. Anything that does not match this exact shape is not a checklist as far
 * as this reader is concerned, and the caller falls back to a plain card.
 */
function parseChecklist(json: string): ChecklistItem[] | null {
  let value: unknown
  try {
    value = JSON.parse(json)
  } catch {
    return null
  }
  if (typeof value !== "object" || value === null) return null
  const items = (value as Record<string, unknown>)["items"]
  if (!Array.isArray(items) || items.length === 0) return null
  const parsed: ChecklistItem[] = []
  for (const raw of items) {
    if (typeof raw !== "object" || raw === null) return null
    const record = raw as Record<string, unknown>
    const text = record["text"]
    const state = record["state"]
    if (typeof text !== "string") return null
    if (state !== "todo" && state !== "doing" && state !== "done") return null
    parsed.push({ text, state })
  }
  return parsed
}

function checklistOf(view: ToolView): ChecklistItem[] | null {
  return parseChecklist(view.args) ?? (view.output.length > 0 ? parseChecklist(view.output) : null)
}

function firstLine(text: string, limit: number): string {
  const line = text.split("\n", 1)[0] ?? ""
  return line.length > limit ? `${line.slice(0, limit - 1)}…` : line
}

/**
 * Whether this `shell` call was launched with `background: true` (DESIGN §6.1).
 *
 * Read from the ARGUMENTS, not from the result: it is true from the moment the
 * call is complete and stays true, where the receipt only exists once the call
 * has returned. Which matters because it decides which card draws it.
 */
export function isBackground(argsJson: string): boolean {
  try {
    const value = JSON.parse(argsJson)
    return Boolean(value && typeof value === "object" && (value as { background?: unknown }).background === true)
  } catch {
    // Still streaming, or malformed: not a background launch as far as anyone
    // can tell yet, and the head line is the same either way.
    return false
  }
}

/**
 * The `agent` tool's call, and the session its receipt named (tui.md §5.10).
 *
 * A delegation IS a sub-session, so it gets that glyph and that accent — and the
 * id comes from the receipt rather than from the arguments, because the session
 * does not exist until the call returns. Same shape as `nulya session new`
 * through `shell` two functions down: the ledger keeps both halves, so a replay
 * reads the same fact.
 */
function agentNameOf(argsJson: string): string | null {
  try {
    const value = JSON.parse(argsJson)
    if (value && typeof value === "object" && typeof (value as { name?: unknown }).name === "string") {
      return (value as { name: string }).name
    }
  } catch {
    // Still streaming, or malformed: the head line says so rather than guessing.
  }
  return null
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

/**
 * A one-line digest of arbitrary tool arguments.
 *
 * A `{path, offset?, limit?}` object is a common file-target shape, so it reads
 * as one target (`src/a.ts:10-14`) without naming the plumbing keys. Everything
 * else follows the generic rule: first string argument bare, later arguments
 * keyed, because the TUI cannot know a package's domain vocabulary.
 */
function argsSummary(argsJson: string, limit: number): string {
  try {
    const value = JSON.parse(argsJson)
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const record = value as Record<string, unknown>
      const path = pathArgsSummary(record)
      if (path !== null) return firstLine(path, limit)
      const parts = Object.entries(record).map(([key, entry], index) => {
        const text = typeof entry === "string" ? entry : JSON.stringify(entry)
        const written = firstLine(text ?? "", 40)
        return index === 0 && typeof entry === "string" ? written : `${key}=${written}`
      })
      return firstLine(parts.join(" · "), limit)
    }
  } catch {
    // Fall through.
  }
  return firstLine(argsJson, limit)
}

function numberArg(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value)
  if (typeof value === "string" && /^\d+$/.test(value)) return Number(value)
  return null
}

/** Common file-target convention, not a tool-name rule: `{path, offset?, limit?}`. */
function pathArgsSummary(record: Record<string, unknown>): string | null {
  const path = record["path"]
  if (typeof path !== "string" || path.length === 0) return null
  const offset = numberArg(record["offset"])
  const limit = numberArg(record["limit"])
  const target = path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(path) ? baseName(path) : path
  if (offset !== null && limit !== null && limit > 0) return `${target}:${offset}-${offset + limit - 1}`
  if (offset !== null) return `${target}:${offset}`
  return target
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
    case "activate": {
      const args = positionals(rest)
      const id = args[0] ?? "?"
      const version = args[1]
      return make({ glyph: glyphs.capability, head: `activate · ${id}${version ? `@${version}` : ""}` })
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
  // Reading the store and judging a session are not sub-sessions: nothing is
  // driven, and one of them is the slow loop's only write (DESIGN §3.3). They
  // still read as evolution — this is the agent looking at its own history.
  if (verb === "list") return make({ glyph: glyphs.readKernel, head: "sessions", countsLines: true })
  if (verb === "outcome") {
    const args = positionals(words.slice(3), ["--note"])
    return make({
      glyph: glyphs.capability,
      head: `outcome · ${args[1] ?? "?"}${args[0] ? ` · ${args[0]}` : ""}`,
      sessionId: args[0] && session_id.test(args[0]) ? args[0] : null,
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

export function describeTool(view: ToolView, glyphs: Glyphs, hint: RenderHint = {}): ToolPresentation {
  if (view.tool === "shell") {
    const command = shellCommandOf(view.args)
    if (command === null) return shellPresentation(firstLine(view.args, 200), glyphs)
    // A background launch is not the action its command names: the call returns
    // a receipt, and what the command DID is a separate event later (tui.md
    // §5.9). So `nulya ext build … background: true` keeps the plain shell card,
    // whose note is about the task rather than about a version that does not
    // exist yet.
    if (isBackground(view.args)) return shellPresentation(firstLine(command, 200), glyphs)
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
  // Matching the BARE name is deliberate, not an oversight. What reaches here is
  // `ledger.ToolCall.tool`, and the kernel records the model-facing name there —
  // which package it came from is in the session header, not in the call
  // (`toolId` in `App.tsx` is the one place that joins them, and it needs the
  // tab's frozen composition to do it). Threading that through the transcript so
  // this card could insist on `ext:agent/agent` would be a new pipeline for one
  // glyph; the cost of not having it is that a third-party tool also named
  // `agent` draws a sub-session card, which is a wrong picture and not a wrong
  // action. The stable id is accepted too, for a caller that has one.
  if (view.tool === "agent" || view.tool === "ext:agent/agent") {
    const named = view.output.split("\n").map((line) => session_id.exec(line.trim())?.[0]).find(Boolean) ??
      /\bs-[A-Za-z0-9._-]+\b/.exec(view.output)?.[0] ??
      null
    return make({
      kind: "subsession",
      glyph: glyphs.subSession,
      head: `agent · ${agentNameOf(view.args) ?? "(pending)"}${named ? ` → ${named}` : ""}`,
      sessionId: named,
    })
  }
  // Anything else is an extension tool promoted onto the model's tool face
  // (DESIGN §5.1). The ledger records the tool NAME; `ext:<id>/<tool>` is the
  // stable id and only shows up if a caller passes one, so both are accepted.
  const name = view.tool.startsWith("ext:") ? (view.tool.split("/").pop() ?? view.tool) : view.tool
  const summary = argsSummary(view.args, 120)
  const head = summary.length > 0 && summary !== "{}" ? `${name || "tool"} · ${summary}` : name || "tool"
  // The manifest's own rendering claim (D12), only reachable here — shell,
  // edit and the sub-session presentations above are kernel-recognised
  // commands, never a package's declared tool, so they carry no such hint.
  switch (hint.render) {
    case "checklist": {
      const items = checklistOf(view)
      // The convention's shape ("items: [{text, state}]") did not match: fall
      // through to the plain card below rather than draw an empty checklist.
      if (items) {
        return {
          kind: "checklist",
          glyph: glyphs.ext,
          head,
          accent: "tool",
          body: "output",
          isEdit: false,
          countsLines: false,
          sessionId: null,
          checklist: items,
        }
      }
      break
    }
    case "markdown":
      return {
        kind: "markdown",
        glyph: glyphs.ext,
        head,
        accent: "tool",
        body: "markdown",
        isEdit: false,
        countsLines: false,
        sessionId: null,
      }
    case undefined:
    case null:
      break
    default:
      // A word this build does not recognise (D12: the vocabulary is open, and
      // an unknown entry is the reader's decision, never a build refusal) — the
      // plain card below is exactly right, and there is nothing further to say
      // that a person reading the transcript needs to see.
      break
  }
  return {
    kind: "ext",
    glyph: glyphs.ext,
    head,
    accent: "tool",
    body: "output",
    isEdit: false,
    countsLines: false,
    sessionId: null,
  }
}
