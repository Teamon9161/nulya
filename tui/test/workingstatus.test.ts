/**
 * T38's pure functions (tui.md §4.4b, §11 T38): the one line above the composer
 * that says what is happening right now, and the two related timings — how long
 * a notice stays up, and the sweep that says a line is alive.
 *
 * `activityOf` is a priority table over independent facts (a stopped-on-a-call
 * kernel, an error, which role this tab has, what the driver's status is, and
 * whether a background task is running), so the test that matters most here is
 * not "does each row work" but "does a higher row really beat a lower one when
 * both would otherwise fire" — that is the whole reason it is a function and
 * not a chain of JSX ternaries.
 */
import { expect, test } from "bun:test"
import { activityOf, elapsedLabel } from "../src/ui/WorkingStatus.tsx"
import { noticeHold } from "../src/ui/App.tsx"
import { shimmerColor, mixHex, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { no_snapshot, type SessionSnapshot } from "../src/state/session.ts"
import type { DriverStatus } from "../src/state/driver.ts"
import type { Role } from "../src/state/attach.ts"
import { pickTip } from "../src/ui/Welcome.tsx"

/** Every fact defaults to "nothing is happening" so a test only states what it needs. */
function facts(over: {
  status?: DriverStatus
  role?: Role
  snapshot?: Partial<SessionSnapshot>
  takeoverReady?: boolean
  awaiting?: boolean
  background?: number
}) {
  return {
    status: over.status ?? "idle",
    role: over.role ?? "driver",
    snapshot: { ...no_snapshot, ...over.snapshot },
    takeoverReady: over.takeoverReady ?? false,
    awaiting: over.awaiting ?? false,
    background: over.background ?? 0,
  }
}

test("activityOf: awaiting a gate verdict outranks everything, including an error and a run in flight", () => {
  const a = activityOf(
    facts({
      awaiting: true,
      snapshot: { error: "boom", lastStopped: "max_tokens" },
      role: "observer",
      takeoverReady: true,
      status: "stepping",
      background: 3,
    }),
  )
  expect(a).toEqual({ text: "waiting for your answer", tone: "warn", moving: false })
})

test("activityOf: a session error outranks the role/status/background rows beneath it", () => {
  const a = activityOf(
    facts({ snapshot: { error: "boom" }, role: "observer", takeoverReady: true, status: "stepping", background: 2 }),
  )
  expect(a).toEqual({ text: "error · see transcript", tone: "err", moving: false })
})

test("activityOf: an observer never reaches the driver rows below it, even mid-step with tasks running", () => {
  // Same facts that would read `shell` + `cancelable` for a driver tab resolve
  // to nothing at all for an observer that is neither ready to take over nor
  // queued behind the other writer — following is not an activity.
  const a = activityOf(
    facts({ role: "observer", status: "stepping", snapshot: { activeTool: "shell" }, background: 4 }),
  )
  expect(a).toBeNull()
})

test("activityOf: observer — takeover-ready outranks queued-behind-the-writer", () => {
  const ready = activityOf(facts({ role: "observer", takeoverReady: true, status: "sending" }))
  expect(ready).toEqual({ text: "press ↵ to take over", tone: "warn", moving: false })

  const queued = activityOf(facts({ role: "observer", takeoverReady: false, status: "sending" }))
  expect(queued).toEqual({ text: "queued for the other writer", tone: "run", moving: true })
  // Moving, but Esc over a queued observer append opens browse mode — it must
  // not claim to be cancelable.
  expect(queued?.cancelable).toBeUndefined()
})

test("activityOf: driver — canceling outranks a background count", () => {
  const a = activityOf(facts({ status: "canceling", background: 5 }))
  expect(a).toEqual({ text: "canceling", tone: "run", moving: true })
})

test("activityOf: driver — stepping outranks sending, a stale lastStopped, and background, and is the only row that is cancelable", () => {
  const withTool = activityOf(
    facts({
      status: "stepping",
      snapshot: { activeTool: "shell", lastStopped: "budget" },
      background: 2,
    }),
  )
  expect(withTool).toEqual({ text: "shell", tone: "run", moving: true, cancelable: true })

  // No active tool: the model itself is the thing being waited on.
  const thinking = activityOf(facts({ status: "stepping", snapshot: { activeTool: null } }))
  expect(thinking?.text).toBe("thinking")
  expect(thinking?.cancelable).toBe(true)
})

test("activityOf: driver — sending outranks a stale lastStopped and background, but is not cancelable", () => {
  const a = activityOf(facts({ status: "sending", snapshot: { lastStopped: "budget" }, background: 3 }))
  expect(a).toEqual({ text: "sending", tone: "run", moving: true })
  expect(a?.cancelable).toBeUndefined()
})

test("activityOf: driver, idle — lastStopped budget outranks background, and max_tokens outranks background too", () => {
  const budget = activityOf(facts({ snapshot: { lastStopped: "budget" }, background: 4 }))
  expect(budget).toEqual({ text: "step budget spent · /step to continue", tone: "warn", moving: false })

  const cutOff = activityOf(facts({ snapshot: { lastStopped: "max_tokens" }, background: 4 }))
  expect(cutOff).toEqual({
    text: "reply cut off (max_tokens) · send a message to continue",
    tone: "warn",
    moving: false,
  })
})

test("activityOf: driver, idle, nothing else — background alone survives, moving but not cancelable", () => {
  const a = activityOf(facts({ background: 2 }))
  expect(a).toEqual({ text: "2 background", tone: "run", moving: true, opens: "tasks" })
  expect(a?.cancelable).toBeUndefined()
})

test("activityOf: a genuinely resting driver tab draws nothing — idle, finished, and canceled all resolve to null", () => {
  expect(activityOf(facts({}))).toBeNull()
  // A step that finished cleanly: `lastStopped` is `end_turn`, not one of the
  // two warned-about reasons, and there is nothing left running.
  expect(activityOf(facts({ snapshot: { lastStopped: "end_turn" } }))).toBeNull()
  // A canceled step: `status` is back to idle by the time the tab settles, and
  // `lastStopped` is neither budget nor max_tokens.
  expect(activityOf(facts({ status: "idle", snapshot: { lastStopped: "canceled" } }))).toBeNull()
})

test("elapsedLabel: seconds below the minute, and the minute boundary", () => {
  expect(elapsedLabel(0)).toBe("0s")
  expect(elapsedLabel(59_000)).toBe("59s")
  expect(elapsedLabel(59_999)).toBe("59s") // floors, does not round up into the next second
  expect(elapsedLabel(60_000)).toBe("1m00s")
  expect(elapsedLabel(100_000)).toBe("1m40s")
})

test("noticeHold: floors at the Ctrl+C-again window, scales with length, and caps at nine seconds", () => {
  // A short notice is held at the floor, not shortened further — the floor IS
  // the `Ctrl+C again to quit` offer's own window, so the two must agree.
  expect(noticeHold("ok")).toBe(3000)
  expect(noticeHold("")).toBe(3000)
  // Mid-length: the formula runs (1500 + 45 * length), clear of both clamps.
  const mid = "opened s-a1b2c3d4 into a new tab, ready when you are"
  const raw = 1500 + mid.length * 45
  expect(raw).toBeGreaterThan(3000)
  expect(raw).toBeLessThan(9000)
  expect(noticeHold(mid)).toBe(raw)
  // A long summary is capped, not left to grow without bound.
  expect(noticeHold("x".repeat(500))).toBe(9000)
})

test("shimmerColor: at rest (far from the band) it is exactly the base colour, unchanged", () => {
  // frame 0 puts the band's centre off the left edge (`-sigma`); the far right
  // column of a width-10 line is well outside the band's reach.
  const base = "#9ad5b0"
  const lift = "#f2f5fb"
  expect(shimmerColor(0, 9, 10, base, lift)).toBe(base);
})

test("shimmerColor: dead centre of the band, the cell has moved all the way to lift", () => {
  // frame 6, column 5, width 10: centre = ((6*1.5) % 30) - 4 = 5, so column 5
  // sits exactly on the peak (`d = 0`, `t = 1`) — the strongest lift the sweep
  // ever applies.
  const base = "#9ad5b0"
  const lift = "#f2f5fb"
  const peak = shimmerColor(6, 5, 10, base, lift)
  expect(peak).toBe(lift)
  expect(peak).not.toBe(base)
})

test("shimmerColor: lift == base (a NO_COLOR theme names `lift` as `fg`) makes the sweep a true no-op", () => {
  const mono = createStyle(default_settings, { NO_COLOR: "1" })
  expect(mono.theme.lift).toBe(mono.theme.fg)
  // Even dead centre of the band, mixing a colour toward itself changes nothing —
  // the still frame and every frame of the animation are the same pixel.
  for (const [frame, column] of [
    [0, 9],
    [6, 5],
    [3, 2],
  ] as const) {
    expect(shimmerColor(frame, column, 10, mono.theme.accent.assistant, mono.theme.lift)).toBe(
      mono.theme.accent.assistant,
    )
  }
})

test("mixHex: t=0 is the start colour, t=1 is the end colour, t=0.5 is the midpoint", () => {
  expect(mixHex("#000000", "#ffffff", 0)).toBe("#000000")
  expect(mixHex("#000000", "#ffffff", 1)).toBe("#ffffff")
  expect(mixHex("#000000", "#ffffff", 0.5)).toBe("#808080")
  // Malformed input: neither channel set parses, so the start colour is
  // returned rather than a half-blended guess.
  expect(mixHex("not-a-color", "#ffffff", 0.5)).toBe("not-a-color")
})

test("pickTip: deterministic for a fixed source, and reaches both ends of the list", () => {
  // Same source, called twice: the opening screen picks once per launch, not
  // once per render, so the underlying pick must not itself be flaky.
  const first = pickTip(() => 0)
  expect(pickTip(() => 0)).toBe(first)
  expect(typeof first).toBe("string")
  expect(first.length).toBeGreaterThan(0)

  // The far end of the source range picks a different entry — proof the index
  // actually depends on the argument instead of being hardcoded to one line —
  // and `random() === 1` (which `Math.random()` itself never returns) still
  // lands on the last tip rather than reading past the end of the array.
  const last = pickTip(() => 0.999999)
  expect(last).not.toBe(first)
  expect(pickTip(() => 1)).toBe(last)
})
