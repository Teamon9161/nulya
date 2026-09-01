import {
  For,
  Match,
  Show,
  Switch,
  createEffect,
  createMemo,
  createSignal,
  onCleanup,
  onMount,
  untrack,
  type JSX,
} from "solid-js"
import { useKeyboard, usePaste, useRenderer, useTerminalDimensions } from "@opentui/solid"
import { createDefaultOpenTuiKeymap } from "@opentui/keymap/opentui"
import type { InputRenderable, KeyEvent, ScrollBoxRenderable, Selection } from "@opentui/core"
import { Transcript, rowsBelow, transcriptRows } from "./Transcript.tsx"
import { Composer, type ComposerApi } from "./Composer.tsx"
import { pointer, releasePointer } from "./pointer.ts"
import { ApprovalPanel, type ApprovalChoice } from "./ApprovalPanel.tsx"
import { ModePicker, initialChoice, modeAt, moveChoice } from "./ModePicker.tsx"
import { AgentPicker } from "./AgentPicker.tsx"
import { WithPicker, type Wearable } from "./WithPicker.tsx"
import { EnvPicker } from "./EnvPicker.tsx"
import { SshPasswordPrompt } from "./SshPasswordPrompt.tsx"
import { execChoices, withCurrent, type ExecChoice } from "../state/targets.ts"
import { StatusBar } from "./StatusBar.tsx"
import { ContextPanel } from "./ContextPanel.tsx"
import { contextFill, contextSections } from "../state/context.ts"
import { pickTip } from "./Welcome.tsx"
import { WorkingStatus, activityOf, type SyncProgress } from "./WorkingStatus.tsx"
import { readImageFile } from "../image.ts"
import { installCrashLog } from "../crashlog.ts"
import { TabBar } from "./TabBar.tsx"
import { SessionsView } from "./overlays/SessionsView.tsx"
import { ExtView } from "./overlays/ExtView.tsx"
import { HelpView } from "./overlays/HelpView.tsx"
import { SettingsView } from "./overlays/SettingsView.tsx"
import { UsageView } from "./overlays/UsageView.tsx"
import { ModelView, modelParamsFor } from "./overlays/ModelView.tsx"
import { ProviderView } from "./overlays/ProviderView.tsx"
import { TasksView } from "./overlays/TasksView.tsx"
import { BodyWidthContext, ScreenContext, FrameContext, StyleContext, useScreen, useStyle, type Style } from "../render/theme.ts"
import { FoldContext, createFoldStore } from "../state/folds.ts"
import { BrowseContext, createBrowseStore } from "../state/browse.ts"
import { OverlayContext, type OverlayKind } from "../state/overlay.ts"
import { createPaneStore, focusThrough, main_surface, overlayAdapter, tab_surface } from "../state/panes.ts"
import {
  closeSubPane,
  openSubPane,
  reflowSubSplits,
  subSplitDirection,
  subSplitOf,
} from "../state/subpanes.ts"
import {
  closeSidebar,
  default_sidebar_ratio,
  isSidebarOpen,
  openSidebar,
  resizeSidebar,
  sidebarWidth,
  sidebar_min_width,
} from "../state/sidebar.ts"
import {
  agentStart,
  createAskQueue,
  createEntryOnce,
  trustAfter,
  type WorkspaceTrust,
} from "../state/enter.ts"
import { claimsKeyboard, createSurfaceRegistry, type SurfaceMount } from "../pane/registry.ts"
import { leaves, nextPaneId, type FocusDirection } from "../pane/tree.ts"
import { resolveFocus } from "../pane/focus.ts"
import { PaneHost } from "./PaneHost.tsx"
import { SubAgentPane } from "./SubAgentPane.tsx"
import { hostSurfaces } from "./surfaces.tsx"
import { TasksContext, stopTask } from "../state/tasks.ts"
import { TasksPanel } from "./TasksPanel.tsx"
import { NavigateContext, type Navigate } from "../state/navigate.ts"
import type { TranscriptRow } from "../render/runs.ts"
import { createTabStore, type DraftTab, type FirstTab, type SessionTab } from "../state/tabs.ts"
import type { PaneStore } from "../state/panes.ts"
import { execTargetKind, resolveEnvProfile, type ResolvedEnvProfile } from "../state/envprofile.ts"
import {
  execEnv,
  execWorkspace,
  loadTuiState,
  remoteCwd,
  rememberExecEnv,
  rememberModel,
  rememberMode,
  rememberRemoteCwd,
  rememberSessionPins,
  rememberSidebar,
  rememberTabs,
  sessionPins,
  type ModelPick,
} from "../state/tui_state.ts"
import {
  alwaysKey,
  describeKey,
  judge as judgeCall,
  modes,
  normalizeMode,
  poolPolicy,
  summarize as describeCall,
  type GateRequest,
  type PermissionMode,
} from "../approvals.ts"
import { configShow, type GateVerdict } from "../nulya/cli.ts"
import {
  listExtensions,
  readDelegationRecord,
  sessionExists,
  sessions_dir,
  type Contributions,
  type ExtensionEntry,
} from "../nulya/files.ts"
import { wrapApprovalNote } from "../approvalnote.ts"
import { createProjectIndex } from "../references.ts"
import { createSkillTable, skillTurn, splitSlash } from "../skills.ts"
import { describeTool } from "../render/registry.ts"
import { no_snapshot, runningModel, smoothUsageTotals, usageLabel, type UsageTotals } from "../state/session.ts"
import type { NextSession } from "./Welcome.tsx"
import {
  CliError,
  extRun,
  extSync,
  isVerdict,
  remoteCheck,
  sessionOutcome,
  sessionRebind,
  verdicts,
  type ModelView as ModelParams,
  type ProfileView,
  type TaskEntry,
  type ImageInput,
} from "../nulya/cli.ts"
import {
  activateUnattended,
  activeVersionOf,
  adoptBundled,
  adoptInstalled,
  failedIds,
  needsZigIds,
  planStore,
  seedBundled,
  sessionMember,
  summarize,
  syncRoot,
  type SessionMember,
} from "../extensions.ts"
import { builtin_names } from "../commands.ts"
import {
  createPackageCommandTable,
  deprecatedActionNote,
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
import { renderSessionPrompt } from "../sessionprompt.ts"
import { formatWithRef, parseWithRef, type WithRef } from "../with.ts"
import { builtin_tools, orphanPins, resolvableStandingPins, toolId } from "../pins.ts"
import {
  agent_id,
  agentPick,
  listAgents,
  renderAgent,
  readonlyCeiling,
  usableAgents,
  type AgentEntry,
  type RenderedAgent,
} from "../agents.ts"
import { createKeymap, matches, type Action } from "../keymap.ts"
import { expandPath } from "../browsedir.ts"
import { remoteDirSource } from "../dirsource.ts"
import { DirBrowser } from "./overlays/DirBrowser.tsx"
import { CheckoutPrompt } from "./CheckoutPrompt.tsx"
import {
  homeWorkspaceDir,
  isHomeWorkspaceDir,
  openWorkspaceAt,
  sameWorkspace,
  workspaceLabel,
} from "../workspaces.ts"
import { loadRecents, rememberRecent } from "../state/recents.ts"
import {
  applyStoreAction,
  inventory,
  planCheckout,
  planProjectStore,
  samePath,
  storeTrusted,
  workspaceStorePath,
  type CheckoutAction,
  type CheckoutPlan,
} from "../extensions.ts"
import { agentsDirOf, planProjectAgents, workspaceAgentFiles } from "../agents.ts"
import { rememberAgentsAnswer, rememberStoreAsked } from "../state/tui_state.ts"
import type { AttachOptions } from "../state/attach.ts"
import type { SessionState, TranscriptItem } from "../state/session.ts"
import type { Workspace } from "../nulya/bin.ts"

export interface AppProps {
  ws: Workspace
  /**
   * An existing session to open (`nulya-tui --session <id>`), or absent — and
   * then the screen starts on a DRAFT: no session, nothing on disk, until the
   * first message.
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
   * Which screen the guide opens. `/model` when something can
   * run and the remembered pick simply cannot; `/provider` when NO provider can
   * run at all, because then a list of models has nothing to offer and the
   * missing key is the whole of the problem.
   */
  guideOn?: "model" | "provider"
  /** Where the TUI remembers its last pick; tests point it elsewhere. */
  statePath?: string
  /**
   * The global `[[models]]` catalog, read once at launch. Only `context_window`
   * is used, for the status bar's fullness gauge (via `modelParamsFor`, which
   * prefers a profile's own catalog over this list) — without either, the
   * gauge simply does not appear, which is why this is optional rather than
   * loaded here.
   */
  models?: ModelParams[]
  /**
   * The profiles, as `config show --json` projects them. Two fields are read:
   * a profile's default model id (so a draft that names a profile and no model
   * can still say which model the session will actually run on), and — via
   * `modelParamsFor` — a profile's own `catalog`, when the front tab's frozen
   * identity is on a profile that reports one (codex today).
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
   * `current`. The user root needs no permission; the project
   * root is only here when `main` found it already trusted — the trust question,
   * the one thing that can stop a session from being created at all, is asked
   * before this screen exists and is the only thing still asked there.
   *
   * `bundled` seeds the drafts this binary ships into the user store first
   *. Both it and `user` are `[extensions] sync_on_start`;
   * `activate` is `auto_activate`, and it gates the pointer moves in both.
   */
  sync?: SyncPlan
  /**
   * Whether the agent definitions that came with this CHECKOUT may be used
   *. Asked once before this screen exists, exactly as the store
   * question is, and for two reasons at once: a definition becomes a system
   * prompt, and materialising one builds into this workspace's extension store,
   * which for an empty store is how the kernel records trust for it.
   * Definitions in `~/.nulya/agents` are never gated — nothing arrives there
   * without the person putting it there.
   */
  agentsTrusted?: boolean
  /**
   * `/settings` wrote a key in `tui.toml`: read the file chain again and let
   * the answer reach the screen (`render/theme.ts`'s `liveStyle`).
   *
   * The reload lives above this component because `style` is what the whole
   * tree draws from and it arrives as a prop; absent in tests, where a static
   * style is exactly what is wanted.
   */
  onSettingsEdited?: () => void | Promise<void>
}

/**
 * Which store roots a start-up pass touches, and whether it may move
 * `current`.
 *
 * There are two callers: the process's own pass
 * over the launch workspace, and the pass a tab makes the first time it walks
 * into a workspace nobody has been in yet (§5.3b point 6). The second one asks
 * for the project root alone — the user store is the machine's, and it is
 * synced once per process, not once per directory.
 */
export interface SyncPlan {
  user: boolean
  project: boolean
  activate: boolean
  bundled: boolean
}

/**
 * One call the kernel is holding open, and the promise it is held on. The
 * request is what `--gate` offered; resolving it is what lets the step
 * continue.
 */
interface Approval {
  request: GateRequest
  /** The session being stepped — not necessarily the tab in front. */
  session: string
  resolve: (verdict: GateVerdict) => void
}

/**
 * How long a notice stays up before the status line goes back to what it says
 * at rest: as long as it takes to read it, and no longer.
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
 * The heartbeat echo going this stale means the reactive layer is dead — the
 * beat is written every second, so five missed echoes is not a busy loop, it
 * is a broken one.
 */
const reactive_stall_ms = 5000

/**
 * The cards browse mode walks: everything with a body that is actually on
 * screen. It walks ROWS, not items — the transcript's own projection,
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
 * by hairlines, no borders. The title line above them is gone
 * what it said that mattered — the model — is under the composer,
 * and what it said that did not — a session id — is in `/sessions`.
 *
 * There is no intelligence above the driver here. Slash commands map one to one
 * onto CLI verbs; anything else the user types goes to the model verbatim.
 */
export function App(props: AppProps) {
  const renderer = useRenderer()
  const keymap = createDefaultOpenTuiKeymap(renderer)
  const screen = useTerminalDimensions()
  const folds = createFoldStore()
  const browse = createBrowseStore()
  /**
   * The content area is a pane tree; today it holds exactly one pane, so the
   * screen this front end draws is that model's degenerate case.
   *
   * `overlay` is the same store every call site below already uses, answered
   * from the tree instead of from a signal of its own — "which overlay is in
   * front" is "which surface the one pane shows", and `active()` is "does
   * that surface take the keyboard" (`state/panes.ts`).
   */
  const surfaces = createSurfaceRegistry<JSX.Element>()
  /**
   * The APP tree: what is on screen across tabs. One leaf today — the
   * portal — with the sessions sidebar splitting off beside it.
   */
  const panes = createPaneStore(tab_surface)
  /** The front tab's own tree: the transcript, a full-screen view, a sub-agent. */
  const tabPanes = (): PaneStore => tabs.active().panes
  /**
   * The leaf the keyboard is really in, resolved through the portal. Every
   * reader of "where is the keyboard" goes through this, so the fact that
   * there are two trees is known in exactly one place (`state/panes.ts`).
   */
  const keyboardLeaf = () => focusThrough(panes, tabPanes())
  const overlay = overlayAdapter(tabPanes, keyboardLeaf, (surface) => claimsKeyboard(surfaces, surface))
  /**
   * The sessions sidebar — the first real split, and the first thing on
   * this screen whose state is NOT the pane tree.
   *
   * What is remembered is what was ASKED for, and the tree is reconciled to it.
   * They come apart on a narrow terminal, where the sidebar hides itself
   * without anybody deciding to: storing "is it open" in the tree alone would
   * turn a window somebody dragged narrow into an answer they never gave, and
   * the next wide window would open without it.
   */
  const remembered_sidebar = loadTuiState(props.statePath).sidebar
  const [sidebarWanted, setSidebarWanted] = createSignal(remembered_sidebar?.open ?? false)
  const [sidebarShare, setSidebarShare] = createSignal(remembered_sidebar?.ratio ?? default_sidebar_ratio)
  const sidebarFits = () => screen().width >= sidebar_min_width
  const sidebarOpen = () => isSidebarOpen(panes.tree())
  /**
   * The box the panes are laid out in, for the one question only placement can
   * answer: which pane is to the left of this one (`moveFocus`).
   *
   * The terminal's own rectangle. The content area is narrower than the screen
   * by the rows above and below it, but a row split divides the WIDTH and those
   * rows take height — and a direction is decided by relative positions, which
   * a uniform vertical offset cannot change.
   */
  const screenRect = () => ({ x: 0, y: 0, width: screen().width, height: screen().height })
  /**
   * The portal's box: where the front tab's own tree is laid out.
   *
   * Measured through the app tree's `layout` rather than recomputed from the
   * sidebar ratio, for the reason `sidebarWidth` is: a second copy of the
   * same arithmetic is a second answer waiting to disagree with the seam.
   */
  const portalRect = () =>
    panes.boxes(screenRect()).find((box) => box.surface === tab_surface)?.rect ?? screenRect()
  createEffect(() => {
    const want = sidebarWanted() && sidebarFits()
    if (want === sidebarOpen()) return
    // Closing hands the focus to whatever takes the box (`closePane`), so a
    // sidebar that goes away while the keyboard is in it does not leave the
    // keyboard nowhere.
    panes.apply((tree) => (want ? openSidebar(tree, panes.main(), sidebarShare()) : closeSidebar(tree)))
  })
  const keys = createKeymap(props.style.settings)
  // Opened by name, or a draft. Nothing else creates a session on the way in:
  // composition freezes at `session new` (physics #2), so a session made before
  // the first word is one whose tools, pins and model were decided by nobody.
  const first: FirstTab =
    props.id && props.state
      ? { kind: "session", id: props.id, state: props.state, created: props.created ?? false, effort: props.effort }
      : { kind: "draft", pick: props.pick, effort: props.effort }
  /**
   * Every step this TUI drives is gated: the kernel asks before
   * each tool call and this answers. The mode is not passed to the kernel and
   * never could be — `--gate` has one semantic, allow or deny, and WHICH calls
   * are worth a person's attention is this front end's policy. So a mode
   * switched mid-batch reaches the very next request, because every request is a
   * fresh call into `approve`.
   */
  const tabs = createTabStore(props.ws, first, {
    ...(props.driver ?? {}),
    statePath: props.statePath,
    sshPassword: (session) => {
      const held = sshPassword()
      if (!held) return undefined
      const target = tabs.tabs().find((tab) => tab.kind === "session" && tab.id === session)
      return target?.kind === "session" && target.state.snapshot.header?.environment === held.spec
        ? held.bytes.slice()
        : undefined
    },
    gate: (request, session) => approve(request, session),
    // Every line every step prints, to whatever plugins asked to watch
    // (tui-plugin U3, `api.observe`). A pure observer: it runs after the
    // transcript has been told, and it decides nothing.
    onLine: (line, session) => plugins.observe(line, session),
  })

  /**
   * A sub-agent split follows the terminal it is drawn in.
   *
   * `subSplitDirection` answers "is there room to read two conversations side
   * by side" from the width, and the width is something a person changes by
   * dragging a window — so the answer has to be re-derived rather than kept
   * from the moment the pane opened. Every tab, not only the one in front: a
   * tab holds its own tree and a background one would otherwise come forward
   * still divided the way some earlier terminal was. It costs nothing to do so,
   * because `reflowSubSplits` hands back the tree it was given whenever no
   * split needs turning — and a tab with no sub-agent pane is exactly that case.
   */
  createEffect(() => {
    const width = screen().width
    for (const one of tabs.tabs()) one.panes.apply((tree) => reflowSubSplits(tree, width))
  })

  /**
   * One instance per workspace of the three tables that are ABOUT a directory:
   * the `@` path index, the skill catalog and the package command table.
   *
   * They used to be one each, built from the process's workspace, which was
   * right while there was one. Keyed and kept, rather than rebuilt per read:
   * the path index walks a repository and the other two spawn the binary,
   * so a memo that ran on every frame would be a process per frame. A workspace
   * a tab still holds keeps its table; there is no eviction because the number
   * of directories a person has tabs in is the number of tabs.
   */
  const perWorkspace = <T,>(make: (where: Workspace) => T) => {
    const held = new Map<string, T>()
    return (where: Workspace): T => {
      let made = held.get(where.dir)
      if (!made) {
        made = make(where)
        held.set(where.dir, made)
      }
      return made
    }
  }
  // The workspace's paths, for `@` completion. Built in the
  // background from the moment the screen exists: the first `@` before it
  // finishes shows nothing and the next one shows everything, which beats a
  // composer that stops accepting characters while git walks a monorepo.
  const referencesFor = perWorkspace((where) => createProjectIndex(where.dir))
  /**
   * The skill catalog behind `/name`. It goes stale exactly
   * when an extension is activated or deactivated, which is why `/ext` hands
   * back `invalidate` rather than this polling for it.
   */
  const skillsFor = perWorkspace((where) => createSkillTable(where))
  /**
   * Package-declared slash commands (tui-plugin D1/D2/D8), same staleness
   * contract as `skills` above — `/ext` invalidates both on a membership
   * change, since activating or deactivating a package can add or remove
   * either kind of thing it offers.
   */
  const packageCmdsFor = perWorkspace((where) => createPackageCommandTable(where))

  /**
   * The line under the composer, when it has news.
   *
   * A notice covers that whole line while it is up, so it must also come down
   * on its own: a message that stays is a message that stops being true — the
   * screen said `Ctrl+C again to quit` long after the offer had lapsed, and
   * `opened s-…` for the rest of the session. Everything here is news by
   * default and goes stale; `holdNotice` is for the two things that are not
   * news but a state the screen is IN (browse mode, a plugin panel awaiting an
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
  const [displayUsage, setDisplayUsage] = createSignal<UsageTotals>({ ...no_snapshot.usage })
  const [ctrlCArmed, setCtrlCArmed] = createSignal(false)
  const [behind, setBehind] = createSignal(0)
  /**
   * Bumped whenever the pin list on disk may have moved (an overlay closed, a
   * session was created). The draft card's tool face is read from files, and a
   * signal is what tells this screen to look again.
   */
  const [planTick, setPlanTick] = createSignal(0)
  /**
   * The start-up store pass while it is running (`WorkingStatus.SyncProgress`).
   * Null at rest, which is what makes the activity line disappear on its own.
   */
  const [syncing, setSyncing] = createSignal<SyncProgress | null>(null)
  /**
   * The permission mode. Remembered on screen, like the model
   * pick: `tui-state.json` first (what was last chosen here), then `tui.toml`'s
   * `[driver] mode`, then `ask`.
   */
  const [mode, setMode] = createSignal<PermissionMode>(
    loadTuiState(props.statePath).mode ?? props.style.settings.driver.mode,
  )
  /**
   * Whether the mode picker is up, and which row its cursor is on. A dialog
   * above the composer rather than a full-screen overlay — two rows of
   * content — so it is its own two signals rather than an `OverlayKind`.
   */
  const [modePicker, setModePicker] = createSignal(false)
  const [modeChoice, setModeChoice] = createSignal(0)
  /**
   * Whether the context panel is open (`ui/ContextPanel.tsx`) — the ring on
   * the status row, opened out.
   *
   * Deliberately NOT one of `resolveFocus`'s dialogs: it chooses nothing, takes
   * no keystroke, and everything on it is a number. What it does share with a
   * package's panel is where it may appear — while a trusted zone is up it is
   * not drawn at all, and comes back when the zone clears (`dialogUp`).
   */
  const [contextPanel, setContextPanel] = createSignal(false)
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
   * at when they pressed it.
   *
   * Ids, not a flag, and that is the whole point. A run can contain several
   * steps, so "allow the rest" as a boolean would quietly cover a batch nobody
   * has seen yet; the ids are exactly the calls that were on screen — every one
   * of them already drawn as a card — and nothing else can join the set.
   */
  const [batchAllowed, setBatchAllowed] = createSignal<ReadonlySet<string>>(new Set())
  /** Which answer the approval dialog's cursor is on. */
  const [choice, setChoice] = createSignal(0)
  /** Whether the dialog's note field has the keyboard rather than the list. */
  const [noteFocused, setNoteFocused] = createSignal(false)
  /** The dialog's note field, for focusing, reading and clearing it. */
  let noteField: InputRenderable | null = null

  /**
   * What the `/agent` PICKER is showing, and nothing else.
   *
   * Read once when the picker opens and never consulted by a path that starts
   * something: `agentsIn` returns its listing, and every caller acting on a
   * definition uses that return value, in the directory it asked about. A
   * catalog shared by the screen and the delegation is a catalog that can be
   * replaced by another workspace's between the two — which is exactly how a
   * definition from one checkout came to be started against another's answer.
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
  /**
   * Whether the composer-area background-tasks panel is open (`TasksPanel`) —
   * the background count on the activity line, opened out.
   *
   * Deliberately NOT one of `resolveFocus`'s dialogs: it chooses nothing and
   * takes no keystroke of its own (its stop buttons are mouse-only, `ui/rows.
   * ts`). What it shares with a package's panel is where it may appear —
   * while a trusted zone is up it is not drawn at all, and comes back when
   * the zone clears (`dialogUp`). `/tasks` (F7) is a separate, full-screen
   * view and this signal does not touch it.
   */
  const [tasksPanel, setTasksPanel] = createSignal(false)
  const toggleTasksPanel = () => setTasksPanel((up) => !up)
  /** Bare `/with`: the registered packages a session may name (`WithPicker`). */
  const [withPicker, setWithPicker] = createSignal(false)
  const [withChoice, setWithChoice] = createSignal(0)
  const [wearables, setWearables] = createSignal<Wearable[]>([])
  /** Bare `/env`: where this machine can run a shell (`EnvPicker`). */
  const [envPicker, setEnvPicker] = createSignal(false)
  const [envChoice, setEnvChoice] = createSignal(0)
  const [envTargets, setEnvTargets] = createSignal<ExecChoice[]>([])
  /**
   * The remote directory browser's pending target, between picking a
   * `remote:` row in `EnvPicker` and choosing a directory on it — the second
   * half of a two-part choice. `null` means
   * the `envdir` overlay has nothing to show, which is also why opening it is
   * never the picker's own move: `beginRemoteBrowse` sets this and THEN opens
   * the overlay, so the two can never disagree about whether there is a
   * target.
   */
  const [remoteBrowse, setRemoteBrowse] = createSignal<{ spec: string; start: string; home: string } | null>(null)
  /**
   * A remote channel refusal belongs on the main screen, not in the one-row
   * status hint below the composer. In particular, OpenSSH may write a warning
   * before the actionable authentication failure; `CliError.message` keeps
   * only that first line while `detail` keeps the complete diagnosis.
   *
   * This is separate from `refusal`: choosing an environment may happen on a
   * live session too, and its failure says nothing about creating that session.
   * A new attempt clears the old answer; success leaves no stale failure behind.
   */
  const [remoteFailure, setRemoteFailure] = createSignal<{ tab: string; detail: string } | null>(null)
  /** Password bytes exist only for the current remote workflow. */
  const [sshPassword, setSshPassword] = createSignal<{ spec: string; bytes: Uint8Array } | null>(null)
  const [passwordRequest, setPasswordRequest] = createSignal<{ spec: string; bytes: Uint8Array } | null>(null)
  const freshSshPassword = (spec = sshPassword()?.spec): Uint8Array | undefined => {
    const held = sshPassword()
    return held && spec === held.spec ? held.bytes.slice() : undefined
  }
  const replacePasswordRequest = (next: { spec: string; bytes: Uint8Array } | null) => {
    const old = passwordRequest()
    if (old) old.bytes.fill(0)
    setPasswordRequest(next)
  }
  const clearSshPassword = () => {
    const held = sshPassword()
    if (held) held.bytes.fill(0)
    setSshPassword(null)
  }
  const clearSshWorkflow = () => {
    replacePasswordRequest(null)
    clearSshPassword()
  }
  /**
   * Any of the composer's pickers is up. One accessor because every rule about
   * them is about ALL of them — who holds the keyboard, whether the composer
   * may blink, whether a shortcut layer answers — and a fifth picker should
   * change one line rather than six.
   */
  const pickerUp = () => modePicker() || withPicker() || agentPicker() || envPicker()
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
   * One map where there used to be one `let` per package: configured
   * entries come from `[extensions] session_with`, and `agentPackage`
   * below reads the same entry the composition does rather than building the
   * same draft a second time.
   *
   * KEYED BY WORKSPACE as well as by id (S1c). A version resolved here is a
   * version in a particular store, and the store search order is the
   * workspace's (`.nulya/extensions` first) — so the same id in
   * two directories can honestly be two versions, and a cache that remembered
   * only the id would compose the second workspace's session out of the first
   * one's build.
   */
  const memberBuilds = new Map<string, Promise<SessionMember | null>>()
  const sessionMemberOnce = (where: Workspace, id: string): Promise<SessionMember | null> => {
    const key = `${where.dir}::${id}`
    let started = memberBuilds.get(key)
    if (!started) {
      started = sessionMember(where, id).catch(() => null)
      memberBuilds.set(key, started)
    }
    return started
  }
  /**
   * The `agent` package IN ONE DIRECTORY, for the delegation paths that need
   * its version.
   *
   * `where` is a parameter and not `ws()` because building it is the slow step
   * on a cold machine — a whole toolchain run — and everything after the await
   * has to be about the directory the caller asked about, not about whichever
   * tab happens to be in front by the time it answers.
   */
  const agentPackage = async (where: Workspace): Promise<WithRef | null> => {
    const member = await sessionMemberOnce(where, agent_id)
    return member ? { id: member.id, version: member.version } : null
  }
  const [composedWithTools, setComposedWithTools] = createSignal<string[]>([])
  /**
   * The `surface:"auto"` tools those composed packages will put on the face,
   * known before the session exists — so the draft screen can count them.
   *
   * Read from the ACTIVE version's manifest plus config projection, not by
   * resolving the member: `sessionMember` may build a bundled draft, which is a
   * toolchain run, and a screen that has not been asked for anything yet must
   * not start one. Under-reporting while background sync is still
   * activating a freshly built bundled package is the right way to be wrong.
   */
  const refreshComposedMembership = async () => {
    try {
      const [listed, config] = await Promise.all([listExtensions(ws()), configShow(ws(), props.driver?.env)])
      healStandingPins(listed)
      const profile = envProfile(execEnv(props.statePath))
      // Three ways a package is in every session started here: it asked
      // and the kernel recorded it (`standing` — the kernel's own answer, never
      // an `apply` re-read here), config named it, or this front end always
      // brings it. Under `--bare` (the default for `remote` exec targets)
      // neither standing table applies — config's `with` and every
      // `apply:"auto"` package's own bit — so only THIS list's own `--with`
      // refs count.
      const named = profile.bare ? new Set(profile.with) : new Set([...config.extensions.with, ...profile.with])
      setComposedWithTools(
        listed
          .filter((entry) => entry.current && !entry.shadowed && (named.has(entry.id) || (!profile.bare && entry.standing)))
          .flatMap((entry) => entry.autoTools.map((tool) => toolId(entry.id, tool))),
      )
    } catch {
      // No listing is "unknown"; the pin files still say what they say.
      setComposedWithTools([])
    }
  }
  /**
   * The profile the NEXT `session new` from this screen would compose with,
   * for the exec target `spec` names — `/env`'s pending choice on a draft, or
   * a started session's frozen `environment` (`state/envprofile.ts`).
   *
   * One function two call sites read: `sessionExtras()` (what is actually
   * sent to the kernel) and the draft screen's tool count
   * (`refreshComposedMembership` / `plannedFaceTools`) — never two answers to
   * "what does this env compose".
   */
  const envProfile = (spec: string): ResolvedEnvProfile =>
    resolveEnvProfile(
      execTargetKind(spec),
      props.style.settings.extensions.session_with,
      props.style.settings.extensions.session_prompts,
      props.style.settings.env,
    )

  /**
   * Take back standing pins this front end should no longer hold — before the
   * first message, not when somebody happens to open `/ext`.
   *
   * One kind of stale line: a pin whose package has no `current` any more. A
   * pin brings its package in, and with nothing to bring the
   * session does not start at all (`WithVersionNotFound`, `cli/session.zig`).
   * `/ext` has repaired this list but only while its panel was up.
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
   * Why the draft in front of this person is still a draft.
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

  let composer: ComposerApi | null = null
  let scroll: ScrollBoxRenderable | null = null

  const tab = () => tabs.active()
  /**
   * The directory the front tab works in (goals/tui-shell.md §5.3b).
   *
   * Everything below that acts on a session, reads a store, or spawns anything
   * at all goes through this rather than `props.ws` — which now means only "the
   * workspace the PROCESS was launched in": the default a new tab inherits, and
   * the one whose start-up questions `main` already asked on a bare terminal.
   */
  const ws = (): Workspace => tab().ws
  /**
   * The distinct workspaces with a tab open, the front tab's first.
   *
   * The sessions list is grouped by this (§5.3b point 4), and the ordering is
   * the whole of that policy: the group somebody is working in is the one they
   * are looking for. On a screen with one workspace this has one entry and the
   * list draws no headings at all — which is what keeps the whole feature
   * invisible until a second directory is actually open.
   */
  const openWorkspaces = (): Workspace[] => {
    const out: Workspace[] = [tab().ws]
    for (const one of tabs.tabs()) {
      if (!out.some((known) => sameWorkspace(known, one.ws))) out.push(one.ws)
    }
    return out
  }
  /**
   * What the status line says about this tab's directory, or nothing at all.
   *
   * Nothing is the normal case and the reason this is a function rather than a
   * chip that is always drawn (§6.1 rule 4): on a screen working in one
   * directory the answer is the same for every tab and for the whole program,
   * so a column spent repeating it is a column spent saying nothing. It earns
   * its place exactly twice — when a second workspace has a tab open and the
   * answer therefore varies, and on the `no project` tab, whose whole point is
   * that it is not the directory you launched in.
   */
  const workspaceChip = (): string | undefined => {
    const here = ws()
    if (isHomeWorkspaceDir(here.dir)) return workspaceLabel(here.dir)
    return openWorkspaces().length > 1 ? workspaceLabel(here.dir) : undefined
  }
  /** The three per-directory tables, for the tab in front. */
  const references = () => referencesFor(ws())
  const skills = () => skillsFor(ws())
  const packageCmds = () => packageCmdsFor(ws())
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
  /**
   * A stop button pressed on screen — the tasks panel's and `/tasks`'s only
   * write, and `state/tasks.stopTask` is the one place it happens (its own
   * doc comment says why: the kill and the "stopped by the user" note have to
   * land together or not at all). Bound here to the front tab's `ws` and
   * `attach.send` so neither caller needs to know either exists.
   *
   * BOTH halves come off the same tab, and that is the whole of it: `ws` is
   * where `nulya task kill` actually runs and `send` is where the note lands,
   * so taking one from the tab and the other from the process's launch
   * directory (`props.ws`, which since S1c means only "where this process
   * started") is a stop executed in one checkout and explained in another —
   * usually killing nothing, and where two workspaces hold the same handle,
   * killing the wrong task.
   */
  const stopBackgroundTask = async (task: string) => {
    const here = live()
    if (!here) return
    try {
      await stopTask(here.ws, here.attach.send, task)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
    void here.tasks.refresh()
  }

  createEffect(() => {
    if (!props.style.motion) return
    // Every kind of work that draws a moving line, not just the driver's own.
    // A background task spins while the driver rests — and so does
    // the start-up store pass, which is the FIRST thing anybody sees and used to
    // be the one moving line that did not move: it runs before there is a
    // session to be stepping, so `idle` plus no tasks stopped the clock and
    // `building std` sat there with a frozen glyph and a still shimmer for as
    // long as zig took. The condition is the union of what `activityOf` calls
    // `moving`, written from the same three facts.
    if (status() === "idle" && runningTasks() === 0 && !syncing()) return
    const timer = setInterval(() => setSpinnerTick((tick) => tick + 1), 90)
    onCleanup(() => clearInterval(timer))
  })

  /**
   * Build the drafts sitting in the store roots, in the background. A
   * compiled draft takes seconds, so this must never be on the way in —
   * the transcript is usable throughout and the status line says what is going
   * on. Nothing here decides what a draft is or which version it becomes: the
   * plan and the pass are both `nulya ext sync`.
   *
   * Activation is narrower than the kernel's `--activate`, which also points
   * `current` at any id that has none at all: this pass only activates versions
   * it produced itself, so a package somebody deliberately rolled back stays
   * where they put it.
   *
   * Whether a pointer may move at all is not decided here. Every unattended
   * move in this front end goes through `activateUnattended`, which asks
   * the reach question from both sides: does the CANDIDATE declare
   * `apply: "auto"`, and is whatever is active today STANDING — the kernel's
   * own record, not a manifest re-read here. For everything else activating
   * composes nothing and is safe to do unattended. For an
   * `apply: "auto"` package on either side of the move, activating IS
   * composing — the kernel joins or drops it from every fresh session here
   * from that moment — and a background pass does not get to decide what
   * every session on this machine carries, in either direction.
   */
  const syncStores = async (where: Workspace = props.ws, asked?: SyncPlan) => {
    const plan = asked ?? props.sync
    if (!plan) return
    // The drafts the BINARY ships, into the user store, before the pass that
    // builds them: seeding writes source only, so the one pass
    // below builds what arrived along with everything else. This used to be a
    // question on a bare terminal BEFORE the screen existed, and answering it
    // held that terminal for a minute of zig with `installing…` as the only
    // sign of life.
    //
    // It also CARRIES FORWARD the drafts a previous binary seeded and nobody has
    // edited since — before that, upgrading nulya left the user store on
    // whatever source the first binary happened to drop, so a package that grew
    // a tool, or lost a manifest field, stayed as it was until somebody deleted
    // the directory. Drafts that were edited are left alone and named
    // below; the ids seeding moved are ordinary changed drafts to the pass that
    // follows, which builds them and points `current` at what it built.
    // Which ids already had a `current` BEFORE this pass — read once, before
    // seeding writes anything. It is what separates "installed" from "moved
    // forward", and only the first may write pins on somebody's behalf. An
    // unreadable listing leans towards "already had one", so a pass that cannot
    // tell writes no pins rather than writing them over a person's choices.
    const hadCurrent = new Set<string>()
    let listedBefore: ExtensionEntry[] | null = null
    try {
      listedBefore = await listExtensions(where)
    } catch {
      listedBefore = null
    }
    for (const entry of listedBefore ?? []) if (entry.current !== null) hadCurrent.add(entry.id)
    const canTellInstalls = listedBefore !== null

    let arrived: string[] = []
    let refreshed: string[] = []
    let untouched: string[] = []
    if (plan.user && plan.bundled) {
      try {
        setSyncing({ what: "installing the bundled extensions", done: 0, total: 0, since: Date.now() })
        const seed = await seedBundled(where)
        arrived = seed.ids
        refreshed = seed.updated
        untouched = seed.mine
      } catch {
        // A binary too old to have `ext seed` ships nothing to install.
      }
    }
    const roots = [
      ...(plan.user ? [{ label: "user store", user: true }] : []),
      // The launch workspace is "this checkout" because that is what it is to
      // the person who started the program here. A workspace a TAB walked into
      // is named, because by then there is more than one and "this checkout"
      // stops picking one out (§5.3b point 6).
      ...(plan.project
        ? [{ label: sameWorkspace(where, props.ws) ? "this checkout" : workspaceLabel(where.dir), user: false }]
        : []),
    ]
    // One line of news for the whole pass, across roots: a quiet second root
    // must not wipe what the first one had to say.
    const news: string[] = []
    for (const root of roots) {
      try {
        // The plan's ids IN ORDER, not just how many there are: the kernel
        // reports a draft when it finishes, so the one being worked on is the
        // next one in the same list `ext sync` is walking. Naming it is what
        // turns a stalled counter into `building std` — the whole difference
        // between a screen that looks stuck and one that says who it is waiting
        // for.
        const queue = (await planStore(where, root.user)).lines.map((line) => line.id)
        const total = queue.length
        if (total === 0) continue
        let done = 0
        const since = Date.now()
        // Past the last draft the pass is still going — pointers to move, a
        // listing to re-read — so the line stays up and stops naming a draft
        // rather than naming one that is already done.
        const onDraft = () => {
          const next = queue[done]
          setSyncing({ what: next ? `building ${next}` : "syncing extensions", done, total, since })
        }
        onDraft()
        const report = await extSync(where, { user: root.user }, () => {
          done += 1
          onDraft()
        })
        let activated = 0
        // Built, and left where it was: the store could not answer what the
        // pointer was about to name. Named rather than counted — "1 not
        // activated" is not something anybody can act on, and the id is one
        // `/ext` Enter away.
        const held: string[] = []
        // Packages this pass INSTALLED — gave a first `current` — and what they
        // now reach. A first install is the one moment the pins a package
        // recommends may be written for somebody (`pinRecommended`); after that
        // the pin list is theirs.
        const installed: Contributions[] = []
        if (plan.activate) {
          for (const line of report.lines) {
            if (!line.version || line.activation === "active") continue
            // What arrived with the binary this run is `adoptBundled`'s to
            // decide: everything a fresh seed drops is `built` by this pass.
            if (arrived.includes(line.id)) continue
            // A bundled draft refreshed by `ext seed` is this binary's own old
            // copy, untouched locally. The build may still print `already
            // built` when that content-addressed version was produced earlier
            // (for example by another driver or TUI start), but the SOURCE
            // did move forward in this run and the active pointer should follow
            // it just as it does when the version was newly built here.
            if (line.state !== "built" && !(root.user && refreshed.includes(line.id))) continue
            // Every unattended pointer move goes through the one door, here and
            // everywhere else this front end moves one with nobody watching —
            // this loop only knows which version was built.
            const { outcome, built } = await activateUnattended(where, {
              id: line.id,
              version: line.version,
              root: syncRoot(where, root.user),
              user: root.user,
            })
            if (outcome === "activated") {
              activated += 1
              if (built && canTellInstalls && !hadCurrent.has(line.id)) installed.push(built)
            } else if (outcome === "held") held.push(line.id)
          }
        }
        const adopted =
          root.user && arrived.length > 0 && plan.activate
            ? await adoptBundled(where, arrived, report, props.statePath, canTellInstalls ? hadCurrent : undefined)
            : []
        // The same two sentences for the ids this loop installed, from the one
        // place that knows what a first `current` is worth saying about.
        adopted.push(...(await adoptInstalled(where, installed, props.statePath)))
        // Pins land in `tui-state.json`, which the draft card and the status
        // line read from disk: this is what tells them to look again.
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
          adopted.length === 0 &&
          held.length === 0
        ) {
          continue
        }
        news.push(
          summarize(root.label, report) +
            (activated > 0 ? ` · ${activated} activated` : "") +
            (held.length > 0 ? ` · ${held.join(" ")} built, not activated · /ext` : "") +
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
    // What the binary brought and what it did not dare touch. The second
    // half is the one that needs a person: a bundled draft it cannot recognise
    // as its own is either something you wrote or something an old nulya seeded,
    // and only you know which — so it is named with the command that replaces it
    // rather than replaced.
    if (refreshed.length > 0) news.push(`${refreshed.join(" & ")} updated to this build`)
    if (untouched.length > 0) {
      // A notice is not where this lives — it is durable state, and `/ext` says
      // it for as long as it is true, with the key that fixes it. Naming a
      // shell command here was the wrong shape twice over: it is gone in six
      // seconds, and it asks a person to leave the program to repair it.
      news.push(`${untouched.join(" & ")} differ from this build · /ext · s updates one`)
    }
    // There used to be one more line here: whichever mode packages were active
    // on this machine, named because activating one put its system prompt in
    // front of every model. That state no longer exists — `current` says
    // which version an id means and composes nothing — so there
    // is nothing to warn about and no list to compute.
    setSyncing(null)
    setNotice(news.length > 0 ? news.join(" · ") : null)
    // The pass wrote to the store, so every screen reading it from disk is now
    // stale — including an `/ext` a person opened WHILE it ran, which used to
    // keep showing the plan from before the build and made a finished sync look
    // like one that never happened. `planTick` is the existing "something wrote
    // those files" signal; the bump is unconditional because a pass that only
    // moved a pointer changed the listing just as much as one that built.
    setPlanTick((tick) => tick + 1)
  }

  // ── Walking into a workspace for the first time (§5.3b point 6) ───────────

  /**
   * The start-up flow this process has driven, per directory
   * (`state/enter.ts`).
   *
   * The launch workspace is in it from the start: `main` asked about that one
   * on the bare terminal, before the alternate screen, which is still the right
   * place for it — it is the only workspace that exists before the screen does.
   * Every other one is walked into by a TAB, and a question asked on a bare
   * terminal at that point would be a question asked underneath the screen.
   *
   * An entry is the RUN, and it means the flow reached an answer rather than
   * that somebody started it. A mark written on the way in describes a
   * directory whose question is still on screen exactly as it describes one
   * that was answered — so a question that got lost was never asked again.
   */
  const entered = createEntryOnce([props.ws.dir])
  /**
   * What the agent definitions that came with a CHECKOUT may do, per
   * workspace.
   *
   * A map rather than a single value: this is a fact about a directory, and
   * the screen now holds tabs in several. `props.agentsTrusted` is the launch
   * workspace's answer, already given.
   *
   * THREE STATES, not a boolean (`WorkspaceTrust`): "not answered yet" is a
   * state this screen is really in — the question is on screen, or it is behind
   * another workspace's — and a boolean could only spell it as one of the two
   * answers. It was spelled as the permissive one. An absent prop is `pending`
   * for the same reason: a host that never asked has no answer to report, and
   * the word for that is not "trusted".
   */
  const [agentsTrust, setAgentsTrust] = createSignal<ReadonlyMap<string, WorkspaceTrust>>(
    new Map<string, WorkspaceTrust>(
      props.agentsTrusted === undefined ? [] : [[props.ws.dir, props.agentsTrusted ? "trusted" : "denied"]],
    ),
  )
  const noteAgentsTrust = (where: Workspace, trust: WorkspaceTrust) =>
    setAgentsTrust((now) => new Map([...now, [where.dir, trust]]))
  const agentsTrustIn = (where: Workspace): WorkspaceTrust => agentsTrust().get(where.dir) ?? "pending"

  /** One directory's unanswered checkout question, and the start-up it holds up. */
  interface Asking {
    ws: Workspace
    plan: Extract<CheckoutPlan, { kind: "ask" }>
    store: string
    agentsDir: string
    storeAsked: boolean
    /** Which `planProjectAgents` kind this directory had — what the answer is worth. */
    agentsPlan: "none" | "ready" | "ask"
  }
  /**
   * The checkout questions waiting for a key (`ui/CheckoutPrompt.tsx`), in line.
   *
   * A QUEUE rather than one slot, because tabs enter their directories
   * concurrently — restoring a remembered screen walks into all of them at
   * once. With one slot the second question overwrote the first, and the
   * checkout it silently dropped was left with an untrusted store and
   * unanswered definitions that nothing would ever ask about again.
   */
  const asking = createAskQueue<Asking>()
  const checkout = asking.head

  /**
   * The start-up flow, per workspace rather than per launch (§5.3b point 6).
   *
   * Everything `main.tsx` does before the screen exists — the workspace store's
   * trust question, the `.nulya/agents` question, and then the project store's
   * build pass — happens here for every OTHER directory a tab walks into. The
   * plans themselves are the same pure functions `main` uses (`planProjectStore`,
   * `planProjectAgents`, `planCheckout`); what differs is only where the answer
   * is typed, and that difference is why this exists at all.
   *
   * The kernel's own gate is untouched and still has the last word: a store
   * this refuses to trust makes `session new` fail in that tab, with the
   * kernel's paragraph shown in full where the draft is (`refusal`).
   */
  const enterWorkspace = (where: Workspace) =>
    entered.enter(where.dir, async () => {
      const store = workspaceStorePath(where)
      const storePlan = await (async () => {
        if (!props.style.settings.extensions.sync_on_start) return { kind: "none" as const }
        try {
          return planProjectStore(
            store,
            await inventory(where, false),
            storeTrusted(store),
            loadTuiState(props.statePath).asked_stores ?? [],
          )
        } catch {
          // No store, no binary answer — the session's own gate still speaks.
          return { kind: "none" as const }
        }
      })()
      const agentsDir = agentsDirOf(where, "workspace")
      const state = loadTuiState(props.statePath)
      const trustedAlready = (state.trusted_agents ?? []).some((known) => samePath(known, agentsDir))
      const agentsPlan = planProjectAgents(
        agentsDir,
        workspaceAgentFiles(where),
        trustedAlready,
        state.asked_agents ?? [],
        samePath,
      )
      const plan = planCheckout(storePlan, agentsPlan)
      if (plan.kind !== "ask") {
        noteAgentsTrust(where, trustAfter(agentsPlan.kind, null))
        if (storePlan.kind === "ready") await syncEntered(where)
        return
      }
      // In line, and this flow is not finished until that question is answered:
      // an entry means an ANSWER, so a second tab walking in here waits with it
      // rather than deciding the directory has been dealt with.
      await asking.push({
        ws: where,
        plan,
        store,
        agentsDir,
        storeAsked: storePlan.kind === "ask",
        agentsPlan: agentsPlan.kind,
      })
    })

  /** That workspace's project store, built on the same pass the launch one gets. */
  const syncEntered = (where: Workspace) =>
    syncStores(where, {
      user: false, // the machine's store is synced once per process, not per directory
      project: props.style.settings.extensions.sync_on_start,
      activate: props.style.settings.extensions.auto_activate,
      bundled: false, // what the binary ships goes to the user store, once
    }).then(refreshComposedMembership)

  /**
   * One key at the checkout question. An answer the plan does not recognise
   * leaves the dialog exactly where it is — `apply` is what decides which keys
   * are answers, here as on the bare terminal.
   */
  const answerCheckout = async (key: string) => {
    const asked = checkout()
    if (!asked) return
    const action: CheckoutAction | null = asked.plan.apply(key)
    if (!action) return
    // The answered question leaves the queue and releases ITS OWN start-up
    // flow — the next directory's question is then on screen, having waited
    // rather than been overwritten. It is released here rather than after the
    // install below because what a flow was waiting for is the ANSWER; the
    // install is what the answer then causes, and it reports for itself.
    asking.settleHead()
    if (asked.storeAsked) rememberStoreAsked(asked.store, props.statePath)
    if (asked.agentsPlan === "ask") rememberAgentsAnswer(asked.agentsDir, action.agentsTrust, props.statePath)
    // What the answer is worth to the definitions is `trustAfter`'s one
    // reading, the same one the never-asked path uses: a question that did not
    // speak for them (they were already trusted, or there are none) does not
    // get to grant them anything on the strength of a store answer.
    noteAgentsTrust(asked.ws, trustAfter(asked.agentsPlan, action.agentsTrust))
    const where = workspaceLabel(asked.ws.dir)
    if (!action.store.trust && !action.store.sync) {
      setNotice(`${where} · left alone · \`nulya ext trust\` whenever you mean to`)
      return
    }
    try {
      setSyncing({ what: `installing ${where}`, done: 0, total: 0, since: Date.now() })
      const report = await applyStoreAction(asked.ws, action.store)
      setSyncing(null)
      setNotice(report ? summarize(where, report) : `${where} · trusted`)
      setPlanTick((tick) => tick + 1)
      void refreshComposedMembership()
    } catch (error) {
      setSyncing(null)
      setNotice(`${where} · ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  // …and only then the code layer: a plugin lives in an ACTIVE version, and
  // the pass above is what makes a freshly seeded package active. Chained
  // rather than parallel for that ordering alone — `syncStores` returns at once
  // when there is nothing to sync (a test, `sync_on_start = false`).
  onMount(() => void syncStores().then(loadPlugins).then(refreshComposedMembership))

  // The screen is an interface, so the pointer over it is an arrow; the
  // composer asks for the beam back while the mouse is inside it
  // (`ui/pointer.ts`). Terminals default to a beam over the whole window, which
  // said "text to select" over the tab bar and every clickable row.
  onMount(() => {
    pointer("default")
    onCleanup(releasePointer)
  })

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
   * Dragging across the screen selects text, and letting go copies it.
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
      // A DRAG, and only a drag. OpenTUI 0.5.7 gave every selectable renderable
      // the terminal's click-repeat selection — a second click selects the word
      // under it (`behavior: "word"`), a third the line — and those arrive here
      // as finished selections like any other. Copying them would mean every
      // double click anywhere silently overwrites the clipboard, including the
      // double click the sessions list already spends on "open this in a tab of
      // its own": that gesture was putting a word from the row on the clipboard
      // and "copied N characters" over the notice saying what it had done.
      //
      // The alternative — opting each clickable row out with `selectable:
      // false` — is the same decision made again in every list that ever grows
      // a click, and the one that forgets is the one nobody notices. So the
      // rule stays where it was written: dragging selects, letting go copies.
      // A click-repeat still highlights, which is the terminal's own feedback;
      // it just does not reach for the clipboard on its own.
      if (selection && selection.behavior !== "cell") return
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

  onCleanup(() => {
    clearSshWorkflow()
    tabs.disposeAll()
  })

  /**
   * The tabs this screen had last time, read ONCE and before any effect writes
   * over them (§5.3b point 8).
   *
   * Captured at component construction rather than in `onMount`, because the
   * effect below writes the current tab list as soon as it runs and would
   * otherwise have replaced the record with "one tab" before anything read it.
   */
  const remembered_tabs = loadTuiState(props.statePath).tabs ?? []

  /**
   * Bring back the tabs BEYOND the first, each in its own directory.
   *
   * The first tab is whatever this launch decided it is (`--session`, else a
   * draft) — untouched, so the screen a person opens in one directory with one
   * conversation is the screen they have always opened. Only sessions come
   * back: a draft is nothing on disk, and one whose file has gone (a checkout
   * deleted, a drive unmounted) is skipped rather than opened into an error.
   *
   * Restoring does not step anything and creates nothing: `tabs.open` is the
   * same verb `/sessions` uses, and `created: false` means this process will
   * not prune those sessions when they close.
   */
  onMount(() => {
    let restored = 0
    for (const slot of remembered_tabs.slice(1)) {
      if (!slot.session) continue
      try {
        const where = openWorkspaceAt(slot.ws)
        if (!sessionExists(where, slot.session)) continue
        tabs.open(slot.session, { ws: where })
        restored += 1
        void enterWorkspace(where)
      } catch {
        // A remembered directory that will not open is one fewer tab, never a
        // screen that will not open.
      }
    }
    // Back to the tab this launch is about: restoring focuses each one it
    // opens, and the person asked for the first.
    if (restored > 0) tabs.select(0)
  })

  /**
   * …and write the record whenever the tabs change. A plain effect rather than
   * a save on exit: `Ctrl+C`, a killed terminal and a crash all end this
   * process without an exit path, and a record only written on a clean quit is
   * a record that is wrong exactly when it is needed.
   */
  createEffect(() => {
    rememberTabs(
      tabs.tabs().map((one) => ({ ws: one.ws.dir, ...(one.kind === "session" ? { session: one.id } : {}) })),
      props.statePath,
    )
  })

  /** One tip per launch, chosen here so re-rendering the screen cannot reroll it. */
  const tip = pickTip(props.style.glyphs)

  const spinnerFrame = () => props.style.spinner[spinnerTick() % props.style.spinner.length]!

  /**
   * What the line above the composer says. The rules are in
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
      syncing: syncing(),
    }),
  )

  createEffect(() => {
    const target = snapshot().usage
    if (!props.style.motion || !activity()?.moving) {
      setDisplayUsage({ ...target })
      return
    }
    spinnerTick()
    setDisplayUsage((current) => smoothUsageTotals(current, target))
  })

  // Every error OpenTUI swallows lands in `.nulya/tui-crash.log`
  // (`crashlog.ts`, BUGS.md #17) — the renderer registers process-level
  // handlers that reduce a fatal error to an invisible console line, and the
  // log is what turned the third freeze from a mystery into a stack trace.
  {
    const crashes = installCrashLog(props.ws.dir, renderer)
    // The reactive heartbeat: a signal written every second, an
    // effect that echoes it. When the echo goes stale the renderer is fine but
    // Solid is not — updates no longer reach the screen, which nothing
    // frame-level can see. The verdict goes to the crash log, and the console
    // overlay is opened DELIBERATELY: it is renderer-level, so it still draws,
    // and it is where OpenTUI cached the very error that broke the graph. A
    // dead UI showing its reason beats a dead UI pretending to work.
    const [beat, setBeat] = createSignal(0)
    let echoAt = Date.now()
    createEffect(() => {
      beat()
      echoAt = Date.now()
    })
    let verdictGiven = false
    let lastTick = Date.now()
    const beatTimer = setInterval(() => {
      const tickNow = Date.now()
      // An event loop that was itself starved (heavy load, a debugger paused
      // the process) proves nothing about the graph: rebase instead of judging
      // on a clock nobody was advancing.
      if (tickNow - lastTick > 3000) echoAt = tickNow
      lastTick = tickNow
      if (!verdictGiven && tickNow - echoAt >= reactive_stall_ms) {
        verdictGiven = true
        crashes.note(
          "heartbeat",
          new Error("reactive layer stalled: signal writes no longer reach effects; opening the console overlay"),
        )
        renderer.console.show()
      }
      try {
        setBeat((tick) => tick + 1)
      } catch (error) {
        crashes.note("heartbeat-write", error)
      }
    }, 1000)
    onCleanup(() => {
      clearInterval(beatTimer)
      crashes.dispose()
    })
  }

  /**
   * `Date.now()`, resampled on the animation tick rather than read during a
   * render. A render that reads the wall clock is not a function of its inputs
   * — it would show a different elapsed each repaint and never repaint on its
   * own — so the tick that moves the sweep is also what moves the clock.
   */
  const clockNow = () => (spinnerTick(), Date.now())

  /** The session a card names, if it names one — the sub-session link. */
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

  /**
   * Show the sessions list beside the transcript, or put it away.
   *
   * Three ways in, one verb: `/sidebar`, the key, and the handle on the status
   * line. Nothing here touches the focus — showing a list and going to it are
   * two gestures, and the one people do all day is the first.
   */
  const toggleSidebar = () => {
    const next = !sidebarWanted()
    setSidebarWanted(next)
    rememberSidebar({ open: next, ratio: sidebarShare() }, props.statePath)
    if (next && !sidebarFits()) {
      setNotice(`the sessions sidebar needs ${sidebar_min_width} columns · it comes back when there is room`)
    }
  }

  /**
   * Move the keyboard to a pane, and hand it back to the box if that pane does
   * not want it.
   *
   * The second half cannot be left to the effect above. Solid flushes effects
   * while the signal is still settling, and at that instant the composer's own
   * `disabled` effect has not yet made the textarea focusable again — so a
   * `focus()` from inside the flush is refused, and the box ends up enabled,
   * blank and not listening. Every OTHER way of leaving a pane already tells
   * the composer by hand (`closeOverlay`); `settleKeyboard`/`goToPane` are the
   * other path.
   */
  const settleKeyboard = () => {
    if (!overlay.active()) composer?.focus()
  }
  const goToPane = (pane: string) => {
    panes.focusOn(pane)
    settleKeyboard()
  }
  /**
   * A click landed in one of the FRONT TAB's panes.
   *
   * Both hops, in the order the mouse makes them: the app tree has to be
   * pointing at the portal for the inner focus to be the one that answers, and
   * when the sidebar is open the wrapper around the portal will bubble the very
   * same press into `goToPane` a moment later — which is the same assignment,
   * so the two cannot disagree.
   */
  const goToTabPane = (pane: string) => {
    panes.focusOn(panes.main())
    tabPanes().focusOn(pane)
    settleKeyboard()
  }
  /** Back to the pane this tab's screen is about, in both trees. */
  const goToMain = () => {
    panes.focusOn(panes.main())
    tabPanes().focusOn(tabPanes().main())
  }
  /**
   * Move the keyboard one pane in a direction, INNERMOST FIRST.
   *
   * A tiling window manager's rule for nested containers, and the only one that
   * composes without either tree learning about the other: try the tab's own
   * neighbours inside the portal's box, and fall out to the app tree only when
   * there is nothing that way in here. So `Ctrl+→` from the transcript reaches
   * the sub-agent beside it, and `Ctrl+←` from the sub-agent passes the
   * transcript on its way to the sidebar rather than jumping over it.
   */
  const moveKeyboard = (direction: FocusDirection) => {
    const inner = tabPanes()
    if (panes.surface() === tab_surface) {
      const before = inner.focus()
      inner.move(direction, portalRect())
      if (inner.focus() !== before) return settleKeyboard()
    }
    panes.move(direction, screenRect())
    settleKeyboard()
  }
  /**
   * How many panes are on screen at all, across both trees — the portal counted
   * once, as the tab tree it stands for. What decides whether `Ctrl+←/→/↑/↓`
   * mean anything, and therefore whether that layer claims them at all.
   */
  const paneCount = () => leaves(panes.tree().root).length + leaves(tabPanes().tree().root).length - 1

  /** `/sidebar <percent>`: drag the seam by saying where it should be. */
  const setSidebarPercent = (percent: number) => {
    const share = percent / 100
    setSidebarShare(share)
    setSidebarWanted(true)
    panes.apply((tree) => resizeSidebar(tree, share))
    rememberSidebar({ open: true, ratio: share }, props.statePath)
  }

  const openOverlay = (kind: OverlayKind) => {
    if (browse.active()) leaveBrowse()
    // A full-screen view is about the main pane, so that is where the keyboard
    // has to be for it to be answerable — F2 pressed with the keyboard in the
    // sidebar (or in a sub-agent pane) opens `/ext` in front of the
    // transcript, not beside it.
    goToMain()
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
   * `/provider` chose a provider: `/model`, landed on its first model. This
   * is the second step of "pick a provider, then its model" —
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
    // "Back to the transcript" includes bringing the keyboard back with it:
    // this is also how a click in the sidebar ends.
    goToMain()
    composer?.focus()
      // `/ext` may have moved a membership, pin, or activation while it was up,
      // and the draft card's tool face is read off those files plus the active
      // manifests for composed `surface:"auto"` tools.
    setPlanTick((tick) => tick + 1)
    void refreshComposedMembership()
  }

  /**
   * Take a directory as this tab's workspace (goals/tui-shell.md §5.3b).
   *
   * A DRAFT is re-pointed in place: it is nothing on disk, so its directory is
   * still a decision, and the next message is what freezes it. A tab that
   * already has a session gets a NEW tab instead — a session's file lives in
   * one directory, and moving the tab would be claiming the session moved with
   * it. Same rule, same reason, as switching model on a started session
   * (`startDraft`): what is frozen is frozen, and the honest way to work
   * somewhere else is somewhere else.
   *
   * The first tab into a directory is what runs that directory's start-up flow
   * (`enterWorkspace`): its trust question, its agent-definitions question and
   * its project store build, all of which used to happen once per launch.
   */
  const chooseWorkspace = (dir: string) => {
    const where = openWorkspaceAt(dir)
    closeOverlay()
    const here = tab()
    if (here.kind === "draft") tabs.retarget(here.key, where)
    else tabs.draft({ ws: where, ...(currentPick() ? { pick: currentPick()! } : {}) })
    setNotice(`${workspaceLabel(where.dir)} · ${where.dir} · your next message starts a session here`)
    void enterWorkspace(where)
  }

  /**
   * A tab of its own for that session, in ITS OWN directory (§5.3b).
   *
   * `where` defaults to this tab's workspace, which is what every caller that
   * names a session of the current conversation means (a delegation card's
   * link, a plugin's `openTab`). The sessions list passes the group's, because
   * across groups the id alone does not say which `.nulya/sessions/` it is in.
   */
  const openSession = (id: string, where: Workspace = ws(), created = false) => {
    tabs.open(id, { created, ws: where })
    closeOverlay()
    void enterWorkspace(where)
    setNotice(`opened ${id}`)
  }

  /**
   * Go to a session HERE: the tab in front becomes that session.
   *
   * The list's primary action, and the reason it needed a second verb at all.
   * `openSession` grows the tab strip by one every time, which is right when
   * somebody asked for a second window on something and wrong for the gesture
   * people make constantly — "show me that conversation". A browser tab does
   * not clone itself when you click a bookmark.
   *
   * `tabs.replace` is exactly this move and already existed: a session already
   * open is brought to the front (so the strip never grows for a switch), and
   * otherwise the front tab gives up its place. What it gives up is what
   * closing that tab would have given up — a draft is nothing on disk, and a
   * session this process created and nobody ever said anything in is removed
   * by the same `sessionPrune` (`state/tabs.ts`). Nothing running is
   * killed: a step is a kernel process with its own ledger, and leaving it is
   * leaving it, not stopping it.
   */
  const switchToSession = (id: string, where: Workspace = ws()) => {
    if (live()?.id === id && sameWorkspace(ws(), where)) return closeOverlay()
    tabs.replace(tabs.active().key, id, { ws: where })
    closeOverlay()
    void enterWorkspace(where)
  }

  /**
   * What a card's link does. One entry point, so clicking `↗ open …` on a
   * delegation card and pressing `Enter` on it in browse mode are the same move
   * and cannot drift; browse mode steps aside first, because the keyboard
   * belongs to the tab that just came to the front.
   */
  /**
   * Follow a delegation in a pane of the tab that made it.
   *
   * The default of the card's two routes, and the one that says what a
   * delegation IS: subordinate to this conversation. A pane rather than a tab
   * because the strip is horizontal and has no shape for "under" — and because
   * closing the conversation should close the window onto its delegation, which
   * a sibling tab could never express (`state/tabs.ts` releases them together).
   *
   * The direction is decided here and not remembered: at 100 columns and up
   * there is room to read two conversations side by side, and below it the
   * terminal's other axis is the one with room to spare.
   */
  const watchSession = (id: string, label?: string) => {
    if (browse.active()) leaveBrowse()
    const here = tab()
    // A draft has delegated nothing, so nothing can name a session of its own
    // here. Opening a tab is the honest fallback rather than a silent no-op.
    if (here.kind !== "session") return openSession(id, ws())
    // A full-screen view is in front of the very pane we are about to split;
    // this is the same "back to the transcript" the link's other route does.
    if (overlay.kind() !== null) closeOverlay()
    const already = here.subs().find((sub) => sub.id === id)
    if (already) {
      goToTabPane(already.pane)
      setNotice(`following ${label ?? id}`)
      return
    }
    const pane = nextPaneId()
    here.watch(pane, id, label)
    here.panes.apply((tree) =>
      openSubPane(tree, here.panes.main(), { direction: subSplitDirection(screen().width), id: pane }),
    )
    setNotice(`watching ${label ?? id} · Ctrl+arrow to go there · Esc there closes it`)
  }

  /** Stop watching: the pane goes, its follower is detached, the box comes back. */
  const closeSub = (pane: string) => {
    const here = tab()
    if (here.kind !== "session") return
    here.unwatch(pane)
    // `closePane` hands the focus to whatever takes the box, so the keyboard is
    // never left naming a pane that is gone — but the composer still has to be
    // told by hand, for the reason `goToPane` spells out.
    here.panes.apply((tree) => closeSubPane(tree, pane))
    settleKeyboard()
  }

  const navigate: Navigate = {
    delegationRecord: (id) => readDelegationRecord(ws(), id),
    openTasks: () => openOverlay("tasks"),
    watchSession: (id, label) => watchSession(id, label),
    openSession: (id) => {
      if (browse.active()) leaveBrowse()
      // A card's link names a session of THIS conversation — a delegation this
      // tab started — so it is in this tab's directory by construction.
      openSession(id, ws())
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

  /**
   * Whether that model is catalogued as accepting images (`[[models]]` with
   * `vision = true`) — the same question, against the same table, that the
   * kernel's gate asks when the turn is appended. An id the
   * catalog does not mention is a refusal there, so it is one here too.
   *
   * Null only when this launch has no catalog at all: the front end may repeat
   * the kernel's answer, never invent one it would not have given.
   */
  const visionHere = (): { model: string; accepted: boolean } | null => {
    const catalog = props.models
    const model = modelName()
    if (!catalog || model.length === 0) return null
    return { model, accepted: catalog.find((entry) => entry.id === model)?.vision ?? false }
  }

  /**
   * The model the front tab talks to: chosen on a draft, and on a session the
   * one IN FORCE — its header's, or whatever the last `model_rebind` moved it
   * to (`runningModel`, the single place that answers this). A frozen identity
   * is still frozen; there is simply a chain of freeze points now, and reading
   * only the header would leave this line naming a model that has stopped
   * answering.
   */
  const modelName = (): string => {
    const here = tab()
    if (here.kind === "draft") return modelOf(here.pick())
    const now = runningModel(snapshot())
    return now ? now.model || now.profile : ""
  }

  /**
   * What the next `session new` from this TUI would put on the model's face:
   * the merged config pins, this TUI's own pin list, and `surface:"auto"` tools
   * from packages composed into every session started here — all of it
   * filtered through the exec-target profile (`envProfile`): under
   * `--bare` the config's own pin list drops out entirely, and the env
   * profile's own `pins` list joins in.
   *
   * The composed entries are counted for display only. They are not passed as
   * `--pin`; the kernel derives them from the `--with` membership when the
   * session is created.
   */
  // A memo, because reading the session pins is a file read: it is asked for
  // once per frame by both the status line and the draft card, and it can only
  // change when something wrote that file — which is what `planTick` says.
  const plannedFaceTools = createMemo((): string[] => {
    planTick()
    const profile = envProfile(execEnv(props.statePath))
    const face = profile.bare ? [] : [...(props.pinnedTools ?? [])]
    for (const pin of sessionPins(props.statePath)) if (!face.includes(pin)) face.push(pin)
    for (const pin of profile.pins) if (!face.includes(pin)) face.push(pin)
    for (const id of composedWithTools()) if (!face.includes(id)) face.push(id)
    return face
  })

  /** The tool face this tab shows beside the builtin. */
  const faceSize = (): number => {
    const here = tab()
    if (here.kind === "draft") return plannedFaceTools().length
    return snapshot().header?.composition.native_tools.length ?? 0
  }

  /**
   * The packages whose SYSTEM PROMPT this tab is wearing.
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

  /**
   * Where this tab's `shell` commands run, when that is not this host
   *. Empty means the ordinary answer and the status line spends
   * no column on it.
   *
   * Two sources for one fact, and they are not interchangeable: a started
   * session's target is FROZEN in its header, so `/env` cannot move it and the
   * header is the only truthful answer; a draft has no header yet, so what it
   * shows is the pending choice — what its first message would freeze.
   */
  const runsIn = (): string => {
    // Tracked so `/env` (which writes `tui-state.json`, not a signal) shows up
    // on this row the moment it is typed rather than the next time `tab()`
    // happens to change for an unrelated reason (`setExecEnv` bumps this).
    planTick()
    const here = tab()
    if (here.kind === "draft") return execEnv(props.statePath)
    return snapshot().header?.environment ?? ""
  }

  /**
   * The directory the welcome screen's `cwd` row (and, once a session
   * exists, the same row read off its header) is actually about — this
   * machine's own `ws().dir` unless a `remote:` target is in force, in which
   * case it is the WORKSPACE that target's `--workspace` names, not the
   * directory this process happens to be running in — "the pair on the
   * welcome screen — where the files are, where the commands go" already
   * said this for `shell`, this is the other half.
   *
   * Two sources, same split `runsIn` already draws: a draft reads the pending
   * choice (`tui_state.ts`), a started session reads its FROZEN header — `/env`
   * cannot move either one after the fact.
   */
  const displayCwd = (): string => {
    planTick()
    const here = tab()
    if (here.kind === "draft") {
      const dir = execEnv(props.statePath).startsWith("remote:") ? execWorkspace(props.statePath) : ""
      return dir.length > 0 ? dir : ws().dir
    }
    const header = snapshot().header
    if (header && header.environment.startsWith("remote:") && header.remote_workspace.length > 0) {
      return header.remote_workspace
    }
    return ws().dir
  }

  /** What a draft tab's first message would freeze — the welcome screen's facts. */
  const plan = (): NextSession | undefined => {
    const here = draft()
    if (!here) return undefined
    const bring = here.bring()
    return {
      tools: plannedFaceTools(),
      ...(bring ? { bring: formatWithRef(bring) } : {}),
    }
  }

  /**
   * The front tab's context window, when a catalog names one — from the FROZEN
   * header, never from the picker's pending selection (a session's identity
   * does not move after creation, physics #2).
   *
   * The profile matters as much as the model id: the same id can mean two
   * different windows depending on who serves it — a ChatGPT subscription's
   * `gpt-5.6-sol` is not the public API's — so this reads `modelParamsFor` —
   * the one place that per-profile-catalog-first, global-`[[models]]`-fallback
   * lookup happens, also used by `/model`'s rows.
   */
  const contextWindow = (): number | null => {
    const now = runningModel(snapshot())
    const id = now?.model
    if (!now || !id) return null
    const profile = props.profiles?.find((p) => p.name === now.profile)
    if (!profile) return props.models?.find((m) => m.id === id)?.context_window ?? null
    return modelParamsFor(props.models ?? [], profile, id)?.context_window ?? null
  }

  /** What the front tab runs on, in the picker's terms. */
  const currentPick = (): ModelPick | null => {
    const here = tab()
    if (here.kind === "draft") {
      const pick = here.pick()
      return pick ? { ...pick, effort: here.effort() } : null
    }
    const now = runningModel(snapshot())
    if (!now) return null
    return { profile: now.profile, model: now.model || undefined, effort: here.effort() }
  }

  /**
   * What `/model` does with the row somebody pressed Enter on (BUGS.md #12,
   * goals/model-rebind.md).
   *
   * Two answers, because there are two things in front of a person. A DRAFT has
   * no session yet, so the pick is simply what its first message will freeze.
   * A session that already exists is MOVED: `session rebind` deposits a
   * `model_rebind` event and everything from the next step on is answered by
   * the new model, with this conversation's whole history intact.
   *
   * The effort dial rides along either way: it is a per-step generation option,
   * never frozen, so it takes hold on the tab in front of us with no ceremony.
   */
  const chooseModel = async (pick: ModelPick) => {
    const here = live()
    if (!here) return startDraft(pick)
    setRefusal(null)
    try {
      const moved = await sessionRebind(here.ws, here.id, { profile: pick.profile, ...(pick.model ? { model: pick.model } : {}) })
      here.setEffort(pick.effort)
      // The event is in the inbox, not yet in the ledger — the kernel drains it
      // at the next step boundary. Echoing it here is the same move a just-sent
      // user turn gets: the chips read the new model straight away, and
      // the announcement carries the kernel's own words about what the switch
      // costs until its `model_rebind` event arrives and replaces it.
      here.state.noteRebind(
        { profile: pick.profile, model: pick.model ?? modelOf(pick), provider: "" },
        moved.costs.join("\n"),
      )
      rememberModel(pick, props.statePath)
      closeOverlay()
      setGuide(null)
      setNotice(moved.said || `${here.id} · ${modelOf(pick)} from its next step`)
    } catch (error) {
      // Verbatim, and with room to be read: the kernel's three gates
      // (credential, vision, already-there) each answer with the config key or
      // the command that fixes it, and nothing here re-decides or re-words any
      // of them.
      closeOverlay()
      setRefusal(error instanceof CliError ? error.detail : error instanceof Error ? error.message : String(error))
      setNotice(error instanceof Error ? error.message : String(error))
    }
  }

  /**
   * Choose what the next session runs on, and remember it as the last pick.
   *
   * Nothing is created here. On a draft this only rewrites the draft — no
   * process, no file. A started session no longer comes through here from
   * `/model` (see `chooseModel`); `/new` and `/evolve` still do, and for them
   * "beside it, as a draft" is the whole point.
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
      // The new tab starts in the directory the front one works in (§5.3b): a
      // person who opened a second repository and pressed `+` meant another tab
      // THERE, not one back where the process happened to be launched.
      tabs.draft({
        ws: ws(),
        ...(chosen ? { pick: chosen } : {}),
        ...(bring ? { bring } : {}),
        ...(chosen?.effort ? { effort: chosen.effort } : {}),
      })
    }
    closeOverlay()
    setGuide(null)
    const what = bring ? ` · with ${formatWithRef(bring)}` : ""
    const who = chosen ? `${modelOf(chosen)}` : "the default model"
    setNotice(`next session · ${who}${what} · starts when you send a message`)
    if (remember && chosen) rememberModel(chosen, props.statePath)
  }

  /**
   * Replace the front tab with a fresh draft, IN PLACE (`/clear`) — the
   * opposite move from `startDraft`, which leaves the front tab alone and
   * opens another beside it. The old tab's session, if it had one, is not
   * touched: `tabs.clear` only releases this tab's own attachment (and
   * un-creates the session behind it if this process made it and nothing was
   * ever said — the same rule closing a tab follows), the file stays on disk.
   *
   * `pick` and `remember` mean what they mean in `startDraft`: named on the
   * command line, a one-off; otherwise the last remembered pick.
   */
  const startClear = (pick?: ModelPick, remember = pick !== undefined) => {
    const chosen = pick ?? loadTuiState(props.statePath).model
    tabs.clear(tab().key, {
      ...(chosen ? { pick: chosen } : {}),
      ...(chosen?.effort ? { effort: chosen.effort } : {}),
    })
    closeOverlay()
    setGuide(null)
    const who = chosen ? `${modelOf(chosen)}` : "the default model"
    setNotice(`new draft here · ${who} · starts when you send a message`)
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
    // Before the early return: a refusal's lifetime is "until the next
    // attempt", and on a started tab the next attempt is saying something —
    // a refused `/model` must not stay on screen through the rest of the
    // conversation.
    setRefusal(null)
    if (here.kind === "session") return here
    try {
      const extras = await sessionExtras(here.ws)
      const tab = await tabs.materialize(here, extras)
      setPlanTick((tick) => tick + 1)
      // A directory somebody actually started a session in — the one event
      // worth remembering across runs (`state/recents.ts`). Browsing to a
      // place is not working in it, so this is here and not in `chooseWorkspace`.
      rememberRecent(here.ws.dir)
      return tab
    } catch (error) {
      setRefusal(error instanceof CliError ? error.detail : error instanceof Error ? error.message : String(error))
      setNotice(error instanceof Error ? error.message : String(error))
      return null
    }
  }

  /**
   * Everything the SCREEN adds to a top-level `session new`: one `--with` for
   * each id the exec-target profile brings in — `[extensions] session_with`
   * on `local` / `wsl`, or whatever `tui.toml`'s `[env.<kind>]` says instead
   * (`envProfile`). `/env`'s pending choice decides which profile this
   * is, and it is read once, right here, at the same moment as everything
   * else on this list — a choice made after this line is a choice about the
   * NEXT session, which is exactly what `/env` says it is.
   *
   * One list. A package that belongs in every session says so in its
   * manifest (`apply: "auto"`), and the kernel composes it at `session new`
   * whatever is driving; what is left here is the other direction, composing a
   * package that did NOT ask, which is this front end's line to write.
   *
   * `surface:"auto"` tools do not appear here as pins: the kernel derives those
   * native tool slots from the membership itself, which is how configured
   * session packages reach the model — one flag each. A
   * member's `surface:"manual"` tools DO need a pin in the same argv, since
   * membership is not a tool face; that is `SessionMember.pins`, read off the
   * version being composed, so a package that moves a tool between surfaces is
   * followed without an edit here. The profile's own `pins` list joins
   * the same argv for the same reason — an extra native slot this env's
   * `--with` members did not ask for on their own.
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
  const sessionExtras = async (
    target: Workspace,
  ): Promise<{
    with?: string[]
    pin?: string[]
    prompt?: string[]
    execEnv?: string
    workspace?: string
    sshPassword?: Uint8Array
    bare?: boolean
  }> => {
    const where = execEnv(props.statePath)
    const profile = envProfile(where)
    const withRefs: string[] = []
    const pins: string[] = [...profile.pins]
    const missing: string[] = []
    for (const id of profile.with) {
      const member = await sessionMemberOnce(target, id)
      if (!member) {
        missing.push(id)
        continue
      }
      withRefs.push(formatWithRef({ id: member.id, version: member.version }))
      for (const pin of member.pins) if (!pins.includes(pin)) pins.push(pin)
    }
    // The renderers: resolved by the same machinery, composed by none of it —
    // each writes a file and the FILE is what the session gets
    // (`sessionprompt.ts`). Deliberately last, so whatever they report is read
    // at the latest possible moment before `session new` freezes it.
    const prompts: string[] = []
    const broke: string[] = []
    // …and not at all in the home workspace (§5.3b point 5). What these
    // renderers write is a picture of a PROJECT — its layout, its instruction
    // files, this branch, this working tree — and `no project` is the answer
    // "there is no project": every one of those paragraphs would be an empty
    // section, paid for on every step of the session because it rides in the
    // cached prefix. The renderer is not asked rather than asked and ignored:
    // there is nothing here for it to be right about.
    const grounded = !isHomeWorkspaceDir(target.dir)
    for (const id of grounded ? profile.session_prompts : []) {
      const member = await sessionMemberOnce(target, id)
      if (!member) {
        missing.push(id)
        continue
      }
      try {
        prompts.push(await renderSessionPrompt(target, { id: member.id, version: member.version }))
      } catch (error) {
        // Kept apart from `missing`, because they are different failures with
        // different fixes: a package that would not resolve is answered by
        // `/ext`, while one whose `render` failed has its own reason, and
        // pointing at `/ext` for that one sends somebody to a screen that has
        // nothing to say about it.
        broke.push(error instanceof Error ? error.message : String(error))
      }
    }
    // Both kinds, when both happened. An `else if` here would have undone the
    // split above: one unresolvable package would swallow a second package's
    // real diagnostic, which is the thing keeping them apart was for.
    const notices = missing.length > 0
      ? [`${missing.join(" & ")} not composed in · /ext for what it said`, ...broke]
      : broke
    if (notices.length > 0) setNotice(notices.join(" · "))
    // `--workspace` only ever makes sense beside a `remote:` target (DESIGN
    // §8.2) — read here rather than passed down from wherever `where` was
    // chosen, because the two are frozen in the SAME call to `rememberExecEnv`
    // and travel together in `tui-state.json` for exactly this reason.
    const workspace = where.startsWith("remote:") ? execWorkspace(props.statePath) : ""
    const password = freshSshPassword(where)
    return {
      ...(withRefs.length > 0 ? { with: withRefs } : {}),
      ...(pins.length > 0 ? { pin: pins } : {}),
      ...(prompts.length > 0 ? { prompt: prompts } : {}),
      ...(where.length > 0 ? { execEnv: where } : {}),
      ...(workspace.length > 0 ? { workspace } : {}),
      ...(password ? { sshPassword: password } : {}),
      ...(profile.bare ? { bare: true } : {}),
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
   * The `/with`, `/agent` and `/env` pickers are in here too, for a duller
   * reason: they are dialogs in the same three rows, and two of them drawn at
   * once is just a mess. Nothing is being protected there.
   */
  const dialogUp = (): boolean =>
    passwordRequest() !== null ||
    pending() !== null ||
    checkout() !== null ||
    pickerUp() ||
    overlay.kind() === "provider"

  /** The front tab's session, in the read-only shape the contract projects. */
  const pluginSession = () => {
    const here = live()
    if (!here) return null
    const now = runningModel(here.state.snapshot)
    const activity = here.attach.status()
    const pluginStatus: "idle" | "stepping" | "canceling" =
      activity === "stepping" || activity === "canceling" ? activity : "idle"
    return {
      id: here.id,
      model: now?.model || now?.profile || "",
      members: here.contributions().map((c) => ({ id: c.id, version: c.version, tools: [...c.tools] })),
      role: here.attach.role(),
      status: pluginStatus,
      activity,
      permissionMode: mode(),
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
    openTab: (sessionId, options) => {
      tabs.open(sessionId, { driven: options?.wakePending ?? false })
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

  // Plugins are process-wide while their view state is session-scoped. Tell
  // them when the front tab's identity changes so a queued surface can return.
  createEffect(() => plugins.observeSession(pluginSession()))

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

  // ── The gate ────────────────────────────────────────────────

  /** The tab a gate request belongs to — the session being stepped, not the one in front. */
  const tabOf = (session: string): SessionTab | null =>
    (tabs.tabs().find((t) => t.kind === "session" && t.id === session) as SessionTab | undefined) ?? null

  /**
   * A member package's `contributes.policy` narrowing, pooled (tui-plugin
   * D2/D3): which members, if any, claimed `readonly: true`. Read from the
   * frozen composition — for a SessionTab that is already `contributions()`,
   * populated before the first step can run (`state/tabs.ts` `hydrate`/`ready`),
   * so there is no race to guard against here.
   *
   * It reaches the gate as the CEILING below, never as extra rows in the
   * approval tables: a package asks for one thing now, and that one thing is
   * judged before any table is read.
   */
  const compositionPolicy = (asked: SessionTab | null) => poolPolicy(asked?.contributions() ?? [])

  const judgeNow = (request: GateRequest, asked: SessionTab | null) =>
    judgeCall(request, {
      mode: mode(),
      rules: props.style.settings.approvals,
      always: always(),
    })

  const decideNow = (request: GateRequest, asked: SessionTab | null) => judgeNow(request, asked).decision

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
   * Answer one gate request (`nulya session step --gate`).
   *
   * Rules and mode decide first (`approvals.ts`); only what neither settles
   * reaches a person, above the composer (`ui/ApprovalPanel.tsx`). The kernel is
   * blocked on this promise, which is exactly why it is safe to wait: the
   * model's connection closed before the batch began.
   */
  const approve = (request: GateRequest, session: string): Promise<GateVerdict> => {
    const asked = tabOf(session)
    // A read-only agent's ceiling, before every table: the whole
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
    const judged = judgeNow(request, asked)
    const verdict = judged.decision
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
    if (verdict === "allow") {
      // The one layer that owes an explanation: in `ask` mode a call went
      // through without a question, and the card is where that is said.
      if (judged.via === "readonly-command") asked?.state.markAutoAllowed(request.call_id)
      return Promise.resolve<GateVerdict>({ allow: true })
    }
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
   * (`approvalnote.ts`).
   *
   * The kernel's gate carries a note on exactly one of its two answers: `deny
   * <note>` becomes that call's marker result. A note on a YES has
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
   * It says NOTHING afterwards. The chip on the status line already shows
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
   *. It used to be a toggle, which is the one gesture that
   * cannot say what the other side is.
   */
  const openModePicker = () => {
    setModeChoice(initialChoice(mode()))
    setModePicker(true)
    setNotice(null)
  }

  const closeModePicker = () => setModePicker(false)

  /**
   * The chip's click: open the picker, and close it again if it is already up.
   *
   * The same gesture on the same spot goes both ways everywhere else on this
   * screen — every overlay opens and closes on its own key and on a second
   * click (`openOverlay`), a fold opens and closes on its head row. A dialog
   * that can only be opened by the thing that opened it is the one place where
   * the way in is not the way out.
   */
  const toggleModePicker = () => (modePicker() ? closeModePicker() : openModePicker())

  /** `/context` and a click on the ring: the same gesture both ways. */
  const toggleContextPanel = () => setContextPanel((up) => !up)

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
        !pickerUp() &&
        checkout() === null &&
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
   * approval dialog does: a list you choose from is not a list you can
   * choose from if `j` goes into the composer behind it.
   */
  createEffect(() => {
    if (pickerUp() || checkout() !== null) composer?.blur()
    else if (!pending() && !overlay.active() && !browse.active() && !plugins.panel()) composer?.focus()
  })

  /**
   * A plugin panel takes the keyboard the same way, applied to a surface this
   * front end did not write: a box that still blinks says "type here", and
   * what is typed there would be eaten by the panel anyway.
   */
  createEffect(() => {
    if (plugins.panel()) composer?.blur()
    else if (!pending() && !overlay.active() && !browse.active() && !pickerUp()) {
      composer?.focus()
    }
  })

  /**
   * The keyboard moved INTO a pane, or back out of it.
   *
   * Until there was a second pane, every way of putting the keyboard in one
   * went through `openOverlay`, which blurred the composer on the spot. Focus
   * can now move on its own — Ctrl+←/→, a click in the sidebar — so the rule
   * lives where the fact does: while a focused pane claims the keyboard, the
   * box must stop saying "type here", and when it stops, the box gets it
   * back if nothing else has taken it meanwhile.
   */
  createEffect(() => {
    if (overlay.active()) composer?.blur()
    else if (!pending() && !browse.active() && !pickerUp() && !plugins.panel()) {
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
   * takes the note, so none of them needs to be "deny with a reason" as a
   * separate answer.
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

  /** A step just ended: clean up any approval request that outlived it. */
  createEffect(() => {
    const now = status()
    if (now !== "idle") return
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
  })

  // `/evolve` used to live here, as the one command this front end special-cased
  // into a build: it rebuilt the shipped evolution draft and wore the
  // version it produced. It is now the evolution package's OWN declaration —
  // `contributes.commands` with `{with: true}` — so it arrives through the same
  // chain as `/ask` and `/plan` (`runPackageCommand`), and this file has stopped
  // knowing one package's name.

  // ── `/agent` ───────────────────────────────────────────────

  /**
   * The definitions ONE DIRECTORY holds — through the package, which is the one
   * reader (`agents.ts`). Asked again at every `/agent` rather than watched: a
   * definition is a file somebody edits in another window, and the moment that
   * matters is the moment one is about to be used.
   *
   * `where` is asked for and never read off the screen, and the answer is
   * returned rather than published. Building the package can take a whole
   * toolchain run on a cold machine, and a person is free to switch tabs while
   * it does: a version resolved for directory A, a listing taken from whichever
   * tab is in front when it lands, and a trust answer looked up in a third are
   * three different directories agreeing to start a system prompt. One
   * parameter, threaded from the tab that asked to the render that ends it, is
   * what makes them one directory.
   */
  const agentsIn = async (
    where: Workspace,
  ): Promise<{ defs: readonly AgentEntry[]; warnings: readonly string[] }> => {
    const pkg = await agentPackage(where)
    if (!pkg) return { defs: [], warnings: [] }
    try {
      const found = await listAgents(where, pkg)
      return { defs: usableAgents(found), warnings: found.flatMap((entry) => entry.warnings) }
    } catch {
      // No listing is "none known"; the sentence a caller needs comes from
      // whichever command it was about to run. Emphatically NOT the last
      // listing taken: that one may be another checkout's.
      return { defs: [], warnings: [] }
    }
  }

  // Deliberately NOT on mount: reading the definitions means building the
  // package, which is a compiled build, and a compiled build on the way in
  // does not belong on the critical path. It happens when
  // `/agent` is used, and — in the background, once — when the first session is
  // composed, exactly as any compiled session package does.

  /**
   * Start a delegation: build the persona, open a tab on a session wearing it,
   * and send the task.
   *
   * Every part of it is something this front end already does — `session new
   * --prompt` a file, `--with` the packages its pins imply (`/evolve`), `--pin`
   * a tool face, `--max-steps` a run (the driver's own option) — which is
   * the point: a sub-agent is a `session new` with a particular set of arguments,
   * and there is nothing here the kernel had to grow.
   *
   * A visible tab rather than a hidden run, because a delegation that goes wrong
   * is a delegation somebody has to be able to watch, cancel and read afterwards.
   *
   * ONE DIRECTORY runs through all of it, `draft.ws`, and nothing here reads
   * `ws()`. `entry` was listed in that directory, its trust answer is that
   * directory's, the package is built there and the definition is rendered
   * there. Mixing them is not a cosmetic slip: `entry.layer` is what the trust
   * gate below judges, so a `user`-layer row listed in one checkout would let
   * `renderAgent` load a `workspace`-layer definition of the same name out of
   * another — the gate answering about a file it never saw.
   */
  const startAgent = async (entry: AgentEntry, task: string, draft: DraftTab): Promise<SessionTab | null> => {
    const where = draft.ws
    // This path IS the nulya runner, hand-driven: a tab needs a local session
    // to step. A persona on another harness has no such session — opening one
    // anyway would run it on a harness its definition did not name (the very
    // thing defs.zig refuses a whole definition over). Delegating to it is the
    // model's `agent` tool's job, not a tab's (goals/agent-runner.md D1).
    if (entry.runner !== "nulya") {
      tabs.close(draft.key)
      setNotice(`'${entry.name}' runs on '${entry.runner}', which a tab cannot drive · delegate to it from a conversation instead`)
      return null
    }
    // Only a directory that has actually been ANSWERED for may start what
    // arrived in it: a definition is a system prompt, and materialising the tab
    // builds into that checkout's extension store. "Not answered
    // yet" is its own refusal rather than a yes — the question may be on screen
    // this very second, and starting the persona would be answering it.
    const gate = agentStart(entry.layer, agentsTrustIn(where))
    if (gate !== "allow") {
      tabs.close(draft.key)
      setNotice(
        gate === "denied"
          ? `'${entry.name}' came with this checkout and was not trusted · its prompt would enter a session here · answer the question again by clearing asked_agents in tui-state.json`
          : `'${entry.name}' came with this checkout and ${workspaceLabel(where.dir)} has not been answered for yet · its prompt would enter a session here · answer that question first`,
      )
      return null
    }
    const inherited = draft.pick()
    setNotice(`agent ${entry.name} · rendering its prompt…`)
    const pkg = await agentPackage(where)
    if (!pkg) {
      setNotice("the agent package could not be built here · /ext for what it said")
      return null
    }
    let m: RenderedAgent
    try {
      // The package renders the definition and checks that the packages its
      // pins name can be brought in — one implementation of both, and the same
      // one the model reaches through the `agent` tool.
      m = await renderAgent(where, pkg, entry.name)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
      return null
    }
    // The parent's model unless the definition names one. The draft is already
    // visible; refine its inherited choice in place once rendering answers.
    const pick =
      agentPick(m) ??
      (inherited ? { profile: inherited.profile, ...(inherited.model ? { model: inherited.model } : {}) } : undefined)
    if (pick) draft.setPick(pick)
    try {
      const child = await tabs.materialize(draft, {
        // The persona rides as BYTES the header freezes: nothing is
        // installed, so `/ext` gains nothing and no `ext prune` can take this
        // session's own identity text away from its resume.
        prompt: [m.prompt],
        // Only the `agent` package rides as `--with`, and only for a persona
        // that names somebody to pass work to: everything else is a leaf, and a
        // delegated session that cannot delegate simply does not carry the tool.
        // The persona's OWN pins bring their packages in by themselves — that
        // implication is the kernel's, not a list assembled here.
        //
        // No pin goes with that `--with`: the `agent` tool is `surface: "auto"`,
        // so membership already is its tool face, and a pin naming it would be
        // refused (`PinToolNotPinnable`).
        ...(m.agents.length > 0 ? { with: [formatWithRef(pkg)] } : {}),
        ...(m.pins.length > 0 ? { pin: m.pins } : {}),
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
    const { defs, warnings } = await agentsIn(ws())
    setAgentDefs(defs)
    setAgentWarnings(warnings)
    setAgentChoice(0)
    setAgentPicker(true)
    const skipped = warnings.length
    setNotice(
      defs.length === 0
        ? "no agent definitions yet"
        : skipped > 0
          ? `${defs.length} agent${defs.length === 1 ? "" : "s"} · ${skipped} file${skipped === 1 ? "" : "s"} skipped: ${warnings[0]}`
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
    if (task.trim().length === 0) {
      const { defs } = await agentsIn(ws())
      const def = defs.find((entry) => entry.name === name)
      setNotice(
        def
          ? `/agent ${def.name} <task> · it starts a session of its own and sees nothing of this one, so say the whole task`
          : defs.length === 0
            ? `no agent '${name}' · no definitions in .nulya/agents or ~/.nulya/agents`
            : `no agent '${name}' · ${defs.map((entry) => entry.name).join(" ")}`,
      )
      return
    }

    // A real task gets its destination immediately, before package discovery,
    // rendering or `session new`. If discovery later refuses the name, remove
    // only this untouched draft and return to the tab the user came from.
    const inherited = currentPick()
    const waiting = tabs.draft({ ws: ws(), ...(inherited ? { pick: inherited } : {}) })
    // …and from here on, THAT tab's directory is the only one anybody asks
    // about. `waiting.ws` is fixed; `ws()` is not, and the awaits below are
    // long enough (a first build of the `agent` package is a toolchain run) for
    // somebody to switch tabs inside one.
    const target = waiting.ws
    setNotice(`agent ${name} · loading its definition…`)
    const { defs } = await agentsIn(target)
    const def = defs.find((entry) => entry.name === name)
    if (!def) {
      tabs.close(waiting.key)
      setNotice(
        defs.length === 0
          ? `no agent '${name}' · no definitions in .nulya/agents or ~/.nulya/agents`
          : `no agent '${name}' · ${defs.map((entry) => entry.name).join(" ")}`,
      )
      return
    }
    void startAgent(def, task.trim(), waiting)
  }

  /**
   * The package command table, resolved: built-ins can never be shadowed
   * (D8), and among the rest the first package `/ext list` names for a given
   * name wins — the loser is reported, not silently dropped (`packageCommands.ts`
   * `resolve`). Recomputed on every read rather than cached again: the table
   * itself is already cached (`packageCmds`), and this is a pure fold over it.
   */
  const resolvedPackageCommands = () => resolvePackageCommands(packageCmds().entries(), builtin_names)

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
   * last read), and `skill <ref>` is `skillTurn` with the ref standing
   * in for whatever the person would otherwise have typed after `/`.
   *
   * `with` alone is like a plugin command: it does not stop at wearing. Text typed
   * after the command name is a person's own words and wins; with none, the
   * package's own default (`action.prompt`, `manifest.Action.withPrompt`) is
   * sent instead, if it wrote one. Neither present is the original shape —
   * wear and wait for the person to say something, exactly as before.
   */
  const runPackageCommand = async (raw: string): Promise<boolean> => {
    const { name, args } = splitSlash(raw)
    const row = resolvedPackageCommands().winners.find((entry) => entry.name === name)
    if (!row) return false
    // An older spelling this build still reads (the string form, or the
    // `"wear"` verb) is folded below; warned once per dispatch so the
    // package's own author sees it.
    const stale = deprecatedActionNote(row.action)
    if (stale) console.warn(`${row.id}: command '/${row.name}' — ${stale}`)
    const action = parseAction(row.action)
    switch (action.kind) {
      case "with": {
        startDraft(undefined, false, { id: row.id })
        const opening = args.length > 0 ? args : action.prompt
        if (!opening) return true
        const here = await ensureSession()
        if (!here) {
          composer?.restore(raw)
          return true
        }
        await here.attach.send(opening)
        return true
      }
      case "run": {
        const version = await activeVersionOf(ws(), row.id)
        if (!version) {
          setNotice(`${row.id} has no active version · run \`nulya ext build\` then \`nulya ext activate\` first`)
          return true
        }
        const result = await extRun(ws(), `${row.id}@${version}`, action.tool, runArgs(args))
        const said = (result.stdout.trim() || result.stderr.trim() || `exit ${result.code}`).split("\n")[0]
        setNotice(`${row.id} ${action.tool} · ${said}`)
        return true
      }
      case "skill": {
        try {
          const turn = await skillTurn(ws(), skills().entries(), `/${action.ref} ${args}`.trim())
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
   *. The two earlier names both said less than the flag does —
   * `/mode` collided with the permission mode, and `/as` read the general
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
   * composer.
   *
   * Derived from the store and nothing else: a package with a `current` and a
   * SYSTEM PROMPT. That is what makes wearing one a decision worth a dialog —
   * it changes what this session IS, and it is paid for on every step.
   *
   * The filter used to also ask the manifest whether the package had declared
   * itself opt-in, and skip the ones that had not, because those were already
   * in every session and a row offering one would offer a no-op. Nothing is
   * automatically in every session now, so the question has no
   * answer to ask for and every mode belongs on this list.
   */
  const openWithPicker = async () => {
    let listed: Wearable[] = []
    try {
      listed = (await listExtensions(ws()))
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
   * Bare `/env`, the `⇥` chip and the welcome screen's `shell` row.
   *
   * The list is what this machine answers (`state/targets.ts`), never a pair of
   * words written here — and it is probed on every open rather than cached,
   * because a distribution installed since the TUI started is exactly the case
   * where somebody goes looking for this dialog.
   *
   * The cursor opens on the target in force, so the first thing the dialog says
   * is where things stand — which is what bare `/env` used to print as a notice.
   */
  const openEnvPicker = async () => {
    const now = execEnv(props.statePath)
    let listed: ExecChoice[] = []
    try {
      listed = withCurrent(await execChoices(), now)
    } catch {
      // A probe that throws is a shorter list, never a screen that failed to
      // open: `local` and the typing row are always an answer.
      listed = withCurrent([], now)
    }
    setEnvTargets(listed)
    const at = listed.findIndex((one) => one.spec === (now || "local"))
    setEnvChoice(at >= 0 ? at : 0)
    setEnvPicker(true)
  }

  const closeEnvPicker = () => setEnvPicker(false)

  /**
   * Taking a row applies it — except the last one, which is not a target but
   * the way out of a list that cannot be complete: it writes the command into
   * the composer, the same move the bare `/agent` picker makes with a name.
   * Running `/env` bare there would CLEAR the target, which is the one thing a
   * person on this dialog cannot have meant.
   *
   * A `remote:` row is not applied on the spot: choosing THAT target is
   * only half a decision — the workspace, the directory this machine's
   * `--workspace` will freeze in, is the other half — so it hands off to the
   * directory browser instead of calling `setExecEnv` directly.
   */
  const takeEnvChoice = () => {
    const one = envTargets()[envChoice()]
    setEnvPicker(false)
    if (!one) {
      composer?.restore("/env ")
      return
    }
    if (one.spec.startsWith("remote:")) {
      void beginRemoteBrowse(one.spec)
      return
    }
    setExecEnv(one.spec)
  }

  /**
   * The first half of the remote flow's second half: open a channel to
   * confirm `spec` is reachable, then open the browser there
   *. A check that fails is shown exactly as it
   * came back and the browser never opens — a directory listing over a
   * channel that just refused would be a screen of round trips that can only
   * fail the same way again.
   *
   * The starting point is whatever this front end remembered for `spec` last
   * time (`tui_state.ts`'s `remote_cwd`), or the agent's own home when there
   * is nothing remembered yet — `remote check`'s `home`, falling back to its
   * `cwd` when the far side has no `$HOME` to report.
   */
  const beginRemoteBrowse = async (spec: string) => {
    const owner = tab().key
    if (sshPassword()?.spec !== spec) clearSshWorkflow()
    setRemoteFailure(null)
    setNotice(`reaching ${spec}…`)
    let hello: Awaited<ReturnType<typeof remoteCheck>>
    try {
      hello = await remoteCheck(ws(), spec, undefined, freshSshPassword(spec))
    } catch (error) {
      const detail = error instanceof CliError ? error.detail : error instanceof Error ? error.message : String(error)
      setRemoteFailure({ tab: owner, detail })
      if (spec.startsWith("remote:ssh:") && /Permission denied|authentication failed/i.test(detail)) {
        clearSshPassword()
        replacePasswordRequest({ spec, bytes: new Uint8Array() })
        setNotice(`password required for ${spec}`)
      } else {
        setNotice(error instanceof Error ? error.message : String(error))
      }
      return
    }
    replacePasswordRequest(null)
    const home = hello.home.length > 0 ? hello.home : hello.cwd
    setRemoteBrowse({ spec, start: remoteCwd(spec, props.statePath) ?? home, home })
    setNotice(null)
    openOverlay("envdir")
  }

  const appendPasswordBytes = (incoming: Uint8Array) => {
    try {
      const request = passwordRequest()
      if (!request || incoming.length === 0) return
      const clean = incoming.filter((byte) => byte !== 10 && byte !== 13)
      try {
        if (clean.length === 0) return
        const next = new Uint8Array(Math.min(4096, request.bytes.length + clean.length))
        next.set(request.bytes.subarray(0, next.length))
        next.set(clean.subarray(0, next.length - request.bytes.length), request.bytes.length)
        replacePasswordRequest({ spec: request.spec, bytes: next })
      } finally {
        clean.fill(0)
      }
    } finally {
      incoming.fill(0)
    }
  }

  const deletePasswordByte = () => {
    const request = passwordRequest()
    if (!request || request.bytes.length === 0) return
    let end = request.bytes.length - 1
    while (end > 0 && (request.bytes[end]! & 0xc0) === 0x80) end--
    replacePasswordRequest({ spec: request.spec, bytes: request.bytes.slice(0, end) })
  }

  const submitSshPassword = () => {
    const request = passwordRequest()
    if (!request || request.bytes.length === 0) return
    const held = request.bytes.slice()
    replacePasswordRequest(null)
    clearSshPassword()
    setSshPassword({ spec: request.spec, bytes: held })
    void beginRemoteBrowse(request.spec)
  }

  const cancelSshPassword = () => {
    clearSshWorkflow()
    setRemoteFailure(null)
    setNotice("SSH password entry canceled")
  }

  /**
   * A directory was chosen on the pending remote target: freeze the pair
   * together (`rememberExecEnv`'s own rule — a spec and its workspace travel
   * as one) and remember it as that spec's own starting point for next time
   * (`rememberRemoteCwd`).
   */
  const applyRemoteWorkspace = (dir: string) => {
    const at = remoteBrowse()
    if (!at) return
    rememberRemoteCwd(at.spec, dir, props.statePath)
    rememberExecEnv(at.spec, props.statePath, dir)
    setRemoteBrowse(null)
    closeOverlay()
    setNotice(`next session's shell and workspace run on ${at.spec} · ${dir}`)
    // Same bump `setExecEnv` makes: the tool-face count and the `⇥` chip both
    // read `tui-state.json` through functions Solid cannot see as reactive.
    setPlanTick((tick) => tick + 1)
    void refreshComposedMembership()
  }

  /**
   * `/outcome <verdict> [note]` — how this session turned out.
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
      await sessionOutcome(here.ws, here.id, word, note)
      setSettled([...settled(), here.id])
      setNotice(`${here.id}: ${word}${note ? ` · ${note}` : ""}`)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
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
   * `/env [<spec>]`: where the shell commands of the sessions this TUI starts
   * from now on will run.
   *
   * Deliberately NOT a change to the tab in front of you: the target is frozen
   * in a session's header, exactly like its model identity, because a
   * transcript only means something against the machine that produced it. So
   * the answer is always about the NEXT session, and the sentence says so.
   *
   * No argument opens the picker. It used to print a notice instead, on
   * the reasoning that the useful set is not enumerable — an ssh destination is
   * whatever that person's `ssh_config` calls a host, and the distributions on
   * this machine are "a `wsl -l` away". Both halves of that sentence name a
   * source, and `state/targets.ts` asks them: a list built from `wsl -l` and
   * `~/.ssh/config` reports rather than pretends, and the row that hands the
   * typing back is what keeps it from claiming to be everything.
   *
   * The spelling is not checked here. `session new` refuses a bad one with the
   * vocabulary in the message, and that refusal already reaches the screen
   * (`ensureSession`) — checking twice would be two answers to one question.
   */
  const setExecEnv = (raw: string | undefined) => {
    setRemoteFailure(null)
    if (raw === undefined) {
      void openEnvPicker()
      return
    }
    clearSshWorkflow()
    rememberExecEnv(raw, props.statePath)
    const now = execEnv(props.statePath)
    setNotice(
      now.length > 0
        ? `next session's shell runs in ${now} · extensions, tasks and the store stay on this host`
        : "next session's shell runs on this host",
    )
    // The tool-face count and the `⇥` chip both read `tui-state.json` through
    // functions Solid cannot see as reactive (a file, not a signal) — `/env`
    // changed what the NEXT session composes, so this
    // is the same "something wrote that file" bump `healStandingPins` uses.
    setPlanTick((tick) => tick + 1)
    void refreshComposedMembership()
  }

  /**
   * `ask` is only for the deliberate `/quit`: a session that did work and was
   * never judged leaves a hole in the slow loop — no verdict means `unknown`,
   * which is not failure but is not knowledge either — and the
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
    //: a task is a detached process with a supervisor of its own,
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
    releasePointer()
    renderer.destroy()
    process.exit(0)
  }

  const runCommand = (raw: string): boolean => {
    if (!raw.startsWith("/")) return false
    const words = raw.trim().split(/\s+/)
    const command = words[0]
    /** Everything after the command word, verbatim — a note keeps its spacing. */
    const rest = raw.slice(raw.indexOf(command!) + command!.length).trim()
    // `/exit` is the word other harnesses use for this, kept for the same
    // reason `/resume` is (commands.ts): a muscle-memory `/exit` that fell
    // through would be offered to the skill catalog and then sent to the model
    // verbatim, which is the worst possible answer to "leave".
    if (command === "/quit" || command === "/exit") {
      quit(true)
      return true
    }
    if (command === "/outcome") {
      void judge(words[1], rest.slice(words[1]?.length ?? 0).trim())
      return true
    }
    if (command === "/mode") {
      const word = words[1]
      // Bare `/mode` is the picker, not a flip: the two modes and what
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
    if (command === "/context") {
      toggleContextPanel()
      return true
    }
    // Collapse only. The other direction — one key that opens everything —
    // was a key: a screenful of every tool body at once is not a view of
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
      if (!sessionExists(ws(), id)) {
        setNotice(`no session '${id}' in ${sessions_dir} · ${command} with no id lists them`)
        return true
      }
      // The named form of what `Enter` in that list does, so it follows it:
      // naming a session goes to it here rather than growing the strip by
      // one — `/sessions` with no id is one keystroke away for the other verb.
      switchToSession(id)
      return true
    }
    if (command === "/tasks") {
      openOverlay("tasks")
      return true
    }
    // Bare, the sidebar goes up or comes down. With a number it is a width —
    // which is also the only way to say "and put it up", so a person who types
    // `/sidebar 35` gets the sidebar rather than a remembered number and no
    // list. The kernel of this is `resizeSidebar`, and the model clamps: 3 and
    // 300 both land on a pane that can still be drawn.
    if (command === "/sidebar") {
      const width = words[1]
      if (!width) {
        toggleSidebar()
        return true
      }
      const percent = Number(width.replace(/%$/, ""))
      if (!Number.isFinite(percent)) {
        setNotice(`/sidebar <percent> · a number between 10 and 90, or no argument to show or hide it`)
        return true
      }
      setSidebarPercent(percent)
      return true
    }
    if (command === "/ext") {
      openOverlay("ext")
      return true
    }
    // Which directory this tab works in (§5.3b). Bare, the browser; with an
    // argument, that directory straight away — the named form of what taking a
    // row does, exactly as `/resume <id>` is the named form of `Enter` in the
    // sessions list. `~` and a relative path both work, because a
    // person typing a path types the one they would type in a shell.
    if (command === "/cwd") {
      const said = rest.trim()
      if (said.length === 0) {
        openOverlay("cwd")
        return true
      }
      chooseWorkspace(expandPath(said, ws().dir))
      return true
    }
    // `/new` opens a SECOND tab beside this one (or, if the front tab is
    // already an untouched draft, just retunes it — there is no reason for
    // two). The tab in front, and whatever session is behind it, is left
    // exactly as it is: `/new` never closes a tab or drops a session.
    if (command === "/new") {
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
    // `/clear` is the word other harnesses use for starting a conversation
    // over, and the honest nulya shape of that is a NEW session in the SAME
    // tab slot rather than the second tab `/new` opens: a ledger only appends
    // (physics #1), so nothing is actually cleared — the old session, if this
    // tab had one, keeps its file and every event in it, exactly one
    // `/sessions` away. What clears is this tab's display, back to a draft.
    // An observer tab (one this process is only watching, not driving) clears
    // the same way: there is nothing special about a fresh draft taking the
    // place of a tab that used to be watching something.
    if (command === "/clear") {
      const flag = (name: string) => {
        const at = words.indexOf(name)
        return at >= 0 ? words[at + 1] : undefined
      }
      const profile = flag("--profile")
      const model = flag("--model")
      const last = loadTuiState(props.statePath).model
      const pick: ModelPick | undefined =
        profile || model ? { profile: profile ?? last?.profile ?? "", model, effort: last?.effort } : undefined
      startClear(pick)
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
    if (command === "/env") {
      setExecEnv(words[1])
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
   * existence.
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
  /**
   * `interrupt`: this turn came from the interrupt-and-deliver gesture
   * (agent-runner ar-t1) rather than a plain Enter — the only thing that
   * changes is which `Attachment` verb the turn ends up going through.
   */
  const sendTurn = async (text: string, interrupt = false, images: readonly ImageInput[] = []) => {
    let turn = text
    if (images.length === 0 && text.startsWith("/")) {
      if (await runPluginCommand(text)) return
      if (await runPackageCommand(text)) return
      try {
        turn = (await skillTurn(ws(), skills().entries(), text)) ?? text
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
    if (interrupt) await here.attach.interruptAndDeliver(turn, false, images)
    else await here.attach.send(turn, false, images)
  }

  const submit = (text: string, interrupt = false, images: readonly ImageInput[] = []) => {
    setNotice(null)
    if (images.length === 0 && runCommand(text)) return
    void sendTurn(text, interrupt, images)
  }

  /**
   * "Flush the queue" — the interrupt-and-deliver gesture with nothing NEW to
   * say: `ctrl+g` over an empty composer while something is already queued.
   * There is no composer text to route through `sendTurn`'s command/skill
   * dispatch here, so this goes straight to the attachment (agent-runner ar-t1).
   */
  const flushQueue = () => {
    const here = live()
    if (here) void here.attach.interruptAndDeliver("")
  }

  /** Whether the interrupt key currently has a step or queued turn to act on. */
  const interruptRelevant = () => {
    const here = live()
    if (!here) return false
    return here.attach.status() !== "idle" || here.state.pendingCount() > 0
  }

  /**
   * `ctrl+g`: with something typed, submit it flagged as an interrupt (through
   * the composer's own path, so paste-expansion and history still apply);
   * with nothing typed, it flushes anything already queued (ar-t1).
   */
  const handleInterruptAndDeliver = () => {
    if (composer?.isEmpty() ?? true) {
      flushQueue()
      return
    }
    composer?.triggerInterrupt()
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

  const handleGlobalCancel = () => {
    if (passwordRequest()) {
      cancelSshPassword()
      return
    }
    // Something opened on purpose a moment ago is what Esc is about, ahead of
    // the handover proposal that may have been sitting there for minutes and
    // ahead of the step — closing a panel of numbers or task rows costs
    // nothing to get wrong, and cancelling a step to put one away would.
    if (tasksPanel()) {
      setTasksPanel(false)
      return
    }
    if (contextPanel()) {
      setContextPanel(false)
      return
    }
    const here = live()
    if (here && here.attach.status() === "stepping") {
      void here.attach.cancel()
      return
    }
    // Nothing to stop and nothing typed: Esc means "go read".
    if (composer?.isEmpty() ?? true) enterBrowse()
  }

  const handleGlobalQuit = () => {
    // A FULL-SCREEN view is up, so there is nothing on this screen to stop and
    // Ctrl+C is about leaving. Deliberately `kind()` rather than `active()`
    // a focused sidebar also takes the keyboard, but the transcript
    // and its step are still right there beside it, and the narrowing below —
    // clear the draft, kill the step, then quit — is what Ctrl+C means then.
    if (overlay.kind() !== null) {
      quit()
      return
    }
    // Ctrl+C narrows from the nearest thing to stop to the furthest, and
    // NEVER quits on its first press. Three truths about
    // "stop", in the order a person means them: the draft in the box, the
    // kernel's step, and last — only ever after having said so — this process.
    // Losing a half-written message to a reflex, or the whole screen, is not
    // something a second keystroke can undo.
    if (!(composer?.isEmpty() ?? true)) {
      composer?.clear()
      setCtrlCArmed(false)
      setNotice("input cleared · Ctrl+C twice to quit")
      return
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

  const shortcutLayerBlocked = () =>
    Boolean(
      passwordRequest() !== null ||
        checkout() !== null ||
        pickerUp() ||
        pending() ||
        browse.active() ||
        plugins.panel(),
    )
  const normalShortcutLayerBlocked = () => shortcutLayerBlocked() || overlay.active()

  onMount(() => {
    const warnings: string[] = []
    const bind = (action: Action, run: () => void) => {
      const key = keys[action]
      try {
        keymap.parseKeySequence(key)
      } catch (error) {
        warnings.push(`${action}=${key}`)
        return []
      }
      return [{ key, cmd: run }]
    }

    const quitBindings = bind("quit", handleGlobalQuit)
    const offQuit = keymap.registerLayer({
      priority: 120,
      bindings: quitBindings,
    })

    const openers: readonly [Action, OverlayKind][] = [
      ["ext", "ext"],
      ["sessions", "sessions"],
      ["model", "model"],
      ["provider", "provider"],
      ["tasks", "tasks"],
      ["help", "help"],
    ]
    const openerBindings = [
      ...openers.flatMap(([action, kind]) => bind(action, () => openOverlay(kind))),
      // The sidebar is in this layer rather than the one below it because it is
      // the same kind of gesture — "show me this" — and, like the openers, it
      // still means something while a full-screen view is up: putting the rail
      // away is exactly what somebody in `/sessions` might want to do.
      ...bind("sidebar", toggleSidebar),
    ]
    const offOpeners = keymap.registerLayer({
      priority: 100,
      enabled: () => !shortcutLayerBlocked(),
      bindings: openerBindings,
    })

    /**
     * Move the keyboard between panes.
     *
     * A layer of its own so it can be OFF while there is only one pane: Ctrl+←
     * and Ctrl+→ are the composer's word-motion, and taking them permanently
     * for a gesture that has nowhere to go would be the theft `closeTab`
     * carefully avoids on a single tab.
     */
    const focusBindings = [
      ...bind("focusLeft", () => moveKeyboard("left")),
      ...bind("focusRight", () => moveKeyboard("right")),
      ...bind("focusUp", () => moveKeyboard("up")),
      ...bind("focusDown", () => moveKeyboard("down")),
    ]
    const offFocus = keymap.registerLayer({
      priority: 95,
      enabled: () => !shortcutLayerBlocked() && paneCount() > 1,
      bindings: focusBindings,
    })

    const normalBindings = [
      ...bind("scrollUp", () => scrollBy(-1)),
      ...bind("scrollDown", () => scrollBy(1)),
      ...bind("scrollEnd", scrollToEnd),
      ...bind("nextTab", () => tabs.next()),
      ...bind("redraw", () => renderer.requestRender()),
    ]
    const offNormal = keymap.registerLayer({
      priority: 90,
      enabled: () => !normalShortcutLayerBlocked(),
      bindings: normalBindings,
    })

    const closeTabBindings = bind("closeTab", () => tabs.close(tab().key))
    const offCloseTab = keymap.registerLayer({
      priority: 85,
      enabled: () => !normalShortcutLayerBlocked() && tabs.tabs().length > 1,
      bindings: closeTabBindings,
    })

    // Same trick as `closeTab` above: this layer only claims its key while it
    // actually means something (agent-runner ar-t1). At rest there is nothing
    // to interrupt or flush, so a configured chord remains available to the
    // focused control.
    const interruptBindings = bind("interrupt", handleInterruptAndDeliver)
    const offInterrupt = keymap.registerLayer({
      priority: 82,
      enabled: () => !normalShortcutLayerBlocked() && interruptRelevant(),
      bindings: interruptBindings,
    })

    const cancelBindings = bind("cancel", handleGlobalCancel)
    const offCancel = keymap.registerLayer({
      priority: 80,
      enabled: () => !normalShortcutLayerBlocked(),
      bindings: cancelBindings,
    })

    if (warnings.length > 0) setNotice(`ignored invalid key binding${warnings.length === 1 ? "" : "s"}: ${warnings.join(", ")}`)
    onCleanup(() => {
      offQuit()
      offOpeners()
      offFocus()
      offNormal()
      offCloseTab()
      offInterrupt()
      offCancel()
    })
  })

  /**
   * Who holds the keyboard for this keystroke (`pane/focus.ts`).
   *
   * The order this returns is read as a priority list: one pure function is
   * the single place to read the answer, and the single place S2 has to
   * satisfy to give a package's surface the keyboard.
   *
   * `modified` is passed in rather than filtered out beforehand because the
   * exception belongs beside the rule: a chord skips every claimant so that
   * Ctrl+C still kills a step while the approval dialog is up.
   */
  const focusOwner = (key: KeyEvent) =>
    resolveFocus({
      modified: Boolean(key.ctrl || key.meta),
      password: passwordRequest() !== null,
      checkout: checkout() !== null,
      withPicker: withPicker(),
      agentPicker: agentPicker(),
      envPicker: envPicker(),
      modePicker: modePicker(),
      approval: pending() !== null,
      keyboardPane: overlay.active() ? { pane: keyboardLeaf().pane, surface: keyboardLeaf().surface ?? "" } : null,
      pluginPanel: Boolean(plugins.panel()),
      browse: browse.active(),
    })

  usePaste((event) => {
    if (!passwordRequest()) return
    event.preventDefault()
    event.stopPropagation()
    appendPasswordBytes(event.bytes)
  })

  useKeyboard((key) => {
    if (key.propagationStopped) return
    const owner = focusOwner(key)
    /**
     * The agent picker, on the same terms as the mode picker below it: while a
     * dialog above the composer is up it holds the keyboard, so the list is a
     * list you can actually choose from. It is the outermost of the three
     * because it is the one that can only be opened deliberately.
     */
    /**
     * The checkout question, outermost (§5.3b point 6). Every printable key is
     * offered to `plan.apply`, which is the only thing that decides which of
     * them are answers — the same function the bare-terminal asking uses. A key
     * it does not accept changes nothing and is swallowed, so a stray keystroke
     * cannot answer a question about trust by accident.
     */
    if (owner.kind === "dialog" && owner.dialog === "password") {
      if (key.name === "return") return consume(key, submitSshPassword)
      if (key.name === "backspace") return consume(key, deletePasswordByte)
      const printable = !key.ctrl && !key.meta && Array.from(key.sequence).length === 1 && key.sequence >= " " && key.sequence !== "\x7f"
      if (printable) return consume(key, () => appendPasswordBytes(new TextEncoder().encode(key.sequence)))
      return consume(key, () => {})
    }
    if (owner.kind === "dialog" && owner.dialog === "checkout") {
      const said = key.name === "return" ? "return" : matches(keys.cancel, key) ? "escape" : (key.name ?? "")
      return consume(key, () => void answerCheckout(said.toLowerCase()))
    }
    if (owner.kind === "dialog" && owner.dialog === "with") {
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
    if (owner.kind === "dialog" && owner.dialog === "env") {
      // One more row than there are targets: the last one hands the typing back.
      const count = envTargets().length + 1
      if (matches(keys.cancel, key)) return consume(key, closeEnvPicker)
      if (key.name === "up" || key.name === "k") {
        return consume(key, () => setEnvChoice((at) => Math.max(at - 1, 0)))
      }
      if (key.name === "down" || key.name === "j") {
        return consume(key, () => setEnvChoice((at) => Math.min(at + 1, count - 1)))
      }
      if (key.name === "return") return consume(key, takeEnvChoice)
      if (key.name && /^[1-9]$/.test(key.name) && Number(key.name) <= count) {
        return consume(key, () => {
          setEnvChoice(Number(key.name) - 1)
          takeEnvChoice()
        })
      }
      return consume(key, () => {})
    }
    if (owner.kind === "dialog" && owner.dialog === "agent") {
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
     * the one moment two dialogs are on screen at once.
     * Answering it re-judges that waiting call on the spot (`chooseMode`).
     */
    if (owner.kind === "dialog" && owner.dialog === "mode") {
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
     * The approval dialog owns the keyboard while it is up.
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
    if (owner.kind === "dialog" && owner.dialog === "approval") {
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
    // The focused pane's surface owns the keyboard while it claims it (every
    // full-screen view does); global shortcuts that remain available there are
    // registered in OpenTUI keymap layers above. The surfaces the host ships
    // listen for themselves, which is why there is nothing to hand the key to
    // here — S2's packages get `SurfaceDefinition.onKey` instead.
    if (owner.kind === "surface") return
    /**
     * A plugin's panel owns the keyboard while it is up (tui-plugin D6) — on
     * exactly the terms every other composer dialog has, and no better ones:
     * the trusted zones above already returned, a full-screen overlay above
     * already returned, and `Ctrl+C` never arrives here at all
     * (`PluginHost.handleKey` refuses it, and the branch below still runs).
     * `Esc` takes the panel down whether or not the plugin wants it.
     */
    if (owner.kind === "plugin-panel") {
      if (plugins.handleKey(pluginKeyOf(key))) return consume(key, () => {})
    }
    // Read from the signal rather than from the verdict above, because a plugin
    // panel that DECLINED the key still falls through to browse mode — the
    // arbiter names one owner, and the one place the old chain did not stop at
    // the first claimant is here.
    if (browse.active()) {
      // The composer is blurred while browsing, so these keys are ours alone.
      if (matches(keys.cancel, key)) {
        leaveBrowse()
        return
      }
      if (key.name === "j" || key.name === "down") return moveBrowse(1)
      if (key.name === "k" || key.name === "up") return moveBrowse(-1)
      if (key.name === "space") return toggleSelected()
      // The card's `↗` row, on the keyboard: `Enter` watches it here
      // and `t` gives it a tab, the same two words `/sessions` uses for the
      // same pair of gestures. One vocabulary, and neither input can
      // reach a behaviour the other cannot.
      if (key.name === "t") {
        const id = sessionOf(selectedItem())
        if (id) return navigate.openSession(id)
        return
      }
      if (key.name === "return") {
        // A card that names a session opens it; every other card folds. The
        // sub-session link is the one place Enter means something else.
        const id = sessionOf(selectedItem())
        if (id) {
          navigate.watchSession(id)
          return
        }
        return toggleSelected()
      }
      return
    }
  })

  /**
   * Enter on an empty composer is the take-over gesture: the lease has looked
   * free for a while and this process is willing to drive again.
   */
  const takeOverIfOffered = (): boolean => {
    const here = live()
    if (!here?.attach.takeoverReady()) return false
    here.attach.takeOver()
    setNotice("took over · driving this session")
    return true
  }

  /**
   * The host's screens, into the table a package will register into next (S2).
   *
   * Registered here rather than beside the store because a definition is an
   * identity plus a thunk that draws it, and these draw from most of what this
   * component holds — the thunks are only ever called by a mounted pane, which
   * is long after every handle above exists.
   *
   * The bodies are the ones the `<Switch>` held moved verbatim: the
   * point of S1a is that the skeleton changed and nothing else did.
   */
  for (const definition of hostSurfaces({
    /**
     * The portal: the front tab's own tree, drawn by the SAME `PaneHost`
     * the app tree is. That reuse is the whole of the two-layer composition —
     * mounting, the hit test and pane-local focus each stay one implementation,
     * used twice, and a single-leaf tab tree still renders its surface with no
     * wrapper at all, so a screen with no sub-agent is byte-identical to the
     * screen before this existed.
     */
    tab: () => <PaneHost tree={tabPanes().tree()} registry={surfaces} onFocusPane={goToTabPane} />,
    /**
     * A delegation, followed. The view is looked up by the PANE, because
     * that is what a sub-agent surface is keyed by: one registration serves
     * every pane, and two tabs watching the same session are two panes with two
     * followers, which a per-session-id registration could not have expressed.
     */
    subagent: (mount: SurfaceMount) => {
      const here = tab()
      if (here.kind !== "session") return null
      const view = here.subs().find((sub) => sub.pane === mount.pane)
      if (!view) return null
      return (
        <SubAgentPane
          view={view}
          label={view.label}
          direction={subSplitOf(here.panes.tree(), mount.pane) ?? "row"}
          focused={mount.focused}
          width={
            here.panes.boxes(portalRect()).find((box) => box.pane === mount.pane)?.rect.width ?? portalRect().width
          }
          onClose={() => closeSub(mount.pane)}
        />
      )
    },
    transcript: () => (
      // The cards' wrap width, as a number from the pane tree:
      // this pane's own box when the tab is split, the portal otherwise.
      <BodyWidthContext.Provider
        value={() =>
          tabPanes()
            .boxes(portalRect())
            .find((box) => box.surface === main_surface)?.rect.width ?? portalRect().width
        }
      >
        <Transcript
          items={snapshot().items}
          header={snapshot().header}
          contributions={live()?.contributions() ?? []}
          highlightedCallId={snapshot().highlightedToolCallId}
          plan={plan()}
          // Failures that need more than the status bar's one row share one
          // readable place. A remote refusal can happen before a draft starts
          // or while choosing the next environment from a live session.
          error={(remoteFailure()?.tab === tab().key ? remoteFailure()!.detail : null) ?? snapshot().error ?? refusal()}
          retry={remoteFailure()?.tab === tab().key || !snapshot().error ? null : snapshot().retry}
          cwd={displayCwd()}
          onPickCwd={() => openOverlay("cwd")}
          // Always a value on this screen, `this machine` included: here it is
          // still a decision. The status line below says the opposite
          // thing by staying silent about the ordinary answer.
          shell={runsIn() || "this machine"}
          onPickEnv={() => void openEnvPicker()}
          onPickModel={() => openOverlay("model")}
          onOpenSession={(id) => openSession(id, ws())}
          onCommand={submit}
          tip={tip}
          ref={(box) => (scroll = box)}
        />
      </BodyWidthContext.Provider>
    ),
    sessions: (mount: SurfaceMount) => (
      <SessionsView
        workspaces={openWorkspaces()}
        currentId={live()?.id ?? ""}
        focused={mount.focused}
        onSwitch={switchToSession}
        onOpenTab={(id, where) => openSession(id, where)}
        onNew={() => startDraft()}
        onClose={closeOverlay}
        sessionTitle={(text) => plugins.sessionTitle(text)}
      />
    ),
    /**
     * The same list, docked. Its `onClose` is not "close the view" — it
     * is "give the keyboard back", which is what Esc means in a pane that is
     * still on screen after you leave it.
     *
     * The width is measured through the pane model rather than guessed from the
     * ratio, so what the rail lays its columns out in is what the seam is at
     * (`state/sidebar.ts`).
     */
    sidebar: (mount: SurfaceMount) => (
      <SessionsView
        workspaces={openWorkspaces()}
        variant="sidebar"
        width={sidebarWidth(panes.tree(), screen().width)}
        currentId={live()?.id ?? ""}
        focused={mount.focused}
        onSwitch={switchToSession}
        onOpenTab={(id, where) => openSession(id, where)}
        onNew={() => startDraft()}
        onClose={() => {
          panes.focusOn(panes.main())
          composer?.focus()
        }}
      />
    ),
    ext: () => (
      <ExtView
        // The tab's directory. Every write this view makes — build, activate,
        // deactivate, prune, seed — lands in a store, and the store search
        // order is the workspace's; the capability note it asks
        // the kernel to deposit goes into the session below, which is this
        // tab's. One directory for both, or the two disagree.
        ws={ws()}
        header={snapshot().header}
        // A draft has no session for the kernel to deposit a capability note
        // into — and no frozen tool face to warn about either, which the null
        // header already says.
        sessionFile={live() ? `${sessions_dir}/${live()!.id}.jsonl` : undefined}
        statePath={props.statePath}
        tick={planTick()}
        onMembershipChanged={() => {
          skills().invalidate()
          // Activating or deactivating a package can add or remove a `/name`
          // it declares just as easily as a skill (tui-plugin D1/D8): same
          // staleness, same fix.
          packageCmds().invalidate()
          // A package that was just activated may ship a front end. The other
          // direction is not symmetric and says so in `host.ts`: a module that
          // has run has run, so deactivating takes effect at the next start.
          void loadPlugins()
        }}
        onClose={closeOverlay}
      />
    ),
    tasks: () => (
      <TasksView
        // The tab's directory, not the process's: `k`/`K` run `nulya task kill`
        // there, and every other prop on this view already comes off the tab in
        // front (see `stopBackgroundTask`).
        ws={ws()}
        sessionId={live()?.id ?? ""}
        tasks={tasks()}
        send={(text, framed) => live()?.attach.send(text, framed) ?? Promise.resolve()}
        onRefresh={() => void live()?.tasks.refresh()}
        onClose={closeOverlay}
      />
    ),
    help: () => <HelpView keys={keys} onClose={closeOverlay} />,
    settings: () => (
      <SettingsView
        ws={ws()}
        onClose={closeOverlay}
        {...(props.onSettingsEdited ? { onEdited: props.onSettingsEdited } : {})}
        // The choices this front end makes and remembers for itself, each
        // opening the same thing its status-line chip opens. They are
        // computed here rather than in the view because every one of them is
        // already an accessor this component holds: a second reading of "what
        // model is this tab on" would be a second answer waiting to disagree.
        choices={[
          { label: "model", value: modelName(), command: "/model", open: () => openOverlay("model") },
          { label: "permission mode", value: mode() ?? "ask", command: "/mode", open: toggleModePicker },
          { label: "directory", value: workspaceLabel(ws().dir), command: "/cwd", open: () => openOverlay("cwd") },
          {
            label: "shell runs in",
            value: runsIn() || "this machine",
            command: "/env",
            open: () => {
              closeOverlay()
              void openEnvPicker()
            },
          },
          { label: "packages and pins", value: `tools ${builtin_tools}+${faceSize()}`, command: "/ext", open: () => openOverlay("ext") },
        ]}
      />
    ),
    usage: () => <UsageView ws={ws()} snapshot={snapshot()} onClose={closeOverlay} />,
    model: () => (
      <ModelView
        // The tab's directory: config has a project layer, so which profiles
        // and models exist is a question about a checkout, and the pick lands
        // on this tab — as its draft, or as a rebind of its session.
        ws={ws()}
        current={currentPick()}
        live={live() !== null}
        notice={guide() ?? undefined}
        focusProfile={focusProfile()}
        onPick={(pick) => void chooseModel(pick)}
        onNotice={setNotice}
        onOpenProviders={() => openOverlay("provider")}
        onClose={closeOverlay}
      />
    ),
    cwd: () => (
      <DirBrowser
        start={ws().dir}
        recents={loadRecents()}
        onChoose={chooseWorkspace}
        onClose={closeOverlay}
      />
    ),
    /**
     * The same browser, a channel to `remoteBrowse()!.spec` for a data source
     * instead of this machine's disk (`dirsource.ts`'s `remoteDirSource`).
     * `remoteBrowse` is only ever null before `beginRemoteBrowse` sets
     * it and after `applyRemoteWorkspace`/`onClose` clears it — both of which
     * close this overlay in the same breath — so a mount that somehow sees
     * null draws nothing rather than guessing at a target.
     */
    envdir: () => {
      const at = remoteBrowse()
      if (!at) return null
      return (
        <DirBrowser
          start={at.start}
          recents={[]}
          homeDir={at.home}
          label={(dir) => dir}
          source={remoteDirSource(ws(), at.spec, () => freshSshPassword(at.spec))}
          onChoose={applyRemoteWorkspace}
          onClose={() => {
            // Esc/cancel: no target was chosen, so nothing about `/env`
            // moves — but the pending target itself is cleared too, rather
            // than lingering as a stale value nothing on screen still means.
            setRemoteBrowse(null)
            clearSshWorkflow()
            closeOverlay()
          }}
        />
      )
    },
    provider: () => (
      <ProviderView
        // The tab's directory, for the same reason `/model` reads it there.
        ws={ws()}
        current={currentPick()}
        notice={guide() ?? undefined}
        onShowModels={showModelsOf}
        onNotice={setNotice}
        onClose={closeOverlay}
      />
    ),
  })) {
    surfaces.register(definition)
  }

  // Opened by `main` with a reason: show that screen before anything else.
  if (props.guide) overlay.open(props.guideOn ?? "model")

  return (
    <StyleContext.Provider value={props.style}>
      <ScreenContext.Provider value={screen}>
        <FrameContext.Provider value={spinnerTick}>
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
                  going. */}
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
                  with was a string nobody reads. */}
              <box flexDirection="column" width="100%" height="100%">
                {/* The mouse's half of the two verbs the keyboard already has:
                    `✕` is Ctrl+W's `tabs.close`, `+` is the draft a
                    bare `/new` opens. */}
                <TabBar
                  tabs={tabs.tabs()}
                  activeIndex={tabs.activeIndex()}
                  onSelect={(index) => tabs.select(index)}
                  onClose={(index) => {
                    const closing = tabs.tabs()[index]
                    if (closing) tabs.close(closing.key)
                  }}
                  onNew={() => startDraft()}
                />
                <Show when={tabs.tabs().length > 1}>
                  <Hairline />
                </Show>

                {/* The content area, mounted through the surface registry
                    rather than a switch over overlay names. One pane today,
                    so what this draws is exactly the one active overlay's view. */}
                <PaneHost tree={panes.tree()} registry={surfaces} onFocusPane={goToPane} />

                {/* A deliberate seam between the record and the controls: the
                    transcript/overlay scrolls above, while everything below is
                    about what can happen next. */}
                <box height={1} flexShrink={0} />

                {/* A directory this screen has just walked into, asking to be
                    trusted before anything in it takes part in a session
                    (DESIGN §9, §5.3b point 6). Outermost of the dialogs: it is
                    the only one that grants authority rather than choosing
                    something. */}
                <Show when={passwordRequest()}>
                  <SshPasswordPrompt spec={passwordRequest()!.spec} bytes={passwordRequest()!.bytes.length} />
                </Show>
                <Show when={checkout()}>
                  <CheckoutPrompt where={workspaceLabel(checkout()!.ws.dir)} plan={checkout()!.plan} />
                </Show>
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
                {/* Where the next session's shell runs. Same dialog shape
                    as the pickers around it, and the same rule: a target is
                    frozen when a session starts, so this is always about the
                    next one. */}
                <Show when={envPicker()}>
                  <EnvPicker
                    choices={envTargets()}
                    current={execEnv(props.statePath) || "local"}
                    selected={envChoice()}
                    onSelect={setEnvChoice}
                    onPick={(choice) => {
                      setEnvChoice(choice ? envTargets().indexOf(choice) : envTargets().length)
                      takeEnvChoice()
                    }}
                  />
                </Show>
                {/* Which agent to delegate to. Same dialog shape
                    as the mode picker, above it for the same reason it holds the
                    keyboard first: it is only ever opened on purpose. */}
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
                {/* The permission mode, where it is chosen.
                    Above the approval dialog because it can be opened from one:
                    a click on the chip while a call waits is exactly the "stop
                    asking me" gesture, and the answer re-judges that call. */}
                <Show when={modePicker()}>
                  <ModePicker
                    current={mode()}
                    selected={modeChoice()}
                    onSelect={setModeChoice}
                    onPick={chooseMode}
                  />
                </Show>
                {/* A plugin's own panel (tui-plugin D6), below every dialog
                    the host owns: a trusted zone hides it outright
                    (`dialogUp`), and the ordering here is the second half of
                    that promise — nothing an extension drew can ever sit
                    between a person and the question they are answering. */}
                <Show when={plugins.panel()}>
                  <PluginPanel panel={plugins.panel()!} revision={plugins.revision()} />
                </Show>
                {/* The call the kernel is stopped on, asked where the answer is
                    given. Above the composer for the same reason
                    the handover proposal is: it is a question about what happens
                    next, not a thing that happened. */}
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
                {/* The context ring, opened out. Low among the panels
                    because it is the expansion of a chip on the row below the
                    composer, and hidden outright while a host dialog is up —
                    the same terms a package's panel lives under, for the same
                    reason: nothing may come between a person and a question. */}
                <Show when={contextPanel() && !dialogUp()}>
                  <ContextPanel
                    fill={contextFill(snapshot().usage.lastPrompt, contextWindow())}
                    sections={contextSections(snapshot().usage, contextWindow())}
                  />
                </Show>
                {/* The background count on the activity line, opened out
                    (`TasksPanel`, tui.md §11 T87). Same terms as the context
                    panel above: expansion of a chip, gone while a host dialog
                    is up. */}
                <Show when={tasksPanel() && !dialogUp()}>
                  <TasksPanel tasks={tasks()} onStop={(task) => void stopBackgroundTask(task)} />
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
                  usage={usageLabel(displayUsage())}
                  onOpenTasks={toggleTasksPanel}
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
                  onNotice={setNotice}
                  onEmptySubmit={() => takeOverIfOffered()}
                  // Clicking the input box means "type here": browse mode holds
                  // the keyboard and the textarea cannot let itself out of it.
                  onActivate={() => {
                    if (browse.active()) leaveBrowse()
                  }}
                  readImage={(path) => readImageFile(path, ws().dir)}
                  vision={visionHere}
                  references={references()}
                  skills={skills()}
                  packages={packageCmds()}
                  pluginCommands={plugins.commands}
                  disabled={overlay.active()}
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
                  execEnv={runsIn()}
                  onPickEnv={() => void openEnvPicker()}
                  onOpenExt={() => openOverlay("ext")}
                  hint={notice()?.text}
                  behind={behind()}
                  contextWindow={contextWindow()}
                  onOpenContext={toggleContextPanel}
                  onPickModel={() => openOverlay("model")}
                  onScrollEnd={scrollToEnd}
                  sidebarOpen={sidebarOpen()}
                  onToggleSidebar={toggleSidebar}
                  workspace={workspaceChip()}
                  onPickCwd={() => openOverlay("cwd")}
                  onOpenSettings={() => openOverlay("settings")}
                />
              </box>
              </NavigateContext.Provider>
              </TasksContext.Provider>
              </PluginContext.Provider>
            </OverlayContext.Provider>
          </BrowseContext.Provider>
        </FoldContext.Provider>
        </FrameContext.Provider>
      </ScreenContext.Provider>
    </StyleContext.Provider>
  )
}

/**
 * One of the two rules that separate the three blocks. Sized to the
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
