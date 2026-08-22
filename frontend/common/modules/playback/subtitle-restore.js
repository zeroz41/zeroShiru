// Restoring the subtitle track the user last chose for a show — once, and without
// calling itself.
//
// The bug this exists for, straight out of the user's main.log: PlayerPage's
// checkSubtitle picked the remembered track and called `subs.selectCaptions(n)`, and
// selectCaptions announces the change by calling its `onHeader` callback — which IS
// PlayerPage's handleHeaders, which calls checkSubtitle. Nothing broke the ring, so
// every episode with a remembered subtitle track recursed until the stack overflowed:
//
//   St@…MediaHandler.js  selectCaptions@…  he@…  St@…  selectCaptions@…  (×thousands)
//
// The throw unwound out of `Subtitles.handleTracks`, which is called from the debrid
// metadata parser's `getTracks().then(...)` — one line ABOVE the call that starts the
// subtitle stream. So the stack overflow did not just waste a few milliseconds: it took
// out the subtitle stream for the whole episode, and the seconds of stack-building and
// unwinding froze the main thread right when the player was starting. Subtitles
// "taking a few seconds to load at the start" was this.
//
// The rules below are pure so the ring can be proven broken in a test rather than
// argued about: which track a remembered choice means, and the fact that a restore that
// has already happened is not repeated.

/**
 * How a track presents itself for matching — the same string the picker shows, so what
 * was remembered ("eng - Signs & Songs") lines up with what is offered now.
 *
 * @param {any} track
 * @param {any[]} headers - Every track header, used to decide whether an unlabelled track
 *   should be described as english (the picker's own fallback).
 * @returns {string}
 */
export function trackLabel (track, headers = []) {
  const anyEnglish = Object.values(headers ?? {}).some(header => header?.language === 'eng' || header?.language === 'en')
  const language = track?.language || (!anyEnglish ? 'eng' : track?.type)
  return `${language ?? ''}${track?.name ? ' - ' + track.name : ''}`
}

/**
 * Which track a remembered choice means, or null when nothing should change.
 *
 * @param {object} state
 * @param {any[]} [state.headers] - Track headers known so far; sparse, indexed by track number.
 * @param {string} [state.remembered] - The stored choice: a track label, or 'OFF'.
 * @param {boolean} [state.restored] - A restore already happened for this file. The single
 *   most important guard here: selectCaptions calls back into the code that calls this.
 * @param {(remembered: string, label: string, tolerance: number) => boolean} [state.matches]
 * @returns {number | null} A track number, -1 for subtitles off, or null to do nothing.
 */
export function subtitleRestoreTarget ({ headers, remembered, restored = false, matches = () => false } = {}) {
  if (restored || !remembered) return null
  const tracks = (headers ?? []).filter(Boolean)
  if (!tracks.length) return null
  if (remembered === 'OFF') return -1
  for (const track of tracks) {
    const label = trackLabel(track, headers)
    if (track?.number && matches(remembered, label, label.length > 10 ? 3 : 2)) return track.number
  }
  return null
}
