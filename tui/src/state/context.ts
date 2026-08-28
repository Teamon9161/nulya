/**
 * How full the model's context window is (tui.md §4.5, §11 T82) — the ring on
 * the row under the composer, and the sections of the panel it opens.
 *
 * Pure functions, for the same reason `WorkingStatus.activityOf` is one: the
 * rules that decide a colour, a glyph and which rows exist are the whole of
 * this feature, and inside a render they can only be read by running the
 * program.
 *
 * The number itself is not ours. `usage.lastPrompt` is what the provider
 * counted for the whole prefix of the most recent step (`state/session.ts`),
 * and the denominator is the `[[models]]` catalog's `context_window` for the id
 * this session froze. Neither is estimated here: with no catalog entry there is
 * no denominator, and a made-up one would be a meter that reads wrong in a
 * place where the only reason to look is to decide whether to `/compact`.
 */
import { compactCount, type UsageTotals } from "./session.ts"

/**
 * How much of the window is worth being told about. Three bands rather than a
 * gradient because a colour on this screen means one thing (tui.md §6): dim is
 * "this is metadata", amber is "this is going to matter", red is "act".
 */
export type ContextBand = "calm" | "warn" | "urgent"

export const warn_at = 60
export const urgent_at = 85

export interface ContextFill {
  /** Prompt tokens the last step sent — cached ones included; they occupy the window. */
  used: number
  window: number
  /** 0–100. Clamped: a prompt that outgrew a stale catalog number is still 100, never 137. */
  percent: number
  band: ContextBand
}

/**
 * The fill, or null when there is nothing honest to draw: no catalog window for
 * this model, or a session that has not been priced yet (a draft tab, a session
 * reopened but not stepped). Null is what makes the column disappear rather
 * than show a placeholder word (T35's "nothing takes a column").
 */
export function contextFill(used: number, window: number | null | undefined): ContextFill | null {
  if (!window || window <= 0 || used <= 0) return null
  const percent = Math.min(100, Math.round((used / window) * 100))
  const band: ContextBand = percent >= urgent_at ? "urgent" : percent >= warn_at ? "warn" : "calm"
  return { used, window, percent, band }
}

/**
 * The ring, from a ladder of glyphs (`style.glyphs.ring`, empty → full).
 *
 * Rounded to the nearest rung, with two ends that are never rounded INTO: a
 * used window never shows the empty ring and a window with room left never
 * shows the full one. The exact percentage is written beside it, so the glyph's
 * job is to be readable at a glance and its only real duty is not to lie about
 * the two states somebody would act on.
 */
export function fillGlyph(percent: number, ring: readonly string[]): string {
  const last = ring.length - 1
  if (last <= 0) return ring[0] ?? ""
  let at = Math.round((Math.max(0, Math.min(100, percent)) / 100) * last)
  if (at === 0 && percent > 0) at = 1
  if (at === last && percent < 100) at = last - 1
  return ring[at]!
}

/**
 * Filled cells of a `width`-wide bar. Same two end rules as the ring: a used
 * window shows at least one cell, and a window with room left leaves at least
 * one — a bar that reads full at 99% would be the one row on the panel that
 * contradicts the number above it.
 */
export function barCells(percent: number, width: number): number {
  if (width <= 0) return 0
  let cells = Math.round((Math.max(0, Math.min(100, percent)) / 100) * width)
  if (cells === 0 && percent > 0) cells = 1
  if (cells === width && percent < 100) cells = width - 1
  return cells
}

export interface ContextRow {
  label: string
  value: string
}

export interface ContextSection {
  title: string
  rows: ContextRow[]
}

/**
 * What the panel says, as data.
 *
 * A LIST of sections rather than a fixed pair, because the next thing to go
 * here is already known: a provider's own account of what this subscription has
 * left (a Codex rate-limit window, tcode's usage strip). That arrives as one
 * more section from whoever can answer it — nothing here reaches a network, and
 * a section with no rows is never produced, so an unanswered one costs no rows
 * on the screen.
 *
 * Every row is a fact somebody could act on. A counter at zero is not one, so
 * it is left out rather than printed as `0` — the same rule the row under the
 * composer follows (T35).
 */
export function contextSections(usage: UsageTotals, window: number | null | undefined): ContextSection[] {
  const sections: ContextSection[] = []
  const fill = contextFill(usage.lastPrompt, window)
  const rows: ContextRow[] = []
  if (fill) {
    rows.push({ label: "last prompt", value: compactCount(fill.used) })
    rows.push({ label: "window", value: compactCount(fill.window) })
    rows.push({ label: "free", value: compactCount(Math.max(0, fill.window - fill.used)) })
  } else if (!window || window <= 0) {
    // Worth a row, unlike on the status line: the panel is where a person came
    // for the number, and "this model has no [[models]] entry" is the answer to
    // why there is none — not an omission to puzzle over.
    rows.push({ label: "window", value: "unknown · no [[models]] entry names one" })
  } else {
    rows.push({ label: "last prompt", value: "nothing sent yet" })
    rows.push({ label: "window", value: compactCount(window) })
  }
  sections.push({ title: "context", rows })

  const spent: ContextRow[] = []
  if (usage.input > 0) spent.push({ label: "input", value: compactCount(usage.input) })
  if (usage.cacheRead > 0) spent.push({ label: "cache read", value: compactCount(usage.cacheRead) })
  if (usage.cacheWrite > 0) spent.push({ label: "cache write", value: compactCount(usage.cacheWrite) })
  if (usage.output > 0) spent.push({ label: "output", value: compactCount(usage.output) })
  if (usage.pricedSteps > 0) spent.push({ label: "priced steps", value: String(usage.pricedSteps) })
  if (spent.length > 0) sections.push({ title: "this session", rows: spent })

  return sections
}
