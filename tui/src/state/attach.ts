/**
 * Attaching to one session — as its driver, or as an observer.
 *
 * A durable session has exactly one writer, enforced by an exclusive advisory
 * lease on `<id>.lock` (DESIGN §3.4). So "am I driving this?" is not a mode the
 * TUI chooses; it is a fact about the world, and this module's whole job is to
 * keep the screen honest about it (tui.md §5.6):
 *
 *   driver   — we own the `session step --stream` subprocess. Deltas, tools and
 *              ledger lines all arrive on its stdout.
 *   observer — somebody else holds the lease (a driver script, another TUI, a
 *              parent session's shell). We never spawn a step; we tail the
 *              ledger with `session events --follow` and may still `append`,
 *              which lands in the inbox for the other writer's next step
 *              boundary. Granularity drops from delta to event: deltas exist
 *              only on the driver's stdout, and inventing a second source for
 *              them would need a kernel change we are not making (tui.md §10.4).
 *
 * Two independent signals decide the role, and neither is a guess:
 *   1. the lease probe (`files.probeWriterLease`), polled while idle — on
 *      platforms where it can see the lock at all;
 *   2. the kernel's own `SessionBusy` when a step is refused — authoritative
 *      everywhere, which is why the probe is allowed to answer "unknown".
 */
import { createSignal, type Accessor } from "solid-js"
import { sessionAppend, sessionCancel, sessionFollow, type FollowHandle } from "../nulya/cli.ts"
import { probeWriterLease } from "../nulya/files.ts"
import { createDriver, type Driver, type DriverOptions, type DriverStatus } from "./driver.ts"
import type { Workspace } from "../nulya/bin.ts"
import type { SessionState } from "./session.ts"

export type Role = "driver" | "observer"

export interface Attachment {
  role: Accessor<Role>
  status: Accessor<DriverStatus>
  /** The lease has looked free for a while: `Enter` would take over. */
  takeoverReady: Accessor<boolean>
  send(text: string): Promise<void>
  step(): Promise<void>
  cancel(): Promise<void>
  kill(): void
  /** Stop observing and try to drive again (tui.md §5.6, "press ↵ to take over"). */
  takeOver(): void
  dispose(): void
}

export interface AttachOptions extends DriverOptions {
  /** How often the writer lease is probed while we are not stepping. */
  pollMs?: number
  /**
   * Consecutive free probes before take-over is offered. A driver script that
   * loops `session step` drops the lease between steps, so a single free probe
   * means nothing — it just means we looked between two of its steps.
   */
  freeProbesToOffer?: number
}

export function createAttachment(
  ws: Workspace,
  id: string,
  state: SessionState,
  options: AttachOptions = {},
): Attachment {
  const pollMs = options.pollMs ?? 700
  const needed = options.freeProbesToOffer ?? 3

  const [role, setRole] = createSignal<Role>("driver")
  const [takeoverReady, setTakeoverReady] = createSignal(false)
  const [sending, setSending] = createSignal(false)

  let follow: FollowHandle | null = null
  let freeProbes = 0
  let disposed = false

  const driver: Driver = createDriver(ws, id, state, {
    ...options,
    onBusy: () => becomeObserver(),
  })

  function becomeObserver() {
    if (disposed) return
    setRole("observer")
    setTakeoverReady(false)
    freeProbes = 0
    startFollow()
  }

  function startFollow() {
    if (follow || disposed) return
    const handle = sessionFollow(ws, id, state.lastSeq())
    follow = handle
    void (async () => {
      try {
        for await (const event of handle.events) {
          if (disposed || follow !== handle) return
          // Idempotent by seq, so a `--since` off by one costs nothing.
          state.applyEvent(event)
        }
      } catch {
        // The follower is a convenience, never a source of truth: if the tail
        // process dies the next poll starts another one.
      } finally {
        if (follow === handle) follow = null
      }
    })()
  }

  function stopFollow() {
    follow?.stop()
    follow = null
  }

  const timer = setInterval(() => {
    if (disposed) return
    // While our own step runs WE hold the lease; probing would only tell us so.
    if (driver.status() === "stepping" || driver.status() === "canceling") return
    const lease = probeWriterLease(ws, id)
    if (lease === "held") {
      freeProbes = 0
      setTakeoverReady(false)
      if (role() === "driver") becomeObserver()
      else startFollow()
      return
    }
    if (lease === "free" && role() === "observer") {
      freeProbes += 1
      if (freeProbes >= needed) setTakeoverReady(true)
    }
  }, pollMs)

  return {
    role,
    takeoverReady,
    status: () => (role() === "observer" ? (sending() ? "sending" : "idle") : driver.status()),
    async send(text) {
      const trimmed = text.trim()
      if (trimmed.length === 0) return
      if (role() === "driver") {
        await driver.send(trimmed)
        return
      }
      // Observer: append only. The turn is deposited in the inbox and the other
      // writer drains it at its next step boundary (DESIGN §3.4) — we must not
      // start a step of our own, and we could not if we tried.
      state.enqueueUser(trimmed)
      setSending(true)
      try {
        await sessionAppend(ws, id, trimmed)
      } catch (error) {
        state.setError(error instanceof Error ? error.message : String(error))
      } finally {
        setSending(false)
      }
    },
    async step() {
      if (role() === "observer") return
      await driver.step()
    },
    async cancel() {
      // Cancellation is a kernel semantic, not a process one: the marker is
      // consumed at a step boundary by whoever holds the lease (physics #7), so
      // an observer may ask for it too — it just is not our step that stops.
      if (role() === "driver") {
        await driver.cancel()
        return
      }
      try {
        await sessionCancel(ws, id)
      } catch (error) {
        state.setError(error instanceof Error ? error.message : String(error))
      }
    },
    kill() {
      driver.kill()
    },
    takeOver() {
      stopFollow()
      freeProbes = 0
      setTakeoverReady(false)
      setRole("driver")
      // A turn we queued as observer is still in the inbox if the other writer
      // left before draining it. Taking over is the user saying "drive", and the
      // one mechanical re-step tui.md §4.3 allows is exactly this case: our own
      // pending turn, nobody else to drain it.
      if (state.pendingCount() > 0) void driver.step()
    },
    dispose() {
      disposed = true
      clearInterval(timer)
      stopFollow()
      driver.dispose()
    },
  }
}
