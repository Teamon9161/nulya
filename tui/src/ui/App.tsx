import { Match, Switch, createEffect, createSignal, onCleanup, onMount } from "solid-js"
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
import { ScreenContext, StyleContext, useScreen, useStyle, type Style } from "../render/theme.ts"
import { FoldContext, createFoldStore } from "../state/folds.ts"
import { BrowseContext, createBrowseStore } from "../state/browse.ts"
import { OverlayContext, createOverlayStore, type OverlayKind } from "../state/overlay.ts"
import { createTabStore, type SessionTab } from "../state/tabs.ts"
import { loadTuiState, rememberModel, sessionPins, type ModelPick } from "../state/tui_state.ts"
import { sessions_dir } from "../nulya/files.ts"
import { createProjectIndex } from "../references.ts"
import { createSkillTable, skillTurn } from "../skills.ts"
import { describeTool } from "../render/registry.ts"
import {
  extSetCurrent,
  extSync,
  isVerdict,
  sessionNew,
  sessionOutcome,
  verdicts,
  type ModelView as ModelParams,
} from "../nulya/cli.ts"
import { planStore, summarize } from "../extensions.ts"
import { runCompact } from "../compact.ts"
import { buildEvolution, formatWithRef, parseWithRef, withOptions, type WithRef } from "../evolve.ts"
import { createKeymap, matches } from "../keymap.ts"
import type { AttachOptions } from "../state/attach.ts"
import type { SessionState, TranscriptItem } from "../state/session.ts"
import type { Workspace } from "../nulya/bin.ts"

export interface AppProps {
  ws: Workspace
  id: string
  state: SessionState
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
  /** Where the TUI remembers its last pick; tests point it elsewhere. */
  statePath?: string
  /**
   * The `[[models]]` catalog, read once at launch. Only `context_window` is
   * used, for the status bar's fullness gauge; without it the gauge simply does
   * not appear, which is why this is optional rather than loaded here.
   */
  models?: ModelParams[]
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
 * The whole screen: header, transcript, composer, status bar — three blocks
 * separated by hairlines, no borders (tui.md §4.1, §6).
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
  const tabs = createTabStore(
    props.ws,
    { id: props.id, state: props.state, created: props.created ?? false, effort: props.effort },
    props.driver ?? {},
  )

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
  /**
   * Sessions this process will not ask about again on the way out: either a
   * verdict was recorded, or the question was already put once and declined.
   */
  const [settled, setSettled] = createSignal<readonly string[]>([])
  const [spinnerTick, setSpinnerTick] = createSignal(0)
  const [ctrlCArmed, setCtrlCArmed] = createSignal(false)
  const [allOpen, setAllOpen] = createSignal(false)
  const [behind, setBehind] = createSignal(0)
  let composer: ComposerApi | null = null
  let scroll: ScrollBoxRenderable | null = null

  const tab = () => tabs.active()
  const snapshot = () => tab().state.snapshot
  const cards = () => foldable(snapshot().items, props.style.historyWindow)

