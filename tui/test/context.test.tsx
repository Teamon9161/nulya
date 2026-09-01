/**
 * The context-window pure functions: how full the context window is, what
 * the ring shows for it, and which rows the panel gets.
 *
 * Three mechanisms are worth pinning and nothing else is. (1) `contextFill`
 * refuses to invent a meter when either half of the fraction is missing, and
 * the bands are what turns a number into a colour. (2) the ring and the bar
 * never round INTO their two ends — a used window that draws empty, or a window
 * with room left that draws full, is the one way this display can lie about a
 * state somebody would act on. (3) a section is made of rows that exist, so a
 * counter at zero produces no row and a section with no rows produces nothing.
 *
 * The wording of a label, the exact glyphs, and the band thresholds as
 * literals are not pinned: those are taste and settings, and a test over them
 * only taxes the next harmless change.
 */
import { expect, test } from "bun:test"
import type { JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { ContextPanel } from "../src/ui/ContextPanel.tsx"
import { StyleContext } from "../src/render/theme.ts"
import { settle } from "./support.ts"
import {
  barCells,
  contextFill,
  contextSections,
  fillGlyph,
  urgent_at,
  warn_at,
} from "../src/state/context.ts"
import { createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import type { UsageTotals } from "../src/state/session.ts"

const nothing: UsageTotals = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, pricedSteps: 0, lastPrompt: 0 }

test("contextFill: no denominator and no numerator each mean no meter at all", () => {
  // A model the `[[models]]` catalog does not name has no window, and a
  // session nothing has been priced for has no prompt. Either way the honest
  // answer is nothing rather than a made-up percentage.
  expect(contextFill(10_000, null)).toBeNull()
  expect(contextFill(10_000, undefined)).toBeNull()
  expect(contextFill(10_000, 0)).toBeNull()
  expect(contextFill(0, 200_000)).toBeNull()
  expect(contextFill(10_000, 200_000)).not.toBeNull()
})

test("contextFill: the bands are the thresholds, on both sides of each edge", () => {
  const at = (percent: number) => contextFill(percent, 100)!.band
  expect(at(warn_at - 1)).toBe("calm")
  expect(at(warn_at)).toBe("warn")
  expect(at(urgent_at - 1)).toBe("warn")
  expect(at(urgent_at)).toBe("urgent")
})

test("contextFill: a prompt past a stale window reads 100, never more", () => {
  // The catalog number can be wrong (an endpoint serving a bigger window than
  // the id is listed with). A meter that reads 137% is a meter nobody trusts
  // for the one decision it exists for.
  const over = contextFill(300_000, 200_000)!
  expect(over.percent).toBe(100)
  expect(over.band).toBe("urgent")
})

test("fillGlyph: never empty while something is used, never full while there is room", () => {
  for (const set of [createStyle(default_settings, {}).glyphs, createStyle({ ...default_settings, transcript: { ...default_settings.transcript, ascii: true } }, {}).glyphs]) {
    const ring = set.ring
    const empty = ring[0]
    const full = ring[ring.length - 1]
    expect(fillGlyph(0, ring)).toBe(empty!)
    expect(fillGlyph(100, ring)).toBe(full!)
    for (const percent of [1, 5, 12, 50, 88, 97, 99]) {
      expect(fillGlyph(percent, ring)).not.toBe(empty!)
      expect(fillGlyph(percent, ring)).not.toBe(full!)
    }
  }
})

test("fillGlyph: the ladder only ever climbs", () => {
  const ring = createStyle(default_settings, {}).glyphs.ring
  let previous = -1
  for (let percent = 0; percent <= 100; percent++) {
    const at = ring.indexOf(fillGlyph(percent, ring))
    expect(at).toBeGreaterThanOrEqual(previous)
    previous = at
  }
  expect(previous).toBe(ring.length - 1)
})

test("barCells: the same two ends as the ring, and it scales with the width", () => {
  expect(barCells(0, 20)).toBe(0)
  expect(barCells(100, 20)).toBe(20)
  expect(barCells(1, 20)).toBe(1)
  expect(barCells(99, 20)).toBe(19)
  expect(barCells(50, 20)).toBe(10)
  // A bar with no room draws nothing rather than a negative number of cells.
  expect(barCells(50, 0)).toBe(0)
})

test("contextSections: a counter at zero is not a row, and a section with no rows is not a section", () => {
  // A session that has cost nothing: the context section still answers (it is
  // what somebody opened the panel for), the spend section does not exist.
  const fresh = contextSections(nothing, 200_000)
  expect(fresh.length).toBe(1)
  expect(fresh[0]!.rows.length).toBeGreaterThan(0)

  const priced: UsageTotals = {
    input: 1_200,
    output: 800,
    cacheRead: 40_000,
    cacheWrite: 0,
    pricedSteps: 3,
    lastPrompt: 41_200,
  }
  const sections = contextSections(priced, 200_000)
  expect(sections.length).toBe(2)
  const labels = sections[1]!.rows.map((row) => row.label)
  expect(labels).toContain("cache read")
  // `cacheWrite` is zero on this session, so it contributes nothing.
  expect(labels).not.toContain("cache write")
  for (const section of sections) expect(section.rows.length).toBeGreaterThan(0)
})

test("ContextPanel: every section the data names reaches the screen, meter and all", async () => {
  // The one thing a render test buys over the pure ones above: the sections
  // are data, and this is what proves the panel draws ALL of them rather than
  // the first — the reason it is a list is that the next one is already known.
  const usage: UsageTotals = {
    input: 1_200,
    output: 800,
    cacheRead: 40_000,
    cacheWrite: 0,
    pricedSteps: 3,
    lastPrompt: 41_200,
  }
  const style = createStyle(default_settings, {})
  const mount = (node: () => JSX.Element) =>
    testRender(() => <StyleContext.Provider value={style}>{node()}</StyleContext.Provider>, { width: 80, height: 20 })
  const setup = await mount(() => (
    <ContextPanel fill={contextFill(usage.lastPrompt, 200_000)} sections={contextSections(usage, 200_000)} />
  ))
  try {
    const frame = await settle(setup, 3)
    for (const section of contextSections(usage, 200_000)) {
      expect(frame).toContain(section.title)
      for (const row of section.rows) expect(frame).toContain(row.label)
    }
    // The ring's rung is the panel's title glyph, so the two surfaces cannot
    // disagree about how full the window is.
    expect(frame).toContain(fillGlyph(21, style.glyphs.ring))
  } finally {
    setup.renderer.destroy()
  }
})

test("contextSections: an unnamed window is answered rather than left blank", () => {
  // The status row drops the column when there is no window (nothing takes a
  // column). The panel is the opposite case: somebody asked, and "this model
  // has no catalog entry" is the answer to why there is no percentage.
  const sections = contextSections({ ...nothing, lastPrompt: 10_000, input: 10_000, pricedSteps: 1 }, null)
  expect(sections[0]!.rows.length).toBeGreaterThan(0)
  // …and what the session has spent is still knowable without a window.
  expect(sections.length).toBe(2)
})
