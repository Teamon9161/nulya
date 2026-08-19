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
import { normalizeMode, type PermissionMode } from "../approvals.ts"
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
   * The permission mode last chosen on screen (`/mode`, the status-line chip).
   * Program state, like the model pick and for the same reason: a person who
   * switched to `unsafe` yesterday should not have to find `tui.toml` today.
   * `tui.toml`'s `[driver] mode` is the fallback when nothing was chosen. A file
   * that still says `auto` is read as `unsafe` (`normalizeMode`).
   */
  mode?: PermissionMode
  /**
   * Workspace extension stores the trust question has already been put for, by
   * absolute path. "Only ask once" is the whole point of remembering: a person
   * who said "not now" to a checkout should not be asked again every time they
   * open it — they can still run `nulya ext trust` whenever they mean to.
   */
  asked_stores?: string[]
  /**
   * Extension tools this TUI puts on the face of every session it starts, as
   * stable ids (`ext:<id>/<tool>`) — the `this TUI` state of the pin panel
   * (tui.md §11, T12). Program state rather than config on purpose: trying a
   * tool out should cost nothing and leave nothing in a file somebody else
   * reads. `A` in the panel is what makes one permanent, and that writes the
   * kernel's own `registry.pinned_native_tools` instead.
   */
  session_pins?: string[]
  /**
   * Set once `edit` has been offered to an existing `session_pins` list — the
   * tool moved out of the kernel and into `std` after some people already had
   * the other std pins written here. The marker is what makes it a migration
   * rather than a rule: someone who then unpins `edit` in `/ext` keeps it
   * unpinned.
   */
  adopted_std_edit_pin?: boolean
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
    const pins = record["session_pins"]
    if (Array.isArray(pins)) state.session_pins = pins.filter((s): s is string => typeof s === "string")
    // `auto` was this mode's name until it was renamed to `unsafe`; the file
    // written yesterday still says it, and `normalizeMode` is the one place that
    // knows. Nothing is rewritten here — the next `rememberMode` writes the new
    // word, and until then the old one keeps meaning what it meant.
    const mode = record["mode"]
    if (typeof mode === "string") {
      const known = normalizeMode(mode)
      if (known) state.mode = known
    }
    if (record["adopted_std_edit_pin"] === true) state.adopted_std_edit_pin = true
    // Every key is picked out by name, so a file written by an older build —
    // `asked_bundled`, retired in T23 when the bundled question went away — is
    // simply not read. An unknown key has never been an error here, and a state
    // file that refused to load would cost the model pick and the pins as well.
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

/** The `--pin` list every `session new` from this TUI carries (tui.md §11, T12). */
export function sessionPins(path = tuiStatePath()): string[] {
  return loadTuiState(path).session_pins ?? []
}

export function rememberSessionPins(pins: readonly string[], path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.session_pins = [...pins]
  saveTuiState(state, path)
}

/** Remember the permission mode the person is working in (tui.md §5.7). */
export function rememberMode(mode: PermissionMode, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.mode = mode
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
