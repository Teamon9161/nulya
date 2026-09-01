/**
 * The driver: idle → sending → stepping → idle.
 *
 * It owns the `session step --stream` subprocess and nothing else. Deciding
 * *why* or *how long* an agent should keep going is a driver-script or agent
 * concern, never the TUI's — so there is no goal loop here, no
 * retry policy, and no automatic continuation past a spent step budget.
 *
 * A step is started by itself in exactly one situation, spelled two ways: there
 * is something in the inbox that only a step boundary can drain. Inside a run
 * that is the user speaking while the run was
 * ending; at rest it is `wake()` (a background task finished, or another
 * process appended). Both are mechanical — an event exists and nobody else will
 * pick it up — and neither ever steps on an empty inbox.
 */
import { createSignal, type Accessor } from "solid-js"
import { noteCrash } from "../crashlog.ts"
import { wrapMidTask } from "../midtask.ts"
import {
  sessionAppend,
  sessionCancel,
  sessionStep,
  type GateRequest,
  type GateVerdict,
  type StepHandle,
  type StepLine,
  type ImageInput,
} from "../nulya/cli.ts"
import { inboxPending } from "../nulya/files.ts"
import type { Workspace } from "../nulya/bin.ts"
import type { SessionState } from "./session.ts"

export type DriverStatus = "idle" | "sending" | "stepping" | "canceling"

export interface Driver {
  status: Accessor<DriverStatus>
  /**
   * When the current run began (`Date.now`), or null while idle.
   *
   * The one thing a person wants from a spinner is whether it is still worth
   * waiting for, and only the thing that starts the run knows when that was.
   * It is a clock, not state: nothing branches on it, the running line reads it
   * to say `12s`.
   */
  startedAt: Accessor<number | null>
  /**
   * Append a user turn, and start a step unless one is already running.
   *
   * `framed` says the text already carries its own explanation of how it got
   * here (`approvalnote.ts`), so the mid-task wrapper must not be put around it
   * a second time — two sentinels for one turn is one card the transcript
   * cannot fold and one contract too many for the model to read.
   */
  send(text: string, framed?: boolean, images?: readonly ImageInput[]): Promise<void>
  /** Run a step now (used to continue after a spent budget). */
  step(): Promise<void>
  /**
   * Step IF the session's inbox has something in it — the whole wake-up policy
   * (goals/background.md D8).
   *
   * A background task that finished deposits its report into the inbox and the
   * kernel drains it at the next step boundary; without somebody starting that
   * step the report sits on disk and the model never hears about the thing it
   * asked for. Deciding when to continue is a driver's job, never the kernel's
   * (physics #8), and this is that decision in one line.
   *
   * The condition is the INBOX, not "a task finished". Finishing is only one of
   * the ways the inbox becomes non-empty — a `session append` from another
   * terminal and an `ext activate` are two more — and stepping on an EMPTY inbox
   * is the thing that must never happen: a bare step re-sends the last assistant
   * turn as a prefill, which is not a continuation, it is a lie
   * about who spoke last.
   */
  wake(): Promise<void>
  /** Esc: ask the kernel to stop at its next step boundary. */
  cancel(): Promise<void>
  /** Ctrl+C twice: kill the step process; the kernel repairs the tail next open. */
  kill(): void
  /**
   * Interrupt-and-deliver (goals/agent-runner.md ar-t1): append `text`, then — if a step is
   * actually running — kill it and re-step the moment it has actually exited,
   * rather than waiting for it to reach its own next boundary or for some
   * idle-poll timer to notice the inbox is non-empty.
   *
   * At rest this is exactly `send`: there is nothing to interrupt, so the turn
   * just starts a step as usual. `text` may be empty — that is the "nothing
   * new to say, just stop waiting for the current step to get around to what
   * is already queued" gesture (a click on the queue lane), and it still
   * forces the kill-and-immediate-restep when a step is running.
   */
  interruptAndDeliver(text: string, framed?: boolean, images?: readonly ImageInput[]): Promise<void>
  dispose(): void
}

