/**
 * Walking into a workspace: the start-up flow's state machine, without a screen.
 *
 * The checkout questions — the workspace extension store's trust
 * question and the `.nulya/agents` one — run once per DIRECTORY, as tabs walk
 * into them, rather than once per launch: several tabs can be walking into
 * different directories at once, and the three facts a
 * concurrent version needs are the three things in this file:
 *
 *  - a directory's answer has a `pending` (there is no answer YET, because the
 *    question is on screen) that is neither "yes" nor "no",
 *  - a directory's start-up runs at most once, and "once" means driven to an
 *    answer rather than merely begun,
 *  - two questions that arrive together are a QUEUE, not one slot the second
 *    one takes from the first.
 *
 * Everything here is pure or a plain signal, so the machine is answerable
 * without a terminal and the answers a test gets are the answers the screen
 * gets.
 */
import { createSignal, type Accessor } from "solid-js"
import type { AgentLayer } from "../agents.ts"

/**
 * What this process knows about the agent definitions a DIRECTORY holds.
 *
 * `pending` is the state a boolean could not express and the reason this type
 * exists: a workspace whose question is still on screen — or one whose question
 * was thrown away by another workspace's — has no answer, and reading that as
 * "trusted" is what let a definition that arrived with a checkout start a
 * session before anybody had said it could. Nothing turns `pending` into
 * `trusted` except an answer.
 */
export type WorkspaceTrust = "pending" | "trusted" | "denied"

/** What starting one definition may do: run, or say which of the two refusals it is. */
export type AgentStart = "allow" | "pending" | "denied"

/**
 * May this definition be started here?
 *
 * The gate is only about what arrived with a CHECKOUT: a definition in
 * `~/.nulya/agents` or one the binary ships got there because somebody put it
 * there, and no directory's answer has anything to say about it. For a
 * workspace one, only `trusted` is a yes — the two refusals are handed back
 * separately because they need different sentences (one points at a question on
 * screen, the other at an answer already given).
 */
export function agentStart(layer: AgentLayer, trust: WorkspaceTrust): AgentStart {
  if (layer !== "workspace") return "allow"
  return trust === "trusted" ? "allow" : trust
}

/**
 * What a directory's definitions are once its start-up flow has got that far.
 *
 * One reading of `planProjectAgents`'s three kinds, used by both paths into the
 * answer — the flow that never had to ask, and the flow whose question was just
 * answered — so the two cannot decide differently. `ready` is a machine that
 * already recorded the trust; `ask` is worth exactly what was answered; `none`
 * is the two cases with nothing to grant — a checkout with no definitions, and
 * one that was asked about before and is not being asked again.
 */
export function trustAfter(plan: "none" | "ready" | "ask", answered: boolean | null): WorkspaceTrust {
  if (plan === "ready") return "trusted"
  if (plan !== "ask") return "denied"
  if (answered === null) return "pending"
  return answered ? "trusted" : "denied"
}

/**
 * Questions waiting for a person, one at a time.
 *
 * The head is what is on screen; answering it lets the next one up. A single
 * slot — which is what a lone signal is — loses every question but the last,
 * and the ones it loses are the ones nobody will be asked about again.
 */
export interface AskQueue<Q> {
  /** The question on screen, or null when there is none. */
  head: Accessor<Q | null>
  /** Everything still in line, head first. */
  all: Accessor<readonly Q[]>
  /**
   * Put a question in line. The promise settles when that question LEAVES the
   * queue, so the flow that asked it can wait for its own answer and not for
   * somebody else's.
   */
  push(question: Q): Promise<void>
  /** The head has been answered: it leaves, its asker is released, the next appears. */
  settleHead(): void
}

export function createAskQueue<Q>(): AskQueue<Q> {
  interface Waiting {
    question: Q
    release: () => void
  }
  const [queue, setQueue] = createSignal<readonly Waiting[]>([])
  return {
    head: () => queue()[0]?.question ?? null,
    all: () => queue().map((one) => one.question),
    push: (question) =>
      new Promise<void>((resolve) => setQueue((now) => [...now, { question, release: resolve }])),
    settleHead: () => {
      const going = queue()[0]
      if (!going) return
      setQueue((now) => now.slice(1))
      going.release()
    },
  }
}

/**
 * Drive a per-directory flow at most once, where ONCE MEANS TO AN ANSWER.
 *
 * The entry is the in-flight run, not a mark that one started. That distinction
 * is the whole point: a flow that is still waiting for a keypress has not
 * decided anything, and a second tab walking into the same directory must join
 * that run rather than either starting a second one or being told it already
 * happened.
 *
 * IF THE FLOW THROWS, THE ENTRY GOES. A run that failed reached no answer, and
 * leaving a mark behind would make a directory that could not be asked about
 * look like one that had been — permanently, for the life of the process. The
 * next tab into it drives it again. The promise still resolves rather than
 * rejecting: every caller fires this with `void`, and a directory that would
 * not answer is not a reason to take the screen down.
 */
export interface EntryOnce {
  enter(dir: string, work: () => Promise<void>): Promise<void>
  /** Has this directory's flow reached an answer (or is it reaching one now)? */
  driven(dir: string): boolean
}

export function createEntryOnce(already: Iterable<string> = []): EntryOnce {
  const running = new Map<string, Promise<void>>()
  for (const dir of already) running.set(dir, Promise.resolve())
  return {
    driven: (dir) => running.has(dir),
    enter(dir, work) {
      const joined = running.get(dir)
      if (joined) return joined
      const run = work().catch(() => {
        running.delete(dir)
      })
      running.set(dir, run)
      return run
    },
  }
}
