/**
 * The one thing every cursor list in an overlay needs: which slice to draw.
 *
 * An overlay sits between two hairlines with the composer below it. A list
 * longer than that space does not politely disappear — it draws over the rows
 * around it — so every overlay with a cursor windows its rows instead of
 * trusting the box to clip.
 */

/**
 * The slice of `count` rows to draw so that `cursor` is visible in `visible`
 * rows. The window slides only when the cursor leaves it, so moving one row
 * does not repaint the whole list at a new offset.
 */
export function windowRange(count: number, cursor: number, visible: number): { start: number; end: number } {
  if (count <= visible) return { start: 0, end: count }
  const start = Math.min(Math.max(cursor - Math.floor(visible / 2), 0), count - visible)
  return { start, end: start + visible }
}

/**
 * How many rows an overlay list may draw at `height` terminal rows. The chrome
 * around it — header, hairline, title, blank, detail, footer, hairline,
 * composer, hairline, status bar — is about sixteen rows, and `extra` accounts
 * for anything a particular overlay adds. Never fewer than three.
 */
export function visibleRows(height: number, extra = 0): number {
  return Math.max(3, height - 16 - extra)
}