  createEffect(() => {
    if (!props.style.motion) return
    if (tab().attach.status() === "idle") return
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
        setNotice(summarize(root.label, report) + (activated > 0 ? ` · ${activated} activated` : ""))
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
    if (tab().attach.status() === "stepping") setCtrlCArmed(false)
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
    setNotice(null)
  }

  const closeOverlay = () => {
    overlay.close()
    composer?.focus()
  }

  const openSession = (id: string, created = false) => {
    tabs.open(id, { created })
    closeOverlay()
    setNotice(`opened ${id}`)
  }

  /**
   * A tab this process created and that never recorded anything. Picking a
   * model on such a tab replaces it (the session simply becomes that model)
   * instead of leaving an empty session beside the new one.
   */
  const untouched = (t: SessionTab) => t.created && t.state.snapshot.items.length === 0 && t.attach.status() === "idle"

  /**
   * The front tab's context window, when the catalog names one. The session's
   * frozen model id is the key — not the profile — since a window is a property
   * of the model, whoever serves it (DESIGN §9.5).
   */
  const contextWindow = (): number | null => {
    const id = snapshot().header?.model_identity.model
    if (!id) return null
    return props.models?.find((m) => m.id === id)?.context_window ?? null
  }

  /** What the front tab runs on, in the picker's terms. */
  const currentPick = (): ModelPick | null => {
    const header = snapshot().header
    if (!header) return null
    return { profile: header.model, model: header.model_identity.model || undefined, effort: tab().effort() }
  }

  /**
   * Start a session on `pick` and remember it as the last one. `pick` undefined
   * means "the last pick, else the kernel's default" — what a bare `/new` does.
   * `bring` adds `--with` members: composition membership for this session only,
   * which is how `/evolve` and `/mode` put a package in front of the model.
   */
  const newSession = async (pick?: ModelPick, remember = pick !== undefined, bring?: WithRef) => {
    const chosen = pick ?? loadTuiState(props.statePath).model
    try {
      // `--pin` from the panel's `this TUI` list, read at the moment the session
      // is created rather than held in a signal: the pins are program state on
      // disk, and a second TUI (or a `/ext` toggle a minute ago) must be the
      // truth here, not whatever this process saw at launch.
      const pins = sessionPins(props.statePath)
      const id = await sessionNew(props.ws, {
        ...(chosen ? { profile: chosen.profile, model: chosen.model } : {}),
        ...(bring ? withOptions(bring) : {}),
        ...(pins.length > 0 ? { pin: pins } : {}),
      })
      const current = tab()
      if (untouched(current)) tabs.replace(current.id, id, { created: true, effort: chosen?.effort })
      else tabs.open(id, { created: true, effort: chosen?.effort })
      closeOverlay()
      setGuide(null)
      const what = bring ? ` · with ${formatWithRef(bring)}` : ""
      setNotice(
        chosen ? `${id} · ${chosen.profile}${chosen.model ? ` · ${chosen.model}` : ""}${what}` : `opened ${id}${what}`,
      )
      if (remember && chosen) rememberModel(chosen, props.statePath)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
  }

  /**
   * `/evolve` — build the evolution package and start a session wearing it
   * (`evolve.ts`). A fresh session, not this one: composition freezes at
   * `session new` (physics #2), so there is no way to hand the model a new
   * system prompt mid-conversation, and pretending otherwise would be the one
   * lie this front end must never tell.
   */
  const evolveNow = async () => {
    setNotice("building the evolution package…")
    try {
      const ref = await buildEvolution(props.ws)
      await newSession(undefined, false, ref)
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
    void newSession(undefined, false, ref)
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
    if (!word || !isVerdict(word)) {
      setNotice(`/outcome <${verdicts.join("|")}> [note] · nothing recorded is "not judged", not failure`)
      return
    }
    try {
      await sessionOutcome(props.ws, tab().id, word, note)
      setSettled([...settled(), tab().id])
      setNotice(`${tab().id}: ${word}${note ? ` · ${note}` : ""}`)
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
    const source = tab()
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
    const here = tab()
    const worked = here.state.snapshot.items.some((item) => item.seq !== null)
    if (ask && worked && !settled().includes(here.id)) {
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
      void tab().attach.cancel()
      return true
    }
    if (command === "/step") {
      void tab().attach.step()
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
      void newSession(pick, false)
      return true
    }
    if (command === "/model") {
      openOverlay("model")
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
   * `/name args` that no built-in claimed. If a skill has that name, its body
   * becomes an ordinary user turn wrapped in the echo sentinel (`skills.ts`);
   * otherwise the line goes to the model exactly as typed, which is what it has
   * always done.
   *
   * Asynchronous, so this is the one dispatch that cannot answer synchronously:
   * the send happens after `skill load` returns, and a failure to load says so
   * instead of quietly sending `/name` as prose.
   */
  const submitSlash = async (text: string) => {
    try {
      const turn = await skillTurn(props.ws, skills.entries(), text)
      await tab().attach.send(turn ?? text)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
  }

  const submit = (text: string) => {
    setNotice(null)
    if (runCommand(text)) return
    if (text.startsWith("/")) return void submitSlash(text)
    void tab().attach.send(text)
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
      if (tabs.tabs().length > 1) consume(key, () => tabs.close(tab().id))
      return
    }
    if (matches(keys.cancel, key)) {
      if (tab().attach.status() === "stepping") {
        void tab().attach.cancel()
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
      if (tab().attach.status() === "stepping" && !ctrlCArmed()) {
        tab().attach.kill()
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
    if (!tab().attach.takeoverReady()) return false
    tab().attach.takeOver()
    setNotice("took over · driving this session")
    return true
  }

  /**
   * The title line, in two tiers: WHICH session on WHICH model is the answer to
   * "where am I", and the shape of its frozen composition is a detail about it.
   * One flat grey sentence made the two impossible to tell apart at a glance.
   */
  const header = () => {
    const current = snapshot()
    const identity = current.header?.model_identity
    // Profile then model id — the two names a person picked, not the wire kind.
    const profile = current.header?.model ?? "…"
    const model =
      identity && identity.model.length > 0 && identity.model !== profile ? `${profile} · ${identity.model}` : profile
    const effort = tab().effort()
    const native = current.header?.composition.native_tools.length ?? 0
    const skills = tab()
      .contributions()
      .reduce((count, entry) => count + entry.skills.length, 0)
    return {
      subject: `nulya · ${tab().id} · ${model}`,
      detail: `${effort ? ` · effort ${effort}` : ""} · tools 2+${native} · skills ${skills}`,
    }
  }

  // Opened by `main` with a reason: show the picker before anything else.
  if (props.guide) overlay.open("model")

  return (
    <StyleContext.Provider value={props.style}>
      <ScreenContext.Provider value={screen}>
        <FoldContext.Provider value={folds}>
          <BrowseContext.Provider value={browse}>
            <OverlayContext.Provider value={overlay}>
              <box flexDirection="column" width="100%" height="100%">
                <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={1} paddingRight={1}>
                  <text fg={props.style.theme.muted} flexShrink={0}>
                    {header().subject}
                  </text>
                  <text fg={props.style.theme.dim}>{header().detail}</text>
                </box>
                <TabBar tabs={tabs.tabs()} activeIndex={tabs.activeIndex()} onSelect={(index) => tabs.select(index)} />
                <Hairline />

                <Switch
                  fallback={
                    <Transcript
                      items={snapshot().items}
                      header={snapshot().header}
                      contributions={tab().contributions()}
                      ref={(box) => (scroll = box)}
                    />
                  }
                >
                  <Match when={overlay.kind() === "sessions"}>
                    <SessionsView
                      ws={props.ws}
                      currentId={tab().id}
                      onOpen={openSession}
                      onNew={() => void newSession()}
                      onClose={closeOverlay}
                    />
                  </Match>
                  <Match when={overlay.kind() === "ext"}>
                    <ExtView
                      ws={props.ws}
                      header={snapshot().header}
                      sessionFile={`${sessions_dir}/${tab().id}.jsonl`}
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
                      onPick={(pick) => void newSession(pick)}
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
                  status={tab().attach.status()}
                  role={tab().attach.role()}
                  takeoverReady={tab().attach.takeoverReady()}
                  spinnerFrame={spinnerFrame()}
                  hint={notice() ?? undefined}
                  behind={behind()}
                  contextWindow={contextWindow()}
                  onScrollEnd={scrollToEnd}
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
