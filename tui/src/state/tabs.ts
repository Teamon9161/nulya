/**
 * Open sessions, one per tab — and, before the first message, one tab that is
 * not a session at all (tui.md §11, T22).
 *
 * A tab is a session plus its attachment (tui.md §5.5). The second tab exists
 * for one reason: the agent drove another session from inside a step, and you
 * want to watch it. That session already has a writer — the parent's shell — so
 * the new tab attaches as an observer by construction; nothing here has to force
 * it, the lease decides (`state/attach.ts`).
 *
 * The DRAFT tab is the answer to a different problem. Composition freezes at
 * `session new` (physics #2), so a session created the moment the screen opens
 * has already decided its tools, its pins and its model — before the person has
 * touched anything. Everything they then do in `/ext` or `/model` either lands
 * on the *next* session or has to be papered over by silently replacing an empty
 * one. A draft carries what `session new` will be told and creates nothing until
 * there is something to say; `materialize` is the single moment that turns it
 * into a session, and it happens at the first message.
 */
import { createSignal, type Accessor } from "solid-js"
import { createSessionState, type SessionState } from "./session.ts"
import { createAttachment, type AttachOptions, type Attachment } from "./attach.ts"
import { createTaskWatch, type TaskWatch } from "./tasks.ts"
import { sessionPins, type ModelPick } from "./tui_state.ts"
import { discardIfUntouched, readActiveContributions, readHeader, type Contributions } from "../nulya/files.ts"
import { sessionEvents, sessionNew } from "../nulya/cli.ts"
import { withOptions, type WithRef } from "../evolve.ts"
import type { Workspace } from "../nulya/bin.ts"

interface TabCommon {
  /**
   * Tab identity for the store's own bookkeeping. A session tab's key IS its
   * id; a draft has no id, so it gets a minted one — and `replace` therefore
   * takes a key rather than an id, which is the whole reason this exists.
   */
  key: string
  /**
   * The reasoning effort this tab's steps run with (`session step --effort`).
   * Per tab, not per session file: it is a generation option the driver
   * chooses each step, never part of the frozen identity (DESIGN §3).
   * Undefined = whatever the kernel defaults to for the session's model.
   */
  effort: Accessor<string | undefined>
  setEffort(effort: string | undefined): void
}

/**
 * A tab with no session behind it: nothing on disk, nothing in `/sessions`,
 * nothing frozen. It holds exactly what `session new` needs — which model, and
 * which built package to wear — and the pins are deliberately NOT here: they
 * are read from `tui-state.json` at materialize time, so a `/ext` toggle made
 * one second before the first message is carried by that very session.
 */
export interface DraftTab extends TabCommon {
  kind: "draft"
  pick: Accessor<ModelPick | undefined>
  setPick(pick: ModelPick | undefined): void
  /** `--with <id>@<version>`: what `/evolve` and `/as` put on the session. */
  bring: Accessor<WithRef | undefined>
  setBring(ref: WithRef | undefined): void
}

export interface SessionTab extends TabCommon {
  kind: "session"
  id: string
  state: SessionState
  attach: Attachment
  /**
   * The background tasks this session has, re-read on a beat (tui.md §5.9).
   * Per tab because a task belongs to a session and outlives every step of it —
   * and because the interval has to stop when the tab does.
   */
  tasks: TaskWatch
  contributions: Accessor<Contributions[]>
  /**
   * This process ran `session new` for it. Only such a session is un-created
   * again when it closes without ever having recorded anything
   * (`files.discardIfUntouched`); one opened by id, or somebody else's, is
   * never touched.
   */
  created: boolean
}

export type Tab = DraftTab | SessionTab

export interface OpenOptions {
  created?: boolean
  effort?: string
}

/** What the screen adds to a `session new` beyond the draft's own choices. */
export interface SessionExtras {
  /** `--with <id>[@<version>]`: composition membership, not a pin. */
  with?: readonly string[]
  /** `--pin ext:<id>/<tool>`: a native slot on the model's tool face. */
  pin?: readonly string[]
}

