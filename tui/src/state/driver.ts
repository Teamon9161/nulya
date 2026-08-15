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
  /** Extra child environment (tests set NULYA_SCRIPTED_MODE here). */
  env?: Record<string, string>
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

  async function drive(): Promise<void> {
    if (disposed) return
    setStatus("stepping")
    try {
      // Re-step only while the queue is actually shrinking: a pending turn that
      // survives a whole step is a real problem to surface, not to spin on.
      for (;;) {
        const pendingBefore = state.pendingCount()
        const step = sessionStep(ws, id, { maxSteps: options.maxSteps, env: options.env })
        handle = step
        try {
          for await (const line of step.lines) {
            if (line.kind === "stream") state.applyStream(line.line)
            else state.applyEvent(line.event)
          }
          await step.exited
        } finally {
          handle = null
        }
        if (disposed) return
        const pendingAfter = state.pendingCount()
        if (pendingAfter === 0 || pendingAfter >= pendingBefore) break
      }
    } catch (error) {
      state.setError(error instanceof Error ? error.message : String(error))
    } finally {
      if (!disposed) setStatus("idle")
    }
  }

  return {
    status,
    async send(text) {
      const trimmed = text.trim()
      if (trimmed.length === 0) return
      state.enqueueUser(trimmed)
      const running = status() === "stepping"
      if (!running) setStatus("sending")
      try {
        await sessionAppend(ws, id, trimmed)
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
      if (status() === "stepping") return
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
      handle?.kill()
    },
    dispose() {
      disposed = true
      handle?.kill()
    },
  }
}
