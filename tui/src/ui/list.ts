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
 * What the App itself costs an overlay, in rows: the tab bar, the hairline
 * above, and below it the hairline, the three-row composer, a hairline and the
 * status line. (There is no title line since T22 — the model moved under the
 * composer, into the status line that was already there.)
 */
export const app_chrome = 8

/**
 * How many rows are left for a list when the overlay knows exactly what it
 * draws around it — `own` is its title, its blank, its detail and hint lines,
 * counted as they are actually rendered rather than guessed at. Never fewer
 * than three: a list with no room is still a list.
 */
export function listBudget(height: number, own: number): number {
  return Math.max(3, height - app_chrome - own)
}

/**
 * How many rows an overlay list may draw at `height` terminal rows when it has
 * not counted its own chrome: title, blank, detail and footer come to about
 * seven, and `extra` accounts for anything a particular overlay adds.
 */
export function visibleRows(height: number, extra = 0): number {
  return listBudget(height, 7 + extra)
}
