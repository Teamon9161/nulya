import { createEffect, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/solid"
import { Transcript } from "./Transcript.tsx"
import { Composer, type ComposerApi } from "./Composer.tsx"
import { StatusBar } from "./StatusBar.tsx"
import { StyleContext, useStyle, type Style } from "../render/theme.ts"
import { FoldContext, createFoldStore } from "../state/folds.ts"
import { BrowseContext, createBrowseStore } from "../state/browse.ts"
import { createDriver, type DriverOptions } from "../state/driver.ts"
import { sessionEvents } from "../nulya/cli.ts"
import { readActiveContributions, readHeader, type Contributions } from "../nulya/files.ts"
import { createKeymap, matches } from "../keymap.ts"
import type { SessionState, TranscriptItem } from "../state/session.ts"
import type { Workspace } from "../nulya/bin.ts"

export interface AppProps {
  ws: Workspace
  id: string
  state: SessionState
  style: Style
  driver?: DriverOptions
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
  const keys = createKeymap(props.style.settings)
  const driver = createDriver(props.ws, props.id, props.state, props.driver ?? {})

  const [notice, setNotice] = createSignal<string | null>(null)
  const [spinnerTick, setSpinnerTick] = createSignal(0)
  const [ctrlCArmed, setCtrlCArmed] = createSignal(false)
  const [contributions, setContributions] = createSignal<Contributions[]>([])
  const [allOpen, setAllOpen] = createSignal(false)
  let composer: ComposerApi | null = null

  onMount(async () => {
    const header = await readHeader(props.ws, props.id)
    props.state.setHeader(header)
    // The FROZEN versions, not the store's `current`: what this session runs was
    // decided at `session new` and cannot move (DESIGN §7.5).
    if (header) setContributions(await readActiveContributions(props.ws, header.composition.active))
    // Replay before anything else can stream in: `--session <id>` must paint the
    // same picture the live session left behind (tui.md §3).
    try {
      props.state.applyEvents(await sessionEvents(props.ws, props.id))
    } catch (error) {
      props.state.setError(error instanceof Error ? error.message : String(error))
    }
  })

  createEffect(() => {
    if (!props.style.motion) return
    if (driver.status() === "idle") return
    const timer = setInterval(() => setSpinnerTick((tick) => tick + 1), 90)
    onCleanup(() => clearInterval(timer))
  })

  onCleanup(() => driver.dispose())

  const spinnerFrame = () => props.style.spinner[spinnerTick() % props.style.spinner.length]!

  const lastFoldable = () => {
    const cards = foldable(props.state.snapshot.items)
    return cards.length > 0 ? cards[cards.length - 1]! : null
  }

  const enterBrowse = () => {
    const cards = foldable(props.state.snapshot.items)
    if (cards.length === 0) return
    composer?.blur()
    browse.enter(cards[cards.length - 1]!.key)
    setNotice("browse · j/k move · Enter fold · Esc back")
  }

  const leaveBrowse = () => {
    browse.exit()
    composer?.focus()
    setNotice(null)
  }

  const moveBrowse = (delta: number) => {
    const cards = foldable(props.state.snapshot.items)
    if (cards.length === 0) return
    const at = cards.findIndex((item) => item.key === browse.selected())
    const next = Math.min(Math.max((at < 0 ? cards.length - 1 : at) + delta, 0), cards.length - 1)
    browse.select(cards[next]!.key)
  }

  const toggleSelected = () => {
    const key = browse.selected()
    if (key) folds.toggle(key, false)
  }

  const quit = () => {
    driver.dispose()
    renderer.destroy()
    process.exit(0)
  }

  const runCommand = (raw: string): boolean => {
    if (!raw.startsWith("/")) return false
    const command = raw.trim().split(/\s+/)[0]
    if (command === "/quit") {
      quit()
      return true
    }
    if (command === "/cancel") {
      void driver.cancel()
      return true
    }
    if (command === "/step") {
      void driver.step()
      return true
    }
    if (command === "/fold") {
      folds.setAll(false)
      setAllOpen(false)
      return true
    }
    if (command === "/help") {
      setNotice(
        "Enter send · Shift+Enter newline · Esc cancel/browse · Ctrl+O fold · Ctrl+C twice quit · /step /cancel /fold /quit",
      )
      return true
    }
    // Unknown slash commands are the model's business, not ours (tui.md §4.4).
    return false
  }

  const submit = (text: string) => {
    setNotice(null)
    if (runCommand(text)) return
    void driver.send(text)
  }

  useKeyboard((key) => {
    if (browse.active()) {
      // The composer is blurred while browsing, so these keys are ours alone.
      if (matches(keys.cancel, key)) {
        leaveBrowse()
        return
      }
      if (key.name === "j" || key.name === "down") return moveBrowse(1)
      if (key.name === "k" || key.name === "up") return moveBrowse(-1)
      if (key.name === "return" || key.name === "space") return toggleSelected()
    }
    if (matches(keys.cancel, key)) {
      if (driver.status() === "stepping") {
        void driver.cancel()
        return
      }
      // Nothing to stop and nothing typed: Esc means "go read" (tui.md §4.2).
      if (composer?.isEmpty() ?? true) enterBrowse()
      return
    }
    if (matches(keys.fold, key)) {
      const item = browse.active() ? null : lastFoldable()
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
      if (driver.status() === "stepping" && !ctrlCArmed()) {
        driver.kill()
        setCtrlCArmed(true)
        setNotice("step killed · Ctrl+C again to quit")
        return
      }
      quit()
    }
  })

  const header = () => {
    const snapshot = props.state.snapshot
    const identity = snapshot.header?.model_identity
    const model = identity && identity.model.length > 0 ? `${identity.provider}/${identity.model}` : (snapshot.header?.model ?? "…")
    const native = snapshot.header?.composition.native_tools.length ?? 0
    const skills = contributions().reduce((count, entry) => count + entry.skills.length, 0)
    return `nulya · ${props.id} · ${model} · tools 2+${native} · skills ${skills}`
  }

  return (
    <StyleContext.Provider value={props.style}>
      <FoldContext.Provider value={folds}>
        <BrowseContext.Provider value={browse}>
          <box flexDirection="column" width="100%" height="100%">
            <box flexDirection="row" width="100%" height={1} flexShrink={0} paddingLeft={1} paddingRight={1}>
              <text fg={props.style.theme.dim}>{header()}</text>
            </box>
            <Hairline />

            <Transcript
              items={props.state.snapshot.items}
              header={props.state.snapshot.header}
              contributions={contributions()}
            />

            <Hairline />
            <Composer onSubmit={submit} onReady={(api) => (composer = api)} />
            <Hairline />
            <StatusBar
              snapshot={props.state.snapshot}
              status={driver.status()}
              spinnerFrame={spinnerFrame()}
              hint={notice() ?? undefined}
            />
          </box>
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