export interface DraftOptions {
  pick?: ModelPick
  bring?: WithRef
  effort?: string
}

export type FirstTab =
  | { kind: "session"; id: string; state: SessionState; created?: boolean; effort?: string }
  | ({ kind: "draft" } & DraftOptions)

export interface TabStore {
  tabs: Accessor<Tab[]>
  active: Accessor<Tab>
  activeIndex: Accessor<number>
  /** Focus the tab for `id`, opening one if it is not already open. */
  open(id: string, options?: OpenOptions): SessionTab
  /** A new tab with no session behind it yet. */
  draft(options?: DraftOptions): DraftTab
  /**
   * Turn a draft into a session: `session new` with the draft's model, its
   * `--with` member and the pin list as it stands on disk right now, then the
   * session tab takes the draft's place. Throws the kernel's own refusal (no
   * credential, an untrusted store, a pin naming nothing) so the caller can show
   * that sentence and leave the draft where it is.
   *
   * `extra` is whatever the SCREEN decided this session should also carry — the
   * `handoff` package, today (tui.md §5.8). It arrives as an argument rather
   * than as tab state because it is a policy the caller owns and may not have
   * resolved (a build) until this very moment.
   */
  materialize(draft: DraftTab, extra?: SessionExtras): Promise<SessionTab>
  /**
   * Open `id` in place of the tab keyed `oldKey`: same position, the old
   * attachment released (and the old session un-created if this process made it
   * and it is still empty).
   */
  replace(oldKey: string, id: string, options?: OpenOptions): SessionTab
  select(index: number): void
  next(): void
  /** Close a tab and its attachment; the last remaining tab never closes. */
  close(key: string): void
  disposeAll(): void
}

/**
 * Load what a freshly opened session needs: the frozen header, what its frozen
 * extension versions contribute, and the whole event tail. Replay comes first so
 * that `--session <id>` paints what the live session left behind (tui.md §3).
 */
async function hydrate(
  ws: Workspace,
  id: string,
  state: SessionState,
  setContributions: (value: Contributions[]) => void,
): Promise<void> {
  const header = await readHeader(ws, id)
  state.setHeader(header)
  // The FROZEN versions, not the store's `current`: what this session runs was
  // decided at `session new` and cannot move (DESIGN §7.5).
  if (header) setContributions(await readActiveContributions(ws, header.composition.active))
  try {
    state.applyEvents(await sessionEvents(ws, id))
  } catch (error) {
    state.setError(error instanceof Error ? error.message : String(error))
  }
}

export interface TabStoreOptions extends AttachOptions {
  /** Where `session_pins` is remembered; tests point it elsewhere. */
  statePath?: string
}

