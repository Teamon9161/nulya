/**
 * `tui.toml` (tui.md §7): user layer, then project layer, then defaults.
 *
 * Deliberately NOT part of the kernel's config chain — the kernel has no
 * business knowing a fold default (tui.md §1.2 D4). The paths mirror it so
 * "where does settings live" still has one answer.
 */
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { default_rules, modes, normalizeMode, type ApprovalRules, type PermissionMode } from "../approvals.ts"
import type { EnvProfileOverride, EnvProfiles } from "./envprofile.ts"
import { code_theme_names, type CodeThemeName } from "../render/syntax.ts"
import type { TomlValue } from "./settingsfile.ts"

export type FoldDefault = "expanded" | "collapsed"
/**
 * `hidden` is the default (T43). Reasoning is not something the model SAID and
 * not something it DID — it is the provider's own scratch, kept in the ledger
 * for replay (DESIGN §3.1) — and a collapsed card for it still spends a head
 * line, a glyph and a fold marker on every single answer, directly above the
 * answer. What that line was doing for a reader is said better by the status
 * line, which reads `thinking` while the model is in exactly that state (T38).
 *
 * Nothing is lost and nothing is decided for anybody: the reasoning is in the
 * ledger either way, and `transcript.thinking = "collapsed"` brings the card
 * back for whoever wants it.
 */
export type ThinkingDefault = "expanded" | "collapsed" | "hidden"

