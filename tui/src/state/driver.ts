/**
 * The driver: idle → sending → stepping → idle.
 *
 * It owns the `session step --stream` subprocess and nothing else. Deciding
 * *why* or *how long* an agent should keep going is a driver-script or agent
 * concern (PLAN §3.6), never the TUI's — so there is no goal loop here, no
 * retry policy, and no automatic continuation past a spent step budget.
 *
 * A step is started by itself in exactly one situation, spelled two ways: there
 * is something in the inbox that only a step boundary can drain. Inside a run
 * that is the case tui.md §4.3 calls for (the user spoke while the run was
 * ending); at rest it is `wake()` (a background task finished, or another
 * process appended). Both are mechanical — an event exists and nobody else will
 * pick it up — and neither ever steps on an empty inbox.
 */
import { createSignal, type Accessor } from "solid-js"
import { wrapMidTask } from "../midtask.ts"
import {
  sessionAppend,
  sessionCancel,
  sessionStep,
  type GateRequest,
  type GateVerdict,
  type StepHandle,
} from "../nulya/cli.ts"
import { inboxPending } from "../nulya/files.ts"
import type { Workspace } from "../nulya/bin.ts"
import type { SessionState } from "./session.ts"

export type DriverStatus = "idle" | "sending" | "stepping" | "canceling"

export interface Driver {
  status: Accessor<DriverStatus>
  /**
   * When the current run began (`Date.now()`), or null while idle (T38).
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
  send(text: string, framed?: boolean): Promise<void>
  /** Run a step now (used to continue after a spent budget). */
  step(): Promise<void>
  /**
   * Step IF the session's inbox has something in it — the whole wake-up policy
   * (tui.md §5.9, goals/background.md D8).
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
   * turn as a prefill (DESIGN §4), which is not a continuation, it is a lie
   * about who spoke last.
   */
  wake(): Promise<void>
  /** Esc: ask the kernel to stop at its next step boundary. */
  cancel(): Promise<void>
  /** Ctrl+C twice: kill the step process; the kernel repairs the tail next open. */
  kill(): void
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
  /**
   * The session already has a writer: this process is not the driver after all.
   * The kernel is the authority on that (`SessionBusy`, DESIGN §3.4), so the
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
   * Answer the kernel's per-call gate (`--gate`, DESIGN §14). Read at every
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
        // The kernel reports every diagnostic it knows about as a `run error`
        // line (DESIGN §14). Anything else that ends the process non-zero — an
        // unexpected Zig error, a crash — only exists on stderr; a killed step
        // is the one non-zero exit the user asked for.
        if (code !== 0 && !reported && !killed) {
          const stderr = (await step.stderr).trim().split("\n")[0] ?? ""
          state.setError(stderr.length > 0 ? `step exited ${code}: ${stderr}` : `step exited ${code}`)
        }
        if (disposed || killed) return
        const pendingAfter = state.pendingCount()
        if (pendingAfter === 0 || pendingAfter >= pendingBefore) break
      }
    } catch (error) {
      state.setError(error instanceof Error ? error.message : String(error))
    } finally {
      driving = false
      noted = false
      if (!disposed) setStatus("idle")
    }
  }

  return {
    status,
    startedAt,
    async send(text, framed = false) {
      const trimmed = text.trim()
      if (trimmed.length === 0) return
      // A step in flight means the model is mid-task, and a bare user turn
      // after tool results reads like a stop signal — so the turn carries its
      // own framing (midtask.ts). "sending" is not mid-task: that run has not
      // started yet, the turn just joins its opening batch unwrapped. The
      // contract rides once per run; later messages carry the tag alone.
      const midTask = !framed && (status() === "stepping" || status() === "canceling")
      const wire = midTask ? wrapMidTask(trimmed, !noted) : trimmed
      if (midTask) noted = true
      state.enqueueUser(wire)
      // Anything but idle means a step is running or about to: the turn is
      // appended and the run in flight (or the one the earlier send is about to
      // start) drains it at its next step boundary. Starting a second `drive()`
      // here would spawn a second step process against the same session.
      const running = status() !== "idle"
      if (!running) setStatus("sending")
      try {
        await sessionAppend(ws, id, wire)
      } catch (error) {
        state.setError(error instanceof Error ? error.message : String(error))
        if (!running) setStatus("idle")
        return
      }
      // Mid-run appends are not interruptions: the kernel drains the inbox at
      // its next step boundary (DESIGN §3.4), so the turn joins the run itself.
      if (running) return
      await drive()
    },
    async step() {
      if (status() !== "idle") return
      await drive()
    },
    async wake() {
      if (disposed || driving || status() !== "idle") return
      if (!inboxPending(ws, id)) return
      await drive()
    },
    async cancel() {
      if (status() !== "stepping") return
      setStatus("canceling")
      try {
        await sessionCancel(ws, id)
      } catch (error) {
        state.setError(error instanceof Error ? error.message : String(error))
      }
      // The kernel consumes the marker at the step boundary; `drive()` returns
      // to idle when the run ends, so no status is forced here.
      if (status() === "canceling") setStatus("stepping")
    },
    kill() {
      if (!handle) return
      killed = true
      handle.kill()
    },
    dispose() {
      disposed = true
      handle?.kill()
    },
  }
}
