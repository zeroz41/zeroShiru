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

/** How long nothing at all may change before the watchdog looks harder. */
export const STALL_PATIENCE_MS = 15_000

/** How many times a dead stream is quietly re-opened before the user is told. */
export const STALL_RELOADS = 2

/** How many watchdog firings a STARTING debrid load gets before the user is told.
 * A debrid preroll is invisible to the page — readyState 0, empty buffered ranges,
 * downloaded pinned at 100 — and healthy desktop starts have been MEASURED at 10-27s
 * to metadata. The old 15s-then-reload rule was killing healthy prerolls mid-pull and
 * restarting them from zero, over and over: the "90% of videos infinitely spin" bug
 * was the watchdog itself. So a starting load is given firings at 15s intervals that
 * PROBE instead of reload (measured: a concurrent probe is harmless to the stream),
 * and only the last one before the report is allowed to touch the pipeline. One untouched
 * 15s grace window covers the measured healthy starts; at 30s an alive-but-empty pipeline
 * is restarted once, and the next unchanged window becomes an honest error. */
export const START_RELOADS = 2

/** Once metadata exists but no decoded frame follows, one changed-URL connection gets
 * this long before recovery. This is independent of the moving buffer fingerprint: a
 * CDN can trickle container bytes for a minute without ever reaching a frame. */
export const POST_METADATA_PATIENCE_MS = 20_000

/** A debrid failure routes itself again once; a second failure waits for the user. Pure
 * so the one-shot rule cannot regress into an automatic replay loop. */
export function reportPlan ({ debrid = false, replayed = false } = {}) {
  return debrid && !replayed ? 'replay' : 'ask'
}

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
 * @param {number} [maxReloads] Firings before `report` — [STALL_RELOADS] mid-play,
 *   [START_RELOADS] for a starting debrid load, whose firings mostly probe-and-wait.
 * @returns {{ state: { mark: string | null, stalledMs: number, reloads: number, reported: boolean }, action: 'wait' | 'reload' | 'report' }}
 *   `reload` hands one firing to the recovery plan; `report` tells the user and gives up,
 *   once, so a stream nobody can fix cannot turn into a reload loop.
 */
export function advanceStall (stall, mark, elapsedMs = 0, maxReloads = STALL_RELOADS) {
  const previous = stall ?? { mark: null, stalledMs: 0, reloads: 0, reported: false }
  if (mark !== previous.mark) return { state: { ...previous, mark, stalledMs: 0 }, action: 'wait' }
  const stalledMs = previous.stalledMs + elapsedMs
  if (stalledMs < STALL_PATIENCE_MS) return { state: { ...previous, stalledMs }, action: 'wait' }
  if (previous.reloads < maxReloads) return { state: { ...previous, stalledMs: 0, reloads: previous.reloads + 1 }, action: 'reload' }
  if (!previous.reported) return { state: { ...previous, stalledMs, reported: true }, action: 'report' }
  return { state: { ...previous, stalledMs }, action: 'wait' }
}

/**
 * What one watchdog firing should actually do, given what is known.
 *
 * Re-opening in place is the whole answer for a torrent: the data comes from the client,
 * and the client's download percentage is already in the fingerprint, so a frozen one
 * really is stuck. Debrid divides in two:
 *
 * **Starting** (no metadata yet): the page cannot tell a healthy preroll from a dead link
 * — every fingerprint field sits at zero for both — and healthy desktop prerolls have been
 * measured taking up to 27s. So the firing PROBES (measured harmless to the stream, see
 * playback/probe.js): a dead link makes waiting a lie and the play is routed again from
 * the top immediately, where it fails fast into the torrent fallback or an honest error;
 * a live link means a slow preroll, which is left completely alone — yanking it restarts
 * the pull from zero, which was the infinite-spinner bug. Only the last firing before the
 * report may re-open, in case the pipeline and not the link is what is stuck.
 *
 * **Mid-play** (metadata existed, playback froze): the fingerprint moves during any real
 * progress, so a frozen one earns an immediate re-open, then a probe before the second —
 * a link that answers makes it the pipeline's fault, one that does not gets the replay.
 *
 * @param {object} state
 * @param {number} state.attempt - Which firing this is, 1-based.
 * @param {boolean} [state.debrid]
 * @param {boolean | null} [state.linkAlive] - What a probe just said, or null before one ran.
 * @param {boolean} [state.starting] - The element has not yet produced metadata.
 * @param {boolean} [state.lastAttempt] - No more firings after this one before the report.
 * @returns {'wait' | 'reopen' | 'probe' | 'replay'}
 */
export function reloadPlan ({ attempt, debrid = false, linkAlive = null, starting = false, lastAttempt = false }) {
  if (!debrid) return 'reopen'
  if (starting) {
    if (linkAlive === null) return 'probe'
    if (!linkAlive) return 'replay'
    return lastAttempt ? 'reopen' : 'wait'
  }
  if (attempt < 2) return 'reopen'
  if (linkAlive === null) return 'probe'
  return linkAlive ? 'reopen' : 'replay'
}
