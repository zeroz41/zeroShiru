// When a subtitle stream may be torn down and restarted somewhere else. Pure state and
// arithmetic, because the bug this replaces could only be argued about, not tested: the
// old watcher restarted the stream whenever the playhead's cluster was more than 1MB —
// about one second of 1080p video — past the parser. On any real bitrate with a briefly
// slow link, playback outran the parser, every restart paid connection latency and was
// aborted before it delivered a cue, and main.log filled with "the stream restarted but
// delivered nothing" once a second while the user watched an episode with no subtitles.
//
// The rules that make that impossible:
//  - Only a SEEK moves the stream immediately: a discontinuous jump of the playhead,
//    settled for a moment so a scrub bar being dragged coalesces into one restart
//    instead of a storm of doomed connections.
//  - Playback merely getting AHEAD of the parser is not a seek. The stream is already
//    downloading as fast as the link allows (pacing only holds it back when it is ahead);
//    tearing it down buys nothing. Falling behind by a lot earns a catch-up restart, but
//    only past a real distance and at most once per interval — bounded waste, no livelock.

/** A playhead moving more than this between watcher ticks is a seek, not playback. */
export const SEEK_JUMP_SECONDS = 4
/** A seek target must sit still this long before the stream chases it — the difference
 * between one restart at the end of a scrub and a doomed restart per scrub tick. */
export const SETTLE_MS = 400
/** Continuous playback may lead the parser by this much video before a catch-up restart
 * is worth a torn connection. Measured in seconds because bytes are what misled the old
 * code: 1MB is minutes of a low-bitrate file and one second of a high-bitrate one. */
export const DRIFT_SLACK_SECONDS = 45
/** And catch-up restarts may not happen more often than this, whatever the drift. */
export const DRIFT_RESTART_INTERVAL_MS = 10_000

/**
 * @param {() => number} [clock] - Injectable for tests; Date.now otherwise.
 */
export function createSchedule ({ settleMs = SETTLE_MS, seekJumpSeconds = SEEK_JUMP_SECONDS, driftSlackSeconds = DRIFT_SLACK_SECONDS, driftIntervalMs = DRIFT_RESTART_INTERVAL_MS, clock = Date.now } = {}) {
  return {
    settleMs,
    seekJumpSeconds,
    driftSlackSeconds,
    driftIntervalMs,
    clock,
    /** @type {number | null} Last playhead the watcher reported. */
    lastTime: null,
    /** @type {number | null} When the pending seek was last seen moving. */
    seekAt: null,
    /** When the stream last restarted, for rate-limiting catch-up restarts. */
    restartedAt: -Infinity
  }
}

/**
 * Feed the schedule the playhead, once per watcher tick. Detects seeks as
 * discontinuities; a jump refreshes the settle timer, so dragging the bar keeps the
 * seek pending until the hand stops.
 * @param {ReturnType<typeof createSchedule>} schedule
 * @param {number} time - Playhead seconds.
 */
export function observeTime (schedule, time) {
  const previous = schedule.lastTime
  schedule.lastTime = time
  if (previous === null) return
  if (Math.abs(time - previous) > schedule.seekJumpSeconds) schedule.seekAt = schedule.clock()
}

/** The stream restarted; catch-up restarts are rate-limited from this moment. */
export function noteRestart (schedule) {
  schedule.restartedAt = schedule.clock()
  schedule.seekAt = null
}

/**
 * Whether the stream should restart at `target` now.
 *
 * The caller establishes that a non-null target is real: outside the parsed window and
 * not in an already-covered range. This decides only the WHEN — seek restarts go as soon
 * as the scrub settles, catch-up restarts wait for real distance and the rate limit.
 *
 * @param {ReturnType<typeof createSchedule>} schedule
 * @param {{ target: number | null, offset: number, byteRate: number }} state - Where the
 *   restart would go (null when the stream already covers the playhead), where the
 *   parser is, and the file's bytes per second of video.
 * @returns {boolean}
 */
export function shouldRestart (schedule, { target, offset, byteRate }) {
  const now = schedule.clock()
  if (target == null) {
    // a settled seek that needs no restart landed in already-parsed bytes and is over;
    // forgetting it keeps the next drift from masquerading as a seek
    if (schedule.seekAt !== null && now - schedule.seekAt >= schedule.settleMs) schedule.seekAt = null
    return false
  }
  if (schedule.seekAt !== null) return now - schedule.seekAt >= schedule.settleMs
  // no seek: this is drift. Backward drift does not exist (a rewind is a jump), so any
  // sub-slack forward gap is the sequential read's to close
  if (byteRate > 0 && target - offset <= schedule.driftSlackSeconds * byteRate) return false
  return now - schedule.restartedAt >= schedule.driftIntervalMs
}