export interface Settings {
  transcript: {
    diff: FoldDefault
    tool_output: FoldDefault
    thinking: ThinkingDefault
    /**
     * The composition card at the top of a session (tui.md §5.1). Collapsed by
     * default: what it says at rest — model and counts — is what changes what
     * the session can do; the extension versions under it are provenance, and
     * provenance does not earn a fifth of the screen on every session.
     */
    composition: FoldDefault
    /**
     * Gather a run of finished, successful, bodyless calls into one line
     * (T43, `render/runs.ts`). On by default: a model that reads eleven files
     * before answering should not push what it SAID off the screen.
     *
     * Off restores one row per call. It is a boolean and not a fold default
     * because "summarised but open" and "not summarised" differ by one row of
     * heading — there is no third thing to say.
     */
    run_summary: boolean
    max_width: number
    ascii: boolean
    /**
     * How many transcript items are mounted at once, counting from the newest.
     * 0 draws everything. The whole session is always in the ledger file; this
     * only bounds what the renderer has to lay out on every frame, which is what
     * keeps a long session's typing latency flat (tui.md §11, T4).
     */
    history_window: number
    /**
     * How often a streaming assistant turn's markdown may be re-rendered, in
     * milliseconds. 0 renders every delta, which is what this used to do.
     *
     * A markdown document is re-parsed and re-laid-out whole on every content
     * change, and OpenTUI keeps the TRAILING block unstable while `streaming`
     * is set (its own documented semantics — only the blocks before it are
     * reused). A report that has not reached its first blank line yet IS that
     * one trailing block, so every delta re-lays-out the whole answer, and in a
     * sticky-bottom scrollbox every height change moves the screen. That is the
     * flicker (BUGS.md #21).
     *
     * Sampling the text instead of following it is the cheap half of the fix:
     * it does not stop the trailing block from being unstable, it stops us from
     * looking at it thirty times a second. The alternative — splitting the text
     * at the last closed block ourselves — is a markdown parser of our own, for
     * a problem that is really about frequency.
     *
     * The last delta is never held back: `streaming` going false flushes
     * immediately, so what settles on screen is always the whole turn.
     */
    stream_interval_ms: number
  }
  ui: {
    theme: "nulya-dark" | "nulya-light"
    /**
     * What fenced code is coloured with (`render/syntax.ts`). `auto` — the
     * default — is the palette that goes with the interface theme; `theme`
     * is the old behaviour, code drawn in the interface's own accents.
     */
    code_theme: CodeThemeName
    motion: boolean
  }
  extensions: {
    /**
     * Build the drafts in the store roots when the TUI opens (tui.md §11, T11).
     * On by default because "the source is there and nothing built it" is never
     * what anyone wanted; the user store runs in the background, and the
     * project store is gated by the trust question, which no setting can skip.
     */
    sync_on_start: boolean
    /**
     * Let that pass move `current` onto what it just built. It never moves a
     * pointer that names something else (DESIGN §7.2), so a rollback survives
     * this being on.
     */
    auto_activate: boolean
    /**
     * The packages every TOP-LEVEL session this TUI starts is composed with:
     * `--with <id>@<v>`. Tools in those packages that declare `surface:"auto"`
     * reach the model face through membership; they are not written as pins.
     * One list where there used to be one boolean per package (T34) — "which
     * packages" is a list-shaped question, and a new one should not need a new
     * key and a new branch in `App.tsx`.
     *
     * This is the FRONT END's list, and a package can now say the same thing
     * for itself: `apply: "auto"` in its manifest makes the kernel compose it
     * into every fresh session, whatever is driving (DESIGN §5.1). This key
     * stays for the other direction — composing a package that did NOT ask,
     * and doing it only here.
     *
     * Both defaults earn their place. `handoff`'s tool only ever WRITES A FILE
     * proposing a handover (DESIGN §11) — the fork is this front end's move and
     * it still asks first in `ask` mode. `agent` ships four personas, so there
     * is always something to delegate to, and a delegation is a background task
     * the model can only ASK for; every tool call inside it still meets the gate.
     *
     * TOP-LEVEL only, and that is load-bearing for `agent`: a delegated session
     * composes itself (DESIGN §7.8), so this list never reaches one.
     */
    session_with: string[]
    /**
     * Packages asked to RENDER this session's opening text: each one's internal
     * `render` tool is run just before `session new`, and what it answers goes
     * to `--prompt` (`sessionprompt.ts`).
     *
     * A list and not a boolean, and a sibling of `session_with` rather than a
     * special case beside it. These packages are not members — nothing about
     * them is composed into the session; what lands there is the FILE they
     * wrote, with a one-session lifetime, which is the side of the line
     * `--prompt` serves (`docs/goals/session-prompt.md`).
     *
     * The bundled `ground` reports where the session is running: project
     * layout, the project's own instruction files, environment, git state.
     */
    session_prompts: string[]
    /**
     * The CODE layer's one switch (tui-plugin U3): whether a trusted, active
     * package's `contributes.ui` module is loaded into this process at all.
     *
     * `false` leaves the declaration layer exactly as U2 left it — commands,
     * policy, `render`/`panel` hints all still work, because those are JSON a
     * package wrote and any driver can read. What it turns off is the half
     * where a package ships TypeScript that runs here.
     *
     * On by default, because loading is already gated by the one boundary this
     * decision has: an extension's code runs on this machine the moment
     * anybody calls `ext run`, and the trust gate (DESIGN §9) is where that was
     * decided (tui-plugin D4). Off is for somebody who wants the screen to be
     * only ever the screen — and per package, the switch is `/ext`'s own: a
     * package that is not active and not worn is never loaded.
     */
    plugins: boolean
  }
  /**
   * Per exec-target-KIND overrides of `session_with` / `session_prompts` /
   * pins (`tui.toml` `[env.local]` / `[env.wsl]` / `[env.ssh]`, tui.md §11
   * T88, `state/envprofile.ts`). A table for a kind that never gets a session
   * (nobody uses `/env`) costs nothing and is never read.
   *
   * Kept apart from `extensions` above rather than nested inside it: those
   * fields ARE the `local`/`wsl` default (`envprofile.ts`'s
   * `defaultProfile`), so folding this table into that one would make a
   * setting read itself.
   */
  env: EnvProfiles
  driver: {
    /**
     * The permission mode a run STARTS in: `ask` puts every tool call the rules
     * have no opinion about in front of a person, `unsafe` runs it.
     * `tui-state.json` (what was last chosen on screen) wins over this; the chip
     * on the status line and `/mode` change it for the run in flight
     * (tui.md §5.7).
     */
    mode: PermissionMode
  }
  /** The three tables, the `readonly` switch, and the classifier's own list (`approvals.ts`). */
  approvals: ApprovalRules
  keys: Record<string, string>
  /** Files that actually contributed, nearest last (`/settings` shows these). */
  sources: string[]
}

