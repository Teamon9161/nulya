/**
 * Open sessions, one per tab.
 *
 * A tab is a session plus its attachment (tui.md §5.5). The second tab exists
 * for one reason: the agent drove another session from inside a step, and you
 * want to watch it. That session already has a writer — the parent's shell — so
 * the new tab attaches as an observer by construction; nothing here has to force
 * it, the lease decides (`state/attach.ts`).
 */
import { createSignal, type Accessor } from "solid-js"
import { createSessionState, type SessionState } from "./session.ts"
import { createAttachment, type AttachOptions, type Attachment } from "./attach.ts"
import { discardIfUntouched, readActiveContributions, readHeader, type Contributions } from "../nulya/files.ts"
import { sessionEvents } from "../nulya/cli.ts"
import type { Workspace } from "../nulya/bin.ts"

export interface SessionTab {
  id: string
  state: SessionState
  attach: Attachment
  contributions: Accessor<Contributions[]>
  /**
   * This process ran `session new` for it. Only such a session is un-created
   * again when it closes without ever having recorded anything
   * (`files.discardIfUntouched`); one opened by id, or somebody else's, is
   * never touched.
   */
  created: boolean
}

export interface TabStore {
  tabs: Accessor<SessionTab[]>
  active: Accessor<SessionTab>
  activeIndex: Accessor<number>
  /** Focus the tab for `id`, opening one if it is not already open. */
  open(id: string, options?: { created?: boolean }): SessionTab
  select(index: number): void
  next(): void
  /** Close a tab and its attachment; the last remaining tab never closes. */
  close(id: string): void
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

export function createTabStore(
  ws: Workspace,
  first: { id: string; state: SessionState; created?: boolean },
  options: AttachOptions = {},
): TabStore {
  const [tabs, setTabs] = createSignal<SessionTab[]>([])
  const [activeIndex, setActiveIndex] = createSignal(0)

  function makeTab(id: string, state: SessionState, created: boolean): SessionTab {
    const [contributions, setContributions] = createSignal<Contributions[]>([])
    // The attachment exists immediately (so the lease probe and the follower
    // start at once), but its first step waits for the replay: events from a
    // step that ran first would make the tail look "already seen" and the
    // history would be dropped on arrival.
    let settle!: () => void
    const ready = new Promise<void>((resolve) => (settle = resolve))
    const tab: SessionTab = {
      id,
      state,
      attach: createAttachment(ws, id, state, { ...options, ready }),
      contributions,
      created,
    }
    void hydrate(ws, id, state, setContributions).then(settle, settle)
    return tab
  }

  /** Let go of a tab: stop its attachment, and un-create it if it never held anything. */
  function release(tab: SessionTab) {
    tab.attach.dispose()
    if (tab.created) discardIfUntouched(ws, tab.id)
  }

  setTabs([makeTab(first.id, first.state, first.created ?? false)])

  return {
    tabs,
    activeIndex,
    active: () => tabs()[Math.min(activeIndex(), tabs().length - 1)]!,
    open(id, opened = {}) {
      const at = tabs().findIndex((tab) => tab.id === id)
      if (at >= 0) {
        setActiveIndex(at)
        return tabs()[at]!
      }
      const tab = makeTab(id, createSessionState(id), opened.created ?? false)
      setTabs([...tabs(), tab])
      setActiveIndex(tabs().length - 1)
      return tab
    },
    select(index) {
      if (index >= 0 && index < tabs().length) setActiveIndex(index)
    },
    next() {
      if (tabs().length > 1) setActiveIndex((activeIndex() + 1) % tabs().length)
    },
    close(id) {
      const list = tabs()
      if (list.length <= 1) return
      const at = list.findIndex((tab) => tab.id === id)
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
