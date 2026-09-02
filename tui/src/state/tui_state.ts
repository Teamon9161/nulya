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
 * The rule it serves: a person starts `nulya` and picks the
 * model on screen; they must never have to find a config file to switch models.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { normalizeMode, type PermissionMode } from "../approvals.ts"
import { default_sidebar_ratio } from "./sidebar.ts"
import { userConfigDir } from "./settings.ts"
import { applySelection, selectedToolIds } from "../with.ts"

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
   * Where the NEXT session's `shell` commands run (`/env`) — the
   * spec verbatim, `""`/absent meaning this host.
   *
   * Program state for the model pick's reason: a person working inside a WSL
   * distribution today should not have to type `--env wsl` for every new tab.
   * It is not `tui.toml` and deliberately not the kernel's config either — the
   * kernel has no such key, because "is wsl narrower or wider than local" has
   * no honest answer in a config chain whose project layer may only narrow
   *. Remembering a choice is a front end's job; ranking targets
   * would not be.
   *
   * The spelling is never checked here. `session new` refuses a bad one with
   * the vocabulary in the message, and that refusal already reaches the screen.
   */
  exec_env?: string
  /**
   * The remote workspace `exec_env` would freeze in with `--workspace`
   * — the directory a person
   * picked in the remote directory browser after choosing a `remote:` target
   * in `/env`. Meaningless (and never read) unless `exec_env` names a
   * `remote:` target; travels WITH `exec_env` rather than being looked up by
   * it, so a stale workspace from an earlier remote choice can never be sent
   * alongside a spec it was not chosen for — `rememberExecEnv` clears both
   * together whenever the spec itself changes without a new workspace given.
   */
  exec_workspace?: string
  /**
   * Where the remote directory browser last left off, per exec-target spec
   * — "every machine remembers its own recents".
   * Seeds the NEXT time that same spec is picked in `/env`, so choosing
   * `remote:ssh:box` a second time opens where the first session's workspace
   * was rather than back at that account's home. `remote check`'s `home` (or
   * `cwd`) is the fallback the first time a spec is ever picked.
   */
  remote_cwd?: Record<string, string>
  /**
   * The last `nulya ext push` this front end ran for one (package, target)
   * pair — id, the spec it was pushed to, what the kernel said, and when.
   * Deliberately not a standing "is it there" table: a push is answered once,
   * by the kernel, at the moment it happens (content addressing makes a
   * repeat push a free correctness check, not a cost to avoid) — a
   * cached "yes" would be a claim this front end cannot back up the moment
   * either side changes without going through it. `/ext`'s push action shows
   * this as "last time" explicitly, never as present-tense status.
   */
  remote_pushed?: Record<string, { spec: string; said: string; at: string }>
  /**
   * Agent-definition directories the question has already been put for, by
   * absolute path, and the ones that were answered yes.
   *
   * A definition that arrives with a checkout becomes a SYSTEM PROMPT the moment
   * somebody delegates to it, and
   * materialising one also writes into this workspace's extension store, which
   * for an empty store is the kernel's own "a local build IS the trust" rule
   *. So the question is asked before any of that can happen, and
   * asked once: `asked` is what stops it coming back every morning, `trusted` is
   * the answer it got. The machine's own `~/.nulya/agents` is never asked about,
   * for the same reason the user extension store is not — nothing arrives there
   * without the person putting it there.
   */
  asked_agents?: string[]
  trusted_agents?: string[]
  /**
   * Members this TUI adds to every session it starts, in the kernel's own
   * spelling (`<id>[@<version>][:<tool>,…]`) — the `this TUI` state of the
   * tool-face panel. Program state rather than config on purpose: trying a tool
   * out should cost nothing and leave nothing in a file somebody else reads.
   * `A` in the panel is what makes one permanent, and that writes the kernel's
   * own `[extensions] with` instead.
   */
  session_with?: string[]
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
   * The sessions sidebar: whether it was up, and how wide.
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
   * tab is decided exactly as it always was (`--session`, else a draft),
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
    const sessionWithList = record["session_with"]
    if (Array.isArray(sessionWithList)) {
      state.session_with = sessionWithList.filter((s): s is string => typeof s === "string")
    }
    const execEnv = record["exec_env"]
    // The bare `ssh:<destination>` exec target was retired 2026-08-30
    // — `session new` refuses it outright now, so a
    // value remembered from before that would make every session this front
    // end starts fail at creation. This file is a convenience, not the
    // header, so a spec it can no longer use is simply DROPPED back to
    // "nothing remembered" (= local) rather than rewritten into the
    // similarly-spelled `remote:ssh:` — that word moves the whole workspace,
    // not just the shell, which is a choice only a person should make.
    if (typeof execEnv === "string" && execEnv.length > 0 && !execEnv.startsWith("ssh:")) {
      state.exec_env = execEnv
    }
    const execWorkspaceValue = record["exec_workspace"]
    if (typeof execWorkspaceValue === "string" && execWorkspaceValue.length > 0) {
      state.exec_workspace = execWorkspaceValue
    }
    const remoteCwdValue = record["remote_cwd"]
    if (typeof remoteCwdValue === "object" && remoteCwdValue !== null && !Array.isArray(remoteCwdValue)) {
      const kept: Record<string, string> = {}
      for (const [spec, dir] of Object.entries(remoteCwdValue as Record<string, unknown>)) {
        if (typeof dir === "string" && dir.length > 0) kept[spec] = dir
      }
      state.remote_cwd = kept
    }
    const remotePushedValue = record["remote_pushed"]
    if (typeof remotePushedValue === "object" && remotePushedValue !== null && !Array.isArray(remotePushedValue)) {
      const kept: Record<string, { spec: string; said: string; at: string }> = {}
      for (const [id, entry] of Object.entries(remotePushedValue as Record<string, unknown>)) {
        if (typeof entry !== "object" || entry === null || Array.isArray(entry)) continue
        const slot = entry as Record<string, unknown>
        const spec = slot["spec"]
        const said = slot["said"]
        const at = slot["at"]
        if (typeof spec === "string" && typeof said === "string" && typeof at === "string") {
          kept[id] = { spec, said, at }
        }
      }
      state.remote_pushed = kept
    }
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

