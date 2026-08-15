import { Match, Switch, createEffect, createSignal, onCleanup } from "solid-js"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/solid"
import { Transcript } from "./Transcript.tsx"
import { Composer, type ComposerApi } from "./Composer.tsx"
import { StatusBar } from "./StatusBar.tsx"
import { TabBar } from "./TabBar.tsx"
import { SessionsView } from "./overlays/SessionsView.tsx"
import { ExtView } from "./overlays/ExtView.tsx"
import { HelpView } from "./overlays/HelpView.tsx"
import { SettingsView } from "./overlays/SettingsView.tsx"
import { UsageView } from "./overlays/UsageView.tsx"
import { StyleContext, useStyle, type Style } from "../render/theme.ts"
import { FoldContext, createFoldStore } from "../state/folds.ts"
import { BrowseContext, createBrowseStore } from "../state/browse.ts"
import { OverlayContext, createOverlayStore, type OverlayKind } from "../state/overlay.ts"
import { createTabStore } from "../state/tabs.ts"
import { describeTool } from "../render/registry.ts"
import { sessionNew } from "../nulya/cli.ts"
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
}

/** The cards browse mode walks and Ctrl+O toggles: everything with a body. */
function foldable(items: readonly TranscriptItem[]): TranscriptItem[] {
  return items.filter((item) => item.kind === "tool" || item.kind === "thinking")
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
  const folds = createFoldStore()
  const browse = createBrowseStore()
  const overlay = createOverlayStore()
  const keys = createKeymap(props.style.settings)
  const tabs = createTabStore(props.ws, { id: props.id, state: props.state }, props.driver ?? {})

  const [notice, setNotice] = createSignal<string | null>(null)
  const [spinnerTick, setSpinnerTick] = createSignal(0)
  const [ctrlCArmed, setCtrlCArmed] = createSignal(false)
  const [allOpen, setAllOpen] = createSignal(false)
  let composer: ComposerApi | null = null

  const tab = () => tabs.active()
  const snapshot = () => tab().state.snapshot

  createEffect(() => {
    if (!props.style.motion) return
    if (tab().attach.status() === "idle") return
    const timer = setInterval(() => setSpinnerTick((tick) => tick + 1), 90)
    onCleanup(() => clearInterval(timer))
  })

  onCleanup(() => tabs.disposeAll())

  const spinnerFrame = () => props.style.spinner[spinnerTick() % props.style.spinner.length]!

  const lastFoldable = () => {
    const cards = foldable(snapshot().items)
    return cards.length > 0 ? cards[cards.length - 1]! : null
  }

  /** The session a card names, if it names one — the sub-session link (tui.md §5.5). */
  const sessionOf = (item: TranscriptItem | null): string | null => {
    if (!item || item.kind !== "tool") return null
    return describeTool({ tool: item.tool, args: item.args, output: item.output }, props.style.glyphs).sessionId
  }

  const enterBrowse = () => {
    const cards = foldable(snapshot().items)
    if (cards.length === 0) return
    composer?.blur()
    browse.enter(cards[cards.length - 1]!.key)
    setNotice("browse · j/k move · Enter open/fold · Space fold · Esc back")
  }

  const leaveBrowse = () => {
    browse.exit()
    composer?.focus()
    setNotice(null)
  }

  const moveBrowse = (delta: number) => {
    const cards = foldable(snapshot().items)
    if (cards.length === 0) return
    const at = cards.findIndex((item) => item.key === browse.selected())
    const next = Math.min(Math.max((at < 0 ? cards.length - 1 : at) + delta, 0), cards.length - 1)
    browse.select(cards[next]!.key)
  }

  const selectedItem = () => foldable(snapshot().items).find((item) => item.key === browse.selected()) ?? null

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

  const openSession = (id: string) => {
    tabs.open(id)
    closeOverlay()
    setNotice(`opened ${id}`)
  }

  const newSession = async (model?: string) => {
    try {
      const id = await sessionNew(props.ws, model ? { model } : {})
      openSession(id)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
  }

  const quit = () => {
    tabs.disposeAll()
    renderer.destroy()
    process.exit(0)
  }

  const runCommand = (raw: string): boolean => {
    if (!raw.startsWith("/")) return false
    const words = raw.trim().split(/\s+/)
    const command = words[0]
    if (command === "/quit") {
      quit()
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
      const at = words.indexOf("--model")
      void newSession(at >= 0 ? words[at + 1] : undefined)
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
    // Unknown slash commands are the model's business, not ours (tui.md §4.4).
    return false
  }

  const submit = (text: string) => {
    setNotice(null)
    if (runCommand(text)) return
    void tab().attach.send(text)
  }

  useKeyboard((key) => {
    // An overlay owns the keyboard while it is up; only the keys that open or
    // close one, and the quit key, stay global (tui.md §11, T2 reminder 3).
    if (overlay.active()) {
      if (matches(keys.ext, key)) return openOverlay("ext")
      if (matches(keys.sessions, key)) return openOverlay("sessions")
      if (matches(keys.help, key)) return openOverlay("help")
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
    if (matches(keys.sessions, key)) return openOverlay("sessions")
    if (matches(keys.ext, key)) return openOverlay("ext")
    if (matches(keys.help, key)) return openOverlay("help")
    if (matches(keys.nextTab, key)) {
      tabs.next()
      return
    }
    if (matches(keys.closeTab, key)) {
      tabs.close(tab().id)
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
      const item = lastFoldable()
      if (item) folds.toggle(item.key, false)
      return
    }
    if (matches(keys.foldAll, key)) {
      const next = !allOpen()
      setAllOpen(next)
      folds.setAll(next)
      return
    }
    if (matches(keys.redraw, key)) {
      renderer.requestRender()
      return
    }
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

  const header = () => {
    const current = snapshot()
    const identity = current.header?.model_identity
    const model =
      identity && identity.model.length > 0 ? `${identity.provider}/${identity.model}` : (current.header?.model ?? "…")
    const native = current.header?.composition.native_tools.length ?? 0
    const skills = tab()
      .contributions()
      .reduce((count, entry) => count + entry.skills.length, 0)
    return `nulya · ${tab().id} · ${model} · tools 2+${native} · skills ${skills}`
  }

  return (
    <StyleContext.Provider value={props.style}>
      <FoldContext.Provider value={folds}>
        <BrowseContext.Provider value={browse}>
          <OverlayContext.Provider value={overlay}>
            <box flexDirection="column" width="100%" height="100%">
              <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={1} paddingRight={1}>
                <text fg={props.style.theme.dim}>{header()}</text>
              </box>
              <TabBar tabs={tabs.tabs()} activeIndex={tabs.activeIndex()} />
              <Hairline />

              <Switch
                fallback={
                  <Transcript
                    items={snapshot().items}
                    header={snapshot().header}
                    contributions={tab().contributions()}
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
                  <ExtView ws={props.ws} header={snapshot().header} onClose={closeOverlay} />
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
              </Switch>

              <Hairline />
              <Composer
                onSubmit={submit}
                onEmptySubmit={takeOverIfOffered}
                onReady={(api) => (composer = api)}
              />
              <Hairline />
              <StatusBar
                snapshot={snapshot()}
                status={tab().attach.status()}
                role={tab().attach.role()}
                takeoverReady={tab().attach.takeoverReady()}
                spinnerFrame={spinnerFrame()}
                hint={notice() ?? undefined}
              />
            </box>
          </OverlayContext.Provider>
        </BrowseContext.Provider>
      </FoldContext.Provider>
    </StyleContext.Provider>
  )
}

/**
 * One of the two rules that separate the three blocks (tui.md §6). Sized to the
 * terminal exactly: a longer string would wrap and silently eat rows.
 */
function Hairline() {
  const style = useStyle()
  const dimensions = useTerminalDimensions()
  return (
    <text fg={style.theme.hairline} height={1} flexShrink={0}>
      {style.glyphs.hairline.repeat(Math.max(0, dimensions().width))}
    </text>
  )
}