export const default_settings: Settings = {
  transcript: {
    diff: "expanded",
    tool_output: "collapsed",
    thinking: "hidden",
    composition: "collapsed",
    run_summary: true,
    max_width: 100,
    ascii: false,
    history_window: 400,
    stream_interval_ms: 100,
  },
  ui: { theme: "nulya-dark", code_theme: "auto", motion: true },
  extensions: {
    sync_on_start: true,
    auto_activate: true,
    session_with: ["handoff", "agent"],
    session_prompts: ["ground"],
    plugins: true,
  },
  env: {},
  driver: { mode: "ask" },
  approvals: { ...default_rules },
  keys: {},
  sources: [],
}

/**
 * `$NULYA_HOME`, else `~/.nulya` — the kernel's user config dir
 * (`config.zig` `userHome`), mirrored so `tui.toml` and `tui-state.json` sit
 * next to `config.toml`: one findable place on every platform.
 */
export function userConfigDir(env: Record<string, string | undefined> = process.env): string {
  const home = env["NULYA_HOME"]
  if (home && home.length > 0) return home
  return join(env["HOME"] ?? env["USERPROFILE"] ?? homedir(), ".nulya")
}

export function settingsPaths(workspaceDir: string, env: Record<string, string | undefined> = process.env): string[] {
  return [join(userConfigDir(env), "tui.toml"), join(workspaceDir, ".nulya", "tui.toml")]
}

function pick<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return typeof value === "string" && (allowed as readonly string[]).includes(value) ? (value as T) : fallback
}

function mergeLayer(into: Settings, layer: unknown, source: string) {
  if (typeof layer !== "object" || layer === null) return
  const record = layer as Record<string, unknown>
  const transcript = record["transcript"] as Record<string, unknown> | undefined
  if (transcript) {
    into.transcript.diff = pick(transcript["edit_diff"], ["expanded", "collapsed"], into.transcript.diff)
    into.transcript.diff = pick(transcript["diff"], ["expanded", "collapsed"], into.transcript.diff)
    into.transcript.tool_output = pick(transcript["tool_output"], ["expanded", "collapsed"], into.transcript.tool_output)
    into.transcript.thinking = pick(
      transcript["thinking"],
      ["expanded", "collapsed", "hidden"],
      into.transcript.thinking,
    )
    into.transcript.composition = pick(
      transcript["composition"],
      ["expanded", "collapsed"],
      into.transcript.composition,
    )
    if (typeof transcript["max_width"] === "number" && transcript["max_width"] > 0) {
      into.transcript.max_width = Math.floor(transcript["max_width"])
    }
    if (typeof transcript["run_summary"] === "boolean") into.transcript.run_summary = transcript["run_summary"]
    if (typeof transcript["ascii"] === "boolean") into.transcript.ascii = transcript["ascii"]
    if (typeof transcript["stream_interval_ms"] === "number" && transcript["stream_interval_ms"] >= 0) {
      into.transcript.stream_interval_ms = Math.floor(transcript["stream_interval_ms"])
    }
    if (typeof transcript["history_window"] === "number" && transcript["history_window"] >= 0) {
      into.transcript.history_window = Math.floor(transcript["history_window"])
    }
  }
  const ui = record["ui"] as Record<string, unknown> | undefined
  if (ui) {
    into.ui.theme = pick(ui["theme"], ["nulya-dark", "nulya-light"], into.ui.theme)
    into.ui.code_theme = pick(ui["code_theme"], code_theme_names, into.ui.code_theme)
    if (typeof ui["motion"] === "boolean") into.ui.motion = ui["motion"]
  }
  const extensions = record["extensions"] as Record<string, unknown> | undefined
  if (extensions) {
    if (typeof extensions["sync_on_start"] === "boolean") into.extensions.sync_on_start = extensions["sync_on_start"]
    if (typeof extensions["auto_activate"] === "boolean") into.extensions.auto_activate = extensions["auto_activate"]
    if (typeof extensions["plugins"] === "boolean") into.extensions.plugins = extensions["plugins"]
    // Replaced, not merged — same discipline as `session_with`: a nearer
    // layer that wants FEWER renderers must be able to say so.
    if (Array.isArray(extensions["session_prompts"])) {
      into.extensions.session_prompts = extensions["session_prompts"].filter((e): e is string => typeof e === "string")
    }
    // Replaced, not merged — the same discipline as the approval tables: a
    // nearer layer that wants FEWER packages must be able to say so.
    if (Array.isArray(extensions["session_with"])) {
      into.extensions.session_with = extensions["session_with"].filter((e): e is string => typeof e === "string")
    }
  }
  const envTable = record["env"] as Record<string, unknown> | undefined
  if (envTable) {
    for (const kind of ["local", "wsl", "ssh"] as const) {
      const table = envTable[kind] as Record<string, unknown> | undefined
      if (!table) continue
      const target = { ...(into.env[kind] ?? {}) }
      if (typeof table["bare"] === "boolean") target.bare = table["bare"]
      // Replaced, not merged — the same discipline every other list-shaped
      // setting on this page follows: a nearer layer that wants FEWER things
      // must be able to say so.
      if (Array.isArray(table["with"])) target.with = table["with"].filter((e): e is string => typeof e === "string")
      if (Array.isArray(table["pins"])) target.pins = table["pins"].filter((e): e is string => typeof e === "string")
      if (Array.isArray(table["session_prompts"])) {
        target.session_prompts = table["session_prompts"].filter((e): e is string => typeof e === "string")
      }
      into.env[kind] = target
    }
  }
  const driver = record["driver"] as Record<string, unknown> | undefined
  if (driver && typeof driver["mode"] === "string") {
    const mode = normalizeMode(driver["mode"])
    if (mode) into.driver.mode = mode
  }
  const approvals = record["approvals"] as Record<string, unknown> | undefined
  if (approvals) {
    for (const table of ["allow", "ask", "deny"] as const) {
      const list = approvals[table]
      // Replaced, not merged: a project layer that wanted to narrow a user
      // layer's `allow` could not do it if the two were unioned, and narrowing
      // is the direction that must always be available.
      if (Array.isArray(list)) into.approvals[table] = list.filter((e): e is string => typeof e === "string")
    }
    if (typeof approvals["manifest_readonly"] === "boolean") {
      into.approvals.manifest_readonly = approvals["manifest_readonly"]
    }
    // Same discipline as the three tables: replaced, so a nearer layer can take
    // an entry back off the list.
    if (Array.isArray(approvals["readonly_commands"])) {
      into.approvals.readonly_commands = approvals["readonly_commands"].filter((e): e is string => typeof e === "string")
    }
  }
  const keys = record["keys"] as Record<string, unknown> | undefined
  if (keys) {
    for (const [name, binding] of Object.entries(keys)) {
      if (typeof binding === "string") into.keys[name] = binding
    }
  }
  into.sources.push(source)
}


