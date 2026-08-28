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
import { reportFailure } from "./driver.ts"
import { createTaskWatch, type TaskWatch } from "./tasks.ts"
import { sessionPins, type ModelPick } from "./tui_state.ts"
import { discardIfUntouched, readActiveContributions, readHeader, type Contributions } from "../nulya/files.ts"
import { sessionEvents, sessionNew } from "../nulya/cli.ts"
import { withOptions, type WithRef } from "../with.ts"
import { sameWorkspace } from "../workspaces.ts"
import { createPaneStore, main_surface, type PaneStore } from "./panes.ts"
import type { Workspace } from "../nulya/bin.ts"

interface TabCommon {
  /**
   * Tab identity for the store's own bookkeeping. A session tab's key IS its
   * id; a draft has no id, so it gets a minted one — and `replace` therefore
   * takes a key rather than an id, which is the whole reason this exists.
   */
  key: string
  /**
   * The directory this tab works in (goals/tui-shell.md §5.3b).
   *
   * A TAB IS (WORKSPACE, SESSION). The kernel has always said a session belongs
   * to the directory it was created in — `.nulya/sessions/`, `.nulya/scratch/`,
   * the journals and the workspace extension store are all relative to it — and
   * `Workspace` has always been an explicit argument to every CLI call
   * (`nulya/cli.ts`). S1c only moved where that argument comes from: it was the
   * process, and it is now this field. Every spawn a tab makes runs with it.
   *
   * It never changes for a SESSION tab: the session's file is in that
   * directory, and pointing the same tab at another one would be a session that
   * moved house. A draft can be re-pointed until the moment it becomes a
   * session, which is exactly what the directory browser does.
   */
  ws: Workspace
  /**
   * This tab's own pane tree — the content area, split however this tab has it
   * (goals/tui-shell.md §5.3c point 1, T72).
   *
   * Beside `ws` because it is the same kind of fact: something the whole screen
   * used to hold once, which turned out to belong to a tab. Switching tabs
   * therefore switches trees, and a tab that was watching a delegation is still
   * watching it when you come back. What is ACROSS tabs — the sidebar — stays
   * in the app's own tree, so neither tree needs a mark saying which leaves
   * follow the front tab.
   */
  panes: PaneStore
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
  /** `--with <id>@<version>`: what `/evolve` and `/with` put on the session. */
  bring: Accessor<WithRef | undefined>
  setBring(ref: WithRef | undefined): void
}

/**
 * A session this tab is WATCHING rather than having: a delegation followed in a
 * pane of its own (goals/tui-shell.md §5.3c, T72).
 *
 * The same machinery a tab gets — state, attachment, task watch, replayed
 * header — minus the strip. It is made through the same private factory a tab
 * is, so "how this front end attaches to a session" has one implementation:
 * the observer role is not chosen here either, it is what the lease says
 * (`state/attach.ts`), and `driven: false` is exactly what a tab opened on
 * somebody else's session already passes.
 */
export interface SubView {
  /** The leaf in this tab's tree that draws it. The view is keyed by it. */
  pane: string
  id: string
  /**
   * What the delegation calls itself (`d-…`), when the card that opened this
   * knew it. The pane says this rather than the local session id, because it
   * is the name the person was just reading (goals/agent-runner.md D2).
   */
  label?: string
  ws: Workspace
  state: SessionState
  attach: Attachment
  tasks: TaskWatch
  contributions: Accessor<Contributions[]>
}

export interface SessionTab extends TabCommon {
  kind: "session"
  id: string
  state: SessionState
  attach: Attachment
  /** The delegations this tab has open in panes of its own (T72). */
  subs: Accessor<SubView[]>
  /**
   * Follow `id` in the pane `pane`. Idempotent per pane; a session already
   * being watched in this tab is returned rather than attached twice, because
   * two followers of one ledger is two `events --follow` processes saying the
   * same thing.
   */
  watch(pane: string, id: string, label?: string): SubView
  /** Stop following whatever `pane` held. Unknown panes are ignored. */
  unwatch(pane: string): void
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
  /** Which directory this session lives in; the store's default when absent. */
  ws?: Workspace
  /**
   * `session step --max-steps` for this tab's steps. Per tab because it is a
   * per-run budget the kernel clamps (`session.max_steps_ceiling`), not part of
   * the frozen identity — and because a sub-agent tab is the first thing that
   * wants one while the tab beside it does not (`agents.ts`).
   */
  maxSteps?: number
}

