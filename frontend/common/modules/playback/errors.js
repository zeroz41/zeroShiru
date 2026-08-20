// What an error from the video element is worth telling the user about.
//
// The bug this answers: a "Video Codec Unsupported" toast on every single episode, over
// a video that then played perfectly. Starting playback tears the old file down by
// assigning an empty source, and an empty source is a failed load by definition — the
// element reports MEDIA_ERR_SRC_NOT_SUPPORTED for it. That was meant to be filtered out
// by matching the error message against `MEDIA_ELEMENT_ERROR: Empty src attribute`,
// which is Chromium's wording; the engine this app actually runs on has never produced
// that string, so the filter never matched once and the toast fired every time.
//
// Matching an engine's error text was the mistake. Whether the video plays is the same
// question on every engine, and it is the question the user cares about: an error the
// element recovers from within a few seconds is not something to interrupt them for.

/** How long a source failure gets to turn into playback before it is believed. */
export const CONFIRM_MS = 5_000

/** `HTMLMediaElement.HAVE_CURRENT_DATA`: a frame exists, so the load went somewhere. */
const HAVE_CURRENT_DATA = 2

/**
 * What an error event means, or null when it is not worth reporting at all.
 *
 * @param {object} error
 * @param {number} [error.code] The `MediaError` code.
 * @param {any} [error.src] The source the player is asking for; nothing means the player
 *   is between files, and a failure to load nothing is not a failure.
 * @returns {null | { kind: 'network' | 'decode' | 'source', confirm: boolean }} `confirm`
 *   means wait and see whether it plays anyway before saying anything.
 */
export function mediaErrorReport ({ code, src } = {}) {
  if (!code || !src) return null
  switch (code) {
    case 1: return null // aborted: something the player itself did
    case 2: return { kind: 'network', confirm: false }
    case 3: return { kind: 'decode', confirm: false }
    case 4: return { kind: 'source', confirm: true }
    default: return null
  }
}

/**
 * Whether a source failure reported a moment ago is still true.
 *
 * @param {object} state
 * @param {string} [state.erroredSrc] What was loading when it failed.
 * @param {string} [state.currentSrc] What the element is loading now.
 * @param {number} [state.readyState]
 * @returns {boolean}
 */
export function stillFailing ({ erroredSrc, currentSrc, readyState } = {}) {
  if (!erroredSrc) return false
  if (erroredSrc !== currentSrc) return false // a different file now; the old failure is moot
  return (readyState ?? 0) < HAVE_CURRENT_DATA
}
