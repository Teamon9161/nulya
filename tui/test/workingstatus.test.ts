/**
 * `WorkingStatus`'s pure functions: the one line above the composer
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
import {
  activityOf,
  elapsedLabel,
  stepActivity,
  type ReachProgress,
  type SyncProgress,
} from "../src/ui/WorkingStatus.tsx"
import { noticeHold, reachNarration } from "../src/ui/App.tsx"
import { shimmerColor, mixHex, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { approachCount, no_snapshot, type SessionSnapshot, type ToolItem, type TranscriptItem } from "../src/state/session.ts"
import { seconds } from "../src/state/tasks.ts"
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
  syncing?: SyncProgress | null
  reaching?: ReachProgress | null
}) {
  return {
    status: over.status ?? "idle",
    role: over.role ?? "driver",
    snapshot: { ...no_snapshot, ...over.snapshot },
    takeoverReady: over.takeoverReady ?? false,
    awaiting: over.awaiting ?? false,
    background: over.background ?? 0,
    syncing: over.syncing ?? null,
    reaching: over.reaching ?? null,
  }
}

const sync: SyncProgress = { what: "building std", done: 2, total: 8, since: 1000 }

const reach: ReachProgress = { spec: "remote:ssh:box", said: "", since: 1000 }

function tool(over: Partial<ToolItem> & { tool: string; state: ToolItem["state"] }): ToolItem {
  return {
    key: "p0:tool:0",
    seq: null,
    kind: "tool",
    callId: "c1",
    args: "",
    ok: null,
    output: "",
    spillPath: null,
    resolved: false,
    awaiting: false,
    autoAllowed: false,
    taskResult: null,
    ...over,
    tool: over.tool,
    state: over.state,
  }
}

function assistant(text: string): TranscriptItem {
  return { key: "p0:assistant", seq: null, kind: "assistant", text, streaming: true }
}

test("activityOf: awaiting a gate verdict outranks everything, including an error and a run in flight — but a background count still rides along", () => {
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
  // `text` says what OUTRANKED everything; `background` says a task is still
  // running regardless of which row won (tasks panel: the two coexist).
  expect(a).toEqual({ text: "waiting for your answer", tone: "warn", moving: false, background: 3 })
})

test("activityOf: a session error outranks the role/status rows beneath it, and still carries the background count", () => {
  const a = activityOf(
    facts({ snapshot: { error: "boom" }, role: "observer", takeoverReady: true, status: "stepping", background: 2 }),
  )
  expect(a).toEqual({ text: "error · see transcript", tone: "err", moving: false, background: 2 })
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

test("activityOf: driver — canceling outranks a background count as the LINE'S TEXT, but the count still shows beside it", () => {
  const a = activityOf(facts({ status: "canceling", background: 5 }))
  expect(a).toEqual({ text: "canceling", tone: "run", moving: true, background: 5 })
})

test("activityOf: driver — stepping outranks sending and a stale lastStopped, is the only row that is cancelable, and a background count rides along with it", () => {
  const withTool = activityOf(
    facts({
      status: "stepping",
      snapshot: { activeTool: "shell", lastStopped: "budget" },
      background: 2,
    }),
  )
  expect(withTool).toEqual({ text: "running shell", tone: "run", moving: true, cancelable: true, background: 2 })

  // No stream yet: the model request itself is the thing being waited on.
  const thinking = activityOf(facts({ status: "stepping", snapshot: { activeTool: null } }))
  expect(thinking?.text).toBe("waiting for model")
  expect(thinking?.cancelable).toBe(true)
  // No background task running: the field is absent, not zero — nothing at
  // rest costs a column.
  expect(thinking?.background).toBeUndefined()
})

test("stepActivity: streamed transcript tail names the live phase before, during, and after a tool", () => {
  expect(stepActivity({ ...no_snapshot, items: [assistant("hello")] })).toBe("responding")
  expect(stepActivity({ ...no_snapshot, items: [tool({ tool: "shell", state: "pending" })] })).toBe("preparing shell")
  expect(stepActivity({ ...no_snapshot, items: [tool({ tool: "shell", state: "running" })] })).toBe("running shell")
  expect(stepActivity({ ...no_snapshot, items: [tool({ tool: "shell", state: "done" })] })).toBe(
    "recording shell result",
  )
})

test("activityOf: driver — sending outranks a stale lastStopped as the line's text, is not cancelable, and still carries the background count", () => {
  const a = activityOf(facts({ status: "sending", snapshot: { lastStopped: "budget" }, background: 3 }))
  expect(a).toEqual({ text: "sending", tone: "run", moving: true, background: 3 })
  expect(a?.cancelable).toBeUndefined()
})

test("activityOf: driver, idle — lastStopped budget and max_tokens outrank background as the line's text, but the count still rides along", () => {
  const budget = activityOf(facts({ snapshot: { lastStopped: "budget" }, background: 4 }))
  expect(budget).toEqual({ text: "step budget spent · /step to continue", tone: "warn", moving: false, background: 4 })

  const cutOff = activityOf(facts({ snapshot: { lastStopped: "max_tokens" }, background: 4 }))
  expect(cutOff).toEqual({
    text: "reply cut off (max_tokens) · send a message to continue",
    tone: "warn",
    moving: false,
    background: 4,
  })
})

test("activityOf: driver, idle, nothing else — background alone survives, moving but not cancelable, and does not say itself twice", () => {
  const a = activityOf(facts({ background: 2 }))
  expect(a).toEqual({ text: "2 background", tone: "run", moving: true, opens: "tasks" })
  expect(a?.cancelable).toBeUndefined()
  // The count IS `text` here, so it is not ALSO on `background` — that field
  // is for when something else is the text and the count rides beside it.
  expect(a?.background).toBeUndefined()
})

test("activityOf: a store pass names the draft it is on and carries its own clock", () => {
  const a = activityOf(facts({ syncing: sync }))
  expect(a).toEqual({ text: "building std (2/8)", tone: "run", moving: true, since: 1000 })
  // A phase with nothing to count says only what it is doing — `(0/0)` would be
  // a progress bar that never fills.
  expect(activityOf(facts({ syncing: { ...sync, what: "installing", total: 0 } }))?.text).toBe("installing")
})

test("activityOf: a store pass never blocks the conversation, so every waiting-on-you row outranks it", () => {
  // The pass runs on a timer of its own: whatever the person is actually
  // waiting for is the more useful thing to be told while it goes.
  expect(activityOf(facts({ syncing: sync, awaiting: true }))?.text).toBe("waiting for your answer")
  expect(activityOf(facts({ syncing: sync, status: "stepping" }))?.text).toBe("waiting for model")
  expect(activityOf(facts({ syncing: sync, snapshot: { lastStopped: "budget" } }))?.tone).toBe("warn")
  // …and it beats the one row below it, which is the reason it sits there:
  // before the first message a background count is the less pressing of the two.
  expect(activityOf(facts({ syncing: sync, background: 2 }))?.text).toBe("building std (2/8)")
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
  // One format for a duration in this front end, so this is the same function
  // `/tasks` and a background card's note go through.
  expect(elapsedLabel(60_000)).toBe(seconds(60))
  expect(elapsedLabel(100_000)).toBe(seconds(100))
})

test("approachCount: activity-line counters move toward jumps instead of teleporting", () => {
  expect(approachCount(0, 1)).toBe(1)
  expect(approachCount(0, 500)).toBeGreaterThan(0)
  expect(approachCount(0, 500)).toBeLessThan(500)
  expect(approachCount(400, 380)).toBe(380)
  expect(approachCount(999, 1_000_000)).toBeLessThan(1_000_000)
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
  const glyphs = createStyle(default_settings, {}).glyphs
  // Same source, called twice: the opening screen picks once per launch, not
  // once per render, so the underlying pick must not itself be flaky.
  const first = pickTip(glyphs, () => 0)
  expect(pickTip(glyphs, () => 0)).toBe(first)
  expect(typeof first).toBe("string")
  expect(first.length).toBeGreaterThan(0)

  // The far end of the source range picks a different entry — proof the index
  // actually depends on the argument instead of being hardcoded to one line —
  // and `random() === 1` (which `Math.random()` itself never returns) still
  // lands on the last tip rather than reading past the end of the array.
  const last = pickTip(glyphs, () => 0.999999)
  expect(last).not.toBe(first)
  expect(pickTip(glyphs, () => 1)).toBe(last)

  // Every tip is written for one glyph set: the one that names the
  // sidebar handle has to name the handle this terminal actually draws, or it
  // is pointing at a control that is not on the screen.
  const ascii = createStyle({ ...default_settings, transcript: { ...default_settings.transcript, ascii: true } }, {})
  const named = (set: typeof glyphs) =>
    Array.from({ length: 40 }, (_, i) => pickTip(set, () => i / 40)).find((tip) => tip.includes("/sidebar"))!
  expect(named(glyphs)).toContain(glyphs.sidebar)
  expect(named(ascii.glyphs)).toContain(ascii.glyphs.sidebar)
  expect(named(ascii.glyphs)).not.toContain(glyphs.sidebar)
})

test("a reach in flight says which machine, and says what the kernel last said about it", () => {
  expect(activityOf(facts({ reaching: reach }))?.text).toBe("reaching remote:ssh:box")
  const building = activityOf(facts({ reaching: { ...reach, said: "building a nulya for aarch64-linux" } }))
  expect(building?.text).toBe("remote:ssh:box · building a nulya for aarch64-linux")
  // Its own clock, not the driver's: nothing has been stepped yet.
  expect(building?.since).toBe(1000)
  expect(building?.moving).toBe(true)
})

test("a reach outranks a step and a store pass, and yields only to a question", () => {
  expect(activityOf(facts({ reaching: reach, status: "stepping" }))?.text).toBe("reaching remote:ssh:box")
  expect(activityOf(facts({ reaching: reach, syncing: sync }))?.text).toBe("reaching remote:ssh:box")
  expect(activityOf(facts({ reaching: reach, awaiting: true }))?.text).toBe("waiting for your answer")
})

test("a reach line is the kernel's narration, not ssh's own commentary", () => {
  // What the kernel says while it works — all of it reaches the line.
  expect(reachNarration("building a nulya for aarch64-linux")).toBe("building a nulya for aarch64-linux")
  expect(reachNarration("  installed at $HOME/.nulya/remote-agent\r")).toBe("installed at $HOME/.nulya/remote-agent")
  // OpenSSH writes these to every connection to an older server, and one of
  // them would otherwise hold the line for the whole minute of a cross-build.
  expect(reachNarration("** WARNING: connection is not using a post-quantum key exchange algorithm.")).toBeNull()
  expect(reachNarration("Warning: Permanently added 'box' to the list of known hosts.")).toBeNull()
  expect(reachNarration("")).toBeNull()
  // An authentication refusal is not commentary: it is what happened.
  expect(reachNarration("teamon@box: Permission denied (publickey,password).")).not.toBeNull()
})
