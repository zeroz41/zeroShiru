// A load that never becomes playback.
//
// The complaint this answers: the player spins forever and nothing happens. Every event the
// page listens to fires on the way UP through readiness — `loadedmetadata`, `canplay`,
// `playing` — so a stream that simply stops answering produces no event at all. There is
// nothing to react to, and the spinner is left telling the user something is coming when
// nothing is. Debrid makes it common: the link is an HTTP range stream to a CDN that can go
// quiet mid-request, and an expired link can be accepted and then never answered.
//
// So the spinner watches instead of waiting. Everything about the element that changes while
// a load is making progress goes into one fingerprint; a fingerprint that has not changed in
// STALL_PATIENCE_MS is not slow, it is dead. The first answer is to re-open the connection,
// which is what actually fixes a socket the far end has forgotten. If that does not take
// either, the user is told, once, instead of being left with a spinner.

/** `HTMLMediaElement.HAVE_CURRENT_DATA`: a frame exists, so the load got somewhere. */
const HAVE_CURRENT_DATA = 2

/** How long nothing at all may change before a stream counts as dead rather than slow. */
export const STALL_PATIENCE_MS = 15_000

/** How many times a dead stream is quietly re-opened before the user is told. */
export const STALL_RELOADS = 2

/**
 * Whether the element is supposed to be making progress right now.
 *
 * A paused player is not stalled, it is paused — but a player that has never produced a
 * frame is still starting, whatever its paused flag says, because playback is only started
 * once the header arrives.
 *
 * @param {object} state
 * @param {any} [state.src] What the element is loading; nothing means it is between files.
 * @param {number} [state.readyState]
 * @param {boolean} [state.paused]
 * @param {boolean} [state.externalPlayback] Another player is playing this; not our problem.
 * @returns {boolean}
 */
export function watchesForStall ({ src, readyState = 0, paused = true, externalPlayback = false } = {}) {
  if (!src || externalPlayback) return false
  if ((readyState ?? 0) < HAVE_CURRENT_DATA) return true
  return !paused
}

/**
 * One line describing everything that moves while a load is going anywhere: how ready the
 * element is, how much it holds, where it is, and — on a torrent — how much of the file has
 * arrived. A debrid stream pins that last one at 100, so it says nothing there and everything
 * on a torrent, where a slow-but-downloading start must never be mistaken for a dead one.
 *
 * @param {object} state
 * @param {number} [state.readyState]
 * @param {number} [state.bufferedEnd] The end of the buffered range holding the playhead.
 * @param {number} [state.currentTime]
 * @param {number} [state.downloaded] Percent of the file the client has.
 * @returns {string}
 */
export function loadProgressMark ({ readyState = 0, bufferedEnd = 0, currentTime = 0, downloaded = 0 } = {}) {
  const number = value => (Number.isFinite(value) ? value : 0).toFixed(2)
  return `${readyState ?? 0}:${number(bufferedEnd)}:${number(currentTime)}:${number(downloaded)}`
}

/**
 * Advance the watchdog by one look at the element.
 *
 * @param {null | { mark: string | null, stalledMs: number, reloads: number, reported: boolean }} stall
 * @param {string} mark The element's fingerprint now, from [loadProgressMark].
 * @param {number} [elapsedMs] Since the last look.
 * @returns {{ state: { mark: string | null, stalledMs: number, reloads: number, reported: boolean }, action: 'wait' | 'reload' | 'report' }}
 *   `reload` re-opens the stream where it was; `report` tells the user and gives up, once,
 *   so a stream nobody can fix cannot turn into a reload loop.
 */
export function advanceStall (stall, mark, elapsedMs = 0) {
  const previous = stall ?? { mark: null, stalledMs: 0, reloads: 0, reported: false }
  if (mark !== previous.mark) return { state: { ...previous, mark, stalledMs: 0 }, action: 'wait' }
  const stalledMs = previous.stalledMs + elapsedMs
  if (stalledMs < STALL_PATIENCE_MS) return { state: { ...previous, stalledMs }, action: 'wait' }
  if (previous.reloads < STALL_RELOADS) return { state: { ...previous, stalledMs: 0, reloads: previous.reloads + 1 }, action: 'reload' }
  if (!previous.reported) return { state: { ...previous, stalledMs, reported: true }, action: 'report' }
  return { state: { ...previous, stalledMs }, action: 'wait' }
}

/**
 * What one `reload` from the watchdog should actually do, given what is known.
 *
 * Re-opening in place is the whole answer for a torrent: the data comes from the client,
 * and the client's download percentage is already in the fingerprint. A debrid link is an
 * HTTP address that can be dead in a way no re-open fixes — and it cannot be exchanged for
 * a fresh one, the service pins one URL per file — so before burning a second 15s window
 * on it the link is asked directly (see playback/probe.js). A link that answers makes it
 * the local pipeline's fault, worth another rebuild; a link that does not makes every
 * further attempt on it a lie to the user, and the play is routed again from the top,
 * where a dead link now fails fast into the torrent fallback or an honest error.
 *
 * @param {object} state
 * @param {number} state.attempt - Which reload this is, 1-based.
 * @param {boolean} [state.debrid]
 * @param {boolean | null} [state.linkAlive] - What a probe just said, or null before one ran.
 * @returns {'reopen' | 'probe' | 'replay'}
 */
export function reloadPlan ({ attempt, debrid = false, linkAlive = null }) {
  if (!debrid) return 'reopen'
  if (attempt < 2) return 'reopen'
  if (linkAlive === null) return 'probe'
  return linkAlive ? 'reopen' : 'replay'
}
