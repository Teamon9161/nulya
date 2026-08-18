import { Match, Switch, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/solid"
import type { KeyEvent, ScrollBoxRenderable, Selection } from "@opentui/core"
import { Transcript, rowsBelow, windowItems } from "./Transcript.tsx"
import { Composer, type ComposerApi } from "./Composer.tsx"
import { StatusBar } from "./StatusBar.tsx"
import { TabBar } from "./TabBar.tsx"
import { SessionsView } from "./overlays/SessionsView.tsx"
import { ExtView } from "./overlays/ExtView.tsx"
import { HelpView } from "./overlays/HelpView.tsx"
import { SettingsView } from "./overlays/SettingsView.tsx"
import { UsageView } from "./overlays/UsageView.tsx"
import { ModelView } from "./overlays/ModelView.tsx"
import { ProviderView } from "./overlays/ProviderView.tsx"
import { ScreenContext, StyleContext, useScreen, useStyle, type Style } from "../render/theme.ts"
import { FoldContext, createFoldStore } from "../state/folds.ts"
import { BrowseContext, createBrowseStore } from "../state/browse.ts"
import { OverlayContext, createOverlayStore, type OverlayKind } from "../state/overlay.ts"
import { createTabStore, type DraftTab, type FirstTab, type SessionTab } from "../state/tabs.ts"
import { loadTuiState, rememberModel, sessionPins, type ModelPick } from "../state/tui_state.ts"
import { sessions_dir } from "../nulya/files.ts"
import { createProjectIndex } from "../references.ts"
import { createSkillTable, skillTurn } from "../skills.ts"
import { describeTool } from "../render/registry.ts"
import { no_snapshot } from "../state/session.ts"
import type { NextSession } from "../render/cards/CompositionCard.tsx"
import {
  extSetCurrent,
  extSync,
  isVerdict,
  sessionOutcome,
  verdicts,
  type ModelView as ModelParams,
  type ProfileView,
} from "../nulya/cli.ts"
import { failedIds, planStore, summarize } from "../extensions.ts"
import { runCompact } from "../compact.ts"
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
   * root is only here when `main` found it already trusted — the question, when
   * there is one, is asked before this screen exists.
   */
  sync?: { user: boolean; project: boolean; activate: boolean }
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
  const tabs = createTabStore(props.ws, first, { ...(props.driver ?? {}), statePath: props.statePath })

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
  const cards = () => foldable(snapshot().items, props.style.historyWindow)

  createEffect(() => {
    if (!props.style.motion) return
    if (status() === "idle") return
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
    const roots = [
      ...(plan.user ? [{ label: "user store", user: true }] : []),
      ...(plan.project ? [{ label: "this checkout", user: false }] : []),
    ]
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
            try {
              await extSetCurrent(props.ws, "activate", line.id, line.version, { user: root.user })
              activated += 1
            } catch {
              // The version is built either way; `/ext`'s `a` can still point
              // `current` at it, and a failed pointer move is not sync news.
            }
          }
        }
        // A count of failures is not news anybody can act on. Name them, and
        // point at the one screen that says why and offers the way out.
        const failed = failedIds(report)
        setNotice(
          summarize(root.label, report) +
            (activated > 0 ? ` · ${activated} activated` : "") +
            (failed.length > 0 ? ` · ${failed.join(" ")} not built · /ext` : ""),
        )
      } catch (error) {
        setNotice(`extension sync: ${error instanceof Error ? error.message : String(error)}`)
      }
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

  /** The tool face this tab shows beside the two builtins. */
  const faceSize = (): number => {
    const here = tab()
    if (here.kind === "draft") return plannedPins().length
    return snapshot().header?.composition.native_tools.length ?? 0
  }

  /** A draft's composition card: the same three rows, in the future tense. */
  const plan = (): NextSession | undefined => {
    const here = draft()
    if (!here) return undefined
    const bring = here.bring()
    return {
      model: modelOf(here.pick()),
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
      const tab = await tabs.materialize(here)
      setPlanTick((tick) => tick + 1)
      return tab
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
      return null
    }
  }

  /**
   * `/evolve` — build the evolution package and put it on the next session
   * (`evolve.ts`). Not on this one: composition freezes at `session new`
   * (physics #2), so there is no way to hand the model a new system prompt
   * mid-conversation, and pretending otherwise would be the one lie this front
   * end must never tell.
   */
  const evolveNow = async () => {
    setNotice("building the evolution package…")
    try {
      const ref = await buildEvolution(props.ws)
      startDraft(undefined, false, ref)
    } catch (error) {
      // Almost always "there is no extensions/evolution here": the package ships
      // with nulya's source, and this is somebody else's workspace.
      setNotice(error instanceof Error ? error.message : String(error))
    }
  }

  /** `/mode <id>[@<version>]` — the same move with any package that contributes a prompt. */
  const modeNow = (word: string | undefined) => {
    const ref = word ? parseWithRef(word) : null
    if (!ref) {
      setNotice("/mode <id>[@<version>] · a built extension; no version means the store's current")
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
      const result = await runCompact(props.ws, source.id, focus)
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
      modeNow(words[1])
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
    // An overlay owns the keyboard while it is up; only the keys that open or
    // close one, and the quit key, stay global (tui.md §11, T2 reminder 3).
    if (overlay.active()) {
      if (matches(keys.ext, key)) return consume(key, () => openOverlay("ext"))
      if (matches(keys.sessions, key)) return consume(key, () => openOverlay("sessions"))
      if (matches(keys.model, key)) return consume(key, () => openOverlay("model"))
      if (matches(keys.provider, key)) return consume(key, () => openOverlay("provider"))
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
      // First press stops the step, second leaves. Two different truths about
      // "stop" (tui.md §1.2 D6): the kernel's, then the process's.
      const here = live()
      if (here && here.attach.status() === "stepping" && !ctrlCArmed()) {
        here.attach.kill()
        setCtrlCArmed(true)
        setNotice("step killed · Ctrl+C again to quit")
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
              {/* Three blocks, two hairlines (tui.md §4.1). There is no title
                  line: what a person needs to know about the session — what it
                  runs on — is under the composer where they are looking, and the
                  id it used to lead with was a string nobody reads (T22). */}
              <box flexDirection="column" width="100%" height="100%">
                <TabBar tabs={tabs.tabs()} activeIndex={tabs.activeIndex()} onSelect={(index) => tabs.select(index)} />
                <Hairline />

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

                <Hairline />
                <Composer
                  onSubmit={submit}
                  onEmptySubmit={takeOverIfOffered}
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
                <Hairline />
                <StatusBar
                  snapshot={snapshot()}
                  status={status()}
                  role={role()}
                  takeoverReady={live()?.attach.takeoverReady() ?? false}
                  spinnerFrame={spinnerFrame()}
                  model={modelName()}
                  effort={tab().effort()}
                  tools={faceSize()}
                  hint={notice() ?? undefined}
                  behind={behind()}
                  contextWindow={contextWindow()}
                  onPickModel={() => openOverlay("model")}
                  onScrollEnd={scrollToEnd}
                  onHelp={() => openOverlay("help")}
                />
              </box>
            </OverlayContext.Provider>
          </BrowseContext.Provider>
        </FoldContext.Provider>
      </ScreenContext.Provider>
    </StyleContext.Provider>
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
