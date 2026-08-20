// Showing a list that is built row by row.
//
// The episode list is assembled in order — each row's air date is validated against the
// one before it, so the rows cannot be built in parallel — and it used to be shown only
// once the last row was done. For a twelve episode show nobody notices. For a thousand
// episode one, the user waits on nine hundred rows they cannot see before the first
// fifteen appear, which is the whole complaint: opening a show feels slow even though
// everything on screen was ready almost immediately.
//
// So the list is shown as soon as the rows that fit on screen exist, and the rest keep
// filling in behind it.

/**
 * How many rows must be built before the list is worth showing: the ones that fit on
 * screen, or all of them when there are fewer than that.
 *
 * @param {number} total How many rows the finished list will have.
 * @param {number} visible How many rows are rendered before the user has to scroll.
 * @returns {number} The row count at which to paint. Never zero for a non-empty list —
 *   painting an empty list would replace the skeletons with nothing.
 */
export function firstPaintAt (total, visible) {
  if (!Number.isFinite(total) || total <= 0) return 0
  if (!Number.isFinite(visible) || visible <= 0) return total
  return Math.min(Math.max(Math.trunc(visible), 1), total)
}
