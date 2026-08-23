import { For, Match, Show, Switch, createEffect, createMemo, createSignal, onCleanup, onMount, untrack } from "solid-js"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/solid"
import type { InputRenderable, KeyEvent, ScrollBoxRenderable, Selection } from "@opentui/core"
import { Transcript, rowsBelow, transcriptRows } from "./Transcript.tsx"
import { Composer, type ComposerApi } from "./Composer.tsx"
import { ApprovalPanel, type ApprovalChoice } from "./ApprovalPanel.tsx"
import { ModePicker, initialChoice, modeAt, moveChoice } from "./ModePicker.tsx"
import { AgentPicker } from "./AgentPicker.tsx"
import { WithPicker, type Wearable } from "./WithPicker.tsx"
import { StatusBar } from "./StatusBar.tsx"
import { pickTip } from "./Welcome.tsx"
import { WorkingStatus, activityOf } from "./WorkingStatus.tsx"
import { TabBar } from "./TabBar.tsx"
import { SessionsView } from "./overlays/SessionsView.tsx"
import { ExtView } from "./overlays/ExtView.tsx"
import { HelpView } from "./overlays/HelpView.tsx"
import { SettingsView } from "./overlays/SettingsView.tsx"
import { UsageView } from "./overlays/UsageView.tsx"
import { ModelView } from "./overlays/ModelView.tsx"
import { ProviderView } from "./overlays/ProviderView.tsx"
import { TasksView } from "./overlays/TasksView.tsx"
import { ScreenContext, StyleContext, useScreen, useStyle, type Style } from "../render/theme.ts"
import { FoldContext, createFoldStore } from "../state/folds.ts"
import { BrowseContext, createBrowseStore } from "../state/browse.ts"
import { OverlayContext, createOverlayStore, type OverlayKind } from "../state/overlay.ts"
import { TasksContext } from "../state/tasks.ts"
import { NavigateContext, type Navigate } from "../state/navigate.ts"
import type { TranscriptRow } from "../render/runs.ts"
import { createTabStore, type DraftTab, type FirstTab, type SessionTab } from "../state/tabs.ts"
import {
  loadTuiState,
  rememberModel,
  rememberMode,
  rememberSessionPins,
  sessionPins,
  sessionWith,
  type ModelPick,
} from "../state/tui_state.ts"
import {
  alwaysKey,
  decide,
  describeKey,
  modes,
  normalizeMode,
  poolPolicy,
  summarize as describeCall,
  withPolicy,
  type GateRequest,
  type PermissionMode,
} from "../approvals.ts"
import type { GateVerdict } from "../nulya/cli.ts"
import {
  listExtensions,
  readContributions,
  sessionExists,
  sessions_dir,
  type ExtensionEntry,
} from "../nulya/files.ts"
import { wrapApprovalNote } from "../approvalnote.ts"
import { createProjectIndex } from "../references.ts"
import { createSkillTable, skillTurn, splitSlash } from "../skills.ts"
import { describeTool } from "../render/registry.ts"
import { no_snapshot, usageLabel } from "../state/session.ts"
import type { NextSession } from "./Welcome.tsx"
import {
  CliError,
  extRun,
  extSetCurrent,
  extSync,
  isVerdict,
  sessionOutcome,
  verdicts,
  type ModelView as ModelParams,
  type ProfileView,
  type TaskEntry,
} from "../nulya/cli.ts"
import {
  activeVersionOf,
  adoptBundled,
  failedIds,
  needsZigIds,
  pinsOf,
  planStore,
  seedBundled,
  sessionMember,
  summarize,
  type SessionMember,
} from "../extensions.ts"
import { builtin_names } from "../commands.ts"
import {
  createPackageCommandTable,
  isDeprecatedWearAction,
  packageCompletions,
  parseAction,
  resolve as resolvePackageCommands,
  runArgs,
} from "../packageCommands.ts"
import { PanelStrip } from "./PanelStrip.tsx"
import { PluginPanel } from "./PluginPanel.tsx"
import { PluginWidgets } from "./PluginWidgets.tsx"
import { panelItemsOf, withoutSuperseded } from "../state/panels.ts"
import { createPluginHost, pluginKeyOf } from "../plugins/host.ts"
import { PluginContext } from "../plugins/context.ts"
import { wrapExtNote } from "../extnote.ts"
import { runCompact } from "../compact.ts"
import { headline, nextHandoff, type HandoffFile } from "../handoff.ts"
import { buildEvolution, formatWithRef, parseWithRef, type WithRef } from "../evolve.ts"
import { orphanPins, resolvableStandingPins } from "../pins.ts"
import {
  agent_id,
  agent_pin,
  agentPick,
  listAgents,
  renderAgent,
  readonlyCeiling,
  usableAgents,
  type AgentEntry,
  type RenderedAgent,
} from "../agents.ts"
import { createKeymap, matches } from "../keymap.ts"
import type { AttachOptions } from "../state/attach.ts"
import type { SessionState, TranscriptItem } from "../state/session.ts"
import type { Workspace } from "../nulya/bin.ts"

export interface AppProps {
  ws: Workspace
  /**
   * An existing session to open (`nulya-tui --session <id>`), or absent — and
   * then the screen starts on a DRAFT: no session, nothing on disk, until the
   * first message (tui.md §11, T22).
   */
  id?: string
  state?: SessionState
  /** What a draft would start on: `launch.planLaunch`, or the remembered pick. */
  pick?: ModelPick
  style: Style
  driver?: AttachOptions
  /** `id` was created by this process (`session new`), not opened by name. */
  created?: boolean
  /** The effort the first tab starts with (from the pick that created it). */
  effort?: string
  /**
   * Open on the model picker, with this line under its title. `main` sets it
   * when the session it had to create is not the one the user meant — no key
   * for the intended profile — so the first thing on screen is the way out.
   */
  guide?: string
  /**
   * Which screen the guide opens (tui.md §11, T21). `/model` when something can
   * run and the remembered pick simply cannot; `/provider` when NO provider can
   * run at all, because then a list of models has nothing to offer and the
   * missing key is the whole of the problem.
   */
  guideOn?: "model" | "provider"
  /** Where the TUI remembers its last pick; tests point it elsewhere. */
  statePath?: string
  /**
   * The `[[models]]` catalog, read once at launch. Only `context_window` is
   * used, for the status bar's fullness gauge; without it the gauge simply does
   * not appear, which is why this is optional rather than loaded here.
   */
  models?: ModelParams[]
  /**
   * The profiles, as `config show --json` projects them. Only one field is read:
   * a profile's default model id, so a draft that names a profile and no model
   * can still say which model the session will actually run on.
   */
  profiles?: ProfileView[]
  /**
   * `registry.pinned_native_tools` as the config chain merges it, read once at
   * launch. Unioned with this TUI's own `session_pins` it is the face the next
   * session would carry — which is what a draft has instead of a frozen one.
   */
  pinnedTools?: string[]
  /**
   * Which store roots to build on the way in, and whether to let that pass move
   * `current` (tui.md §11, T11). The user root needs no permission; the project
   * root is only here when `main` found it already trusted — the trust question,
   * the one thing that can stop a session from being created at all, is asked
   * before this screen exists and is the only thing still asked there.
   *
   * `bundled` seeds the drafts this binary ships into the user store first
   * (tui.md §11, T23). Both it and `user` are `[extensions] sync_on_start`;
   * `activate` is `auto_activate`, and it gates the pointer moves in both.
   */
  sync?: { user: boolean; project: boolean; activate: boolean; bundled: boolean }
  /**
   * Whether the agent definitions that came with this CHECKOUT may be used
   * (tui.md §5.10). Asked once before this screen exists, exactly as the store
   * question is, and for two reasons at once: a definition becomes a system
   * prompt, and materialising one builds into this workspace's extension store,
   * which for an empty store is how the kernel records trust for it (DESIGN §9).
   * Definitions in `~/.nulya/agents` are never gated — nothing arrives there
   * without the person putting it there.
   */
  agentsTrusted?: boolean
}

/**
 * One call the kernel is holding open, and the promise it is held on. The
 * request is what `--gate` offered; resolving it is what lets the step continue
 * (tui.md §5.7).
 */
interface Approval {
  request: GateRequest
  /** The session being stepped — not necessarily the tab in front. */
  session: string
  resolve: (verdict: GateVerdict) => void
}

/**
 * How long a notice stays up before the status line goes back to what it says
 * at rest (T35): as long as it takes to read it, and no longer.
 *
 * A notice covers that whole line while it is up, so it has to come down on its
 * own — and a fixed number would be wrong at both ends, since the same slot
 * carries `opened s-a1b2` and a three-clause sync summary. The floor is where
 * `Ctrl+C again to quit` lands, which is also exactly how long that offer is
 * good for: the two agree by construction rather than by coincidence.
 */
export function noticeHold(text: string): number {
  return Math.min(9000, Math.max(ctrl_c_ms, 1500 + text.length * 45))
}

/** The window in which a second Ctrl+C means what the first one offered. */
const ctrl_c_ms = 3000

/**
 * The cards browse mode walks: everything with a body that is actually on
 * screen. It walks ROWS, not items (T43) — the transcript's own projection,
 * so a call gathered into a run summary is not a place the cursor can land and
 * the run itself is. Anything outside `history_window` is not mounted, and a
 * selection there would be invisible.
 */
function foldable(rows: readonly TranscriptRow[]): { key: string; item: TranscriptItem | null }[] {
  const out: { key: string; item: TranscriptItem | null }[] = []
  for (const row of rows) {
    if (row.kind === "run") out.push({ key: row.key, item: null })
    else if (row.item.kind === "tool" || row.item.kind === "thinking") out.push({ key: row.key, item: row.item })
  }
  return out
}

/**
 * The whole screen: transcript, composer, status line — three blocks separated
 * by hairlines, no borders (tui.md §4.1, §6). The title line above them is gone
 * since T22: what it said that mattered — the model — is under the composer,
 * and what it said that did not — a session id — is in `/sessions`.
 *
 * There is no intelligence above the driver here. Slash commands map one to one
 * onto CLI verbs; anything else the user types goes to the model verbatim.
 */