/**
 * Every key `mergeLayer` above reads, what it accepts, and how to show what it
 * is set to (tui.md §11, T94).
 *
 * WHY IT EXISTS. `/settings` used to list nine of these and say nothing about
 * what any of them would take, so the only way to find out that
 * `transcript.thinking` has three values — or that `extensions.session_with`
 * is a key at all — was to read this file. A settings screen whose only
 * instruction is "edit the file" has to at least say WHICH words the file
 * accepts.
 *
 * WHY IT IS A TABLE AND NOT A PARSER. The parser above is hand-written on
 * purpose: the list-shaped keys replace rather than merge, two of the numbers
 * have floors, and `diff` still answers to its old name. A schema general
 * enough to drive all of that would be a bigger thing to get right than the
 * branches it replaced. So this describes and does not parse — and the test
 * that keeps the two honest writes a non-default value for every row here
 * through `loadSettings` and checks it arrives (`test/extensions.test.ts`). A
 * row for a key nobody reads fails; a key read but not listed is the one thing
 * that test cannot catch, which is why the order here follows the parser's.
 *
 * WHAT IT GAINED WHEN THE SCREEN LEARNED TO WRITE (T100). A row now also says
 * HOW its key changes — the same vocabulary, used a second way. That is the
 * point: the words a key accepts are written once, so the list a picker offers
 * and the list the third column advertises cannot come to disagree.
 */

/**
 * How `/settings` changes a key, for the keys it will change (T100).
 *
 * A closed list is chosen from, a number and a list are typed. A field with no
 * `edit` is one this screen will not write — `keys.*`, whose names are an open
 * set, and the `env.<kind>` rows, whose one line stands for three tables and
 * so has no single value to put anywhere.
 */