export function createTabStore(ws: Workspace, first: FirstTab, options: TabStoreOptions = {}): TabStore {
  const [tabs, setTabs] = createSignal<Tab[]>([])
  const [activeIndex, setActiveIndex] = createSignal(0)
  const { statePath, ...attachOptions } = options
  let nextDraft = 1

  function makeDraft(opened: DraftOptions): DraftTab {
    const [pick, setPick] = createSignal<ModelPick | undefined>(opened.pick)
    const [bring, setBring] = createSignal<WithRef | undefined>(opened.bring)
    const [effort, setEffort] = createSignal<string | undefined>(opened.effort ?? opened.pick?.effort)
    return {
      kind: "draft",
      key: `draft-${nextDraft++}`,
      pick,
      setPick: (value) => setPick(() => value),
      bring,
      setBring: (value) => setBring(() => value),
      effort,
      setEffort,
    }
  }

  function makeTab(id: string, state: SessionState, opened: OpenOptions): SessionTab {
    const [contributions, setContributions] = createSignal<Contributions[]>([])
    const [effort, setEffort] = createSignal<string | undefined>(opened.effort)
    // The attachment exists immediately (so the lease probe and the follower
    // start at once), but its first step waits for the replay: events from a
    // step that ran first would make the tail look "already seen" and the
    // history would be dropped on arrival.
    let settle!: () => void
    const ready = new Promise<void>((resolve) => (settle = resolve))
    const tab: SessionTab = {
      kind: "session",
      key: id,
      id,
      state,
      // `driven`: a session this process created is ours to wake from the first
      // probe; one merely opened here (a sub-session, `/sessions`) is not, until
      // someone drives it from this tab (attach.ts).
      attach: createAttachment(ws, id, state, { ...attachOptions, ready, effort, driven: opened.created ?? false }),
      tasks: createTaskWatch(ws, id, { ...(attachOptions.env ? { env: attachOptions.env } : {}) }),
      contributions,
      effort,
      setEffort,
      created: opened.created ?? false,
    }
    void hydrate(ws, id, state, setContributions).then(settle, settle)
    return tab
  }

  /** Let go of a tab: stop its attachment, and un-create it if it never held anything. */
  function release(tab: Tab) {
    if (tab.kind !== "session") return // a draft is nothing on disk; there is nothing to let go of
    tab.attach.dispose()
    tab.tasks.dispose()
    if (tab.created) discardIfUntouched(ws, tab.id)
  }

  setTabs([
    first.kind === "draft"
      ? makeDraft(first)
      : makeTab(first.id, first.state, { created: first.created, effort: first.effort }),
  ])

  function open(id: string, opened: OpenOptions = {}): SessionTab {
    const at = tabs().findIndex((tab) => tab.kind === "session" && tab.id === id)
    if (at >= 0) {
      setActiveIndex(at)
      return tabs()[at] as SessionTab
    }
    const tab = makeTab(id, createSessionState(id), opened)
    setTabs([...tabs(), tab])
    setActiveIndex(tabs().length - 1)
    return tab
  }

  function replace(oldKey: string, id: string, opened: OpenOptions = {}): SessionTab {
    const list = tabs()
    const at = list.findIndex((tab) => tab.key === oldKey)
    if (at < 0) return open(id, opened)
    const existing = list.findIndex((tab) => tab.kind === "session" && tab.id === id)
    if (existing >= 0) {
      setActiveIndex(existing)
      return list[existing] as SessionTab
    }
    release(list[at]!)
    const tab = makeTab(id, createSessionState(id), opened)
    setTabs(list.map((old, index) => (index === at ? tab : old)))
    setActiveIndex(at)
    return tab
  }

  return {
    tabs,
    activeIndex,
    active: () => tabs()[Math.min(activeIndex(), tabs().length - 1)]!,
    open,
    replace,
    draft(opened = {}) {
      const tab = makeDraft(opened)
      setTabs([...tabs(), tab])
      setActiveIndex(tabs().length - 1)
      return tab
    },
    async materialize(draft, extra = {}) {
      const pick = draft.pick()
      const bring = draft.bring()
      // Read at the moment the session is created rather than held in a signal:
      // the pins are program state on disk, and a second TUI (or a `/ext` toggle
      // a second ago) must be the truth here, not whatever this process saw when
      // the draft was opened.
      const pins = [...sessionPins(statePath)]
      for (const pin of extra.pin ?? []) if (!pins.includes(pin)) pins.push(pin)
      const members = [...(bring ? withOptions(bring).with ?? [] : []), ...(extra.with ?? [])]
      const id = await sessionNew(ws, {
        ...(pick ? { profile: pick.profile, model: pick.model } : {}),
        ...(members.length > 0 ? { with: members } : {}),
        ...(pins.length > 0 ? { pin: pins } : {}),
      })
      return replace(draft.key, id, { created: true, effort: draft.effort() })
    },
    select(index) {
      if (index >= 0 && index < tabs().length) setActiveIndex(index)
    },
    next() {
      if (tabs().length > 1) setActiveIndex((activeIndex() + 1) % tabs().length)
    },
    close(key) {
      const list = tabs()
      if (list.length <= 1) return
      const at = list.findIndex((tab) => tab.key === key)
      if (at < 0) return
      release(list[at]!)
      setTabs(list.filter((_, index) => index !== at))
      setActiveIndex(Math.max(0, Math.min(activeIndex(), tabs().length - 1)))
    },
    disposeAll() {
      for (const tab of tabs()) release(tab)
    },
  }
}