export function App(props: AppProps) {
  const renderer = useRenderer()
  const screen = useTerminalDimensions()
  const folds = createFoldStore()
  const browse = createBrowseStore()
  const overlay = createOverlayStore()
  const keys = createKeymap(props.style.settings)
  // Opened by name, or a draft. Nothing else creates a session on the way in:
  // composition freezes at `session new` (physics #2), so a session made before
  // the first word is one whose tools, pins and model were decided by nobody.
  const first: FirstTab =
    props.id && props.state
      ? { kind: "session", id: props.id, state: props.state, created: props.created ?? false, effort: props.effort }
      : { kind: "draft", pick: props.pick, effort: props.effort }
  /**
   * Every step this TUI drives is gated (tui.md §5.7): the kernel asks before
   * each tool call and this answers. The mode is not passed to the kernel and
   * never could be — `--gate` has one semantic, allow or deny, and WHICH calls
   * are worth a person's attention is this front end's policy. So a mode
   * switched mid-batch reaches the very next request, because every request is a
   * fresh call into `approve`.
   */
  const tabs = createTabStore(props.ws, first, {
    ...(props.driver ?? {}),
    statePath: props.statePath,
    gate: (request, session) => approve(request, session),
    // Every line every step prints, to whatever plugins asked to watch
    // (tui-plugin U3, `api.observe`). A pure observer: it runs after the
    // transcript has been told, and it decides nothing.
    onLine: (line, session) => plugins.observe(line, session),
  })

  // The workspace's paths, for `@` completion (tui.md §11, T13). Built in the
  // background from the moment the screen exists: the first `@` before it
  // finishes shows nothing and the next one shows everything, which beats a
  // composer that stops accepting characters while git walks a monorepo.
  const references = createProjectIndex(props.ws.dir)
  /**
   * The skill catalog behind `/name` (tui.md §11, T15). It goes stale exactly
   * when an extension is activated or deactivated, which is why `/ext` hands
   * back `invalidate` rather than this polling for it.
   */
  const skills = createSkillTable(props.ws)
  /**
   * Package-declared slash commands (tui-plugin D1/D2/D8), same staleness
   * contract as `skills` above — `/ext` invalidates both on a membership
   * change, since activating or deactivating a package can add or remove
   * either kind of thing it offers.
   */
  const packageCmds = createPackageCommandTable(props.ws)

  /**
   * The line under the composer, when it has news (T35).
   *
   * A notice covers that whole line while it is up, so it must also come down
   * on its own: a message that stays is a message that stops being true — the
   * screen said `Ctrl+C again to quit` long after the offer had lapsed, and
   * `opened s-…` for the rest of the session. Everything here is news by
   * default and goes stale; `holdNotice` is for the two things that are not
   * news but a state the screen is IN (browse mode, a handoff awaiting an
   * answer), which their own code path clears.
   */
  const [notice, setNoticeState] = createSignal<{ text: string; hold: boolean } | null>(null)
  const setNotice = (text: string | null) => setNoticeState(text === null ? null : { text, hold: false })
  const holdNotice = (text: string) => setNoticeState({ text, hold: true })
  createEffect(() => {
    const current = notice()
    if (!current || current.hold) return
    const timer = setTimeout(() => setNoticeState((now) => (now === current ? null : now)), noticeHold(current.text))
    onCleanup(() => clearTimeout(timer))
  })
  const [guide, setGuide] = createSignal<string | null>(props.guide ?? null)
  /** Which provider `/model` should open on, when `/provider` sent it there. */
  const [focusProfile, setFocusProfile] = createSignal<string | undefined>(undefined)
  /**
   * Sessions this process will not ask about again on the way out: either a
   * verdict was recorded, or the question was already put once and declined.
   */
  const [settled, setSettled] = createSignal<readonly string[]>([])
  /** Whether `/quit` has already said what happens to a running task. */
  const [tasksWarned, setTasksWarned] = createSignal(false)
  const [spinnerTick, setSpinnerTick] = createSignal(0)
  const [ctrlCArmed, setCtrlCArmed] = createSignal(false)
  const [behind, setBehind] = createSignal(0)
  /**
   * Bumped whenever the pin list on disk may have moved (an overlay closed, a
   * session was created). The draft card's tool face is read from files, and a
   * signal is what tells this screen to look again.
   */
  const [planTick, setPlanTick] = createSignal(0)
  /**
   * The permission mode (tui.md §5.7). Remembered on screen, like the model
   * pick: `tui-state.json` first (what was last chosen here), then `tui.toml`'s
   * `[driver] mode`, then `ask`.
   */
  const [mode, setMode] = createSignal<PermissionMode>(
    loadTuiState(props.statePath).mode ?? props.style.settings.driver.mode,
  )
  /**
   * Whether the mode picker is up, and which row its cursor is on (tui.md §5.7,
   * T31). A dialog above the composer rather than a full-screen overlay — two
   * rows of content — so it is its own two signals rather than an `OverlayKind`.
   */
  const [modePicker, setModePicker] = createSignal(false)
  const [modeChoice, setModeChoice] = createSignal(0)
  /**
   * What `a` has collected. In memory and per run on purpose: trying a tool out
   * should cost nothing and leave nothing in a file somebody else reads — the
   * durable form of the same statement is `[approvals] allow` in `tui.toml`.
   */
  const [always, setAlways] = createSignal<ReadonlySet<string>>(new Set())
  /**
   * The calls the kernel is holding open, oldest first — the head is the one on
   * screen. A queue rather than one slot because this process can drive more
   * than one tab: two sessions stepping at once can each stop on a call, and a
   * second request that overwrote the first would leave that step waiting on a
   * promise nobody can resolve, holding its writer lease forever.
   */
  const [pendingQueue, setPendingQueue] = createSignal<readonly Approval[]>([])
  const pending = (): Approval | null => pendingQueue()[0] ?? null
  /**
   * Calls `A` has waved through: the rest of the batch the person was looking
   * at when they pressed it (tui.md §5.7).
   *
   * Ids, not a flag, and that is the whole point. A run can contain several
   * steps, so "allow the rest" as a boolean would quietly cover a batch nobody
   * has seen yet; the ids are exactly the calls that were on screen — every one
   * of them already drawn as a card — and nothing else can join the set.
   */
  const [batchAllowed, setBatchAllowed] = createSignal<ReadonlySet<string>>(new Set())
  /** Which answer the approval dialog's cursor is on (tui.md §5.7). */
  const [choice, setChoice] = createSignal(0)
  /** Whether the dialog's note field has the keyboard rather than the list. */
  const [noteFocused, setNoteFocused] = createSignal(false)
  /** The dialog's note field, for focusing, reading and clearing it. */
  let noteField: InputRenderable | null = null

  /**
   * The agent definitions this workspace and this machine hold (tui.md §5.10).
   *
   * Re-read whenever `/agent` is used rather than watched: a definition is a
   * file somebody edits in another window, and the moment that matters is the
   * moment one is about to be used. Warnings are the parser's own — a file that
   * is not a definition is named and skipped, never fatal.
   */
  const [agentDefs, setAgentDefs] = createSignal<readonly AgentEntry[]>([])
  const [agentWarnings, setAgentWarnings] = createSignal<readonly string[]>([])
  /** Whether the picker is up, and which row its cursor is on (`AgentPicker`). */
  const [agentPicker, setAgentPicker] = createSignal(false)
  /** Bare `/with`: the registered packages a session may name (`WithPicker`). */
  const [withPicker, setWithPicker] = createSignal(false)
  const [withChoice, setWithChoice] = createSignal(0)
  const [wearables, setWearables] = createSignal<Wearable[]>([])
  const [agentChoice, setAgentChoice] = createSignal(0)
  /**
   * Which tabs are running an agent definition, and which one — the tab-level
   * gate policy reads it (`readonlyCeiling`). A map rather than tab state
   * because it is a fact about a delegation this process started, and a session
   * re-opened later is an ordinary session again: its composition still carries
   * the persona, but the ceiling was never in the ledger and this front end must
   * not pretend it was.
   */
  const agentOf = new Map<string, RenderedAgent>()
  /**
   * The packages this front end composes sessions with, resolved once each and
   * shared. Compiled ones cost a toolchain run the first time on a machine,
   * which is why every caller goes through this instead of building again — and
   * why nothing here happens on mount.
   *
   * One map where there used to be one `let` per package (T34): `handoff` and
   * `agent` are two entries in `[extensions] session_with`, and `agentPackage`
   * below reads the same entry the composition does rather than building the
   * same draft a second time.
   */
  const memberBuilds = new Map<string, Promise<SessionMember | null>>()
  const sessionMemberOnce = (id: string): Promise<SessionMember | null> => {
    let started = memberBuilds.get(id)
    if (!started) {
      started = sessionMember(props.ws, id).catch(() => null)
      memberBuilds.set(id, started)
    }
    return started
  }
  /** The `agent` package, for the delegation paths that need its version. */
  const agentPackage = async (): Promise<WithRef | null> => {
    const member = await sessionMemberOnce(agent_id)
    return member ? { id: member.id, version: member.version } : null
  }
  /**
   * The pins those packages will put on the face, known before the session
   * exists (T42) — so the draft screen can count them.
   *
   * Read from the ACTIVE version's manifest (one `ext list`), not by resolving
   * the member: `sessionMember` builds the bundled draft, which is a toolchain
   * run, and a screen that has not been asked for anything yet must not start
   * one (T23). A pin names a TOOL, never a version (`ext:agent/agent`), so the
   * two answers differ only for a package that is not active anywhere on this
   * machine — and the background sync that runs at the same moment is what makes
   * it active. Under-reporting for that one second is the right way to be wrong.
   */
  const [composedPins, setComposedPins] = createSignal<readonly string[]>([])
  const resolveComposedPins = async () => {
    try {
      const listed = await listExtensions(props.ws)
      const pins: string[] = []
      for (const id of props.style.settings.extensions.session_with) {
        const entry = listed.find((held) => held.id === id && held.current !== null && !held.shadowed)
        if (entry) pins.push(...pinsOf(entry))
      }
      setComposedPins(pins)
      healStandingPins(listed)
    } catch {
      // No listing is "unknown"; the count stays what the pin files say.
    }
  }

  /**
   * Take back standing pins this front end should no longer hold — before the
   * first message, not when somebody happens to open `/ext`.
   *
   * One kind of stale line: a pin whose package has no `current` any more. A
   * pin brings its package in (DESIGN §5.1), and with nothing to bring the
   * session does not start at all (`WithVersionNotFound`, `cli/session.zig`).
   * `/ext` has repaired this list since T12, but only while its panel was up.
   * The list is our own program state; dropping a line out loud is the honest
   * repair, and the same one `ExtView.dropOrphanPins` makes.
   */
  const healStandingPins = (listed: readonly ExtensionEntry[]) => {
    const pins = sessionPins(props.statePath)
    const orphans = orphanPins(pins, resolvableStandingPins(listed))
    if (orphans.length === 0) return
    rememberSessionPins(
      pins.filter((pin) => !orphans.includes(pin)),
      props.statePath,
    )
    setPlanTick((tick) => tick + 1)
    setNotice(`${orphans.join(" ")} unpinned · nothing composed into every session declares them`)
  }

  /**
   * Why the draft in front of this person is still a draft (tui.md §11, T46).
   *
   * A `session new` that refuses says a paragraph — the untrusted store and
   * everything in it, or every pin when one of them names nothing — and it used
   * to be shown only on the status line, which is ONE row shared with the model
   * and the cost. `session new failed: a pin names an extension with no active`
   * was the whole of what a person could read about a front end that would not
   * open a session at all.
   *
   * So it goes where a failure has room: the transcript, through the notice a
   * session's own driver failures already use (`ErrorNotice`). Its lifetime is
   * the draft's — cleared the moment the next attempt starts, so it never
   * outlives the thing it explains, and never appears over a session that did
   * open.
   */
  const [refusal, setRefusal] = createSignal<string | null>(null)

  /** A handover the model proposed and nobody has answered yet (tui.md §5.8). */
  const [handoff, setHandoff] = createSignal<HandoffFile | null>(null)
  /** Handoff files this process has already acted on or dismissed. */
  const [handoffsSeen, setHandoffsSeen] = createSignal<ReadonlySet<string>>(new Set())
  let composer: ComposerApi | null = null
  let scroll: ScrollBoxRenderable | null = null

  const tab = () => tabs.active()
  /**
   * The front tab's session, or null while it is still a draft. Everything that
   * would DO something to a session goes through this; everything that only
   * paints reads `snapshot()`, which is honestly empty on a draft.
   */
  const live = (): SessionTab | null => {
    const here = tab()
    return here.kind === "session" ? here : null
  }
  const draft = (): DraftTab | null => {
    const here = tab()
    return here.kind === "draft" ? here : null
  }
  const snapshot = () => live()?.state.snapshot ?? no_snapshot
  const status = () => live()?.attach.status() ?? "idle"
  const role = () => live()?.attach.role() ?? "driver"
  /**
   * Lazy, not memoised: a memo runs on creation and `plugins` is not built yet
   * at this point in `App`. It is read on a keypress, never on a frame — the
   * transcript's own row list is where the memo has to be (`Transcript.rows`).
   */
  const cards = () =>
    foldable(
      transcriptRows(snapshot().items, props.style, live()?.contributions() ?? [], (tool) => plugins.cardFor(tool) != null),
    )
  /** This tab's background tasks, and how many of them have not ended (§5.9). */
  const tasks = (): TaskEntry[] => live()?.tasks.tasks() ?? []
  const runningTasks = () => live()?.tasks.live() ?? 0

  createEffect(() => {
    if (!props.style.motion) return
    // A background task spins the same spinner while the driver rests: it is the
    // one thing that keeps happening when nothing else is (tui.md §5.9).
    if (status() === "idle" && runningTasks() === 0) return
    const timer = setInterval(() => setSpinnerTick((tick) => tick + 1), 90)
    onCleanup(() => clearInterval(timer))
  })

  /**
   * Build the drafts sitting in the store roots, in the background (tui.md §11,
   * T11). A compiled draft takes seconds, so this must never be on the way in —
   * the transcript is usable throughout and the status line says what is going
   * on. Nothing here decides what a draft is or which version it becomes: the
   * plan and the pass are both `nulya ext sync`.
   *
   * Activation is narrower than the kernel's `--activate`, which also points
   * `current` at any id that has none at all: this pass only activates versions
   * it produced itself, so a package somebody deliberately rolled back stays
   * where they put it.
   *
   * It no longer asks WHAT a package contributes before pointing at it (K8).
   * Activating is safe now — it says which version `<id>` means and composes
   * nothing (DESIGN §5.1) — so the guard that used to keep `evolution`'s system
   * prompt out of every session has nothing left to guard: composing is
   * `[extensions] with` and `/ext`'s Enter, both of them a person's line.
   */
  const syncStores = async () => {
    const plan = props.sync
    if (!plan) return
    // The drafts the BINARY ships, into the user store, before the pass that
    // builds them: seeding writes source only (DESIGN §7.8), so the one pass
    // below builds what arrived along with everything else. This used to be a
    // question on a bare terminal BEFORE the screen existed, and answering it
    // held that terminal for a minute of zig with `installing…` as the only
    // sign of life (tui.md §11, T23).
    //
    // It also CARRIES FORWARD the drafts a previous binary seeded and nobody has
    // edited since (T42) — before that, upgrading nulya left the user store on
    // whatever source the first binary happened to drop, so a package that grew
    // a tool, or lost a manifest field, stayed as it was until somebody deleted
    // the directory. Drafts that were edited are left alone and named
    // below; the ids seeding moved are ordinary changed drafts to the pass that
    // follows, which builds them and points `current` at what it built.
    let arrived: string[] = []
    let refreshed: string[] = []
    let untouched: string[] = []
    if (plan.user && plan.bundled) {
      try {
        setNotice("installing the bundled extensions…")
        const seed = await seedBundled(props.ws)
        arrived = seed.ids
        refreshed = seed.updated
        untouched = seed.mine
      } catch {
        // A binary too old to have `ext seed` ships nothing to install.
      }
    }
    const roots = [
      ...(plan.user ? [{ label: "user store", user: true }] : []),
      ...(plan.project ? [{ label: "this checkout", user: false }] : []),
    ]
    // One line of news for the whole pass, across roots: a quiet second root
    // must not wipe what the first one had to say.
    const news: string[] = []
    for (const root of roots) {
      try {
        const total = (await planStore(props.ws, root.user)).lines.length
        if (total === 0) continue
        let done = 0
        setNotice(`syncing extensions… 0/${total}`)
        const report = await extSync(props.ws, { user: root.user }, () => {
          done += 1
          setNotice(`syncing extensions… ${done}/${total}`)
        })
        let activated = 0
        if (plan.activate) {
          for (const line of report.lines) {
            if (line.state !== "built" || !line.version || line.activation === "active") continue
            // What arrived with the binary this run is `adoptBundled`'s to
            // decide: everything a fresh seed drops is `built` by this pass.
            if (arrived.includes(line.id)) continue
            try {
              await extSetCurrent(props.ws, "activate", line.id, line.version, { user: root.user })
              activated += 1
            } catch {
              // The version is built either way; `/ext`'s `a` can still point
              // `current` at it, and a failed pointer move is not sync news.
            }
          }
        }
        const adopted =
          root.user && arrived.length > 0 && plan.activate
            ? await adoptBundled(props.ws, arrived, report, props.statePath)
            : []
        // The std pins land in `tui-state.json`, which the draft card and the
        // status line read from disk: this is what tells them to look again.
        if (adopted.length > 0) setPlanTick((tick) => tick + 1)
        // A count of failures is not news anybody can act on. Name them, and
        // point at the one screen that says why and offers the way out — and
        // name them under the right verb: a draft that does not compile and one
        // this machine has no toolchain for are two different errands.
        const failed = failedIds(report)
        const needsZig = needsZigIds(report)
        // A pass that changed nothing has no news — "0 built · 5 already" would
        // park on the status line until the next keypress and say nothing. The
        // durable per-id state lives in /ext either way.
        if (
          report.built === 0 &&
          failed.length === 0 &&
          needsZig.length === 0 &&
          activated === 0 &&
          adopted.length === 0
        ) {
          continue
        }
        news.push(
          summarize(root.label, report) +
            (activated > 0 ? ` · ${activated} activated` : "") +
            adopted.map((part) => ` · ${part}`).join("") +
            (failed.length > 0 ? ` · ${failed.join(" ")} not built · /ext` : "") +
            // A different sentence, because it is a different repair: nothing
            // is wrong with these drafts, this machine just cannot compile one.
            // `/ext` carries the kernel's own line, which names the directory a
            // toolchain can be unpacked into.
            (needsZig.length > 0 ? ` · ${needsZig.join(" ")} need a toolchain · /ext` : ""),
        )
      } catch (error) {
        news.push(`extension sync: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
    // What the binary brought and what it did not dare touch (T42). The second
    // half is the one that needs a person: a bundled draft it cannot recognise
    // as its own is either something you wrote or something an old nulya seeded,
    // and only you know which — so it is named with the command that replaces it
    // rather than replaced.
    if (refreshed.length > 0) news.push(`${refreshed.join(" & ")} updated to this build`)
    if (untouched.length > 0) {
      // A notice is not where this lives — it is durable state, and `/ext` says
      // it for as long as it is true, with the key that fixes it (T42). Naming a
      // shell command here was the wrong shape twice over: it is gone in six
      // seconds, and it asks a person to leave the program to repair it.
      news.push(`${untouched.join(" & ")} differ from this build · /ext · s updates one`)
    }
    // There used to be one more line here: whichever mode packages were active
    // on this machine, named because activating one put its system prompt in
    // front of every model (T31). That state no longer exists — `current` says
    // which version an id means and composes nothing (DESIGN §5.1) — so there
    // is nothing to warn about and no list to compute.
    setNotice(news.length > 0 ? news.join(" · ") : null)
  }

  // …and only then the code layer: a plugin lives in an ACTIVE version, and
  // the pass above is what makes a freshly seeded package active. Chained
  // rather than parallel for that ordering alone — `syncStores` returns at once
  // when there is nothing to sync (a test, `sync_on_start = false`).
  onMount(() => void syncStores().then(loadPlugins).then(resolveComposedPins))

  // "Ctrl+C again to quit" is an offer about THIS step. It lapses when a new
  // step starts (the first press must kill again, not quit) and after a short
  // while regardless, so a press minutes later is never a surprise exit.
  createEffect(() => {
    if (status() === "stepping") setCtrlCArmed(false)
  })
  createEffect(() => {
    if (!ctrlCArmed()) return
    // The offer comes off the screen with the arm that backs it. Leaving the
    // words up past the window they describe is how the bottom line ended up
    // permanently reading `Ctrl+C again to quit` on a session where the next
    // press would have done nothing of the sort.
    const said = untrack(notice)
    const timer = setTimeout(() => {
      setCtrlCArmed(false)
      setNoticeState((now) => (now === said ? null : now))
    }, ctrl_c_ms)
    onCleanup(() => clearTimeout(timer))
  })

  // How far back the reader has scrolled. Polled rather than derived: the wheel
  // and the scrollbar move the box without going through us, so the only honest
  // source is the box itself. One subtraction every 200ms.
  //
  // Two polls have to agree before it shows. While a tall turn is being laid
  // out the box is briefly a screenful away from its own sticky bottom, and a
  // "16 more below" that flashes on every long answer is worse than none.
  createEffect(() => {
    let previous = 0
    const timer = setInterval(() => {
      const now = rowsBelow(scroll)
      setBehind(now > 0 && previous > 0 ? now : 0)
      previous = now
    }, 200)
    onCleanup(() => clearInterval(timer))
  })

  const scrollBy = (pages: number) => {
    if (!scroll) return
    const page = Math.max(1, (scroll.viewport?.height ?? 10) - 2)
    scroll.scrollBy({ x: 0, y: Math.round(page * pages) })
    setBehind(rowsBelow(scroll))
  }

  const scrollToEnd = () => {
    if (!scroll) return
    scroll.scrollTo({ x: 0, y: scroll.scrollHeight })
    setBehind(0)
  }

  /**
   * Dragging across the screen selects text, and letting go copies it
   * (tui.md §11, T18).
   *
   * All the machinery is OpenTUI's: a press on selectable text starts a
   * selection, the drag extends it, the release emits it, and `getSelectedText`
   * assembles what the selected renderables actually drew. The only decision
   * here is what "let go" means — and it means the clipboard, because a
   * terminal front end that draws over the scrollback has taken away the
   * terminal's own selection and owes one back.
   *
   * OSC 52 rather than a host clipboard helper: it is one escape sequence to
   * the terminal already attached to this process, so it works over ssh and
   * needs nothing installed. Terminals that refuse it simply do not copy, which
   * is why the notice reports the copy rather than assuming it.
   */
  onMount(() => {
    const copy = (selection: Selection | null) => {
      const text = selection?.getSelectedText() ?? ""
      // Every plain click ends a zero-width selection; only a real one is news.
      if (text.length === 0) return
      try {
        if (renderer.copyToClipboardOSC52(text)) setNotice(`copied ${text.length} characters`)
      } catch {
        // No clipboard is not an error: the selection stands, it just stays here.
      }
    }
    renderer.on("selection", copy)
    onCleanup(() => renderer.off("selection", copy))
  })

  onCleanup(() => tabs.disposeAll())

  /** One tip per launch, chosen here so re-rendering the screen cannot reroll it. */
  const tip = pickTip()

  const spinnerFrame = () => props.style.spinner[spinnerTick() % props.style.spinner.length]!

  /**
   * What the line above the composer says (T38). The rules are in
   * `WorkingStatus.activityOf` — a pure function of the same facts the status
   * bar reads — so "what is happening" has exactly one definition.
   */
  const activity = createMemo(() =>
    activityOf({
      status: status(),
      role: role(),
      snapshot: snapshot(),
      takeoverReady: live()?.attach.takeoverReady() ?? false,
      awaiting: pending() !== null,
      background: runningTasks(),
    }),
  )

  /**
   * `Date.now()`, resampled on the animation tick rather than read during a
   * render. A render that reads the wall clock is not a function of its inputs
   * — it would show a different elapsed each repaint and never repaint on its
   * own — so the tick that moves the sweep is also what moves the clock.
   */
  const clockNow = () => (spinnerTick(), Date.now())

  /** The session a card names, if it names one — the sub-session link (tui.md §5.5). */
  const sessionOf = (item: TranscriptItem | null): string | null => {
    if (!item || item.kind !== "tool") return null
    return describeTool({ tool: item.tool, args: item.args, output: item.output }, props.style.glyphs).sessionId
  }

  const enterBrowse = () => {
    const list = cards()
    if (list.length === 0) return
    composer?.blur()
    browse.enter(list[list.length - 1]!.key)
    holdNotice("browse · j/k move · Enter open/fold · Space fold · Esc back")
  }

  const leaveBrowse = () => {
    browse.exit()
    composer?.focus()
    setNotice(null)
  }

  const moveBrowse = (delta: number) => {
    const list = cards()
    if (list.length === 0) return
    const at = list.findIndex((item) => item.key === browse.selected())
    const next = Math.min(Math.max((at < 0 ? list.length - 1 : at) + delta, 0), list.length - 1)
    browse.select(list[next]!.key)
  }

  /** The item under the browse cursor — null on a run summary, which is a row rather than an event. */
  const selectedItem = () => cards().find((row) => row.key === browse.selected())?.item ?? null

  const toggleSelected = () => {
    const key = browse.selected()
    if (key) folds.toggle(key, false)
  }

  const openOverlay = (kind: OverlayKind) => {
    if (browse.active()) leaveBrowse()
    const opening = overlay.kind() !== kind
    overlay.toggle(kind)
    if (opening) composer?.blur()
    else composer?.focus()
    // Opening `/model` any other way is about the whole list again, so the
    // provider `/provider` handed over is not still selecting rows for it.
    setFocusProfile(undefined)
    setNotice(null)
  }

  /**
   * `/provider` chose a provider: `/model`, landed on its first model (tui.md
   * §11, T21). This is the second step of "pick a provider, then its model" —
   * two screens, as in tcode, rather than two levels of one. The guide goes
   * with it: whatever sent the person to the providers has been dealt with by
   * the time they are choosing among models.
   */
  const showModelsOf = (profile: string) => {
    setFocusProfile(profile)
    setGuide(null)
    overlay.open("model")
    setNotice(null)
  }

  const closeOverlay = () => {
    overlay.close()
    composer?.focus()
    // `/ext` may have moved a pin or an activation while it was up, and the
    // draft card's tool face is read off those files — including, since T42,
    // what the `session_with` packages contribute, which an activation there
    // can have just changed.
    setPlanTick((tick) => tick + 1)
    void resolveComposedPins()
  }

  const openSession = (id: string, created = false) => {
    tabs.open(id, { created })
    closeOverlay()
    setNotice(`opened ${id}`)
  }

  /**
   * What a card's link does (T43). One entry point, so clicking `↗ open …` on a
   * delegation card and pressing `Enter` on it in browse mode are the same move
   * and cannot drift; browse mode steps aside first, because the keyboard
   * belongs to the tab that just came to the front.
   */
  const navigate: Navigate = {
    openSession: (id) => {
      if (browse.active()) leaveBrowse()
      openSession(id)
    },
  }

  /**
   * The model id a pick will actually run on. A pick may name only a profile
   * (`/new --profile p`, the kernel's active profile at launch), and then the
   * model is that profile's default — which `config show` already says, so the
   * draft can name it rather than showing a provider where a model belongs.
   */
  const modelOf = (pick: ModelPick | undefined): string => {
    if (!pick) return ""
    if (pick.model) return pick.model
    return props.profiles?.find((profile) => profile.name === pick.profile)?.model || pick.profile
  }

  /** The model the front tab talks to: frozen on a session, chosen on a draft. */
  const modelName = (): string => {
    const here = tab()
    if (here.kind === "draft") return modelOf(here.pick())
    const header = snapshot().header
    return header?.model_identity.model || header?.model || ""
  }

  /**
   * What the next `session new` from this TUI would put on the model's face:
   * the merged config pins, this TUI's own list, and the pins the packages in
   * `[extensions] session_with` bring with them (T42).
   *
   * That third source is not a third ANSWER — it is the same `--pin` arguments
   * `sessionExtras` is about to pass, asked for early. It was missing here, and
   * the cost was a screen that said `tools 1+5` and listed no `agent` on every
   * draft, while the session that started a keystroke later froze `agent`'s
   * tools onto the face: the one place a person looks to find out what the model
   * can do was under-reporting it, and the honest reading of that screen was
   * "the agent package is off".
   */
  // A memo, because reading it is a file read: it is asked for once per frame by
  // both the status line and the draft card, and it can only change when
  // something wrote that file — which is what `planTick` says.
  const plannedPins = createMemo((): string[] => {
    planTick()
    const face = [...(props.pinnedTools ?? [])]
    for (const pin of sessionPins(props.statePath)) if (!face.includes(pin)) face.push(pin)
    for (const pin of composedPins()) if (!face.includes(pin)) face.push(pin)
    return face
  })

  /** The tool face this tab shows beside the builtin. */
  const faceSize = (): number => {
    const here = tab()
    if (here.kind === "draft") return plannedPins().length
    return snapshot().header?.composition.native_tools.length ?? 0
  }

  /**
   * The packages whose SYSTEM PROMPT this tab is wearing (tui.md §11, T31).
   *
   * A `--with` member is usually nothing but a prompt — a mode, an identity —
   * and it is the single fact that changes what the model thinks it is. It was
   * visible on the draft screen and on the composition card, and nowhere at all
   * once the session had started and the card was folded, which is how a session
   * carrying `evolution` looked exactly like one that was not.
   *
   * A draft has only its `--with` ref (nothing is frozen yet, and the version is
   * not built into a manifest this side can read); a started session has the
   * frozen contributions, which say which members actually contribute a prompt
   * — plus whatever `--prompt` froze into its header by value, which is a system
   * prompt this session wears by exactly the same measure and belongs to no
   * package at all (a sub-agent persona is the one that does this).
   */
  const wearing = (): string[] => {
    const here = tab()
    if (here.kind === "draft") {
      const bring = here.bring()
      return bring ? [bring.id] : []
    }
    return [
      ...here.contributions().filter((c) => c.systemPrompts.length > 0).map((c) => c.id),
      ...(snapshot().header?.composition.prompts ?? []).map((p) => p.source),
    ]
  }

  /** What a draft tab's first message would freeze — the welcome screen's facts. */
  const plan = (): NextSession | undefined => {
    const here = draft()
    if (!here) return undefined
    const bring = here.bring()
    return {
      tools: plannedPins(),
      ...(bring ? { bring: formatWithRef(bring) } : {}),
    }
  }

  /**
   * The front tab's context window, when the catalog names one. The model id is
   * the key — not the profile — since a window is a property of the model,
   * whoever serves it (DESIGN §9.5).
   */
  const contextWindow = (): number | null => {
    const id = snapshot().header?.model_identity.model
    if (!id) return null
    return props.models?.find((m) => m.id === id)?.context_window ?? null
  }

  /** What the front tab runs on, in the picker's terms. */
  const currentPick = (): ModelPick | null => {
    const here = tab()
    if (here.kind === "draft") {
      const pick = here.pick()
      return pick ? { ...pick, effort: here.effort() } : null
    }
    const header = snapshot().header
    if (!header) return null
    return { profile: header.model, model: header.model_identity.model || undefined, effort: here.effort() }
  }

  /**
   * Choose what the next session runs on, and remember it as the last pick.
   *
   * Nothing is created here. On a draft this only rewrites the draft — no
   * process, no file — and on a started session it opens a NEW draft beside it,
   * because a session's model is frozen (physics #2) and the honest way to
   * "switch model" has always been a new session. Which now costs nothing until
   * there is something to say.
   *
   * `pick` undefined means "the last pick, else the kernel's default" — what a
   * bare `/new` does. `bring` is the `--with` member `/evolve` and `/mode` put
   * on the session: membership in that one composition and no other.
   */
  const startDraft = (pick?: ModelPick, remember = pick !== undefined, bring?: WithRef) => {
    const chosen = pick ?? loadTuiState(props.statePath).model
    const here = draft()
    if (here) {
      if (chosen) here.setPick(chosen)
      if (chosen?.effort !== undefined) here.setEffort(chosen.effort)
      if (bring) here.setBring(bring)
    } else {
      tabs.draft({ ...(chosen ? { pick: chosen } : {}), ...(bring ? { bring } : {}), ...(chosen?.effort ? { effort: chosen.effort } : {}) })
    }
    closeOverlay()
    setGuide(null)
    const what = bring ? ` · with ${formatWithRef(bring)}` : ""
    const who = chosen ? `${modelOf(chosen)}` : "the default model"
    setNotice(`next session · ${who}${what} · starts when you send a message`)
    if (remember && chosen) rememberModel(chosen, props.statePath)
  }

  /**
   * The session this tab is about to have. A draft becomes one here and nowhere
   * else, so this is the single moment the composition of a TUI session is
   * decided — with whatever `/ext` and `/model` have been told by then.
   *
   * A refusal (no credential, an untrusted store, a pin naming nothing) leaves
   * the draft exactly as it was: the kernel's own sentence goes to the notice
   * and the caller keeps the user's text.
   */
  const ensureSession = async (): Promise<SessionTab | null> => {
    const here = tab()
    if (here.kind === "session") return here
    setRefusal(null)
    try {
      const extras = await sessionExtras()
      const worn = await wornPins(here.bring())
      const tab = await tabs.materialize(here, {
        ...extras,
        ...(worn.length > 0 ? { pin: [...(extras.pin ?? []), ...worn] } : {}),
      })
      setPlanTick((tick) => tick + 1)
      return tab
    } catch (error) {
      setRefusal(error instanceof CliError ? error.detail : error instanceof Error ? error.message : String(error))
      setNotice(error instanceof Error ? error.message : String(error))
      return null
    }
  }

  /**
   * Everything the SCREEN adds to a top-level `session new`: one `--with` and
   * its pins for each id in `[extensions] session_with` (tui.md §5.8 / §5.10).
   *
   * Two axes, both needed and both separate (DESIGN §7.5): `--with` makes the
   * version a member of this composition, `--pin` gives a tool a native slot so
   * the model can actually call it. WHICH tools get a slot is the package's own
   * answer now (`audience`, DESIGN §7.2.1) instead of a constant per package
   * here — which is what let two hand-written branches become this loop (T34).
   *
   * A package that cannot be resolved costs the session nothing: it starts
   * without it and says so, rather than not starting.
   *
   * **Only top-level**, and that condition is load-bearing for `agent`: a
   * delegated session does not get it, so a sub-agent cannot delegate again —
   * one level, until there is a reason and a bound for more (agents-and-review
   * §1, `SpawnPolicy` in its minimal form). Which is why this lives here and not
   * in `startAgent`, the thing that composes a child.
   */
  /**
   * The pins that travel with this draft's `--with` (`/plan`, `/ask`, `/with`,
   * `/evolve`).
   *
   * Membership and pins are separate axes everywhere else (DESIGN §7.5), and
   * for a WORN package they cannot be: it is a member of exactly this session,
   * so a pin naming its tool belongs in exactly this argv. On a standing list
   * it would not cost a tool — it would wear the mode in every session, which
   * is the difference `/with` exists to make.
   *
   * A package that cannot be read costs nothing: the session starts with the
   * member and without the pins, which is what wearing it meant before its
   * tools were ever on the face.
   */
  const wornPins = async (bring: WithRef | undefined): Promise<string[]> => {
    if (!bring) return []
    try {
      const version =
        bring.version ??
        (await listExtensions(props.ws)).find((entry) => entry.id === bring.id && !entry.shadowed)?.current
      if (!version) return []
      return pinsOf(await readContributions(props.ws, bring.id, version))
    } catch {
      return []
    }
  }

  const sessionExtras = async (): Promise<{ with?: string[]; pin?: string[] }> => {
    const withRefs: string[] = []
    const pins: string[] = []
    const missing: string[] = []
    for (const id of props.style.settings.extensions.session_with) {
      const member = await sessionMemberOnce(id)
      if (!member) {
        missing.push(id)
        continue
      }
      withRefs.push(formatWithRef({ id: member.id, version: member.version }))
      pins.push(...member.pins)
    }
    // …and this TUI's own standing membership list, the half of `/ext`'s Enter
    // that `session_pins` is the other half of (K8). BARE ids, unlike the two
    // above: those are packages this front end resolves to an exact version
    // because it needs their pins before the session exists, while these follow
    // `current` exactly as the kernel's own `[extensions] with` does — so `/ext`
    // rolling one back with `a` is honoured without touching this list.
    for (const id of sessionWith(props.statePath)) {
      if (!withRefs.some((ref) => ref === id || ref.startsWith(`${id}@`))) withRefs.push(id)
    }
    if (missing.length > 0) setNotice(`${missing.join(" & ")} not composed in · /ext for what it said`)
    return {
      ...(withRefs.length > 0 ? { with: withRefs } : {}),
      ...(pins.length > 0 ? { pin: pins } : {}),
    }
  }

  // ── The plugin host (tui-plugin U3) ───────────────────────────────────────

  /**
   * Whether a dialog owns the composer area right now.
   *
   * Three of these are TRUSTED ZONES and the reason this predicate exists at
   * all (tui-plugin D4): the approval dialog, the permission-mode picker and
   * `/provider`'s key field are where a person answers about permission or
   * types a secret, and a plugin panel must be unable to appear over them or
   * take a keystroke meant for them. A plugin's `open()` while one is up does
   * not fail — it waits, and lands the moment the zone clears, which is the
   * behaviour a plugin cannot tell apart from having opened slowly.
   *
   * The `/with` and `/agent` pickers are in here too, for a duller reason:
   * they are dialogs in the same three rows, and two of them drawn at once is
   * just a mess. Nothing is being protected there.
   */
  const dialogUp = (): boolean =>
    pending() !== null || modePicker() || withPicker() || agentPicker() || overlay.kind() === "provider"

  /** The front tab's session, in the read-only shape the contract projects. */
  const pluginSession = () => {
    const here = live()
    if (!here) return null
    const header = here.state.snapshot.header
    return {
      id: here.id,
      model: header?.model_identity.model || header?.model || "",
      members: here.contributions().map((c) => ({ id: c.id, version: c.version, tools: [...c.tools] })),
    }
  }

  /**
   * The code layer (`tui.toml` `[extensions] plugins`, tui-plugin U3). Every
   * seam it is given is a verb this screen already performs for a person (D5):
   * there is no way from here to answer the gate, write a session file, or
   * reach a package other than the plugin's own.
   *
   * One host per process, not per tab, and the tab context rides in the seams:
   * a module that has been imported has been imported, and pretending
   * otherwise would mean calling one package's `activate` once per tab with
   * several APIs that all wrote to the same `tui-state.json` slot.
   */
  const plugins = createPluginHost({
    ws: props.ws,
    enabled: props.style.settings.extensions.plugins,
    ...(props.statePath ? { statePath: props.statePath } : {}),
    // The union over every open session: a package a tab is WEARING is loaded
    // at the version that tab froze, which is not necessarily the store's
    // `current` (`pluginCandidates`).
    members: () =>
      tabs
        .tabs()
        .flatMap((one) => (one.kind === "session" ? one.contributions() : [])),
    session: pluginSession,
    tasks: () =>
      tasks().map((task) => ({
        task: task.task,
        state: task.state,
        command: task.command,
        exitCode: task.exit_code,
      })),
    appendNote: async (pkg, kind, text) => {
      const here = live()
      if (!here) throw new Error(`${pkg}: this tab has no session yet · nothing to append to`)
      // Framed by us, so the driver does not ALSO wrap it as a mid-task
      // message: this turn already says how it got there (`extnote.ts`), and
      // two sentinels on one turn is one card the transcript cannot fold.
      await here.attach.send(wrapExtNote(pkg, kind, text), true)
    },
    compact: (options) => forkHere(options),
    openTab: (sessionId) => {
      tabs.open(sessionId)
      setNotice(`opened ${sessionId}`)
    },
    wearNext: (id) => startDraft(undefined, false, { id }),
    notice: setNotice,
    zoneBusy: dialogUp,
  })

  /**
   * Load, and say what could not be. A pass adds warnings and never removes
   * them, so the count is what tells a later pass whether it has news — the
   * first one usually has none, which is the point of not announcing anything
   * when a machine has no plugins at all.
   */
  const loadPlugins = async () => {
    const before = plugins.warnings().length
    await plugins.load()
    const fresh = plugins.warnings().slice(before)
    if (fresh.length > 0) setNotice(fresh.join(" · "))
  }

  /**
   * A tab's frozen composition arrived: a package this session is WEARING can
   * ship a front end at exactly the version that session froze, which the
   * store's `current` need not name any more (`pluginCandidates`' second
   * half). Only when the set actually grows — `contributions()` settles once
   * per tab, and a pass costs an `ext list`.
   */
  const wornSeen = new Set<string>()
  createEffect(() => {
    const worn = tabs
      .tabs()
      .flatMap((one) => (one.kind === "session" ? one.contributions() : []))
      .map((c) => `${c.id}@${c.version}`)
    if (worn.every((ref) => wornSeen.has(ref))) return
    for (const ref of worn) wornSeen.add(ref)
    void loadPlugins()
  })

  // ── The gate (tui.md §5.7) ────────────────────────────────────────────────

  /** The tab a gate request belongs to — the session being stepped, not the one in front. */
  const tabOf = (session: string): SessionTab | null =>
    (tabs.tabs().find((t) => t.kind === "session" && t.id === session) as SessionTab | undefined) ?? null

  /**
   * A member package's `contributes.policy` narrowing, pooled (tui-plugin
   * D2/D3): every member's `deny`/`ask` entries and which of them, if any,
   * claimed `readonly: true`. Read from the frozen composition — for a
   * SessionTab that is already `contributions()`, populated before the first
   * step can run (`state/tabs.ts` `hydrate`/`ready`), so there is no race to
   * guard against here.
   */
  const compositionPolicy = (asked: SessionTab | null) => poolPolicy(asked?.contributions() ?? [])

  const decideNow = (request: GateRequest, asked: SessionTab | null) =>
    decide(request, {
      mode: mode(),
      // A package can only narrow (D3's own parse-time rule), so merging its
      // `deny`/`ask` into the tables `tui.toml` already declares is still
      // only ever a narrowing — `decide` itself takes no new parameter.
      rules: withPolicy(props.style.settings.approvals, compositionPolicy(asked)),
      always: always(),
    })

  /**
   * The calls of the batch the given session is in the middle of: every tool
   * card the current turn drew, and of those, the ones that have not run yet.
   *
   * The kernel emits a whole turn's calls before executing any of them and
   * resolves them together in one `tool_results` (physics: one batch, one
   * event), so "not resolved" is this turn and "not done" is what is still
   * ahead — which is exactly what "allow the rest of this batch" has to mean.
   */
  const batchOf = (session: string) => {
    const items = tabOf(session)?.state.snapshot.items ?? []
    const turn = items.filter((item): item is Extract<TranscriptItem, { kind: "tool" }> =>
      item.kind === "tool" && !item.resolved,
    )
    return { turn, ahead: turn.filter((item) => item.state !== "done") }
  }

  /**
   * Answer one gate request (`nulya session step --gate`, DESIGN §14).
   *
   * Rules and mode decide first (`approvals.ts`); only what neither settles
   * reaches a person, above the composer (`ui/ApprovalPanel.tsx`). The kernel is
   * blocked on this promise, which is exactly why it is safe to wait: the
   * model's connection closed before the batch began.
   */
  const approve = (request: GateRequest, session: string): Promise<GateVerdict> => {
    const asked = tabOf(session)
    // A read-only agent's ceiling, before every table (tui.md §5.10): the whole
    // meaning of `readonly: true` is that nothing can lift it — an `allow` entry
    // that quietly re-admitted `shell` to a read-only persona would make the
    // word a decoration. It is a policy like every other one here, not a
    // sandbox: the model is told, in the deny note, why nothing ran.
    const wearing_agent = agentOf.get(session)
    if (wearing_agent?.readonly) {
      const refusal = readonlyCeiling(request.tool, request.readonly ?? undefined)
      if (refusal) return Promise.resolve<GateVerdict>({ allow: false, note: refusal })
    }
    // Same ceiling, the other origin (tui-plugin D3): a composition member's
    // own `contributes.policy.readonly: true` — judged by the identical
    // function above rather than a second copy of it (D3's "两个天花板一处判断"),
    // with the note naming which package's policy fired.
    const policy = compositionPolicy(asked)
    if (policy.readonlyBy.length > 0) {
      const refusal = readonlyCeiling(
        request.tool,
        request.readonly ?? undefined,
        `read-only policy of ${policy.readonlyBy.join(", ")}`,
      )
      if (refusal) return Promise.resolve<GateVerdict>({ allow: false, note: refusal })
    }
    const verdict = decideNow(request, asked)
    if (verdict === "deny") {
      const what = describeCall(request)
      setNotice(`denied by a rule · ${request.tool}${what ? ` · ${what}` : ""}`)
      return Promise.resolve<GateVerdict>({ allow: false, note: "denied by a standing rule in this workspace" })
    }
    // Waved through with the rest of its batch. After the standing `deny` table
    // and nothing else: a rule that says never must still say never, and one
    // keypress about six calls cannot outrank it.
    if (batchAllowed().has(request.call_id)) {
      setBatchAllowed(new Set([...batchAllowed()].filter((id) => id !== request.call_id)))
      return Promise.resolve<GateVerdict>({ allow: true })
    }
    if (verdict === "allow") return Promise.resolve<GateVerdict>({ allow: true })
    asked?.state.setAwaitingApproval(request.call_id)
    return new Promise<GateVerdict>((resolve) =>
      setPendingQueue([...pendingQueue(), { request, session, resolve }]),
    )
  }

  /** Answer the call that is up, and let the kernel go on. */
  const settleApproval = (verdict: GateVerdict) => {
    const asked = pending()
    if (!asked) return
    setPendingQueue(pendingQueue().slice(1))
    tabOf(asked.session)?.state.setAwaitingApproval(null)
    asked.resolve(verdict)
    // The dialog is about ONE call: whatever was typed for it does not belong to
    // the next one, and the cursor starts each question at "allow".
    if (noteField) noteField.value = ""
    setNoteFocused(false)
    setChoice(0)
  }

  /**
   * Answer with a note — the gesture the whole dialog is built around
   * (`approvalnote.ts`, tui.md §5.7).
   *
   * The kernel's gate carries a note on exactly one of its two answers: `deny
   * <note>` becomes that call's marker result (DESIGN §4). A note on a YES has
   * nowhere in the gate to go, and should not — the call runs, and what the
   * model reads next is the tool's own output. So it goes where everything else
   * a person says goes: `session append`, drained at the next step boundary,
   * which lands it right after the tool_results of the batch it was about.
   */
  const answer = (allow: boolean, note: string) => {
    const asked = pending()
    if (!asked) return
    const trimmed = note.trim()
    if (!allow) {
      settleApproval({ allow: false, ...(trimmed.length > 0 ? { note: trimmed } : {}) })
      return
    }
    settleApproval({ allow: true })
    if (trimmed.length === 0) return
    const tab = tabOf(asked.session)
    // Framed by us, so the driver does not also wrap it as a mid-task message:
    // this one already says what it is about and what to do with it.
    void tab?.attach.send(wrapApprovalNote(asked.request.tool, trimmed), true)
  }

  /**
   * Allow this one and stop asking about its kind for the rest of the run.
   * `shell` is remembered by its first word, so "always" never quietly becomes
   * "always run any command" (`approvals.alwaysKey`).
   */
  const allowAlways = (note: string) => {
    const asked = pending()
    if (!asked) return
    const key = alwaysKey(asked.request)
    setAlways(new Set([...always(), key]))
    setNotice(`always allowing ${describeKey(key)} this session · /mode for the rest`)
    answer(true, note)
  }

  /**
   * Allow this call and the rest of the batch it belongs to.
   *
   * tcode reviews a batch as one prompt where the tool's own policy says that is
   * safe; nulya's gate is serial by construction (the kernel offers call N only
   * once call N-1 has run), so the equivalent here is a person deciding for the
   * calls THEY CAN SEE: the whole turn is already on screen as cards, and this
   * answers the remaining ones in one gesture instead of six.
   */
  const allowBatch = (note: string) => {
    const asked = pending()
    if (!asked) return
    const ahead = batchOf(asked.session).ahead.filter((item) => item.callId !== asked.request.call_id)
    setBatchAllowed(new Set([...batchAllowed(), ...ahead.map((item) => item.callId)]))
    setNotice(`allowing the remaining ${ahead.length} call${ahead.length === 1 ? "" : "s"} of this batch`)
    answer(true, note)
  }

  /**
   * Switch the mode, and re-judge whatever is on screen with it. A person who
   * flips to `unsafe` while a card is up meant that card too — leaving it
   * waiting would make the switch look broken and hold the kernel for no reason.
   *
   * It says NOTHING afterwards (T31). The chip on the status line already shows
   * which mode this is, and the picker that was just up said what both of them
   * do; a two-line explanation of a state that is drawn three columns away is
   * how the one line with no room to spare lost the model, the cost and the
   * activity to each other.
   */
  const chooseMode = (next: PermissionMode) => {
    setModePicker(false)
    setMode(next)
    rememberMode(next, props.statePath)
    const asked = pending()
    if (!asked) return
    const again = decideNow(asked.request, tabOf(asked.session))
    if (again === "allow") settleApproval({ allow: true })
    else if (again === "deny") settleApproval({ allow: false, note: "denied by a standing rule in this workspace" })
  }

  /**
   * Open the picker — what a click on the chip and a bare `/mode` both do
   * (tui.md §5.7, T31). It used to be a toggle, which is the one gesture that
   * cannot say what the other side is.
   */
  const openModePicker = () => {
    setModeChoice(initialChoice(mode()))
    setModePicker(true)
    setNotice(null)
  }

  const closeModePicker = () => setModePicker(false)

  /**
   * The chip's click: open the picker, and close it again if it is already up
   * (T42).
   *
   * The same gesture on the same spot goes both ways everywhere else on this
   * screen — every overlay opens and closes on its own key and on a second
   * click (`openOverlay`), a fold opens and closes on its head row. A dialog
   * that can only be opened by the thing that opened it is the one place where
   * the way in is not the way out.
   */
  const toggleModePicker = () => (modePicker() ? closeModePicker() : openModePicker())

  /**
   * Who holds the keyboard while a call waits: the dialog's note field, or
   * nobody (the list, which is this screen's own key handler). Never the
   * composer — a box that still blinks is a box that says "type here", and what
   * is typed there could not be sent anyway while the kernel is stopped.
   */
  createEffect(() => {
    if (!pending()) {
      noteField?.blur()
      // …and hand the keyboard back only if nothing else took it meanwhile: an
      // overlay, browse mode and the mode picker all blur the composer on
      // purpose, and a dialog closing is no reason to overrule them.
      if (
        !overlay.active() &&
        !browse.active() &&
        !modePicker() &&
        !agentPicker() &&
        !withPicker() &&
        !plugins.panel()
      ) {
        composer?.focus()
      }
      return
    }
    composer?.blur()
    if (noteFocused()) noteField?.focus()
    else noteField?.blur()
  })

  /**
   * Either picker holds the keyboard while it is up, for the same reason the
   * approval dialog does (T28): a list you choose from is not a list you can
   * choose from if `j` goes into the composer behind it.
   */
  createEffect(() => {
    if (modePicker() || agentPicker() || withPicker()) composer?.blur()
    else if (!pending() && !overlay.active() && !browse.active() && !plugins.panel()) composer?.focus()
  })

  /**
   * A plugin panel takes the keyboard the same way (T28's rule, applied to a
   * surface this front end did not write): a box that still blinks says "type
   * here", and what is typed there would be eaten by the panel anyway.
   */
  createEffect(() => {
    if (plugins.panel()) composer?.blur()
    else if (!pending() && !overlay.active() && !browse.active() && !modePicker() && !agentPicker() && !withPicker()) {
      composer?.focus()
    }
  })

  /** Where the call being asked about sits in its batch, for the panel's heading. */
  const batchPlace = createMemo(() => {
    const asked = pending()
    if (!asked) return { position: 1, batch: 1, ahead: 0 }
    const { turn, ahead } = batchOf(asked.session)
    return { position: Math.max(1, turn.length - ahead.length + 1), batch: Math.max(1, turn.length), ahead: ahead.length - 1 }
  })
  /** How many calls `A` would cover besides this one. */
  const batchAhead = () => Math.max(0, batchPlace().ahead)

  /**
   * The answers, widest-reaching last within each side: allow this one, allow
   * the batch, allow the kind, allow everything — then deny. Every one of them
   * takes the note, which is why none of them is "deny with a reason": that was
   * a separate answer only because the note used to belong to one key
   * (tui.md §5.7).
   */
  const approvalChoices = createMemo((): ApprovalChoice[] => {
    const asked = pending()
    if (!asked) return []
    const kind = describeKey(alwaysKey(asked.request))
    const ahead = batchAhead()
    return [
      { label: "allow this call", tone: "ok", run: (note) => answer(true, note) },
      ...(ahead > 0
        ? [
            {
              label: `allow it and the ${ahead} call${ahead === 1 ? "" : "s"} left in this batch`,
              tone: "ok" as const,
              run: allowBatch,
            },
          ]
        : []),
      { label: `always allow ${kind} this session`, tone: "warn", run: allowAlways },
      {
        // tcode's `set_mode` option, in nulya's two-mode vocabulary. It is on
        // the list because the dialog owns the keyboard: `/mode unsafe` is not
        // typeable while a call is waiting, and "stop asking me" is exactly what
        // somebody reaches for at the fourth prompt in a row.
        label: "allow everything from here on · mode unsafe",
        tone: "warn",
        run: (note) => {
          answer(true, note)
          chooseMode("unsafe")
        },
      },
      { label: "deny · nothing runs, the model is told", tone: "err", run: (note) => answer(false, note) },
    ]
  })

  // ── The model's handover proposal (tui.md §5.8) ───────────────────────────

  /**
   * After every step, look at the directory (DESIGN §11): a new
   * `.nulya/handoffs/<session>-<n>.md` is the model saying a phase is done and
   * the rest does not need the transcript. Exactly the signal `drivers/goal.*`
   * watches for — a file, not a protocol — so both drivers read the same thing.
   *
   * `unsafe` follows it; `ask` puts it on screen, because a fork is the one move
   * that changes which session the person is talking to.
   */
  const checkHandoff = () => {
    const here = live()
    if (!here || handoff()) return
    const found = nextHandoff(props.ws, here.id, handoffsSeen())
    if (!found) return
    if (mode() === "unsafe") {
      setHandoffsSeen(new Set([...handoffsSeen(), found.path]))
      void followHandoffFile(found)
      return
    }
    setHandoff(found)
    holdNotice(`handoff proposed · ${headline(found.brief)} · Enter follow · Esc dismiss`)
  }

  /** A step just ended: that is when a handoff file can have appeared. */
  createEffect(() => {
    if (status() !== "idle") return
    // …and the one case where a question outlives its step: Ctrl+C killed the
    // step that was waiting for it. Nobody is listening for the answer now, so
    // the panel comes down rather than sitting there holding nothing. Only the
    // entries whose OWN session has stopped — another tab may still be running.
    const orphaned = pendingQueue().filter((asked) => tabOf(asked.session)?.attach.status() === "idle")
    if (orphaned.length > 0) {
      setPendingQueue(pendingQueue().filter((asked) => !orphaned.includes(asked)))
      for (const asked of orphaned) {
        tabOf(asked.session)?.state.setAwaitingApproval(null)
        asked.resolve({ allow: false })
      }
      if (noteField) noteField.value = ""
      setNoteFocused(false)
      setChoice(0)
      setNotice("the step ended before that call was answered · nothing ran")
    }
    // A batch nobody is executing any more cannot have calls left to wave
    // through; the ids would be dead weight until the process ends.
    if (batchAllowed().size > 0) setBatchAllowed(new Set<string>())
    // A step that just ended is when a background task can have been STARTED —
    // its receipt is in the batch that just landed — so this is the moment the
    // list is worth re-reading. Its own poll takes over from here (§5.9).
    void live()?.tasks.refresh()
    checkHandoff()
  })

  /**
   * Fork this tab's session and move the tab to the child — the one place that
   * does it on a brief somebody already wrote.
   *
   * Two callers, and they differ only in who asked: the model's handoff
   * proposal below (`/compact`'s `brief_file` branch, DESIGN §11 — the summary
   * exists, so the old session is left byte-identical), and a plugin calling
   * `api.actions.compact` (tui-plugin 1.1, `extensions/plan`'s approve step).
   * The guards, the tab move and the recovery when the lease was lost belong to
   * the act, not to whoever requested it, so they live here once.
   *
   * Throws with a sentence: the handoff path shows it as a notice, the plugin
   * path gets it as a rejected promise and says it in its own words.
   */
  const forkHere = async (options: { briefFile?: string; focus?: string }) => {
    const source = live()
    if (!source) throw new Error("this tab has no session yet · nothing to fork")
    if (source.attach.status() !== "idle") throw new Error("a step is running · fork when it stops")
    setNotice(options.briefFile ? `forking on ${options.briefFile}…` : "compacting…")
    try {
      const result = await runCompact(props.ws, source.id, options)
      tabs.replace(source.id, result.session, { created: true, effort: source.effort() })
      setNotice(`continued in ${result.session} · ${source.id} kept on disk`)
      return result
    } catch (error) {
      // The lease was the driver's while it ran, so this tab may have gone to
      // observer on the way. Nothing is driving it now — take it back rather
      // than leaving the user to reclaim their own session by hand.
      if (source.attach.role() === "observer") source.attach.takeOver()
      throw error
    }
  }

  /** The model's handover proposal, followed. */
  const followHandoffFile = async (file: HandoffFile) => {
    try {
      await forkHere({ briefFile: file.path })
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
  }

  /** `Enter` on the proposal. True when there was one, so the composer knows. */
  const followHandoff = (): boolean => {
    const file = handoff()
    if (!file) return false
    setHandoff(null)
    setHandoffsSeen(new Set([...handoffsSeen(), file.path]))
    void followHandoffFile(file)
    return true
  }

  /** `Esc` on the proposal: the file stays, this process stops offering it. */
  const dismissHandoff = (): boolean => {
    const file = handoff()
    if (!file) return false
    setHandoff(null)
    setHandoffsSeen(new Set([...handoffsSeen(), file.path]))
    setNotice(`handoff dismissed · the brief is still at ${file.path}`)
    return true
  }

  /**
   * `/evolve` — the slow loop, for one session (`evolve.ts`).
   *
   * It opens a NEW tab wearing the evolution package: an identity system prompt
   * and a skill about reviewing sessions that are already finished and judging
   * what is worth keeping or building. It is not "make this conversation start
   * evolving", and it does not activate anything — `--with` is membership in one
   * composition, where `activate` would put that identity in front of every
   * model this machine runs (T31, the bug this wording came from).
   *
   * Not on THIS session either: composition freezes at `session new`
   * (physics #2), so there is no way to hand the model a new system prompt
   * mid-conversation, and pretending otherwise would be the one lie this front
   * end must never tell.
   */
  const evolveNow = async () => {
    setNotice("building the evolution package…")
    try {
      const ref = await buildEvolution(props.ws)
      startDraft(undefined, false, ref)
      // After `startDraft`, whose own line is about the model: this says which
      // tab, what it is wearing, and — the part people got wrong — that nothing
      // was activated and nothing has started yet.
      setNotice(
        `new tab · wearing ${formatWithRef(ref)} · review finished sessions, judge what to keep · nothing activated · your next message starts it`,
      )
    } catch (error) {
      // Almost always "there is no extensions/evolution here": the package ships
      // with nulya's source, and this is somebody else's workspace.
      setNotice(error instanceof Error ? error.message : String(error))
    }
  }

  // ── `/agent` (tui.md §5.10) ───────────────────────────────────────────────

  /**
   * Re-read the definitions — through the package, which is the one reader
   * (`agents.ts`). Asked again at every `/agent` rather than watched: a
   * definition is a file somebody edits in another window, and the moment that
   * matters is the moment one is about to be used.
   */
  const refreshAgents = async (): Promise<readonly AgentEntry[]> => {
    const pkg = await agentPackage()
    if (!pkg) return []
    try {
      const found = await listAgents(props.ws, pkg)
      setAgentDefs(usableAgents(found))
      setAgentWarnings(found.flatMap((entry) => entry.warnings))
      return agentDefs()
    } catch {
      // No listing is "none known"; the sentence a caller needs comes from
      // whichever command it was about to run.
      return agentDefs()
    }
  }

  // Deliberately NOT on mount: reading the definitions means building the
  // package, which is a compiled build, and a compiled build on the way in is
  // the thing T11/T23 exist to keep off the critical path. It happens when
  // `/agent` is used, and — in the background, once — when the first session is
  // composed, exactly as the handoff package's does.

  /**
   * Start a delegation: build the persona, open a tab on a session wearing it,
   * and send the task.
   *
   * Every part of it is something this front end already does — `session new
   * --prompt` a file, `--with` the packages its pins imply (`/evolve`), `--pin`
   * a tool face (T12), `--max-steps` a run (the driver's own option) — which is
   * the point: a sub-agent is a `session new` with a particular set of arguments
   * (PLAN §3.2), and there is nothing here the kernel had to grow.
   *
   * A visible tab rather than a hidden run, because a delegation that goes wrong
   * is a delegation somebody has to be able to watch, cancel and read afterwards.
   */
  const startAgent = async (entry: AgentEntry, task: string): Promise<SessionTab | null> => {
    if (entry.layer === "workspace" && props.agentsTrusted === false) {
      setNotice(`'${entry.name}' came with this checkout and was not trusted · its prompt would enter a session here · answer the question again by clearing asked_agents in tui-state.json`)
      return null
    }
    setNotice(`agent ${entry.name} · rendering its prompt…`)
    const pkg = await agentPackage()
    if (!pkg) {
      setNotice("the agent package could not be built here · /ext for what it said")
      return null
    }
    let m: RenderedAgent
    try {
      // The package renders the definition and checks that the packages its
      // pins name can be brought in — one implementation of both, and the same
      // one the model reaches through the `agent` tool.
      m = await renderAgent(props.ws, pkg, entry.name)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
      return null
    }
    // The parent's model unless the definition names one.
    const inherited = currentPick()
    const pick =
      agentPick(m) ??
      (inherited ? { profile: inherited.profile, ...(inherited.model ? { model: inherited.model } : {}) } : undefined)
    const draft = tabs.draft(pick ? { pick } : {})
    try {
      const child = await tabs.materialize(draft, {
        // The persona rides as BYTES the header freezes (DESIGN §3): nothing is
        // installed, so `/ext` gains nothing and no `ext prune` can take this
        // session's own identity text away from its resume.
        prompt: [m.prompt],
        // Only the `agent` package rides as `--with`, and only for a persona
        // that names somebody to pass work to: everything else is a leaf, and a
        // delegated session that cannot delegate simply does not carry the tool.
        // The persona's OWN pins bring their packages in by themselves — that
        // implication is the kernel's (DESIGN §5.1), not a list assembled here.
        ...(m.agents.length > 0 ? { with: [formatWithRef(pkg)] } : {}),
        ...(m.pins.length > 0 || m.agents.length > 0
          ? { pin: [...m.pins, ...(m.agents.length > 0 ? [agent_pin] : [])] }
          : {}),
        ...(m.max_steps > 0 ? { maxSteps: m.max_steps } : {}),
      })
      agentOf.set(child.id, m)
      setNotice(`${m.name} · ${child.id}${m.readonly ? " · read-only" : ""}`)
      await child.attach.send(task)
      return child
    } catch (error) {
      // A refusal (no credential, an untrusted store, a pin naming nothing) is
      // the kernel's sentence; the draft tab stays where it is, as everywhere.
      setNotice(error instanceof Error ? error.message : String(error))
      return null
    }
  }

  /** Bare `/agent`: the list, as a dialog above the composer. */
  const openAgentPicker = async () => {
    const defs = await refreshAgents()
    setAgentChoice(0)
    setAgentPicker(true)
    const skipped = agentWarnings().length
    setNotice(
      defs.length === 0
        ? "no agent definitions yet"
        : skipped > 0
          ? `${defs.length} agent${defs.length === 1 ? "" : "s"} · ${skipped} file${skipped === 1 ? "" : "s"} skipped: ${agentWarnings()[0]}`
          : null,
    )
  }

  const closeAgentPicker = () => setAgentPicker(false)

  /**
   * Taking a row writes the command and stops. A delegation needs a task and
   * nobody can guess it — and a picker that started a session on a task it made
   * up would be the front end putting words in somebody's mouth.
   */
  const takeAgentChoice = () => {
    const def = agentDefs()[agentChoice()]
    setAgentPicker(false)
    if (!def) return
    composer?.restore(`/agent ${def.name} `)
    setNotice(`${def.name}${def.description ? ` · ${def.description}` : ""} · type the task and send`)
  }

  /** `/agent <name> <task…>`. */
  const delegate = async (name: string | undefined, task: string) => {
    if (!name) {
      await openAgentPicker()
      return
    }
    const defs = await refreshAgents()
    const def = defs.find((entry) => entry.name === name)
    if (!def) {
      setNotice(
        defs.length === 0
          ? `no agent '${name}' · no definitions in .nulya/agents or ~/.nulya/agents`
          : `no agent '${name}' · ${defs.map((entry) => entry.name).join(" ")}`,
      )
      return
    }
    if (task.trim().length === 0) {
      setNotice(`/agent ${def.name} <task> · it starts a session of its own and sees nothing of this one, so say the whole task`)
      return
    }
    void startAgent(def, task.trim())
  }

  /**
   * The package command table, resolved: built-ins can never be shadowed
   * (D8), and among the rest the first package `/ext list` names for a given
   * name wins — the loser is reported, not silently dropped (`packageCommands.ts`
   * `resolve`). Recomputed on every read rather than cached again: the table
   * itself is already cached (`packageCmds`), and this is a pure fold over it.
   */
  const resolvedPackageCommands = () => resolvePackageCommands(packageCmds.entries(), builtin_names)

  /**
   * `/name` where a loaded PLUGIN registered it (`api.registerCommand`).
   *
   * Asked before the declaration layer, which settles the rule tui-plugin §5
   * left open: a package's code command beats the same package's declared one,
   * because it is the same package making a more capable statement about
   * itself. A built-in is still untouchable — the host refuses to register one
   * at all (D8) — and where a code command and a DIFFERENT package's declared
   * command collide, the code one wins for the same reason a code widget wins
   * over a `panel: true` row: the ceiling covers the floor.
   */
  const runPluginCommand = async (raw: string): Promise<boolean> => {
    const { name, args } = splitSlash(raw)
    const row = plugins.commands().find((entry) => entry.name === name)
    if (!row) return false
    try {
      await row.run({ args, session: pluginSession() })
    } catch (error) {
      setNotice(`${row.pkg} · /${row.name} · ${error instanceof Error ? error.message : String(error)}`)
    }
    return true
  }

  /**
   * `/name` where `name` is a package's own DECLARED command (tui-plugin
   * D1/D8): `false` when no package claims it, so the caller falls through to
   * the skill catalog and then the model, exactly as an unrecognised built-in
   * does today.
   *
   * The three verbs each land on a path that already exists for a person
   * typing the general form by hand — `with` is `startDraft`'s own `--with`
   * move (`wearNow` below), `run <tool>` is `ext run` naming the version this
   * package is active AT RIGHT NOW (not whatever it was when the table was
   * last read), and `skill <ref>` is T15's `skillTurn` with the ref standing
   * in for whatever the person would otherwise have typed after `/`.
   */
  const runPackageCommand = async (raw: string): Promise<boolean> => {
    const { name, args } = splitSlash(raw)
    const row = resolvedPackageCommands().winners.find((entry) => entry.name === name)
    if (!row) return false
    // `"wear"` is the pre-D4 spelling of `"with"`, folded into the same kind
    // below; warned once per dispatch so the package's own author sees it.
    if (isDeprecatedWearAction(row.action)) {
      console.warn(`${row.id}: command '/${row.name}' declares action "wear" — rename it to "with"`)
    }
    const action = parseAction(row.action)
    switch (action.kind) {
      case "with":
        startDraft(undefined, false, { id: row.id })
        return true
      case "run": {
        const version = await activeVersionOf(props.ws, row.id)
        if (!version) {
          setNotice(`${row.id} has no active version · run \`nulya ext build\` then \`nulya ext activate\` first`)
          return true
        }
        const result = await extRun(props.ws, `${row.id}@${version}`, action.tool, runArgs(args))
        const said = (result.stdout.trim() || result.stderr.trim() || `exit ${result.code}`).split("\n")[0]
        setNotice(`${row.id} ${action.tool} · ${said}`)
        return true
      }
      case "skill": {
        try {
          const turn = await skillTurn(props.ws, skills.entries(), `/${action.ref} ${args}`.trim())
          if (turn === null) {
            setNotice(`${row.id} · '/${row.name}' names skill '${action.ref}', which is not in the active catalog`)
            return true
          }
          const here = await ensureSession()
          if (!here) {
            composer?.restore(raw)
            return true
          }
          await here.attach.send(turn)
        } catch (error) {
          setNotice(error instanceof Error ? error.message : String(error))
        }
        return true
      }
      case "unknown":
        // An open vocabulary (manifest.zig `Command.action`, D1): a word this
        // build does not understand is skipped rather than refused, and the
        // package's other contributions still stand.
        setNotice(`${row.id} · '/${row.name}' has an action this build does not understand (${action.word || "empty"}) · skipped`)
        return true
    }
  }

  /**
   * `/with <id>[@<version>]` — the same move as `/evolve` with any package that
   * contributes a prompt: wear it for one session, activate nothing.
   *
   * It is the kernel's own word: this runs `session new --with <id>[@<version>]`
   * and nothing else, so the front end does not get to call it something else
   * (tui.md §11, T36). The two earlier names both said less than the flag does —
   * `/mode` collided with the permission mode (T24), and `/as` read the general
   * verb as a special case: `--with` is MEMBERSHIP, and a member may contribute
   * only tools or only skills, in which case no session is speaking "as"
   * anything. `/as` stays as an alias because it is in people's fingers.
   */
  const wearNow = (word: string | undefined) => {
    if (!word) {
      void openWithPicker()
      return
    }
    const ref = parseWithRef(word)
    if (!ref) {
      setNotice("/with <id>[@<version>] · a built extension; no version means the store's current")
      return
    }
    startDraft(undefined, false, ref)
  }

  /**
   * Bare `/with`: the modes this machine could wear, as a dialog above the
   * composer (tui.md §11, T37/K8).
   *
   * Derived from the store and nothing else: a package with a `current` and a
   * SYSTEM PROMPT. That is what makes wearing one a decision worth a dialog —
   * it changes what this session IS, and it is paid for on every step.
   *
   * The filter used to also ask the manifest whether the package had declared
   * itself opt-in, and skip the ones that had not, because those were already
   * in every session and a row offering one would offer a no-op. Nothing is
   * automatically in every session now (DESIGN §5.1), so the question has no
   * answer to ask for and every mode belongs on this list.
   */
  const openWithPicker = async () => {
    let listed: Wearable[] = []
    try {
      listed = (await listExtensions(props.ws))
        .filter((entry) => entry.current !== null && !entry.shadowed && entry.systemPrompts.length > 0)
        .map((entry) => ({
          id: entry.id,
          version: entry.current!,
          prompts: entry.systemPrompts.length,
          skills: entry.skills.length,
          tools: entry.tools.length,
        }))
    } catch {
      // A store this process cannot read is an empty list with its own sentence,
      // never a crash on the way to a dialog.
      setNotice("could not read the extension store · /ext shows what the kernel says")
    }
    setWearables(listed)
    setWithChoice(0)
    setWithPicker(true)
  }

  const closeWithPicker = () => setWithPicker(false)

  /** Taking a row acts: wearing needs no argument, so the tab opens. */
  const takeWithChoice = () => {
    const one = wearables()[withChoice()]
    setWithPicker(false)
    if (!one) return
    startDraft(undefined, false, { id: one.id })
    setNotice(`new tab · wearing ${one.id} · nothing activated · your next message starts it`)
  }

  /**
   * `/outcome <verdict> [note]` — how this session turned out (DESIGN §3.3).
   *
   * It goes to the outcome journal, never to the ledger: a judgment ABOUT a
   * session is not a turn IN it, and the kernel takes no lease for it — so this
   * works on a session whose step is running right now, and on one somebody else
   * is driving.
   */
  const judge = async (word: string | undefined, note: string) => {
    const here = live()
    if (!here) {
      setNotice("this tab has no session yet · send a message and there will be one to judge")
      return
    }
    if (!word || !isVerdict(word)) {
      setNotice(`/outcome <${verdicts.join("|")}> [note] · nothing recorded is "not judged", not failure`)
      return
    }
    try {
      await sessionOutcome(props.ws, here.id, word, note)
      setSettled([...settled(), here.id])
      setNotice(`${here.id}: ${word}${note ? ` · ${note}` : ""}`)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
  }

  /**
   * `/compact [focus]` — spawn the compaction driver (`extensions/compact`) and
   * follow it, then move this tab to the session it opened (PLAN §3.4).
   *
   * The procedure is the extension's; what belongs here is the three guards and
   * the tab move. While the tool runs it holds this session's writer lease, so
   * this tab flips itself to observer and its follower shows the request and the
   * brief as they land — the observer mode that was already there, no new
   * mechanism (tui.md §5.6).
   *
   * Every failure leaves the conversation exactly where it was: the summary is
   * produced before anything moves, and if it does not arrive the old session is
   * still the live one. A compaction that half-happened would be a conversation
   * thrown away, so the driver refuses rather than approximates.
   */
  const compactNow = async (focus: string | undefined) => {
    const source = live()
    if (!source) {
      setNotice("nothing to compact yet · this tab has no session")
      return
    }
    if (source.attach.role() === "observer") {
      setNotice("someone else drives this session · compaction has to run where its steps run")
      return
    }
    if (source.attach.status() !== "idle") {
      setNotice("a step is running · /compact when it stops")
      return
    }
    if (source.state.snapshot.items.length === 0) {
      setNotice("nothing to compact yet")
      return
    }
    setNotice("compacting · asking this session for a continuation brief…")
    try {
      const result = await runCompact(props.ws, source.id, { ...(focus ? { focus } : {}) })
      tabs.replace(source.id, result.session, { created: true, effort: source.effort() })
      setNotice(`compacted into ${result.session} · ${source.id} kept on disk`)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
      // The lease was the driver's while it ran, so this tab may have gone to
      // observer on the way. Nothing is driving it now — take it back rather
      // than leaving the user to reclaim their own session by hand.
      if (source.attach.role() === "observer") source.attach.takeOver()
    }
  }

  /** `/effort <level|auto>`: this tab's next step runs with it; remembered with the pick. */
  const setEffort = (raw: string | undefined) => {
    const level = raw && raw !== "auto" ? raw : undefined
    tab().setEffort(level)
    const pick = currentPick()
    if (pick) rememberModel({ ...pick, effort: level }, props.statePath)
    setNotice(`effort ${level ?? "auto"} · takes hold at the next step`)
  }

  /**
   * `ask` is only for the deliberate `/quit`: a session that did work and was
   * never judged leaves a hole in the slow loop — no verdict means `unknown`,
   * which is not failure but is not knowledge either (DESIGN §3.3) — and the
   * judgment costs a second while the work is still in mind. Asked once per
   * session and never in the way: type `/quit` again and it lets go. Ctrl+C is
   * the escape hatch and never asks anything.
   */
  const quit = (ask = false) => {
    const here = live()
    const worked = here?.state.snapshot.items.some((item) => item.seq !== null) ?? false
    if (here && ask && worked && !settled().includes(here.id)) {
      setSettled([...settled(), here.id])
      setNotice(`how did this session go? /outcome ${verdicts.join("|")} [note] · or /quit again`)
      return
    }
    // Leaving does not stop them, and pretending otherwise would be the lie
    // (tui.md §5.9): a task is a detached process with a supervisor of its own,
    // its output keeps going into its log, and its report will be waiting in the
    // inbox for whoever steps this session next. Said once, then `/quit` again
    // leaves; `/tasks` is where they are actually stopped.
    const running = runningTasks()
    if (running > 0 && ask && !tasksWarned()) {
      setTasksWarned(true)
      setNotice(
        `${running} background task${running === 1 ? "" : "s"} keep running; their results land in the session inbox · /tasks · K stops them all`,
      )
      return
    }
    tabs.disposeAll()
    renderer.destroy()
    process.exit(0)
  }

  const runCommand = (raw: string): boolean => {
    if (!raw.startsWith("/")) return false
    const words = raw.trim().split(/\s+/)
    const command = words[0]
    /** Everything after the command word, verbatim — a note keeps its spacing. */
    const rest = raw.slice(raw.indexOf(command!) + command!.length).trim()
    if (command === "/quit") {
      quit(true)
      return true
    }
    if (command === "/outcome") {
      void judge(words[1], rest.slice(words[1]?.length ?? 0).trim())
      return true
    }
    if (command === "/evolve") {
      void evolveNow()
      return true
    }
    if (command === "/mode") {
      const word = words[1]
      // Bare `/mode` is the picker, not a flip (T31): the two modes and what
      // each one does are the answer to "which mode am I in", and a toggle can
      // only ever say one of them. Named, it still switches on the spot.
      if (!word) openModePicker()
      else {
        const named = normalizeMode(word)
        if (named) chooseMode(named)
        else setNotice(`/mode <${modes.join("|")}> · now: ${mode()} · no argument opens the picker`)
      }
      return true
    }
    // `/as` is the old name, kept working: an alias costs one line here, while a
    // muscle-memory `/as` that fell through would be offered to the skill
    // catalog and then sent to the model verbatim (commands.ts).
    if (command === "/with" || command === "/as") {
      wearNow(words[1])
      return true
    }
    if (command === "/agent") {
      void delegate(words[1], rest.slice(words[1]?.length ?? 0).trim())
      return true
    }
    if (command === "/cancel") {
      const here = live()
      if (here) void here.attach.cancel()
      else setNotice("nothing is running · this tab has no session yet")
      return true
    }
    if (command === "/step") {
      const here = live()
      if (here) void here.attach.step()
      else setNotice("nothing to continue · send a message to start this session")
      return true
    }
    if (command === "/compact") {
      void compactNow(rest)
      return true
    }
    // Collapse only. The other direction — one key that opens everything —
    // was a key (T38): a screenful of every tool body at once is not a view of
    // anything, and folding back down is what a person actually wants after
    // reading a few cards open.
    if (command === "/fold") {
      folds.setAll(false)
      return true
    }
    // `/resume` is the word other harnesses use for this, and it is the SAME
    // command rather than one of its own (commands.ts): a name that opened a
    // different door than `/sessions` would be a second concept wearing an
    // alias. Bare, the list; with an argument, the session it names — the one
    // way to reach one by id from inside the screen, which until now meant
    // relaunching with `--session`.
    //
    // "Resume" needs no ceremony of its own: a ledger is append-only, so opening
    // a session and saying the next thing IS continuing it (physics #1) — and
    // whether this process may write is the lease's answer, not ours
    // (`state/attach.ts`).
    if (command === "/sessions" || command === "/resume") {
      const id = words[1]
      if (!id) {
        openOverlay("sessions")
        return true
      }
      if (!sessionExists(props.ws, id)) {
        setNotice(`no session '${id}' in ${sessions_dir} · ${command} with no id lists them`)
        return true
      }
      openSession(id)
      return true
    }
    if (command === "/tasks") {
      openOverlay("tasks")
      return true
    }
    if (command === "/ext") {
      openOverlay("ext")
      return true
    }
    // `/clear` is `/new` under the name other harnesses use for it, and an alias
    // costs one line here while a muscle-memory `/clear` that fell through would
    // be offered to the skill catalog and then sent to the model as prose
    // (commands.ts). It is not listed, and it clears nothing: the session it
    // leaves behind keeps its tab, its file and every event in it.
    if (command === "/new" || command === "/clear") {
      const flag = (name: string) => {
        const at = words.indexOf(name)
        return at >= 0 ? words[at + 1] : undefined
      }
      const profile = flag("--profile")
      const model = flag("--model")
      // Named on the command line: a one-off, so it is not remembered as the
      // pick (a bare `/new` keeps returning to what was chosen in `/model`). A
      // model id alone rides on the last pick's profile, else the kernel's.
      const last = loadTuiState(props.statePath).model
      const pick: ModelPick | undefined =
        profile || model ? { profile: profile ?? last?.profile ?? "", model, effort: last?.effort } : undefined
      startDraft(pick, false)
      return true
    }
    if (command === "/model") {
      openOverlay("model")
      return true
    }
    if (command === "/provider") {
      openOverlay("provider")
      return true
    }
    if (command === "/effort") {
      setEffort(words[1])
      return true
    }
    if (command === "/help") {
      openOverlay("help")
      return true
    }
    if (command === "/settings") {
      openOverlay("settings")
      return true
    }
    if (command === "/usage") {
      openOverlay("usage")
      return true
    }
    // Not a built-in: the skill catalog gets it next, and only then the model.
    return false
  }

  /**
   * The one path a message takes, and the one place a session comes into
   * existence (tui.md §11, T22).
   *
   * A `/name` no built-in claimed is offered to a loaded PLUGIN's command
   * next (`runPluginCommand`, U3), then to a package's DECLARED one
   * (`runPackageCommand`, tui-plugin D1/D8), and only then to the skill
   * catalog: if a skill has that name, its body becomes an ordinary user turn
   * wrapped in the echo sentinel (`skills.ts`), and a failure to load says so
   * rather than quietly sending `/name` as prose. Only then — with something
   * real to say — is the draft turned into a session.
   *
   * The order matters both ways: a skill that will not load must not create a
   * session, and a session that will not start must not lose the text. The
   * composer has already cleared itself by the time this runs, so a refusal puts
   * the typed line back in the box.
   */
  const sendTurn = async (text: string) => {
    let turn = text
    if (text.startsWith("/")) {
      if (await runPluginCommand(text)) return
      if (await runPackageCommand(text)) return
      try {
        turn = (await skillTurn(props.ws, skills.entries(), text)) ?? text
      } catch (error) {
        setNotice(error instanceof Error ? error.message : String(error))
        return
      }
    }
    const here = await ensureSession()
    if (!here) {
      composer?.restore(text)
      return
    }
    await here.attach.send(turn)
  }

  const submit = (text: string) => {
    setNotice(null)
    if (runCommand(text)) return
    void sendTurn(text)
  }

  /** Take the answer the cursor is on, with whatever is in the note field. */
  const takeChoice = () => {
    const choices = approvalChoices()
    const picked = choices[Math.min(choice(), choices.length - 1)]
    picked?.run(noteField?.value ?? "")
  }

  /**
   * A key this screen acted on must not ALSO reach the focused textarea:
   * global listeners run before the focused renderable, and the composer has
   * readline bindings of its own (Ctrl+W deletes a word), so without this a
   * rebound key would do two things at once.
   */
  const consume = (key: KeyEvent, action: () => void) => {
    key.preventDefault()
    action()
  }

  useKeyboard((key) => {
    /**
     * The agent picker, on the same terms as the mode picker below it: while a
     * dialog above the composer is up it holds the keyboard, so the list is a
     * list you can actually choose from (T28). It is the outermost of the three
     * because it is the one that can only be opened deliberately.
     */
    if (withPicker() && !key.ctrl && !key.meta) {
      const count = wearables().length
      if (matches(keys.cancel, key)) return consume(key, closeWithPicker)
      if (key.name === "up" || key.name === "k") {
        return consume(key, () => setWithChoice((at) => Math.max(at - 1, 0)))
      }
      if (key.name === "down" || key.name === "j") {
        return consume(key, () => setWithChoice((at) => Math.min(at + 1, Math.max(count - 1, 0))))
      }
      if (key.name === "return") return consume(key, takeWithChoice)
      if (key.name && /^[1-9]$/.test(key.name) && Number(key.name) <= count) {
        return consume(key, () => {
          setWithChoice(Number(key.name) - 1)
          takeWithChoice()
        })
      }
      return consume(key, () => {})
    }
    if (agentPicker() && !key.ctrl && !key.meta) {
      const count = agentDefs().length
      if (matches(keys.cancel, key)) return consume(key, closeAgentPicker)
      if (key.name === "up" || key.name === "k") {
        return consume(key, () => setAgentChoice((at) => Math.max(at - 1, 0)))
      }
      if (key.name === "down" || key.name === "j") {
        return consume(key, () => setAgentChoice((at) => Math.min(at + 1, Math.max(count - 1, 0))))
      }
      if (key.name === "return") return consume(key, takeAgentChoice)
      if (key.name && /^[1-9]$/.test(key.name) && Number(key.name) <= count) {
        return consume(key, () => {
          setAgentChoice(Number(key.name) - 1)
          takeAgentChoice()
        })
      }
      return consume(key, () => {})
    }
    /**
     * The mode picker, first of all — it is the most recently opened dialog, and
     * it can be opened by CLICKING the chip while a call is waiting, which is
     * the one moment two dialogs are on screen at once (tui.md §5.7, T31).
     * Answering it re-judges that waiting call on the spot (`chooseMode`).
     */
    if (modePicker() && !key.ctrl && !key.meta) {
      if (matches(keys.cancel, key)) return consume(key, closeModePicker)
      if (key.name === "up" || key.name === "k") return consume(key, () => setModeChoice((at) => moveChoice(at, -1)))
      if (key.name === "down" || key.name === "j") return consume(key, () => setModeChoice((at) => moveChoice(at, 1)))
      if (key.name === "return") {
        return consume(key, () => {
          const picked = modeAt(modeChoice())
          if (picked) chooseMode(picked)
          else closeModePicker()
        })
      }
      // A digit picks the row it numbers, as in the approval dialog.
      if (key.name && /^[1-9]$/.test(key.name) && modeAt(Number(key.name) - 1)) {
        return consume(key, () => chooseMode(modeAt(Number(key.name) - 1)!))
      }
      return consume(key, () => {})
    }
    /**
     * The approval dialog owns the keyboard while it is up (tui.md §5.7).
     *
     * The kernel is stopped on this one call, so there is nothing else on screen
     * to type at — and that is what lets typing have a single obvious meaning
     * here: it is the note. The old shape (single letters, only on an empty
     * composer) had to reserve `y`/`n`/`a` from a box that was still live, which
     * is why saying anything about a call needed its own designated key.
     *
     * `Enter` answers with the row the cursor is on; `Tab` moves between the
     * list and the note. Everything the composer would have done is unreachable
     * for these few seconds, which is honest — nothing else can happen anyway.
     */
    // …but never the modified keys: Ctrl+C has to keep working while a call
    // waits, and killing the step is one of the two ways out of a dialog whose
    // question nobody wants to answer.
    if (pending() && !key.ctrl && !key.meta) {
      const choices = approvalChoices()
      if (key.name === "tab") return consume(key, () => setNoteFocused(!noteFocused()))
      if (key.name === "return") return consume(key, takeChoice)
      if (noteFocused()) {
        // Esc empties the note rather than answering: it is the undo for what
        // was typed, and an Esc that both discarded the words AND denied the
        // call would make the small mistake expensive.
        if (matches(keys.cancel, key)) {
          return consume(key, () => {
            if (noteField && noteField.value.length > 0) noteField.value = ""
            else setNoteFocused(false)
          })
        }
        // Everything else is text: the field has the focus and OpenTUI delivers
        // it there once this listener declines to claim the key.
        return
      }
      if (matches(keys.cancel, key)) return consume(key, () => answer(false, noteField?.value ?? ""))
      // Arrows only — no `j`/`k`. Vim keys on a list whose alternative use for
      // a letter is "start writing a note" would eat two of the twenty-six.
      if (key.name === "up") {
        return consume(key, () => setChoice((at) => (at - 1 + choices.length) % choices.length))
      }
      if (key.name === "down") {
        return consume(key, () => setChoice((at) => (at + 1) % choices.length))
      }
      // A digit picks the row it numbers; a digit with no row is just a digit,
      // and falls through to the note (tcode's rule).
      if (key.name && /^[1-9]$/.test(key.name) && Number(key.name) <= choices.length) {
        return consume(key, () => setChoice(Number(key.name) - 1))
      }
      // Any other typing means annotating — the reason the note never has to be
      // discovered: reach for words and you are already writing them. The
      // character is inserted here because the field is not focused yet, so the
      // keystroke that opened it would otherwise be swallowed.
      if (key.name && key.name.length === 1) {
        return consume(key, () => {
          setNoteFocused(true)
          noteField?.insertText(key.shift ? key.name.toUpperCase() : key.name)
        })
      }
      return
    }
    // An overlay owns the keyboard while it is up; only the keys that open or
    // close one, and the quit key, stay global (tui.md §11, T2 reminder 3).
    if (overlay.active()) {
      if (matches(keys.ext, key)) return consume(key, () => openOverlay("ext"))
      if (matches(keys.sessions, key)) return consume(key, () => openOverlay("sessions"))
      if (matches(keys.model, key)) return consume(key, () => openOverlay("model"))
      if (matches(keys.provider, key)) return consume(key, () => openOverlay("provider"))
      if (matches(keys.tasks, key)) return consume(key, () => openOverlay("tasks"))
      if (matches(keys.help, key)) return consume(key, () => openOverlay("help"))
      if (matches(keys.quit, key)) quit()
      return
    }
    /**
     * A plugin's panel owns the keyboard while it is up (tui-plugin D6) — on
     * exactly the terms every other composer dialog has, and no better ones:
     * the trusted zones above already returned, a full-screen overlay above
     * already returned, and `Ctrl+C` never arrives here at all
     * (`PluginHost.handleKey` refuses it, and the branch below still runs).
     * `Esc` takes the panel down whether or not the plugin wants it.
     */
    if (plugins.panel() && !key.ctrl && !key.meta) {
      if (plugins.handleKey(pluginKeyOf(key))) return consume(key, () => {})
    }
    if (browse.active()) {
      // The composer is blurred while browsing, so these keys are ours alone.
      if (matches(keys.cancel, key)) {
        leaveBrowse()
        return
      }
      if (key.name === "j" || key.name === "down") return moveBrowse(1)
      if (key.name === "k" || key.name === "up") return moveBrowse(-1)
      if (key.name === "space") return toggleSelected()
      if (key.name === "return") {
        // A card that names a session opens it; every other card folds. The
        // sub-session link is the one place Enter means something else.
        const id = sessionOf(selectedItem())
        if (id) {
          navigate.openSession(id)
          return
        }
        return toggleSelected()
      }
      return
    }
    if (matches(keys.sessions, key)) return consume(key, () => openOverlay("sessions"))
    if (matches(keys.ext, key)) return consume(key, () => openOverlay("ext"))
    if (matches(keys.model, key)) return consume(key, () => openOverlay("model"))
    if (matches(keys.provider, key)) return consume(key, () => openOverlay("provider"))
    if (matches(keys.tasks, key)) return consume(key, () => openOverlay("tasks"))
    if (matches(keys.help, key)) return consume(key, () => openOverlay("help"))
    // Reading back. The composer is focused and keeps the keyboard, so these
    // have to be taken here or they are the textarea's cursor movement.
    if (matches(keys.scrollUp, key)) return consume(key, () => scrollBy(-1))
    if (matches(keys.scrollDown, key)) return consume(key, () => scrollBy(1))
    if (matches(keys.scrollEnd, key)) return consume(key, scrollToEnd)
    if (matches(keys.nextTab, key)) return consume(key, () => tabs.next())
    if (matches(keys.closeTab, key)) {
      // With one tab there is nothing to close, and the composer keeps its own
      // meaning for the key (Ctrl+W: delete the word behind the cursor).
      if (tabs.tabs().length > 1) consume(key, () => tabs.close(tab().key))
      return
    }
    if (matches(keys.cancel, key)) {
      // A proposal on screen is what Esc is about while it is there.
      if (dismissHandoff()) return
      const here = live()
      if (here && here.attach.status() === "stepping") {
        void here.attach.cancel()
        return
      }
      // Nothing to stop and nothing typed: Esc means "go read" (tui.md §4.2).
      if (composer?.isEmpty() ?? true) enterBrowse()
      return
    }
    if (matches(keys.redraw, key)) return consume(key, () => renderer.requestRender())
    if (matches(keys.quit, key)) {
      // Ctrl+C narrows from the nearest thing to stop to the furthest, and
      // NEVER quits on its first press (tui.md §1.2 D6). Three truths about
      // "stop", in the order a person means them: the draft in the box, the
      // kernel's step, and last — only ever after having said so — this process.
      // Losing a half-written message to a reflex, or the whole screen, is not
      // something a second keystroke can undo.
      if (!(composer?.isEmpty() ?? true)) {
        return consume(key, () => {
          composer?.clear()
          setCtrlCArmed(false)
          setNotice("input cleared · Ctrl+C twice to quit")
        })
      }
      const here = live()
      if (here && here.attach.status() === "stepping" && !ctrlCArmed()) {
        here.attach.kill()
        setCtrlCArmed(true)
        setNotice("step killed · Ctrl+C again to quit")
        return
      }
      if (!ctrlCArmed()) {
        setCtrlCArmed(true)
        setNotice("Ctrl+C again to quit")
        return
      }
      quit()
    }
  })

  /**
   * Enter on an empty composer is the take-over gesture: the lease has looked
   * free for a while and this process is willing to drive again (tui.md §5.6).
   */
  const takeOverIfOffered = (): boolean => {
    const here = live()
    if (!here?.attach.takeoverReady()) return false
    here.attach.takeOver()
    setNotice("took over · driving this session")
    return true
  }

  // Opened by `main` with a reason: show that screen before anything else.
  if (props.guide) overlay.open(props.guideOn ?? "model")

  return (
    <StyleContext.Provider value={props.style}>
      <ScreenContext.Provider value={screen}>
        <FoldContext.Provider value={folds}>
          <BrowseContext.Provider value={browse}>
            <OverlayContext.Provider value={overlay}>
              {/* The loaded plugins, for the one card that has to ask whether
                  a package draws its own tool call (`render/cards/ToolCard.tsx`,
                  tui-plugin D11). A context for the same reason the style is
                  one: threading it through Transcript → Card → ToolCard would
                  put a plugin concern in three files that have none. */}
              <PluginContext.Provider value={plugins}>
              {/* The live task rows, for the one card that needs a fact nothing
                  appended can carry: how long a background command has been
                  going (tui.md §5.9). */}
              <TasksContext.Provider value={tasks}>
              {/* What a card's `↗ open …` link does — the front end's own verb,
                  handed down so a card can offer it without knowing about tabs
                  (`state/navigate.ts`). */}
              <NavigateContext.Provider value={navigate}>
              {/* Transcript, composer, status line — and the only line drawn
                  between any of them is the composer's own border (tui.md §4.1,
                  T26). Three full-width rules used to fence four regions; two of
                  them were separating things the box already separates, and the
                  top one was a rule with nothing above it whenever there was
                  only one tab. There is no title line either: what a person
                  needs to know about the session — what it runs on — is under
                  the composer where they are looking, and the id it used to lead
                  with was a string nobody reads (T22). */}
              <box flexDirection="column" width="100%" height="100%">
                <TabBar tabs={tabs.tabs()} activeIndex={tabs.activeIndex()} onSelect={(index) => tabs.select(index)} />
                <Show when={tabs.tabs().length > 1}>
                  <Hairline />
                </Show>

                <Switch
                  fallback={
                    <Transcript
                      items={snapshot().items}
                      header={snapshot().header}
                      contributions={live()?.contributions() ?? []}
                      plan={plan()}
                      // A draft has no snapshot to carry one, so the refusal
                      // that kept it a draft rides the same channel a live
                      // session's driver failure does — one notice, one place
                      // to read a failure in full.
                      error={snapshot().error ?? refusal()}
                      cwd={props.ws.dir}
                      onPickModel={() => openOverlay("model")}
                      onCommand={submit}
                      tip={tip}
                      ref={(box) => (scroll = box)}
                    />
                  }
                >
                  <Match when={overlay.kind() === "sessions"}>
                    <SessionsView
                      ws={props.ws}
                      currentId={live()?.id ?? ""}
                      onOpen={openSession}
                      onNew={() => startDraft()}
                      onClose={closeOverlay}
                    />
                  </Match>
                  <Match when={overlay.kind() === "ext"}>
                    <ExtView
                      ws={props.ws}
                      header={snapshot().header}
                      // A draft has no session for the kernel to deposit a
                      // capability note into — and no frozen tool face to warn
                      // about either, which the null header already says.
                      sessionFile={live() ? `${sessions_dir}/${live()!.id}.jsonl` : undefined}
                      statePath={props.statePath}
                      onMembershipChanged={() => {
                        skills.invalidate()
                        // Activating or deactivating a package can add or
                        // remove a `/name` it declares just as easily as a
                        // skill (tui-plugin D1/D8): same staleness, same fix.
                        packageCmds.invalidate()
                        // A package that was just activated may ship a front
                        // end. The other direction is not symmetric and says
                        // so in `host.ts`: a module that has run has run, so
                        // deactivating takes effect at the next start.
                        void loadPlugins()
                      }}
                      onClose={closeOverlay}
                    />
                  </Match>
                  <Match when={overlay.kind() === "tasks"}>
                    <TasksView
                      ws={props.ws}
                      sessionId={live()?.id ?? ""}
                      tasks={tasks()}
                      onRefresh={() => void live()?.tasks.refresh()}
                      onClose={closeOverlay}
                    />
                  </Match>
                  <Match when={overlay.kind() === "help"}>
                    <HelpView keys={keys} onClose={closeOverlay} />
                  </Match>
                  <Match when={overlay.kind() === "settings"}>
                    <SettingsView ws={props.ws} onClose={closeOverlay} />
                  </Match>
                  <Match when={overlay.kind() === "usage"}>
                    <UsageView ws={props.ws} snapshot={snapshot()} onClose={closeOverlay} />
                  </Match>
                  <Match when={overlay.kind() === "model"}>
                    <ModelView
                      ws={props.ws}
                      current={currentPick()}
                      notice={guide() ?? undefined}
                      focusProfile={focusProfile()}
                      onPick={(pick) => startDraft(pick)}
                      onNotice={setNotice}
                      onOpenProviders={() => openOverlay("provider")}
                      onClose={closeOverlay}
                    />
                  </Match>
                  <Match when={overlay.kind() === "provider"}>
                    <ProviderView
                      ws={props.ws}
                      current={currentPick()}
                      notice={guide() ?? undefined}
                      onShowModels={showModelsOf}
                      onNotice={setNotice}
                      onClose={closeOverlay}
                    />
                  </Match>
                </Switch>

                {/* The model's own proposal to hand over, between the
                    transcript and the box you answer it in (tui.md §5.8). Not
                    a transcript card: the brief is a file on disk, not a ledger
                    event, and this front end shows only what the ledger holds. */}
                <Show when={handoff()}>
                  <HandoffPanel file={handoff()!} />
                </Show>
                {/* The permission mode, where it is chosen (tui.md §5.7, T31).
                    Above the approval dialog because it can be opened from one:
                    a click on the chip while a call waits is exactly the "stop
                    asking me" gesture, and the answer re-judges that call. */}
                {/* Which agent to delegate to (tui.md §5.10). Same dialog shape
                    as the mode picker, above it for the same reason it holds the
                    keyboard first: it is only ever opened on purpose. */}
                <Show when={withPicker()}>
                  <WithPicker
                    wearables={wearables()}
                    selected={withChoice()}
                    onSelect={setWithChoice}
                    onPick={(one) => {
                      setWithChoice(wearables().indexOf(one))
                      takeWithChoice()
                    }}
                  />
                </Show>
                <Show when={agentPicker()}>
                  <AgentPicker
                    defs={agentDefs()}
                    selected={agentChoice()}
                    onSelect={setAgentChoice}
                    onPick={(def) => {
                      setAgentChoice(agentDefs().indexOf(def))
                      takeAgentChoice()
                    }}
                  />
                </Show>
                <Show when={modePicker()}>
                  <ModePicker
                    current={mode()}
                    selected={modeChoice()}
                    onSelect={setModeChoice}
                    onPick={chooseMode}
                  />
                </Show>
                {/* The call the kernel is stopped on, asked where the answer is
                    given (tui.md §5.7). Above the composer for the same reason
                    the handover proposal is: it is a question about what happens
                    next, not a thing that happened. */}
                {/* A plugin's own panel (tui-plugin D6), below every dialog
                    the host owns: a trusted zone hides it outright
                    (`dialogUp`), and the ordering here is the second half of
                    that promise — nothing an extension drew can ever sit
                    between a person and the question they are answering. */}
                <Show when={plugins.panel()}>
                  <PluginPanel panel={plugins.panel()!} revision={plugins.revision()} />
                </Show>
                <Show when={pending()}>
                  <ApprovalPanel
                    tool={pending()!.request.tool}
                    summary={describeCall(pending()!.request)}
                    position={batchPlace().position}
                    batch={batchPlace().batch}
                    choices={approvalChoices()}
                    selected={choice()}
                    onSelect={setChoice}
                    noteFocused={noteFocused()}
                    onFocusNote={() => setNoteFocused(true)}
                    onReady={(field) => (noteField = field)}
                  />
                </Show>
                {/* What is happening, directly above the box you would type
                    into to change it (tui.md §4.4b, T38). Below the panels: a
                    question waiting for an answer outranks a report of work. */}
                <WorkingStatus
                  activity={activity()}
                  frame={spinnerTick()}
                  spinnerFrame={spinnerFrame()}
                  since={live()?.attach.startedAt() ?? null}
                  now={clockNow()}
                  usage={usageLabel(snapshot().usage)}
                  onOpenTasks={() => openOverlay("tasks")}
                />
                {/* `panel: true`'s degraded progress display (DESIGN §7.2.1,
                    tui-plugin D12): the latest call of a declaring tool, so it
                    is visible whether or not its own card is still on screen.
                    Below the activity line for the same reason it is above
                    the composer — both are read on every glance. */}
                {/* …and the code layer's version of the same row, above it:
                    a package that ships a widget has superseded its own
                    `panel: true` projection (U3), so the strip below drops
                    those tools rather than saying it twice. */}
                <PluginWidgets widgets={plugins.widgets()} revision={plugins.revision()} />
                <PanelStrip
                  items={withoutSuperseded(
                    panelItemsOf(snapshot().items, live()?.contributions() ?? []),
                    live()?.contributions() ?? [],
                    plugins.widgetPackages(),
                  )}
                  contributions={live()?.contributions() ?? []}
                />
                <Composer
                  onSubmit={submit}
                  onEmptySubmit={() => followHandoff() || takeOverIfOffered()}
                  // Clicking the input box means "type here": browse mode holds
                  // the keyboard and the textarea cannot let itself out of it.
                  onActivate={() => {
                    if (browse.active()) leaveBrowse()
                  }}
                  references={references}
                  skills={skills}
                  packages={packageCmds}
                  pluginCommands={plugins.commands}
                  onReady={(api) => {
                    composer = api
                    // The picker may already be up (`guide`): it owns the keys.
                    if (overlay.active()) api.blur()
                  }}
                />
                <StatusBar
                  snapshot={snapshot()}
                  role={role()}
                  model={modelName()}
                  effort={tab().effort()}
                  tools={faceSize()}
                  mode={mode()}
                  onPickMode={toggleModePicker}
                  wearing={wearing()}
                  onOpenExt={() => openOverlay("ext")}
                  hint={notice()?.text}
                  behind={behind()}
                  contextWindow={contextWindow()}
                  onPickModel={() => openOverlay("model")}
                  onScrollEnd={scrollToEnd}
                />
              </box>
              </NavigateContext.Provider>
              </TasksContext.Provider>
              </PluginContext.Provider>
            </OverlayContext.Provider>
          </BrowseContext.Provider>
        </FoldContext.Provider>
      </ScreenContext.Provider>
    </StyleContext.Provider>
  )
}

