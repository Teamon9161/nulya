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
   * Agent-definition directories the question has already been put for, by
   * absolute path, and the ones that were answered yes (tui.md §5.10).
   *
   * A definition that arrives with a checkout becomes a SYSTEM PROMPT the moment
   * somebody delegates to it — the T31 hazard, one directory over — and
   * materialising one also writes into this workspace's extension store, which
   * for an empty store is the kernel's own "a local build IS the trust" rule
   * (DESIGN §9). So the question is asked before any of that can happen, and
   * asked once: `asked` is what stops it coming back every morning, `trusted` is
   * the answer it got. The machine's own `~/.nulya/agents` is never asked about,
   * for the same reason the user extension store is not — nothing arrives there
   * without the person putting it there.
   */
  asked_agents?: string[]
  trusted_agents?: string[]
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
   * Extension ids this TUI composes into every session it starts, as bare ids
   * resolved at `current` — the membership half of what `/ext`'s Enter turns on
   * (K8), beside `session_pins`, which is the tool-face half.
   *
   * Program state for the same reason the pins are: trying a package out should
   * cost nothing and leave nothing in a file somebody else reads. The permanent
   * form is the kernel's own `[extensions] with` in config, which `nulya config
   * show` projects and this TUI never writes.
   *
   * Not to be confused with `tui.toml`'s `[extensions] session_with`, which is a
   * human-written setting naming the packages this front end always brings
   * (`handoff`, `agent`) and is resolved to an exact version each time.
   */
  session_with?: string[]
  /**
   * Set once `edit` has been offered to an existing `session_pins` list — the
   * tool moved out of the kernel and into `std` after some people already had
   * the other std pins written here. The marker is what makes it a migration
   * rather than a rule: someone who then unpins `edit` in `/ext` keeps it
   * unpinned.
   */
  adopted_std_edit_pin?: boolean
  /**
   * One slot per plugin package, keyed by package id (tui-plugin U3,
   * `api.state`). PREFERENCES a plugin should remember between runs — not view
   * state (that dies with the process) and not anything the model must see
   * (that is a ledger turn, `extnote.ts`).
   *
   * Namespaced by id so two packages cannot collide, and read back loosely:
   * whatever a plugin wrote is whatever it gets, and a slot this build cannot
   * make sense of is still not a reason to lose the model pick.
   */
  plugins?: Record<string, Record<string, unknown>>
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
    for (const key of ["asked_agents", "trusted_agents"] as const) {
      const list = record[key]
      if (Array.isArray(list)) state[key] = list.filter((s): s is string => typeof s === "string")
    }
    for (const key of ["session_pins", "session_with"] as const) {
      const list = record[key]
      if (Array.isArray(list)) state[key] = list.filter((s): s is string => typeof s === "string")
    }
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
    const plugins = record["plugins"]
    if (typeof plugins === "object" && plugins !== null && !Array.isArray(plugins)) {
      const slots: Record<string, Record<string, unknown>> = {}
      for (const [id, slot] of Object.entries(plugins as Record<string, unknown>)) {
        if (typeof slot === "object" && slot !== null && !Array.isArray(slot)) {
          slots[id] = slot as Record<string, unknown>
        }
      }
      state.plugins = slots
    }
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

/** The `--with` list every `session new` from this TUI carries (K8). */
export function sessionWith(path = tuiStatePath()): string[] {
  return loadTuiState(path).session_with ?? []
}

export function rememberSessionWith(ids: readonly string[], path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.session_with = [...ids]
  saveTuiState(state, path)
}

/** Remember the permission mode the person is working in (tui.md §5.7). */
export function rememberMode(mode: PermissionMode, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.mode = mode
  saveTuiState(state, path)
}

/**
 * Remember the answer to the agent-definitions question for one directory.
 * Asked either way, trusted only on a yes (tui.md §5.10).
 */
export function rememberAgentsAnswer(dir: string, trusted: boolean, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  const asked = state.asked_agents ?? []
  const allowed = state.trusted_agents ?? []
  state.asked_agents = asked.includes(dir) ? asked : [...asked, dir]
  if (trusted && !allowed.includes(dir)) state.trusted_agents = [...allowed, dir]
  saveTuiState(state, path)
}

/** One plugin package's remembered slot (`api.state`, tui-plugin U3). */
export function pluginState(pkg: string, path?: string): Record<string, unknown> {
  return loadTuiState(path ?? tuiStatePath()).plugins?.[pkg] ?? {}
}

/**
 * Write one plugin's slot back. Read-modify-write like every other remember
 * here, so two plugins writing in the same second do not lose each other's
 * preferences — and so a slot never takes the model pick down with it.
 */
export function rememberPluginState(pkg: string, slot: Record<string, unknown>, path?: string): void {
  const where = path ?? tuiStatePath()
  const state = loadTuiState(where)
  state.plugins = { ...(state.plugins ?? {}), [pkg]: slot }
  saveTuiState(state, where)
}

/** Remember that the trust question was put for this store, whatever the answer. */
export function rememberStoreAsked(store: string, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  const asked = state.asked_stores ?? []
  if (asked.includes(store)) return
  state.asked_stores = [...asked, store]
  saveTuiState(state, path)
}
