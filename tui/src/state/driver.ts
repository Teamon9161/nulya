/**
 * The driver: idle → sending → stepping → idle.
 *
 * It owns the `session step --stream` subprocess and nothing else. Deciding
 * *why* or *how long* an agent should keep going is a driver-script or agent
 * concern (PLAN §3.6), never the TUI's — so there is no goal loop here, no
 * retry policy, and no automatic continuation past a spent step budget. The one
 * automatic re-step is the mechanical case tui.md §4.3 calls for: the user
 * spoke while a run was ending, so their turn is still queued in the inbox.
 */
import { createSignal, type Accessor } from "solid-js"
import { wrapMidTask } from "../midtask.ts"
import { sessionAppend, sessionCancel, sessionStep, type StepHandle } from "../nulya/cli.ts"
import type { Workspace } from "../nulya/bin.ts"
import type { SessionState } from "./session.ts"

export type DriverStatus = "idle" | "sending" | "stepping" | "canceling"

export interface Driver {
  status: Accessor<DriverStatus>
  /** Append a user turn, and start a step unless one is already running. */
  send(text: string): Promise<void>
  /** Run a step now (used to continue after a spent budget). */
  step(): Promise<void>
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
  const [status, setStatus] = createSignal<DriverStatus>("idle")
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
        const step = sessionStep(ws, id, { maxSteps: options.maxSteps, effort: options.effort?.(), env: options.env })
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
    async send(text) {
      const trimmed = text.trim()
      if (trimmed.length === 0) return
      // A step in flight means the model is mid-task, and a bare user turn
      // after tool results reads like a stop signal — so the turn carries its
      // own framing (midtask.ts). "sending" is not mid-task: that run has not
      // started yet, the turn just joins its opening batch unwrapped. The
      // contract rides once per run; later messages carry the tag alone.
      const midTask = status() === "stepping" || status() === "canceling"
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
