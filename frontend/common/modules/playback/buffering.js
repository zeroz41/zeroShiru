// Whether the player is showing its loading spinner.
//
// The bug this answers: the spinner would come up mid-playback and never go away. Two
// causes, and they compound. The `waiting` event was wired straight to the function
// that shows it — `on:waiting={showBuffering}` — so the DOM event object arrived as the
// argument that means "skip the check that the element is actually starved", and every
// `waiting`, including the ones the element recovers from within a frame, put the
// spinner up unconditionally. And nothing took it back down except the events that fire
// on the way *up* through readiness: seeking into a region the element already holds
// can produce a `waiting` and no `canplay` at all, so the spinner stayed forever over a
// video that was playing perfectly well underneath it.

/** How often a spinner that is already up checks whether it is still telling the truth. */
export const BUFFER_RECHECK_MS = 1_000

/** `HTMLMediaElement.HAVE_FUTURE_DATA`: enough buffered to keep playing from here. */
const HAVE_FUTURE_DATA = 3

/**
 * Whether the spinner belongs on screen.
 *
 * @param {object} state
 * @param {boolean} [state.forced] Show it without asking the element — for the moments
 *   the element cannot answer for itself, like a file being swapped underneath it.
 *   Must be a real boolean: this is the argument the `waiting` event used to fill in.
 * @param {number} [state.readyState] The element's `readyState`.
 * @param {boolean} [state.externalPlayback] Playing in an external player instead.
 * @param {boolean} [state.externalPlayerReady] That player has started.
 * @param {boolean} [state.advanced] Playback time moved since the spinner last looked.
 *   A video whose position is advancing is playing, whatever `readyState` claims —
 *   and on debrid range streams this webview has claimed starvation over a video
 *   playing perfectly well underneath the spinner.
 * @returns {boolean}
 */
export function showsSpinner ({ forced = false, readyState = 0, externalPlayback = false, externalPlayerReady = false, advanced = false } = {}) {
  if (externalPlayback) return !externalPlayerReady
  if (forced === true) return true
  if (advanced === true) return false
  return !(readyState >= HAVE_FUTURE_DATA)
}
