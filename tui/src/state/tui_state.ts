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
import { default_sidebar_ratio } from "./sidebar.ts"
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
   * `tui.toml`'s `[driver] mode` is the fallback when nothing was chosen.
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
   * Where the NEXT session's `shell` commands run (`/env`, DESIGN §8.1) — the
   * spec verbatim, `""`/absent meaning this host.
   *
   * Program state for the model pick's reason: a person working inside a WSL
   * distribution today should not have to type `--env wsl` for every new tab.
   * It is not `tui.toml` and deliberately not the kernel's config either — the
   * kernel has no such key, because "is wsl narrower or wider than local" has
   * no honest answer in a config chain whose project layer may only narrow
   * (DESIGN §8.1). Remembering a choice is a front end's job; ranking targets
   * would not be.
   *
   * The spelling is never checked here. `session new` refuses a bad one with
   * the vocabulary in the message, and that refusal already reaches the screen.
   */
  exec_env?: string
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
  /**
   * The sessions sidebar: whether it was up, and how wide (T69).
   *
   * Program state for the same reason the model pick is: a person who pulled
   * the sidebar out yesterday should find it there today without editing a
   * file, and a person who put it away should not have to put it away again
   * every morning. Not `tui.toml`, which is what a person writes to say how the
   * screen should look — this is what the screen remembers about being used.
   *
   * `open` is what was ASKED for, not what was on screen: a narrow terminal
   * hides the sidebar (`sidebar_min_width`) without anybody deciding to, and
   * remembering that as "closed" would lose the answer to the next window that
   * is wide enough.
   */
  sidebar?: { open: boolean; ratio: number }
  /**
   * The tabs that were open, in order, each with the directory it works in
   * (goals/tui-shell.md §5.3b point 8).
   *
   * A tab is (workspace, session), so remembering one means remembering both —
   * an id alone cannot say which `.nulya/sessions/` it came out of once a
   * screen can hold tabs in two directories.
   *
   * What is done with it on the next launch is deliberately narrow: the FIRST
   * tab is decided exactly as it always was (`--session`, else a draft, T22),
   * and only the tabs BEYOND it come back. So the single-tab screen everybody
   * has is unchanged down to the frame, and the person who left four
   * conversations open in two repositories finds them where they left them.
   * Nothing is created by restoring: a draft is not remembered (it is nothing
   * on disk), and a session whose file has since gone is skipped.
   */
  tabs?: { ws: string; session?: string }[]
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
    const sessionPinsList = record["session_pins"]
    if (Array.isArray(sessionPinsList)) {
      state.session_pins = sessionPinsList.filter((s): s is string => typeof s === "string")
    }
    const execEnv = record["exec_env"]
    if (typeof execEnv === "string" && execEnv.length > 0) state.exec_env = execEnv
    const mode = record["mode"]
    if (typeof mode === "string") {
      const known = normalizeMode(mode)
      if (known) state.mode = known
    }
    const sidebar = record["sidebar"]
    if (typeof sidebar === "object" && sidebar !== null && !Array.isArray(sidebar)) {
      const slot = sidebar as Record<string, unknown>
      const ratio = slot["ratio"]
      // Each half read on its own terms: a file that remembers the width but
      // not the answer, or the other way round, still gives back what it does
      // know. `clampRatio` is not applied here — the model clamps every ratio
      // it is handed, and doing it twice would be two places deciding how thin
      // a pane may be.
      state.sidebar = {
        open: slot["open"] === true,
        ratio: typeof ratio === "number" && Number.isFinite(ratio) ? ratio : default_sidebar_ratio,
      }
    }
    const tabs = record["tabs"]
    if (Array.isArray(tabs)) {
      const kept: { ws: string; session?: string }[] = []
      for (const slot of tabs) {
        if (typeof slot !== "object" || slot === null || Array.isArray(slot)) continue
        const where = (slot as Record<string, unknown>)["ws"]
        if (typeof where !== "string" || where.length === 0) continue
        const session = (slot as Record<string, unknown>)["session"]
        kept.push({ ws: where, ...(typeof session === "string" && session.length > 0 ? { session } : {}) })
      }
      state.tabs = kept
    }
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
    // `asked_bundled`, `standing_with`, `adopted_std_edit_pin`, all retired —
    // is simply not read. An unknown key has never been an error here, and a
    // state file that refused to load would cost the model pick and the pins as
    // well.
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

/** Remember whether the sessions sidebar was up, and how wide (T69). */
export function rememberSidebar(sidebar: { open: boolean; ratio: number }, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.sidebar = sidebar
  saveTuiState(state, path)
}

/** Remember which tabs were open and where each one works (§5.3b point 8). */
export function rememberTabs(tabs: readonly { ws: string; session?: string }[], path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.tabs = tabs.map((tab) => ({ ws: tab.ws, ...(tab.session ? { session: tab.session } : {}) }))
  saveTuiState(state, path)
}

/** Where the next `session new` from this TUI runs its shell (DESIGN §8.1). */
export function execEnv(path = tuiStatePath()): string {
  return loadTuiState(path).exec_env ?? ""
}

/**
 * Remember it. An empty spec (or the word `local`) is the absence of a choice,
 * so it is REMOVED rather than stored — otherwise the file would keep saying
 * something about a session that is exactly like every other one.
 */
export function rememberExecEnv(spec: string, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  const trimmed = spec.trim()
  if (trimmed.length === 0 || trimmed === "local") delete state.exec_env
  else state.exec_env = trimmed
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