export interface DriverOptions {
  maxSteps?: number
  /**
   * The effort to run the NEXT step with, read at each spawn so `/effort` mid-
   * session takes hold at the next step boundary. Undefined = kernel default.
   */
  effort?: () => string | undefined
  /** Extra child environment (tests set NULYA_SCRIPTED_MODE here). */
  env?: Record<string, string>
  /** Test seam for fencing the otherwise real append process at scheduler boundaries. */
  append?: typeof sessionAppend
  /** A fresh copy of the transient SSH password for each spawned step. */
  sshPassword?: (session: string) => Uint8Array | undefined
  /**
   * The session already has a writer: this process is not the driver after all.
   * The kernel is the authority on that (`SessionBusy`), so the
   * role is not guessed here — it is reported when a step is refused.
   */
  onBusy?: () => void
  /**
   * Resolves once the session's existing tail has been replayed into `state`.
   * A step started before that would land its events first and the replay
   * would then be dropped as "already seen" — so the first send waits.
   */
  ready?: Promise<void>
  /**
   * Answer the kernel's per-call gate (`--gate`). Read at every
   * spawn, not captured once, so a mode switched between two steps takes hold
   * on the next one — and a switch mid-batch reaches the very next request,
   * because each request is a fresh call into this.
   *
   * Undefined runs the step ungated, which is what an observer's non-existent
   * step process does anyway.
   *
   * The session id rides along because the answer may have to be shown against
   * the right transcript: a TUI can be driving one session while looking at
   * another, and the call being asked about belongs to exactly one of them.
   */
  gate?: (request: GateRequest, session: string) => Promise<GateVerdict>
  /**
   * A pure OBSERVER of everything this step prints — `--stream` lines and
   * ledger events alike, in arrival order, after `state` has been told
   * (tui-plugin U3, `api.observe`). The kernel's own `StepContext.observer` is
   * the precedent for the shape and for the discipline: it may not decide
   * anything, and a throw in it must not reach the step.
   *
   * The session id rides along because one process drives several tabs, and a
   * plugin watching "the plan being written" has to know which session wrote
   * it.
   */
  onLine?: (line: StepLine, session: string) => void
}

/**
 * A driver-side failure: the message on screen, the stack in the crash log.
 *
 * The message alone is what made BUGS.md #22 hard to read — "output.startsWith
 * is not a function" says nothing about where it came from.
 */
export function reportFailure(state: SessionState, source: string, error: unknown): void {
  noteCrash(source, error)
  state.setError(error instanceof Error ? error.message : String(error))
}

/** Preserve the structured run error while adding the provider's stderr detail. */
export function stepExitError(runError: string | null, code: number, stderr: string): string {
  const detail = stderr.trim()
  if (runError) return detail.length > 0 ? `${runError}\n${detail}` : runError
  return detail.length > 0 ? `step exited ${code}: ${detail}` : `step exited ${code}`
}

/** The kernel's refusal to hand over the writer lease, on the `--stream` wire. */
function isBusy(line: { kind: string; line?: { stream?: string; event?: string; message?: unknown } }): boolean {
  if (line.kind !== "stream") return false
  const stream = line.line
  if (!stream || stream.stream !== "run" || stream.event !== "error") return false
  return typeof stream.message === "string" && stream.message.includes("SessionBusy")
}

function isRunError(line: { kind: string; line?: { stream?: string; event?: string } }): boolean {
  return line.kind === "stream" && line.line?.stream === "run" && line.line?.event === "error"
}

