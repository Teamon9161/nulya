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

export type FoldDefault = "expanded" | "collapsed"
export type ThinkingDefault = "expanded" | "collapsed" | "hidden"

export interface Settings {
  transcript: {
    edit_diff: FoldDefault
    tool_output: FoldDefault
    thinking: ThinkingDefault
    max_width: number
    ascii: boolean
  }
  ui: {
    theme: "nulya-dark" | "nulya-light"
    motion: boolean
  }
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
  },
  ui: { theme: "nulya-dark", motion: true },
  keys: {},
  sources: [],
}

function userConfigDir(env: Record<string, string | undefined> = process.env): string {
  if (process.platform === "win32") {
    const appdata = env["APPDATA"]
    if (appdata) return join(appdata, "nulya")
  }
  const xdg = env["XDG_CONFIG_HOME"]
  return join(xdg && xdg.length > 0 ? xdg : join(homedir(), ".config"), "nulya")
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
  }
  const ui = record["ui"] as Record<string, unknown> | undefined
  if (ui) {
    into.ui.theme = pick(ui["theme"], ["nulya-dark", "nulya-light"], into.ui.theme)
    if (typeof ui["motion"] === "boolean") into.ui.motion = ui["motion"]
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