/** What the screen adds to a `session new` beyond the draft's own choices. */
export interface SessionExtras {
  /** `--with <id>[@<version>]`: composition membership, not a pin. */
  with?: readonly string[]
  /** `--pin ext:<id>/<tool>`: a native slot on the model's tool face. */
  pin?: readonly string[]
  /**
   * `--bare`: ignore the config's standing `[extensions] with` and
   * `pinned_native_tools`, composing from these flags alone (DESIGN §14). A
   * sub-agent tab is what wants it, and it comes from the agent package's own
   * `render` rather than being decided here (`agents.ts`).
   */
  bare?: boolean
  /**
   * `--prompt <file>`: a file whose bytes become this session's own system
   * prompt, frozen into its header. Nothing is installed — a sub-agent persona
   * is what wants this (`agents.ts`).
   */
  prompt?: readonly string[]
  /** The step budget the resulting tab drives with (`OpenOptions.maxSteps`). */
  maxSteps?: number
}

export interface DraftOptions {
  pick?: ModelPick
  bring?: WithRef
  effort?: string
  /**
   * Which directory the session this draft becomes will live in. Absent means
   * the store's default — the workspace the process was launched in — which is
   * what `+` and a bare `/new` want on the very first tab.
   */
  ws?: Workspace
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
  /**
   * Point a DRAFT tab at another directory (goals/tui-shell.md §5.3b).
   *
   * Only a draft, and that is the invariant rather than a restriction: a
   * session's file lives in one directory, so re-pointing a started tab would
   * be a session that moved house. A draft is nothing on disk until
   * `materialize`, which is exactly why it is the thing the browser edits.
   *
   * It replaces the tab OBJECT rather than mutating a field, because `ws` is
   * read all over the screen through `tabs.active()` — a mutated field would
   * change what every one of those reads returns without telling any of them.
   * The draft's own signals (its pick, its `--with`, its effort) are carried
   * across by identity: the accessors are the same functions, so nothing that
   * was chosen for this draft is lost by moving it.
   */
  retarget(key: string, ws: Workspace): void
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
    reportFailure(state, "tabs", error)
  }
}

export interface TabStoreOptions extends AttachOptions {
  /** Where `session_pins` is remembered; tests point it elsewhere. */
  statePath?: string
}

/**
 * `home` is the workspace a tab gets when nobody names one: the directory the
 * process was launched in. Every tab still carries its own (`TabCommon.ws`) —
 * this is the default, not a global.
 */
