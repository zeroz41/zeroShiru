// How far into a file the seek-preview thumbnails may run ahead.
//
// Thumbnails are drawn by a second, hidden video element seeking through the file and
// grabbing a frame every few seconds. On a torrent that is free: the throttle below
// holds it to what has already been downloaded, and the bytes come off the local disk.
//
// On debrid every byte is reachable immediately, which was taken to mean the whole file
// could be scrubbed at once — so opening an episode fired hundreds of range requests at
// the same link the player was streaming from, alongside the connection the subtitle
// reader holds. Three streams competing over one link is how a seek ends up waiting on
// bytes that never arrive, and how the subtitle reader burns its retries on stalls.
//
// A reachable file is still walked, just never far ahead of the person watching it.

/** How far past the playhead thumbnails may be drawn on a file that is fully reachable. */
export const THUMBNAIL_LOOKAHEAD_SECONDS = 5 * 60

/**
 * The point in the file thumbnail drawing may work up to, right now.
 *
 * @param {object} state
 * @param {number} state.duration The file's duration in seconds.
 * @param {number} [state.bufferPercent] How much of it is downloaded, 0-100.
 * @param {number} [state.currentTime] Where the player is.
 * @param {boolean} [state.reachable] Every byte can be fetched on demand (debrid/HTTP),
 *   rather than only what has been downloaded so far (torrent).
 * @returns {number} Seconds into the file, or NaN while the duration is still unknown.
 */
export function thumbnailHorizon ({ duration, bufferPercent = 0, currentTime = 0, reachable = false }) {
  if (!Number.isFinite(duration) || duration <= 0) return NaN
  if (!reachable) return (bufferPercent / 100) * duration
  const played = Number.isFinite(currentTime) && currentTime > 0 ? currentTime : 0
  return Math.min(duration, played + THUMBNAIL_LOOKAHEAD_SECONDS)
}