export function createDriver(
  ws: Workspace,
  id: string,
  state: SessionState,
  options: DriverOptions = {},
): Driver {
  const [status, setStatusRaw] = createSignal<DriverStatus>("idle")
  const [startedAt, setStartedAt] = createSignal<number | null>(null)
  /**
   * Every status change goes through here so the clock cannot drift from the
   * state it dates: idle clears it, and the first step out of idle starts it —
   * `sending` into `stepping` is one run, not two.
   */
  const setStatus = (next: DriverStatus) => {
    if (next === "idle") setStartedAt(null)
    else if (startedAt() === null) setStartedAt(Date.now())
    setStatusRaw(next)
  }
  let handle: StepHandle | null = null
  let disposed = false
  // `drive()` must never run twice at once: two `session step` processes on
  // one session means the second is refused with `SessionBusy`, which would
  // read as "somebody else is driving" — a lie about the world caused by us.
  let driving = false
  // Set by `kill()`, so a non-zero exit after Ctrl+C is not reported as a
  // crash: the user asked for exactly that.
  let killed = false
  // Whether the run in flight already received a mid-task message with the
  // interrupt contract attached: later ones carry the sentinel alone
  // (midtask.ts). Reset when the run ends — the next run explains itself anew.
  let noted = false
  // Resolved once, in `drive()`'s own `finally`, the moment `driving` goes
  // back to false — i.e. the step process has actually exited and the status
  // is genuinely idle again. `interruptAndDeliver` is the one caller that
  // needs to know this precisely (ar-t1): re-stepping before it is true would
  // either spawn a second `session step` against the lease the dying one still
  // holds, or (worse) race `step()`'s own `status() !== "idle"` guard.
  let idleWaiters: Array<() => void> = []
  // `session append` is a separate process. Serialize those processes so two
  // Enter presses can never acquire timestamped inbox names in reverse order.
  let appendTail: Promise<void> = Promise.resolve()
  function appendInOrder(text: string, images: readonly ImageInput[]): Promise<void> {
    const next = appendTail.then(() => (options.append ?? sessionAppend)(ws, id, text, images))
    appendTail = next.catch(() => {})
    return next
  }
  async function drainAppends(): Promise<void> {
    for (;;) {
      const tail = appendTail
      await tail
      if (appendTail === tail) return
    }
  }
  function idleOnce(): Promise<void> {
    if (!driving) return Promise.resolve()
    return new Promise((resolve) => idleWaiters.push(resolve))
  }

  async function drive(): Promise<void> {
    if (disposed || driving) return
    driving = true
    setStatus("stepping")
    try {
      await options.ready
      // Re-step only while the queue is actually shrinking: a pending turn that
      // survives a whole step is a real problem to surface, not to spin on.
      for (;;) {
        if (disposed) return
        const pendingBefore = state.pendingCount()
        const step = sessionStep(ws, id, {
          maxSteps: options.maxSteps,
          effort: options.effort?.(),
          env: options.env,
          sshPassword: options.sshPassword?.(id),
          ...(options.gate ? { gate: (request: GateRequest) => options.gate!(request, id) } : {}),
        })
        handle = step
        killed = false
        let busy = false
        let reported = false
        let code = 0
        try {
          for await (const line of step.lines) {
            // A refused lease is a role fact, not an error to paint red: the
            // caller flips to observer and the queued turn stays queued — the
            // other writer drains the inbox at its own step boundary.
            if (isBusy(line)) {
              busy = true
              continue
            }
            if (isRunError(line)) reported = true
            if (line.kind === "stream") state.applyStream(line.line)
            else state.applyEvent(line.event)
            // After the transcript, never before it: an observer sees what is
            // already on screen, so it can never be the reason something is.
            // A throw here is the observer's problem alone — a plugin must not
            // be able to stop a step by mis-reading its output (D10).
            try {
              options.onLine?.(line, id)
            } catch {
              // The host already reports what its own callbacks did; nothing
              // here is worth risking the step for.
            }
          }
          code = await step.exited
        } catch (error) {
          // The reader failed, not the kernel: do not leave a step running with
          // nobody draining its stdout — a full pipe would stall it while it
          // holds the writer lease.
          step.kill()
          throw error
        } finally {
          handle = null
        }
        if (busy) {
          options.onBusy?.()
          return
        }
        // The structured line names the failure class; provider diagnostics
        // remain on stderr because they can contain the response body. Keep
        // both in the transcript. A crash has only stderr, while a killed step
        // is the one non-zero exit the user asked for.
        if (code !== 0 && !killed) {
          const stderr = await step.stderr
          state.setError(stepExitError(reported ? state.snapshot.error : null, code, stderr))
        }
        if (disposed || killed) return
        const pendingAfter = state.pendingCount()
        if (pendingAfter === 0 || pendingAfter >= pendingBefore) break
      }
    } catch (error) {
      reportFailure(state, "driver", error)
    } finally {
      driving = false
      noted = false
      if (!disposed) setStatus("idle")
      const waiters = idleWaiters
      idleWaiters = []
      for (const resolve of waiters) resolve()
    }
  }

  // Named rather than object-literal methods, so `interruptAndDeliver` below
  // can call `send`/`kill`/`step` directly instead of reaching for `this` on
  // an object that has not finished being built yet.
  async function send(text: string, framed = false, images: readonly ImageInput[] = []): Promise<void> {
    const trimmed = text.trim()
    if (trimmed.length === 0 && images.length === 0) return
    // A step in flight means the model is mid-task, and a bare user turn
    // after tool results reads like a stop signal — so the turn carries its
    // own framing (midtask.ts). "sending" is not mid-task: that run has not
    // started yet, the turn just joins its opening batch unwrapped. The
    // contract rides once per run; later messages carry the tag alone.
    const midTask = !framed && (status() === "stepping" || status() === "canceling")
    const wire = midTask ? wrapMidTask(trimmed, !noted) : trimmed
    if (midTask) noted = true
    state.setError(null)
    const localId = state.enqueueUser(wire, images.length)
    // Anything but idle means a step is running or about to: the turn is
    // appended and the run in flight (or the one the earlier send is about to
    // start) drains it at its next step boundary. Starting a second `drive()`
    // here would spawn a second step process against the same session.
    const running = status() !== "idle"
    if (!running) setStatus("sending")
    try {
      await appendInOrder(wire, images)
    } catch (error) {
      state.rejectUser(localId)
      reportFailure(state, "driver", error)
      if (running) return
      // This send owns the opening batch, not merely its own append. A later
      // send may still be queued behind this failed one, so keep `sending`
      // truthful until the append tail is stable and let the durable inbox
      // decide whether the batch still needs a step.
      await drainAppends()
      if (inboxPending(ws, id)) await drive()
      else setStatus("idle")
      return
    }
    // Mid-run appends are not interruptions: the kernel drains the inbox at
    // its next step boundary, so the turn joins the run itself.
    if (running) return
    // Drain to a stable tail, not merely the tail visible after this append:
    // another send may join while we await a queued append. The final identity
    // check and drive()'s synchronous `stepping` transition are one JS turn, so
    // every send admitted during `sending` lands in this opening user turn.
    await drainAppends()
    await drive()
  }

  async function step(): Promise<void> {
    if (status() !== "idle") return
    state.setError(null)
    await drive()
  }

  async function wake(): Promise<void> {
    if (disposed || driving || status() !== "idle") return
    if (!inboxPending(ws, id)) return
    await drive()
  }

  async function cancel(): Promise<void> {
    if (status() !== "stepping") return
    setStatus("canceling")
    try {
      await sessionCancel(ws, id)
    } catch (error) {
      reportFailure(state, "driver", error)
    }
    // The kernel consumes the marker at the step boundary; `drive()` returns
    // to idle when the run ends, so no status is forced here.
    if (status() === "canceling") setStatus("stepping")
  }

  function kill(): void {
    if (!handle) return
    killed = true
    handle.kill()
  }

  /**
   * ar-t1's whole gesture, in three existing verbs: append, kill, step — no new
   * state machine, just the order they run in.
   *
   * At rest (`status() === "idle"`) there is no step to interrupt, so this
   * degrades to an ordinary `send`; blank text at rest is the queue lane's
   * "deliver what is already queued" click landing after the step ended, and
   * that is exactly `wake` — inbox non-empty steps now instead of waiting for
   * the idle-poll timer, inbox empty stays a no-op (a bare step against an
   * empty inbox would re-send the last assistant turn as prefill).
   * Otherwise: append now (mirroring `send`'s queued-append path exactly, so
   * the transcript's `queued` marker behaves the same as any other mid-run
   * message), kill whatever step is running, wait for `drive()` to actually
   * finish (not just for the kill signal to be sent), and start a fresh step
   * the instant that is true — never the idle-poll timer, because there isn't
   * one here to wait for.
   *
   * Blank `text` is deliberately allowed through past the `send` no-op: it is
   * the "nothing new to say, just stop waiting and deliver what is already
   * queued" gesture (the queue lane's own click), and it still has to kill and
   * re-step when a step is running.
   */
  async function interruptAndDeliver(text: string, framed = false, images: readonly ImageInput[] = []): Promise<void> {
    const trimmed = text.trim()
    if (status() === "idle") {
      if (trimmed.length === 0 && images.length === 0) {
        await wake()
        return
      }
      await send(trimmed, framed, images)
      return
    }
    if (trimmed.length > 0 || images.length > 0) await send(trimmed, framed, images)
    kill()
    await idleOnce()
    if (disposed) return
    await step()
  }

  return {
    status,
    startedAt,
    send,
    step,
    wake,
    cancel,
    interruptAndDeliver,
    kill,
    dispose() {
      disposed = true
      handle?.kill()
    },
  }
}
