/**
 * What the TUI remembers between runs — today, the model the user last picked.
 *
 * This is the one file the TUI WRITES. It is deliberately not the kernel's
 * `config.toml` (which only humans write, and which decides what a model id
 * means) and not `tui.toml` (which only humans write, and which decides how the
 * screen looks): it is program state, JSON, at
 * `<user config dir>/tui-state.json`. A missing or broken file means "nothing
 * remembered" and never stops the TUI from opening.
 *
 * The rule it serves (tui.md §1.2 D8): a person starts `nulya` and picks the
 * model on screen; they must never have to find a config file to switch models.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { userConfigDir } from "./settings.ts"

/** The last (profile, model, effort) picked in `/model`, or by `/effort`. */
export interface ModelPick {
  profile: string
  /** Model id within the profile; undefined means the profile's default. */
  model?: string
  /** Effort for `session step --effort`; undefined means the kernel default. */
  effort?: string
}

export interface TuiState {
  model?: ModelPick
  /**
   * Workspace extension stores the trust question has already been put for, by
   * absolute path. "Only ask once" is the whole point of remembering: a person
   * who said "not now" to a checkout should not be asked again every time they
   * open it — they can still run `nulya ext trust` whenever they mean to.
   */
  asked_stores?: string[]
}

export function tuiStatePath(env: Record<string, string | undefined> = process.env): string {
  return join(userConfigDir(env), "tui-state.json")
}

function pickFrom(value: unknown): ModelPick | undefined {
  if (typeof value !== "object" || value === null) return undefined
  const record = value as Record<string, unknown>
  if (typeof record["profile"] !== "string" || record["profile"].length === 0) return undefined
  const pick: ModelPick = { profile: record["profile"] }
  if (typeof record["model"] === "string" && record["model"].length > 0) pick.model = record["model"]
  if (typeof record["effort"] === "string" && record["effort"].length > 0) pick.effort = record["effort"]
  return pick
}

export function loadTuiState(path = tuiStatePath()): TuiState {
  if (!existsSync(path)) return {}
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, "utf8"))
    if (typeof parsed !== "object" || parsed === null) return {}
    const state: TuiState = {}
    const record = parsed as Record<string, unknown>
    const model = pickFrom(record["model"])
    if (model) state.model = model
    const asked = record["asked_stores"]
    if (Array.isArray(asked)) state.asked_stores = asked.filter((s): s is string => typeof s === "string")
    return state
  } catch {
    return {}
  }
}

/** Overwrite the file with `state`. Tiny and whole: there is nothing to merge. */
export function saveTuiState(state: TuiState, path = tuiStatePath()): void {
  try {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, `${JSON.stringify(state, null, 2)}\n`)
  } catch {
    // Not being able to remember is not a reason to stop working.
  }
}

/** Remember one pick: read-modify-write so unrelated state (later) survives. */
export function rememberModel(pick: ModelPick, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.model = pick
  saveTuiState(state, path)
}

/** Remember that the trust question was put for this store, whatever the answer. */
export function rememberStoreAsked(store: string, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  const asked = state.asked_stores ?? []
  if (asked.includes(store)) return
  state.asked_stores = [...asked, store]
  saveTuiState(state, path)
}
