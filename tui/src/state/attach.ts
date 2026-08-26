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
import { wrapMidTask } from "../midtask.ts"
import { sessionAppend, sessionCancel, sessionFollow, type FollowHandle } from "../nulya/cli.ts"
import { probeWriterLease } from "../nulya/files.ts"
import { createDriver, type Driver, type DriverOptions, type DriverStatus } from "./driver.ts"
import type { Workspace } from "../nulya/bin.ts"
import type { SessionState } from "./session.ts"

export type Role = "driver" | "observer"

export interface Attachment {
  role: Accessor<Role>
  status: Accessor<DriverStatus>
  /** When whatever is running started, or null (`Driver.startedAt`, T38). */
  startedAt: Accessor<number | null>
  /** The lease has looked free for a while: `Enter` would take over. */
  takeoverReady: Accessor<boolean>
  /** `framed`: the text already carries its own framing (`Driver.send`). */
  send(text: string, framed?: boolean): Promise<void>
  step(): Promise<void>
  cancel(): Promise<void>
  kill(): void
  /**
   * Ctrl+J (goals/agent-runner.md ar-t1). As a driver this is exactly
   * `Driver.interruptAndDeliver` — append, kill the running step, re-step the
   * moment it has actually exited. As an OBSERVER there is no writer lease of
   * ours to kill, so the gesture degrades to the same queued `send` the
   * composer already does while observing: the append lands in the inbox and
   * the other writer drains it at its own next step boundary.
   */
  interruptAndDeliver(text: string, framed?: boolean): Promise<void>
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
  /**
   * This process is already this session's driver when the attachment is made
   * (it ran `session new` for it). Lets `wake()` act from the first probe; a
   * session merely OPENED here earns that only once someone drives it from this
   * tab — see `driven` below.
   */
  driven?: boolean
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
  /** An observer's own clock: how long its append has been queued for. */
  const [queuedAt, setQueuedAt] = createSignal<number | null>(null)

  let follow: FollowHandle | null = null
  let freeProbes = 0
  let disposed = false
  // Has THIS process driven this session — created it, or sent / stepped /
  // taken over from this tab? The wake-up below is the one step nobody asked
  // for, so it is allowed only where we are the established driver. A tab merely
  // opened on a session (a SubSessionCard's `Enter`, `/sessions`) starts as
  // "driver" by default, and until the first probe says otherwise it has no way
  // of knowing that a parent's shell or a driver script is between two steps of
  // its own — with the inbox non-empty (the other driver's `task wait --any` just
  // returned) that is exactly the instant it would step, and the other driver's
  // next `session step` would be refused `SessionBusy`. Explicit acts (a
  // message, ↵ take-over) are the user saying "drive"; this flag remembers that.
  let driven = options.driven ?? false

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
          // An observer tab sees ledger events and no deltas — the granularity
          // the role has (§5.6) — but it sees them, so a plugin watching a
          // session somebody else drives is not watching a blank screen.
          try {
            options.onLine?.({ kind: "event", event }, id)
          } catch {
            // A follower is a convenience; nothing in it may stop the tail.
          }
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
      return
    }
    // The driver's wake-up (tui.md §5.9): something is in the inbox and only a
    // step boundary drains it. On THIS timer rather than one of its own — it is
    // the same "what has the world done while we sat still" beat the lease probe
    // already runs, and a second timer would only be a second thing to stop.
    //
    // An observer never gets here, and must not: the other writer drains that
    // inbox at its own next step, and two writers is the one thing a durable
    // session refuses (DESIGN §3.4).
    if (role() === "driver" && driven) void driver.wake()
  }, pollMs)

  // Named rather than object-literal methods, so `interruptAndDeliver` below
  // can call `send` directly instead of a second copy of the observer's
  // append path.
  async function send(text: string, framed = false): Promise<void> {
    const trimmed = text.trim()
    if (trimmed.length === 0) return
    if (role() === "driver") {
      driven = true
      await driver.send(trimmed, framed)
      return
    }
    // Observer: append only. The turn is deposited in the inbox and the other
    // writer drains it at its next step boundary (DESIGN §3.4) — we must not
    // start a step of our own, and we could not if we tried. When the probe
    // can see that writer actually holding the lease, its run is in flight
    // and the turn carries the mid-task framing (midtask.ts); "free" and
    // "unknown" claim nothing, so they wrap nothing.
    const wire = !framed && probeWriterLease(ws, id) === "held" ? wrapMidTask(trimmed) : trimmed
    state.enqueueUser(wire)
    setSending(true)
    setQueuedAt(Date.now())
    try {
      await sessionAppend(ws, id, wire)
    } catch (error) {
      state.setError(error instanceof Error ? error.message : String(error))
    } finally {
      setSending(false)
      setQueuedAt(null)
    }
  }

  async function step(): Promise<void> {
    if (role() === "observer") return
    driven = true
    await driver.step()
  }

  async function cancel(): Promise<void> {
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
  }

  function kill(): void {
    driver.kill()
  }

  /**
   * ar-t1's gesture, at this layer: a driver has a real step and a real lease
   * to kill, so it is exactly `Driver.interruptAndDeliver`. An observer has
   * neither — `driver` here has never been stepped and killing it would be
   * killing nothing — so the honest degradation is the same queued append
   * `send` already does while observing (D3): the message joins the inbox and
   * whoever actually holds the lease drains it at its own next boundary.
   */
  async function interruptAndDeliver(text: string, framed = false): Promise<void> {
    if (role() === "driver") {
      driven = true
      await driver.interruptAndDeliver(text, framed)
      return
    }
    await send(text, framed)
  }

  function takeOver(): void {
    stopFollow()
    freeProbes = 0
    setTakeoverReady(false)
    setRole("driver")
    driven = true
    // A turn we queued as observer is still in the inbox if the other writer
    // left before draining it. Taking over is the user saying "drive", and the
    // one mechanical re-step tui.md §4.3 allows is exactly this case: our own
    // pending turn, nobody else to drain it.
    if (state.pendingCount() > 0) void driver.step()
  }

  return {
    role,
    takeoverReady,
    status: () => (role() === "observer" ? (sending() ? "sending" : "idle") : driver.status()),
    startedAt: () => (role() === "observer" ? queuedAt() : driver.startedAt()),
    send,
    step,
    cancel,
    kill,
    interruptAndDeliver,
    takeOver,
    dispose() {
      disposed = true
      clearInterval(timer)
      stopFollow()
      driver.dispose()
    },
  }
}
