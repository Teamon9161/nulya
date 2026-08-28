/**
 * The screen's dead-man switch: when the renderer stops painting while the
 * activity line promises motion, force a frame (BUGS.md #17).
 *
 * The failure is inside @opentui/core 0.5.3 (byte-identical in 0.5.9, the
 * latest): when a native frame comes back SKIPPED under terminal backpressure,
 * the renderer parks itself on `feed.idle()` — and while that wait is up,
 * `requestRender()` drops EVERY request on its first line, with no timeout and
 * no retry. The idle promise resolves only if `resolveIdleIfNeeded()` happens
 * to run at the moment the feed drains, but the drain itself is a native-side
 * refcount write with no JS event attached — a textbook lost wakeup. The
 * process stays healthy (stdin, timers and the driver all keep running, which
 * is why Ctrl+C still quits); the screen just never changes again, frozen on
 * whatever `preparing write · 2m 52s` it last painted.
 *
 * The way out is that `loop()` checks none of those flags — only "already
 * rendering" and "destroyed" — so the public `intermediateRender()` forces one
 * real frame. If the wait was a lost wakeup, that frame renders, its own
 * scheduling replaces the parked state, and the screen is back. If the feed is
 * genuinely still backpressured, the forced frame is skipped again and nothing
 * is lost — the nudge IS the retry upstream forgot to schedule.
 *
 * WHEN to nudge is the only judgement here, and it borrows the screen's own
 * promise: `Activity.moving` (`WorkingStatus.activityOf`) is up exactly when
 * the line above the composer sweeps. While it is up, the spinner tick alone
 * changes state every 90ms, so two seconds without a painted frame is not a
 * quiet screen — it is a dead one. At rest a still screen is correct, and the
 * stall clock starts over when motion does. With `motion = false` there is no
 * spinner, so a nudge may repaint an unchanged screen once per window; the
 * native diff makes that a no-op on the wire.
 */

/** The two things this needs from `CliRenderer`: frames announced, one forced. */
export interface NudgeableRenderer {
  on(event: "frame", listener: () => void): unknown
  off(event: "frame", listener: () => void): unknown
  intermediateRender(): void
}

export interface Watchdog {
  /** One inspection. The caller owns the clock that drives it. */
  tick(): void
  /** How many times the screen had to be revived — evidence, not behaviour. */
  nudges(): number
  dispose(): void
}

/** No frame for this long, while motion is promised, means the screen is dead. */
export const stall_ms = 2000
/** How often the caller should tick — well under the stall it is judging. */
export const tick_ms = 500

export function createRenderWatchdog(
  renderer: NudgeableRenderer,
  moving: () => boolean,
  opts: { stallMs?: number; now?: () => number } = {},
): Watchdog {
  const stallAfter = opts.stallMs ?? stall_ms
  const now = opts.now ?? Date.now
  let last = now()
  let count = 0
  const onFrame = () => {
    last = now()
  }
  renderer.on("frame", onFrame)
  return {
    tick() {
      if (!moving()) {
        last = now()
        return
      }
      if (now() - last < stallAfter) return
      count++
      // Re-arm before nudging: a feed that is genuinely backpressured gets one
      // retry per stall window, not one per tick.
      last = now()
      renderer.intermediateRender()
    },
    nudges: () => count,
    dispose: () => renderer.off("frame", onFrame),
  }
}