/** The extra `--with` members every `session new` from this TUI carries. */
export function sessionMembers(path = tuiStatePath()): string[] {
  return loadTuiState(path).session_with ?? []
}

export function rememberSessionMembers(members: readonly string[], path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.session_with = [...members]
  saveTuiState(state, path)
}

/** The same list seen as the tool face it selects, which is what the panel draws. */
export function sessionSelection(path = tuiStatePath()): string[] {
  return selectedToolIds(sessionMembers(path))
}

/** Write the member list so its selections are exactly `toolIds`. */
export function rememberSessionSelection(toolIds: readonly string[], path = tuiStatePath()): void {
  rememberSessionMembers(applySelection(sessionMembers(path), toolIds), path)
}

/** Remember whether the sessions sidebar was up, and how wide. */
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

/** Where the next `session new` from this TUI runs its shell. */
export function execEnv(path = tuiStatePath()): string {
  return loadTuiState(path).exec_env ?? ""
}

/**
 * The remote workspace that would ride along with `execEnv` as `--workspace`
 * — meaningless (and the caller's to ignore) unless `execEnv` itself names a
 * `remote:` target.
 */
export function execWorkspace(path = tuiStatePath()): string {
  return loadTuiState(path).exec_workspace ?? ""
}

/**
 * Remember it. An empty spec (or the word `local`) is the absence of a choice,
 * so it is REMOVED rather than stored — otherwise the file would keep saying
 * something about a session that is exactly like every other one.
 *
 * `workspace` travels with the spec in the SAME call, never set on its own:
 * the two are chosen together (pick a `remote:` target, then a directory on
 * it) and must be cleared together too, so a later `/env` typed without a
 * workspace (switching back to `local`, or to a different target entirely)
 * can never leave a stale remote directory paired with a spec it was never
 * chosen for.
 */
export function rememberExecEnv(spec: string, path = tuiStatePath(), workspace?: string): void {
  const state = loadTuiState(path)
  const trimmed = spec.trim()
  if (trimmed.length === 0 || trimmed === "local") {
    delete state.exec_env
    delete state.exec_workspace
  } else {
    state.exec_env = trimmed
    if (workspace && workspace.trim().length > 0) state.exec_workspace = workspace.trim()
    else delete state.exec_workspace
  }
  saveTuiState(state, path)
}

/**
 * Where the remote directory browser last left off for `spec` — the seed for
 * the next time that same target is picked.
 */
export function remoteCwd(spec: string, path = tuiStatePath()): string | undefined {
  return loadTuiState(path).remote_cwd?.[spec]
}

/** Remember it: read-modify-write, so browsing one machine never forgets another's. */
export function rememberRemoteCwd(spec: string, dir: string, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.remote_cwd = { ...(state.remote_cwd ?? {}), [spec]: dir }
  saveTuiState(state, path)
}

/** The last `nulya ext push` this front end ran for `id`, if any (`/ext`'s push action). */
export function lastPush(id: string, path = tuiStatePath()): { spec: string; said: string; at: string } | undefined {
  return loadTuiState(path).remote_pushed?.[id]
}

/** Remember one push's outcome, by package id — read-modify-write, same as `rememberRemoteCwd`. */
export function rememberPush(id: string, spec: string, said: string, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.remote_pushed = { ...(state.remote_pushed ?? {}), [id]: { spec, said, at: new Date().toISOString() } }
  saveTuiState(state, path)
}

/** Remember the permission mode the person is working in. */
export function rememberMode(mode: PermissionMode, path = tuiStatePath()): void {
  const state = loadTuiState(path)
  state.mode = mode
  saveTuiState(state, path)
}

/**
 * Remember the answer to the agent-definitions question for one directory.
 * Asked either way, trusted only on a yes.
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