export function createTabStore(home: Workspace, first: FirstTab, options: TabStoreOptions = {}): TabStore {
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
      ws: opened.ws ?? home,
      panes: createPaneStore(main_surface),
      pick,
      setPick: (value) => setPick(() => value),
      bring,
      setBring: (value) => setBring(() => value),
      effort,
      setEffort,
    }
  }

  function makeTab(id: string, state: SessionState, opened: OpenOptions): SessionTab {
    const ws = opened.ws ?? home
    const [contributions, setContributions] = createSignal<Contributions[]>([])
    const [effort, setEffort] = createSignal<string | undefined>(opened.effort)
    const [subs, setSubs] = createSignal<SubView[]>([])
    // The attachment exists immediately (so the lease probe and the follower
    // start at once), but its first step waits for the replay: events from a
    // step that ran first would make the tail look "already seen" and the
    // history would be dropped on arrival.
    let settle!: () => void
    const ready = new Promise<void>((resolve) => (settle = resolve))
    const tab: SessionTab = {
      kind: "session",
      key: id,
      ws,
      panes: createPaneStore(main_surface),
      id,
      state,
      subs,
      watch(pane, watched, label) {
        const already = subs().find((sub) => sub.pane === pane)
        if (already) return already
        const sub = makeSub(ws, pane, watched, label)
        setSubs([...subs(), sub])
        return sub
      },
      unwatch(pane) {
        const going = subs().find((sub) => sub.pane === pane)
        if (!going) return
        setSubs(subs().filter((sub) => sub !== going))
        releaseSub(going)
      },
      // `driven`: a session this process created is ours to wake from the first
      // probe; one merely opened here (a sub-session, `/sessions`) is not, until
      // someone drives it from this tab (attach.ts).
      attach: createAttachment(ws, id, state, {
        ...attachOptions,
        ...(opened.maxSteps !== undefined ? { maxSteps: opened.maxSteps } : {}),
        ready,
        effort,
        driven: opened.created ?? false,
      }),
      tasks: createTaskWatch(ws, id, { ...(attachOptions.env ? { env: attachOptions.env } : {}) }),
      contributions,
      effort,
      setEffort,
      created: opened.created ?? false,
    }
    void hydrate(ws, id, state, setContributions).then(settle, settle)
    return tab
  }

  /**
   * A delegation followed in one of this tab's panes (T72).
   *
   * `driven: false` is not a policy this makes up — it is what every session
   * opened here rather than created here already passes, and the reason a
   * delegation's pane observes: the sub-session's writer is the background task
   * driving it, so the lease decides and this never spawns a step of its own
   * (`state/attach.ts`, tui.md §5.6). Nothing here is created on disk, so
   * letting go is only detaching.
   */
  function makeSub(ws: Workspace, pane: string, id: string, label?: string): SubView {
    const state = createSessionState(id)
    const [contributions, setContributions] = createSignal<Contributions[]>([])
    let settle!: () => void
    const ready = new Promise<void>((resolve) => (settle = resolve))
    const sub: SubView = {
      pane,
      id,
      ...(label ? { label } : {}),
      ws,
      state,
      attach: createAttachment(ws, id, state, { ...attachOptions, ready, driven: false }),
      tasks: createTaskWatch(ws, id, { ...(attachOptions.env ? { env: attachOptions.env } : {}) }),
      contributions,
    }
    void hydrate(ws, id, state, setContributions).then(settle, settle)
    return sub
  }

  function releaseSub(sub: SubView) {
    sub.attach.dispose()
    sub.tasks.dispose()
  }

  /** Let go of a tab: stop its attachment, and un-create it if it never held anything. */
  function release(tab: Tab) {
    if (tab.kind !== "session") return // a draft is nothing on disk; there is nothing to let go of
    // Panes go with the tab that owns them: a delegation was never watched
    // anywhere else, so closing the conversation closes the window onto it
    // (§5.3c point 4).
    for (const sub of tab.subs()) releaseSub(sub)
    tab.attach.dispose()
    tab.tasks.dispose()
    // The tab's OWN workspace: the session file is in that directory and
    // nowhere else, so a discard aimed at the process's launch directory would
    // either miss or, worse, name somebody else's file.
    if (tab.created) discardIfUntouched(tab.ws, tab.id)
  }

  setTabs([
    first.kind === "draft"
      ? makeDraft(first)
      : makeTab(first.id, first.state, { created: first.created, effort: first.effort }),
  ])

  /**
   * Is this tab already the session `id` in the workspace `opened` names?
   *
   * Both halves, because a tab is a pair now: two directories are two stores of
   * sessions, and the answer to "is it already open" is only the same answer
   * when it is the same file. (Two ids colliding across workspaces is not the
   * case this guards — `s-<hash>` makes that vanishingly unlikely — it is that
   * asking about only one half of a pair is how the wrong tab gets focused.)
   */
  const isOpenHere = (tab: Tab, id: string, opened: OpenOptions) =>
    tab.kind === "session" && tab.id === id && sameWorkspace(tab.ws, opened.ws ?? home)

  function open(id: string, opened: OpenOptions = {}): SessionTab {
    const at = tabs().findIndex((tab) => isOpenHere(tab, id, opened))
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
    const existing = list.findIndex((tab) => isOpenHere(tab, id, opened))
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
      // The DRAFT's workspace, which is the one the browser may have re-pointed
      // it at a moment ago. This is the line that makes a tab's directory real:
      // `session new` runs with that cwd, so the file, the journals and the
      // scratch all land there and the session belongs to it from birth.
      const id = await sessionNew(draft.ws, {
        ...(pick ? { profile: pick.profile, model: pick.model } : {}),
        ...(members.length > 0 ? { with: members } : {}),
        ...(pins.length > 0 ? { pin: pins } : {}),
        ...((extra.prompt?.length ?? 0) > 0 ? { prompt: extra.prompt } : {}),
      })
      return replace(draft.key, id, {
        created: true,
        ws: draft.ws,
        effort: draft.effort(),
        ...(extra.maxSteps !== undefined ? { maxSteps: extra.maxSteps } : {}),
      })
    },
    retarget(key, where) {
      const list = tabs()
      const at = list.findIndex((one) => one.key === key)
      const found = list[at]
      if (!found || found.kind !== "draft") return
      setTabs(list.map((old, index) => (index === at ? { ...old, ws: where } : old)))
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
