/**
 * The render watchdog (`ui/watchdog.ts`): while the screen promises motion,
 * frames must land; when they stop, one is forced.
 *
 * What is pinned is the judgement, not OpenTUI: nudge only when moving AND
 * stalled, restart the clock at rest, one retry per stall window, and a real
 * frame calls the whole thing off.
 */
import { expect, test } from "bun:test"
import { createRenderWatchdog, type NudgeableRenderer } from "../src/ui/watchdog.ts"

function fakeRenderer() {
  const listeners = new Set<() => void>()
  let forced = 0
  const renderer: NudgeableRenderer = {
    on: (_event, listener) => listeners.add(listener),
    off: (_event, listener) => listeners.delete(listener),
    intermediateRender: () => forced++,
  }
  return {
    renderer,
    frame: () => {
      for (const fn of listeners) fn()
    },
    forced: () => forced,
    listeners,
  }
}

test("a stall while moving is nudged; frames flowing are not", () => {
  const fake = fakeRenderer()
  let t = 0
  const dog = createRenderWatchdog(fake.renderer, () => true, { now: () => t, stallMs: 2000 })
  // Frames arriving: never nudge.
  t = 1000
  fake.frame()
  t = 2500
  dog.tick()
  expect(fake.forced()).toBe(0)
  // Silence past the stall: one nudge.
  t = 3100
  dog.tick()
  expect(fake.forced()).toBe(1)
  expect(dog.nudges()).toBe(1)
})

test("at rest a still screen is correct, however long it stays still", () => {
  const fake = fakeRenderer()
  let t = 0
  let moving = false
  const dog = createRenderWatchdog(fake.renderer, () => moving, { now: () => t, stallMs: 2000 })
  t = 60_000
  dog.tick()
  expect(fake.forced()).toBe(0)
  // The stall clock starts when motion does — an idle hour does not count
  // against the first two seconds of work.
  moving = true
  t = 60_500
  dog.tick()
  expect(fake.forced()).toBe(0)
  t = 62_600
  dog.tick()
  expect(fake.forced()).toBe(1)
})

test("one retry per stall window, and a frame calls it off", () => {
  const fake = fakeRenderer()
  let t = 0
  const dog = createRenderWatchdog(fake.renderer, () => true, { now: () => t, stallMs: 2000 })
  t = 2500
  dog.tick()
  expect(fake.forced()).toBe(1)
  // Still stalled, but inside the re-armed window: no second nudge yet.
  t = 3000
  dog.tick()
  expect(fake.forced()).toBe(1)
  // A whole window later with still nothing painted: retry.
  t = 4600
  dog.tick()
  expect(fake.forced()).toBe(2)
  // The nudge worked — a frame landed. The clock is a frame clock again.
  t = 4700
  fake.frame()
  t = 6000
  dog.tick()
  expect(fake.forced()).toBe(2)
})

test("dispose unhooks the frame listener", () => {
  const fake = fakeRenderer()
  const dog = createRenderWatchdog(fake.renderer, () => true)
  expect(fake.listeners.size).toBe(1)
  dog.dispose()
  expect(fake.listeners.size).toBe(0)
})