/**
 * The handover the model proposed, waiting for an answer (tui.md §5.8).
 *
 * The brief is shown, not summarised: it is what the NEXT session will open
 * with, and agreeing to a fork without reading what carries over is agreeing to
 * lose the rest. Long briefs are cut here and stay whole in the file — the
 * decision needs the shape of it, not every line.
 */
function HandoffPanel(props: { file: HandoffFile }) {
  const style = useStyle()
  const lines = () => props.file.brief.split("\n").slice(0, 8)
  return (
    <box flexDirection="column" width="100%" paddingLeft={2} paddingRight={1} flexShrink={0}>
      <box flexDirection="row" width="100%">
        <text fg={style.theme.accent.evolve}>{style.glyphs.subSession} handoff proposed · </text>
        <text fg={style.theme.dim}>{props.file.path}</text>
      </box>
      <For each={lines()}>{(line) => <text fg={style.theme.muted}>{`  ${line}`}</text>}</For>
      <text fg={style.theme.dim}>{"  Enter follow it into a new session · Esc dismiss · the file stays either way"}</text>
    </box>
  )
}

/**
 * One of the two rules that separate the three blocks (tui.md §6). Sized to the
 * terminal exactly: a longer string would wrap and silently eat rows.
 */
function Hairline() {
  const style = useStyle()
  const screen = useScreen()
  return (
    <text fg={style.theme.hairline} height={1} flexShrink={0}>
      {style.glyphs.hairline.repeat(Math.max(0, screen().width))}
    </text>
  )
}
