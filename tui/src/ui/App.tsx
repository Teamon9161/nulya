import { For, Match, Show, Switch, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/solid"
import type { InputRenderable, KeyEvent, ScrollBoxRenderable, Selection } from "@opentui/core"
import { Transcript, rowsBelow, windowItems } from "./Transcript.tsx"
import { Composer, type ComposerApi } from "./Composer.tsx"
import { ApprovalPanel, type ApprovalChoice } from "./ApprovalPanel.tsx"
import { ModePicker, initialChoice, modeAt, moveChoice } from "./ModePicker.tsx"
import { StatusBar } from "./StatusBar.tsx"
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
import { createTabStore, type DraftTab, type FirstTab, type SessionTab } from "../state/tabs.ts"
import { loadTuiState, rememberModel, rememberMode, sessionPins, type ModelPick } from "../state/tui_state.ts"
import {
  alwaysKey,
  decide,
  describeKey,
  modes,
  normalizeMode,
  summarize as describeCall,
  type GateRequest,
  type PermissionMode,
} from "../approvals.ts"
import type { GateVerdict } from "../nulya/cli.ts"
import { listExtensions, sessions_dir } from "../nulya/files.ts"
import { wrapApprovalNote } from "../approvalnote.ts"
import { createProjectIndex } from "../references.ts"
import { createSkillTable, skillTurn } from "../skills.ts"
import { describeTool } from "../render/registry.ts"
import { no_snapshot } from "../state/session.ts"
import type { NextSession } from "./Welcome.tsx"
import {
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
  activePromptPackages,
  adoptBundled,
  autoActivatable,
  failedIds,
  planStore,
  promptPackageWarning,
  promptsOf,
  seedBundled,
  summarize,
  syncRoot,
} from "../extensions.ts"
import { runCompact } from "../compact.ts"
import { buildHandoff, handoff_pin, headline, nextHandoff, type HandoffFile } from "../handoff.ts"
import { buildEvolution, formatWithRef, parseWithRef, type WithRef } from "../evolve.ts"
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
 * The cards browse mode walks and Ctrl+O toggles: everything with a body that
 * is actually on screen. Items outside `history_window` are not mounted, so a
 * selection there would be invisible.
 */
function foldable(items: readonly TranscriptItem[], window: number): TranscriptItem[] {
  return windowItems(items, window).filter((item) => item.kind === "tool" || item.kind === "thinking")
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

  const [notice, setNotice] = createSignal<string | null>(null)
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
  const [allOpen, setAllOpen] = createSignal(false)
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

  /** A handover the model proposed and nobody has answered yet (tui.md §5.8). */
  const [handoff, setHandoff] = createSignal<HandoffFile | null>(null)
  /** Handoff files this process has already acted on or dismissed. */
  const [handoffsSeen, setHandoffsSeen] = createSignal<ReadonlySet<string>>(new Set())
  let composer: ComposerApi | null = null
  let scroll: ScrollBoxRenderable | null = null
  /**
   * The `handoff` build, started once and shared. Compiled, so the first build
   * on a machine costs a toolchain run — which is why it happens in the
   * background from the moment the screen exists and not on the way into the
   * first session.
   */
  let handoffBuild: Promise<WithRef | null> | null = null
  const handoffMember = (): Promise<WithRef | null> => (handoffBuild ??= buildHandoff(props.ws).catch(() => null))

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
  const cards = () => foldable(snapshot().items, props.style.historyWindow)
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
   * `current` at any id that has none at all. Since `ext seed` (tui.md §11,
   * T19) the user store legitimately holds built-but-inactive packages —
   * evolution, whose system prompt must NOT enter every session — so this pass
   * only activates versions it produced itself: a draft somebody just dropped
   * in gets picked up, a package left inactive on purpose stays that way.
   */
  const syncStores = async () => {
    const plan = props.sync
    if (!plan) return
    // The drafts the BINARY ships, into the user store, before the pass that
    // builds them: seeding writes source only and leaves alone anything already
    // there (DESIGN §7.8), so the one pass below builds what arrived along with
    // everything else. This used to be a question on a bare terminal BEFORE the
    // screen existed, and answering it held that terminal for a minute of zig
    // with `installing…` as the only sign of life (tui.md §11, T23).
    let arrived: string[] = []
    if (plan.user && plan.bundled) {
      try {
        setNotice("installing the bundled extensions…")
        arrived = (await seedBundled(props.ws)).ids
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
        /** Ids this pass built and deliberately left switched off (T31). */
        const held: string[] = []
        if (plan.activate) {
          const where = syncRoot(props.ws, root.user)
          for (const line of report.lines) {
            if (line.state !== "built" || !line.version || line.activation === "active") continue
            // What arrived with the binary this run is `adoptBundled`'s to
            // decide: everything a fresh seed drops is `built` by this pass.
            if (arrived.includes(line.id)) continue
            // A package that contributes a SYSTEM PROMPT is a mode, and a
            // background pass does not choose modes (`autoActivatable`, T31).
            // `arrived` used to be the whole guard, which only ever covered the
            // ONE start where `ext seed` dropped the drafts — so a machine
            // seeded yesterday, or by hand, had `evolution` switched on by this
            // very loop the next time its draft rebuilt, and every session
            // afterwards opened believing it was the slow loop.
            if (!autoActivatable(line.id, await promptsOf(props.ws, where, line.id, line.version))) {
              held.push(line.id)
              continue
            }
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
        // point at the one screen that says why and offers the way out.
        const failed = failedIds(report)
        // A pass that changed nothing has no news — "0 built · 5 already" would
        // park on the status line until the next keypress and say nothing. The
        // durable per-id state lives in /ext either way.
        if (report.built === 0 && failed.length === 0 && activated === 0 && adopted.length === 0 && held.length === 0) {
          continue
        }
        news.push(
          summarize(root.label, report) +
            (activated > 0 ? ` · ${activated} activated` : "") +
            adopted.map((part) => ` · ${part}`).join("") +
            // Built and left off on purpose: said, because a package that is
            // there and does nothing is otherwise a mystery, and `/ext` is the
            // one key that turns it on for real.
            (held.length > 0 ? ` · ${held.join(" ")} built, left off (a mode) · /ext` : "") +
            (failed.length > 0 ? ` · ${failed.join(" ")} not built · /ext` : ""),
        )
      } catch (error) {
        news.push(`extension sync: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
    // …and whatever a mode package is doing on this machine ALREADY, whoever
    // switched it on and whenever (T31). This is the half no guard can fix: the
    // pointer is on disk, `evolution`'s prompt is in front of every model, and
    // nothing on the screen said so. Named, not undone — turning it off is as
    // much a person's decision as turning it on was.
    const worn = promptPackageWarning(await activeModes())
    if (worn) news.push(worn)
    setNotice(news.length > 0 ? news.join(" · ") : null)
  }

  /** The packages that are active and contribute a system prompt, right now. */
  const activeModes = async (): Promise<string[]> => {
    try {
      return activePromptPackages(await listExtensions(props.ws))
    } catch {
      // No listing is "unknown", and unknown is not news.
      return []
    }
  }

  onMount(() => void syncStores())

  // "Ctrl+C again to quit" is an offer about THIS step. It lapses when a new
  // step starts (the first press must kill again, not quit) and after a short
  // while regardless, so a press minutes later is never a surprise exit.
  createEffect(() => {
    if (status() === "stepping") setCtrlCArmed(false)
  })
  createEffect(() => {
    if (!ctrlCArmed()) return
    const timer = setTimeout(() => setCtrlCArmed(false), 3000)
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

  const spinnerFrame = () => props.style.spinner[spinnerTick() % props.style.spinner.length]!

  const lastFoldable = () => {
    const list = cards()
    return list.length > 0 ? list[list.length - 1]! : null
  }

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
    setNotice("browse · j/k move · Enter open/fold · Space fold · Esc back")
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

  const selectedItem = () => cards().find((item) => item.key === browse.selected()) ?? null

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
    // draft card's tool face is read off those files.
    setPlanTick((tick) => tick + 1)
  }

  const openSession = (id: string, created = false) => {
    tabs.open(id, { created })
    closeOverlay()
    setNotice(`opened ${id}`)
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
   * the merged config pins plus this TUI's own list, read from disk. The same
   * two sources `/ext`'s quota line adds up — there is no third answer here.
   */
  // A memo, because reading it is a file read: it is asked for once per frame by
  // both the status line and the draft card, and it can only change when
  // something wrote that file — which is what `planTick` says.
  const plannedPins = createMemo((): string[] => {
    planTick()
    const face = [...(props.pinnedTools ?? [])]
    for (const pin of sessionPins(props.statePath)) if (!face.includes(pin)) face.push(pin)
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
   * frozen contributions, which say which members actually contribute a prompt.
   */
  const wearing = (): string[] => {
    const here = tab()
    if (here.kind === "draft") {
      const bring = here.bring()
      return bring ? [bring.id] : []
    }
    return here.contributions().filter((c) => c.systemPrompts.length > 0).map((c) => c.id)
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
    try {
      const tab = await tabs.materialize(here, await handoffExtras())
      setPlanTick((tick) => tick + 1)
      return tab
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
      return null
    }
  }

  /**
   * The `handoff` package, for the session about to start (tui.md §5.8).
   *
   * Two axes, both needed and both separate (DESIGN §7.5): `--with` makes the
   * version a member of this composition, `--pin` gives its tool a native slot
   * so the model can actually call it. It is off with one `tui.toml` key, and a
   * build that fails costs the session nothing — it starts without the package
   * and says so, rather than not starting.
   */
  const handoffExtras = async (): Promise<{ with?: string[]; pin?: string[] }> => {
    if (!props.style.settings.extensions.handoff) return {}
    const ref = await handoffMember()
    if (!ref) return {}
    return { with: [formatWithRef(ref)], pin: [handoff_pin] }
  }

  // ── The gate (tui.md §5.7) ────────────────────────────────────────────────

  /** The tab a gate request belongs to — the session being stepped, not the one in front. */
  const tabOf = (session: string): SessionTab | null =>
    (tabs.tabs().find((t) => t.kind === "session" && t.id === session) as SessionTab | undefined) ?? null

  /**
   * The stable id of a tool on that session's face (`ext:<id>/<tool>`), or
   * undefined for a builtin. Read from the FROZEN versions the session
   * composed, which is the only place that knows which package a name came
   * from — the gate request carries the model-facing name and nothing else.
   */
  const toolId = (asked: SessionTab | null, tool: string): string | undefined => {
    for (const c of asked?.contributions() ?? []) {
      if (c.tools.includes(tool)) return `ext:${c.id}/${tool}`
    }
    return undefined
  }

  /** Whether the frozen manifest claims this tool only reads (DESIGN §7.2.1). */
  const toolReadonly = (asked: SessionTab | null, tool: string): boolean | undefined => {
    for (const c of asked?.contributions() ?? []) {
      if (c.tools.includes(tool)) return c.readonlyTools.includes(tool)
    }
    return undefined
  }

  const decideNow = (request: GateRequest, asked: SessionTab | null) =>
    decide(request, {
      mode: mode(),
      rules: props.style.settings.approvals,
      always: always(),
      idOf: (tool) => toolId(asked, tool),
      readonlyOf: (tool) => toolReadonly(asked, tool),
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
    const key = alwaysKey(asked.request, (tool) => toolId(tabOf(asked.session), tool))
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
      if (!overlay.active() && !browse.active() && !modePicker()) composer?.focus()
      return
    }
    composer?.blur()
    if (noteFocused()) noteField?.focus()
    else noteField?.blur()
  })

  /**
   * The mode picker holds the keyboard while it is up, for the same reason the
   * approval dialog does (T28): a list you choose from is not a list you can
   * choose from if `j` goes into the composer behind it.
   */
  createEffect(() => {
    if (modePicker()) composer?.blur()
    else if (!pending() && !overlay.active() && !browse.active()) composer?.focus()
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
    const kind = describeKey(alwaysKey(asked.request, (tool) => toolId(tabOf(asked.session), tool)))
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
    setNotice(`handoff proposed · ${headline(found.brief)} · Enter follow · Esc dismiss`)
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
   * Fork on a brief the model already wrote: `/compact`'s `brief_file` branch,
   * which skips asking for a summary and leaves the old session byte-identical
   * (DESIGN §11). The tab moves to the child, as `/compact` does.
   */
  const followHandoffFile = async (file: HandoffFile) => {
    const source = live()
    if (!source) return
    setNotice(`handoff · forking on ${file.path}…`)
    try {
      const result = await runCompact(props.ws, source.id, { briefFile: file.path })
      tabs.replace(source.id, result.session, { created: true, effort: source.effort() })
      setNotice(`handed off into ${result.session} · ${source.id} kept on disk`)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
      if (source.attach.role() === "observer") source.attach.takeOver()
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

  /**
   * `/as <id>[@<version>]` — the same move as `/evolve` with any package that
   * contributes a prompt: wear it for one session, activate nothing.
   *
   * It was `/mode` until the permission mode needed that name (tui.md §5.7).
   * `/as evolution` also reads as what it does — this session speaks AS that
   * package — where `/mode evolution` and `/mode unsafe` were two unrelated
   * things behind one word.
   */
  const wearNow = (word: string | undefined) => {
    const ref = word ? parseWithRef(word) : null
    if (!ref) {
      setNotice("/as <id>[@<version>] · a built extension; no version means the store's current")
      return
    }
    startDraft(undefined, false, ref)
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
    if (command === "/as") {
      wearNow(words[1])
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
    if (command === "/fold") {
      folds.setAll(false)
      setAllOpen(false)
      return true
    }
    if (command === "/sessions") {
      openOverlay("sessions")
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
   * A `/name` no built-in claimed is offered to the skill catalog first: if a
   * skill has that name, its body becomes an ordinary user turn wrapped in the
   * echo sentinel (`skills.ts`), and a failure to load says so rather than
   * quietly sending `/name` as prose. Only then — with something real to say —
   * is the draft turned into a session.
   *
   * The order matters both ways: a skill that will not load must not create a
   * session, and a session that will not start must not lose the text. The
   * composer has already cleared itself by the time this runs, so a refusal puts
   * the typed line back in the box.
   */
  const sendTurn = async (text: string) => {
    let turn = text
    if (text.startsWith("/")) {
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
          leaveBrowse()
          tabs.open(id)
          setNotice(`opened ${id}`)
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
    if (matches(keys.fold, key)) {
      return consume(key, () => {
        const item = lastFoldable()
        if (item) folds.toggle(item.key, false)
      })
    }
    if (matches(keys.foldAll, key)) {
      return consume(key, () => {
        const next = !allOpen()
        setAllOpen(next)
        folds.setAll(next)
      })
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
              {/* The live task rows, for the one card that needs a fact nothing
                  appended can carry: how long a background command has been
                  going (tui.md §5.9). */}
              <TasksContext.Provider value={tasks}>
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
                      cwd={props.ws.dir}
                      onPickModel={() => openOverlay("model")}
                      onCommand={submit}
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
                      onMembershipChanged={skills.invalidate}
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
                  onReady={(api) => {
                    composer = api
                    // The picker may already be up (`guide`): it owns the keys.
                    if (overlay.active()) api.blur()
                  }}
                />
                <StatusBar
                  snapshot={snapshot()}
                  status={status()}
                  role={role()}
                  takeoverReady={live()?.attach.takeoverReady() ?? false}
                  spinnerFrame={spinnerFrame()}
                  model={modelName()}
                  effort={tab().effort()}
                  tools={faceSize()}
                  mode={mode()}
                  awaiting={pending() !== null}
                  background={runningTasks()}
                  onOpenTasks={() => openOverlay("tasks")}
                  onPickMode={openModePicker}
                  wearing={wearing()}
                  onOpenExt={() => openOverlay("ext")}
                  hint={notice() ?? undefined}
                  behind={behind()}
                  contextWindow={contextWindow()}
                  onPickModel={() => openOverlay("model")}
                  onScrollEnd={scrollToEnd}
                  onHelp={() => openOverlay("help")}
                />
              </box>
              </TasksContext.Provider>
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
