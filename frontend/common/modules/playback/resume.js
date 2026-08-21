// Where the player picks an episode back up.
//
// The bug this answers: on debrid, an episode always restarted from the beginning. Progress
// was only written when the element reported `HAVE_ENOUGH_DATA` — "enough buffered to play
// to the end without stopping" — which a range-served stream that is being fetched as it
// plays has no reason to ever claim, and which this webview does not claim even while the
// video is visibly playing (the same lie that used to leave a spinner over a playing video,
// see playback/buffering.js). So the ten-second save ticked for a whole episode and stored
// nothing, every time.
//
// Whether the position is worth saving is not a question about buffering. It is a question
// about whether there IS a position: the element has decoded a frame, and playback is
// somewhere other than the very start.

/** `HTMLMediaElement.HAVE_CURRENT_DATA`: a frame exists, so the position means something. */
const HAVE_CURRENT_DATA = 2

/**
 * Whether a playback position is worth remembering.
 *
 * @param {object} state
 * @param {number} [state.readyState]
 * @param {number} [state.currentTime]
 * @param {boolean} [state.error] Saving because playback failed, which resets the position
 *   deliberately and must not be blocked by the element's state.
 * @returns {boolean}
 */
export function savesProgress ({ readyState = 0, currentTime = 0, error = false } = {}) {
  if (error) return true
  if ((readyState ?? 0) < HAVE_CURRENT_DATA) return false
  return Number.isFinite(currentTime) && currentTime > 0
}