export type SettingEdit =
  | { kind: "choice"; values: readonly string[]; boolean?: true }
  | { kind: "number"; min: number }
  | { kind: "list" }

/** A closed list of words, written to the file as a string. */
const words = (...values: string[]): SettingEdit => ({ kind: "choice", values })
/** The same, written as a TOML boolean rather than as the word `"true"`. */
const flag: SettingEdit = { kind: "choice", values: ["true", "false"], boolean: true }
const fold = words("expanded", "collapsed")

export interface SettingField {
  key: string
  /**
   * The values it takes — a closed list, or the shape of an open one. Omitted
   * where `edit` already carries the whole vocabulary, so a set of words is
   * written once and cannot come to disagree with itself (`acceptsOf`).
   */
  accepts?: string
  /** What it is set to, as one line. */
  value(settings: Settings): string
  edit?: SettingEdit
  /**
   * What a person needs to know that the new value does not say — only where
   * writing it would otherwise look like it did nothing on this screen.
   */
  note?: string
}

/** The third column of `/settings`: what the file will take here. */
export function acceptsOf(field: SettingField): string {
  if (field.accepts !== undefined) return field.accepts
  return field.edit?.kind === "choice" ? field.edit.values.join(" | ") : ""
}

/**
 * The TOML value an answer becomes, or why it is not one. The words are the
 * screen's, so the field that describes a key also decides what may be put in
 * it — there is no second place where "what does this key take" is answered.
 */
export function editedValue(edit: SettingEdit, text: string): { value: TomlValue } | { problem: string } {
  const trimmed = text.trim()
  switch (edit.kind) {
    case "choice":
      if (!edit.values.includes(trimmed)) return { problem: `takes ${edit.values.join(" | ")}` }
      return { value: edit.boolean ? trimmed === "true" : trimmed }
    case "number": {
      if (!/^\d+$/.test(trimmed)) return { problem: "takes a whole number" }
      const number = Number.parseInt(trimmed, 10)
      if (number < edit.min) return { problem: `takes a number of at least ${edit.min}` }
      return { value: number }
    }
    case "list":
      // Commas, and only commas — an entry may contain spaces (`approvals.allow`
      // holds command patterns), so whitespace cannot be the separator. It is
      // the same joint the value column is written with (`shown`), so a list is
      // read and typed in one form.
      return {
        value: trimmed.length === 0 ? [] : trimmed.split(",").map((one) => one.trim()).filter((one) => one.length > 0),
      }
  }
}

const yesno = "true | false"
/**
 * A list-shaped value: replaced by a nearer layer, never merged into.
 *
 * Comma-jointed, and that is not decoration: `approvals.allow` holds command
 * patterns, which contain spaces, so a space-jointed line cannot be read back
 * — `git status git push` is one entry or two and the screen would not say
 * which. It is also what `/settings` types into and splits on (T100), so what
 * is shown and what is typed are the same string.
 */
const shown = (xs: readonly string[]) => (xs.length === 0 ? "—" : xs.join(", "))
/** Which `[env.<kind>]` tables set this key, since which one applies is per session. */
const envSet = (settings: Settings, has: (table: EnvProfileOverride) => boolean) => {
  const kinds = (["local", "wsl", "ssh"] as const).filter((kind) => {
    const table = settings.env[kind]
    return table !== undefined && has(table)
  })
  return kinds.length === 0 ? "—" : `set for ${kinds.join(" ")}`
}

