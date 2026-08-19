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
import { default_rules, isMode, type ApprovalRules, type PermissionMode } from "../approvals.ts"

export type FoldDefault = "expanded" | "collapsed"
export type ThinkingDefault = "expanded" | "collapsed" | "hidden"

export interface Settings {
  transcript: {
    edit_diff: FoldDefault
    tool_output: FoldDefault
    thinking: ThinkingDefault
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
     * Bring the bundled `handoff` package into every session this TUI starts
     * (`--with handoff@<v> --pin ext:handoff/handoff`, DESIGN §11). On by
     * default: the tool only ever WRITES A FILE proposing a handover — the fork
     * is this front end's move, and it still asks first in `ask` mode.
     */
    handoff: boolean
  }
  driver: {
    /**
     * The permission mode a run STARTS in: `ask` puts every tool call the rules
     * have no opinion about in front of a person, `auto` runs it. `tui-state.json`
     * (what was last chosen on screen) wins over this; the chip on the status
     * line and `/mode` change it for the run in flight (tui.md §5.7).
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
    thinking: "collapsed",
    max_width: 100,
    ascii: false,
    history_window: 400,
  },
  ui: { theme: "nulya-dark", motion: true },
  extensions: { sync_on_start: true, auto_activate: true, handoff: true },
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
    into.transcript.edit_diff = pick(transcript["edit_diff"], ["expanded", "collapsed"], into.transcript.edit_diff)
    into.transcript.tool_output = pick(transcript["tool_output"], ["expanded", "collapsed"], into.transcript.tool_output)
    into.transcript.thinking = pick(
      transcript["thinking"],
      ["expanded", "collapsed", "hidden"],
      into.transcript.thinking,
    )
    if (typeof transcript["max_width"] === "number" && transcript["max_width"] > 0) {
      into.transcript.max_width = Math.floor(transcript["max_width"])
    }
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
    if (typeof extensions["handoff"] === "boolean") into.extensions.handoff = extensions["handoff"]
  }
  const driver = record["driver"] as Record<string, unknown> | undefined
  if (driver && typeof driver["mode"] === "string" && isMode(driver["mode"])) into.driver.mode = driver["mode"]
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
