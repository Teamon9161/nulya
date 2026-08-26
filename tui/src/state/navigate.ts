/**
 * Opening a session in a tab, from a card (T43).
 *
 * A transcript card is handed one item and nothing else — which is right, and
 * is why replay and the live stream draw the same thing. But a delegation card
 * names a session that EXISTS, and "take me there" is the one thing a person
 * wants from it that no amount of text on the card can provide.
 *
 * So: one seam, the same shape as the fold store and the tasks projection — a
 * context with a default that does nothing, so a card in a test needs no
 * provider and a card in a screen without tabs simply has no link. It carries
 * the front end's own verb (`tabs.open`), not a new power: `Enter` in browse
 * mode has opened a sub-session since T3, and this is that move with something
 * on screen to click.
 */
import { createContext, useContext } from "solid-js"
import type { DelegationRecord } from "../nulya/files.ts"

export interface Navigate {
  /** Open this session in a tab of its own, and put it in front. */
  openSession(id: string): void
  /**
   * The delegation record for one `d-…` id, when this front end can read it —
   * null for a stale id, an unreadable record, or a test with no workspace
   * behind `Navigate` (goals/agent-runner.md ar-t2). `SubSessionCard`'s
   * fallback for a follow-up receipt, whose text never repeats the remote
   * conversation a delegation opened (`sendTurn`'s reply only names the
   * delegation and the task it started).
   */
  delegationRecord(id: string): Promise<DelegationRecord | null>
  /**
   * Bring the tasks panel to front — the only place to watch a delegation
   * whose runner is not `nulya`: there is no local session for such a one, so
   * there is nothing a tab could open (ar-t2).
   */
  openTasks(): void
}

export const NavigateContext = createContext<Navigate>()

/** Null when nothing is listening — then a card draws no link at all. */
export function useNavigate(): Navigate | null {
  return useContext(NavigateContext) ?? null
}
