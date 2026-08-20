/**
 * The `panel: true` projection: a tool's latest call, always visible above the
 * composer even when the transcript that call happened in has scrolled off
 * (DESIGN §7.2.1, tui-plugin D12, U2 §3).
 *
 * A pure projection of the ledger's own items — never a second source of
 * truth. Replaying a session must draw the same strip a live one did, so this
 * takes exactly what `Transcript` already has (the item list, the frozen
 * composition) and nothing that only exists while streaming.
 */
import type { ToolItem, TranscriptItem } from "./session.ts"
import { panelToolsOf, type Contributions } from "../nulya/files.ts"

/**
 * The most recent call of each `panel: true` tool, one row per tool, in
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
