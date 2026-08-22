/**
 * The `ui.panel: true` projection: a tool's latest call, always visible above
 * the composer even when the transcript that call happened in has scrolled
 * off (DESIGN §7.2.1, tui-plugin D12, U2 §3).
 *
 * A pure projection of the ledger's own items — never a second source of
 * truth. Replaying a session must draw the same strip a live one did, so this
 * takes exactly what `Transcript` already has (the item list, the frozen
 * composition) and nothing that only exists while streaming.
 */
import type { ToolItem, TranscriptItem } from "./session.ts"
import { panelToolsOf, type Contributions } from "../nulya/files.ts"

/**
 * The most recent call of each `ui.panel: true` tool, one row per tool, in
 * package-declaration order (`panelToolsOf`). A tool with no call yet
 * contributes no row — there is nothing to project until it has run once.
 */
export function panelItemsOf(
  items: readonly TranscriptItem[],
  contributions: readonly Contributions[],
): ToolItem[] {
  const names = panelToolsOf(contributions)
  if (names.length === 0) return []
  const latest = new Map<string, ToolItem>()
  for (const item of items) {
    if (item.kind !== "tool") continue
    if (!names.includes(item.tool)) continue
    // Items arrive in ledger order; the last one seen for a name is the latest.
    latest.set(item.tool, item)
  }
  const out: ToolItem[] = []
  for (const name of names) {
    const item = latest.get(name)
    if (item) out.push(item)
  }
  return out
}

/**
 * The rows a package's own CODE widget has replaced (tui-plugin U3,
 * `api.registerWidget`).
 *
 * `ui.panel: true` is a package asking for a degraded progress display — the
 * one a front end with no plugin host can still give (D12). A package that also
 * ships a widget has said the same thing better, in its own code, so the
 * declared projection stands down: the ceiling covers the floor, and the
 * alternative is one package saying one thing twice, three rows apart.
 *
 * Per PACKAGE rather than per tool, because that is the grain the claim has:
 * a widget is registered by a package, not for a tool, and a package speaks
 * with one voice about its own progress display.
 */
export function withoutSuperseded(
  items: readonly ToolItem[],
  contributions: readonly Contributions[],
  widgetPackages: ReadonlySet<string>,
): ToolItem[] {
  if (widgetPackages.size === 0) return [...items]
  const hidden = new Set<string>()
  for (const c of contributions) {
    if (widgetPackages.has(c.id)) for (const tool of c.panelTools) hidden.add(tool)
  }
  return items.filter((item) => !hidden.has(item.tool))
}
