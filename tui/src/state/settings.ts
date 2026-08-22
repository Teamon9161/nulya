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
import { default_rules, normalizeMode, type ApprovalRules, type PermissionMode } from "../approvals.ts"

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
    edit_diff: FoldDefault
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
  }
  ui: {
    theme: "nulya-dark" | "nulya-light"
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
     * `--with <id>@<v>`, plus a `--pin` for each tool that version puts on the
     * model's face (`audience`, DESIGN §7.2.1). One list where there used to be
     * one boolean per package (T34) — "which packages" is a list-shaped question,
     * and a new one should not need a new key and a new branch in `App.tsx`.
     *
     * Both defaults earn their place. `handoff`'s tool only ever WRITES A FILE
     * proposing a handover (DESIGN §11) — the fork is this front end's move and
     * it still asks first in `ask` mode. `agent` ships four personas, so there
     * is always something to delegate to, and a delegation is a background task
     * the model can only ASK for; every tool call inside it still meets the gate.
     *
     * TOP-LEVEL only, and that is load-bearing for `agent`: a delegated session
     * composes itself (DESIGN §7.8), so this list never reaches one.
     *
     * The two booleans this replaces (`[extensions] handoff` / `agent`) are
     * still read: `handoff = false` removes that id from the list, exactly as it
     * used to mean. Nothing rewrites the file.
     */
    session_with: string[]
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
  driver: {
    /**
     * The permission mode a run STARTS in: `ask` puts every tool call the rules
     * have no opinion about in front of a person, `unsafe` runs it.
     * `tui-state.json` (what was last chosen on screen) wins over this; the chip
     * on the status line and `/mode` change it for the run in flight
     * (tui.md §5.7). A layer that still says `auto` is read as `unsafe`.
     */
    mode: PermissionMode
  }
  /** The three tables and the `readonly` switch (`approvals.ts`). */
  approvals: ApprovalRules
  keys: Record<string, string>
  /** Files that actually contributed, nearest last (`/settings` shows these). */
  sources: string[]
}

export const default_settings: Settings = {
  transcript: {
    edit_diff: "expanded",
    tool_output: "collapsed",
    thinking: "hidden",
    composition: "collapsed",
    run_summary: true,
    max_width: 100,
    ascii: false,
    history_window: 400,
  },
  ui: { theme: "nulya-dark", motion: true },
  extensions: { sync_on_start: true, auto_activate: true, session_with: ["handoff", "agent"], plugins: true },
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

/**
 * The list with `id` present or absent, order otherwise untouched. What a
 * legacy per-package boolean turns into (`[extensions] handoff = false`).
 */
export function withPackage(list: readonly string[], id: string, on: boolean): string[] {
  const without = list.filter((entry) => entry !== id)
  return on ? [...without, id] : without
}

function mergeLayer(into: Settings, layer: unknown, source: string) {
  if (typeof layer !== "object" || layer === null) return
  const record = layer as Record<string, unknown>
  const transcript = record["transcript"] as Record<string, unknown> | undefined
  if (transcript) {
    into.transcript.edit_diff = pick(transcript["edit_diff"], ["expanded", "collapsed"], into.transcript.edit_diff)
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
    if (typeof transcript["history_window"] === "number" && transcript["history_window"] >= 0) {
      into.transcript.history_window = Math.floor(transcript["history_window"])
    }
  }
  const ui = record["ui"] as Record<string, unknown> | undefined
  if (ui) {
    into.ui.theme = pick(ui["theme"], ["nulya-dark", "nulya-light"], into.ui.theme)
    if (typeof ui["motion"] === "boolean") into.ui.motion = ui["motion"]
  }
  const extensions = record["extensions"] as Record<string, unknown> | undefined
  if (extensions) {
    if (typeof extensions["sync_on_start"] === "boolean") into.extensions.sync_on_start = extensions["sync_on_start"]
    if (typeof extensions["auto_activate"] === "boolean") into.extensions.auto_activate = extensions["auto_activate"]
    if (typeof extensions["plugins"] === "boolean") into.extensions.plugins = extensions["plugins"]
    // Replaced, not merged — the same discipline as the approval tables: a
    // nearer layer that wants FEWER packages must be able to say so.
    if (Array.isArray(extensions["session_with"])) {
      into.extensions.session_with = extensions["session_with"].filter((e): e is string => typeof e === "string")
    }
    // The two per-package booleans this key replaced (T34). A layer that still
    // writes one keeps meaning what it meant: `false` takes that id off the
    // list, `true` puts it back. Read only — `tui.toml` is a person's file.
    for (const legacy of ["handoff", "agent"] as const) {
      if (typeof extensions[legacy] !== "boolean") continue
      into.extensions.session_with = withPackage(into.extensions.session_with, legacy, extensions[legacy] as boolean)
    }
  }
  const driver = record["driver"] as Record<string, unknown> | undefined
  if (driver && typeof driver["mode"] === "string") {
    // A `tui.toml` written before the rename still says `auto`; it keeps
    // meaning what it meant (`normalizeMode`). Nothing rewrites the file —
    // `tui.toml` is a person's, and this only reads it.
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
  }
  const keys = record["keys"] as Record<string, unknown> | undefined
  if (keys) {
    for (const [name, binding] of Object.entries(keys)) {
      if (typeof binding === "string") into.keys[name] = binding
    }
  }
  into.sources.push(source)
}

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