export const setting_fields: readonly SettingField[] = [
  { key: "transcript.diff", edit: fold, value: (s) => s.transcript.diff },
  { key: "transcript.tool_output", edit: fold, value: (s) => s.transcript.tool_output },
  { key: "transcript.thinking", edit: words("expanded", "collapsed", "hidden"), value: (s) => s.transcript.thinking },
  { key: "transcript.composition", edit: fold, value: (s) => s.transcript.composition },
  { key: "transcript.run_summary", edit: flag, value: (s) => String(s.transcript.run_summary) },
  {
    key: "transcript.max_width",
    accepts: "columns, above 0",
    edit: { kind: "number", min: 1 },
    value: (s) => String(s.transcript.max_width),
  },
  {
    key: "transcript.history_window",
    accepts: "items, 0 draws all",
    edit: { kind: "number", min: 0 },
    value: (s) => String(s.transcript.history_window),
  },
  {
    key: "transcript.stream_interval_ms",
    accepts: "ms, 0 renders every delta",
    edit: { kind: "number", min: 0 },
    value: (s) => String(s.transcript.stream_interval_ms),
  },
  { key: "transcript.ascii", edit: flag, value: (s) => String(s.transcript.ascii) },
  { key: "ui.theme", edit: words("nulya-dark", "nulya-light"), value: (s) => s.ui.theme },
  { key: "ui.code_theme", edit: words(...code_theme_names), value: (s) => s.ui.code_theme },
  { key: "ui.motion", edit: flag, value: (s) => String(s.ui.motion) },
  {
    key: "extensions.sync_on_start",
    edit: flag,
    note: "read when this front end opens",
    value: (s) => String(s.extensions.sync_on_start),
  },
  {
    key: "extensions.auto_activate",
    edit: flag,
    note: "read when this front end opens",
    value: (s) => String(s.extensions.auto_activate),
  },
  {
    key: "extensions.plugins",
    edit: flag,
    // A module that has run has run (tui-plugin U3), so turning this off is a
    // fact about the next start rather than about this screen.
    note: "read when this front end opens",
    value: (s) => String(s.extensions.plugins),
  },
  {
    key: "extensions.session_with",
    accepts: "package ids · --with, every session",
    edit: { kind: "list" },
    note: "composition freezes at `session new`, so this reaches the next session",
    value: (s) => shown(s.extensions.session_with),
  },
  {
    key: "extensions.session_prompts",
    accepts: "package ids · their render tool writes --prompt",
    edit: { kind: "list" },
    note: "read just before the next `session new`",
    value: (s) => shown(s.extensions.session_prompts),
  },
  { key: "env.<local|wsl|ssh>.bare", accepts: yesno, value: (s) => envSet(s, (t) => t.bare !== undefined) },
  { key: "env.<local|wsl|ssh>.with", accepts: "package ids", value: (s) => envSet(s, (t) => t.with !== undefined) },
  { key: "env.<local|wsl|ssh>.pins", accepts: "ext:<id>/<tool>", value: (s) => envSet(s, (t) => t.pins !== undefined) },
  {
    key: "env.<local|wsl|ssh>.session_prompts",
    accepts: "package ids",
    value: (s) => envSet(s, (t) => t.session_prompts !== undefined),
  },
  {
    key: "driver.mode",
    edit: words(...modes),
    // This is where a run STARTS; what was last chosen on screen wins over it
    // and is remembered in `tui-state.json` (§7), so writing it here changes
    // nothing about the run in flight.
    note: "the mode this run is in was chosen on screen · /mode changes that one",
    value: (s) => s.driver.mode,
  },
  { key: "approvals.allow", accepts: "command patterns", edit: { kind: "list" }, value: (s) => shown(s.approvals.allow) },
  { key: "approvals.ask", accepts: "command patterns", edit: { kind: "list" }, value: (s) => shown(s.approvals.ask) },
  {
    key: "approvals.deny",
    accepts: "command patterns · nothing overrules it",
    edit: { kind: "list" },
    value: (s) => shown(s.approvals.deny),
  },
  { key: "approvals.manifest_readonly", edit: flag, value: (s) => String(s.approvals.manifest_readonly) },
  {
    key: "approvals.readonly_commands",
    accepts: "program names the ask mode may run unasked",
    edit: { kind: "list" },
    value: (s) => shown(s.approvals.readonly_commands),
  },
]

export async function loadSettings(
  workspaceDir: string,
  env: Record<string, string | undefined> = process.env,
): Promise<Settings> {
  const merged: Settings = structuredClone(default_settings)
  // NO_COLOR is honoured in the theme, not here; `ascii` is a glyph choice.
  for (const path of settingsPaths(workspaceDir, env)) {
    if (!existsSync(path)) continue
    try {
      mergeLayer(merged, Bun.TOML.parse(await Bun.file(path).text()), path)
    } catch {
      // A broken settings file must not stop the TUI from opening; the defaults
      // are always usable and `sources` shows what was actually applied.
    }
  }
  return merged
}
