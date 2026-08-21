// The player's audio, and what switching track costs.
//
// Every rule here was learned from the same complaint, three rounds of it: switching audio
// track silenced everything, switching back did not bring it back, and once the switch did
// produce sound it stopped the player dead — a black screen, a seekbar that stopped saying
// where playback was, and a jump backwards when it came back. The first two are about the
// order the flags are written in and when the pipeline can take them. The rest is about
// everything the page must hold still while the element underneath it is rebuilt.

/**
 * The order to write `enabled` in when switching audio track.
 *
 * Writing the whole track list in list order — `enabled = track.id === id` for each —
 * disables the playing track before enabling the wanted one whenever the wanted one
 * sorts later. For a moment the element has no audio track selected at all, and the
 * media pipeline underneath (GStreamer, on the system webview) takes that literally:
 * it tears the audio chain down, then rebuilds it for the selection that arrives a
 * line later. What comes back is silence.
 *
 * So the wanted track is enabled first and the others are turned off afterwards.
 * There is never an instant with nothing selected, and a track id that is not in the
 * list writes nothing at all rather than muting everything on the way to a track that
 * does not exist.
 *
 * @param {{ id: any }[]} tracks The element's audio tracks, in list order.
 * @param {any} id The track to switch to.
 * @returns {{ id: any, enabled: boolean }[]} The writes to make, in order.
 */
export function audioSelectionWrites (tracks, id) {
  const list = [...(tracks || [])]
  const target = list.find(track => track.id === id)
  if (!target) return []
  return [
    { id: target.id, enabled: true },
    ...list.filter(track => track.id !== target.id).map(track => ({ id: track.id, enabled: false }))
  ]
}

/**
 * The gain to restore for a title the user had boosted.
 *
 * The boost is remembered as a pair — that it was on, and how much — and the two were
 * read back with different defaults: a missing amount became `0`, which is not "no
 * boost", it is silence, applied to a graph the volume slider sits upstream of. So
 * the player could come back from a restart muted with no control that could undo it.
 * Anything that is not a usable amount reads as no boost.
 *
 * @param {any} stored The remembered gain.
 * @returns {number} A multiplier safe to write to a gain node: 1 is untouched audio.
 */
export function safeGain (stored) {
  const gain = Number(stored)
  if (!Number.isFinite(gain) || gain <= 0) return 1
  return gain
}

/**
 * A volume read back from settings, as a number.
 *
 * It is persisted as a string — `String(volume || 0)` — and read straight back into the
 * arithmetic behind the scroll wheel, where `"0.5" + -0.05` concatenates instead of
 * adding and the result is `NaN`. That `NaN` was then stored as the title's boost, and
 * the next launch restored it as silence. See [safeGain].
 *
 * @param {any} stored
 * @returns {number} A volume between 0 and 1; a value that makes no sense reads as full.
 */
export function storedVolume (stored) {
  const volume = Number(stored)
  if (!Number.isFinite(volume) || volume < 0) return 1
  return Math.min(1, volume)
}

/** `HTMLMediaElement.HAVE_METADATA`: the header is parsed, so a pipeline exists to disturb. */
const HAVE_METADATA = 1

/** Before this much has played, the pipeline is still being built and the flags go in with it. */
export const MID_PLAY_AFTER = 1

/**
 * Whether switching audio track has to rebuild the element's pipeline instead of just
 * writing the flags.
 *
 * Before playback is underway, flipping `enabled` is the whole job: the pipeline is built
 * with the selection already in it, which is why the right track comes up at every episode
 * start. Mid-play is different — this webview's pipeline answers an in-place reselection by
 * tearing its audio chain down and coming back silent, with the flags reading perfectly the
 * whole time (the user's log proved it, twice). So a mid-play switch reloads the element
 * with the selection applied while it is being built. See PlayerPage's `rebuildPipeline`.
 *
 * @param {object} state
 * @param {number} [state.readyState] The element's `readyState`.
 * @param {number} [state.currentTime] Where playback is.
 * @returns {boolean}
 */
export function needsPipelineRebuild ({ readyState = 0, currentTime = 0 } = {}) {
  if ((readyState ?? 0) < HAVE_METADATA) return false
  return Number.isFinite(currentTime) && currentTime > MID_PLAY_AFTER
}

/**
 * The setup work that belongs to a NEW FILE, keyed by name.
 *
 * All of it hangs off `loadedmetadata`, and a rebuild fires `loadedmetadata` again over the
 * file that is already playing. Re-running it is not just wasted: `resume` throws playback
 * back to the last saved position (up to ten seconds stale), `thumbnails` restarts a second
 * video element scrubbing the same debrid link the player is streaming from, `autoplay`
 * waits on a network round trip before it will let the video play, and `audio` re-applies
 * the *preferred* language over the track the user just picked.
 */
export const PER_FILE_SETUP = ['thumbnails', 'chapters', 'autoplay', 'audio', 'subtitles', 'resume']

/**
 * Whether a piece of per-file setup should run when the element was rebuilt under the same
 * file. Anything not named as per-file setup still runs — a rebuild is not a reason to skip
 * work nobody has thought about.
 *
 * @param {string} step
 * @param {object} [rebuild] The rebuild in flight.
 * @param {boolean} [rebuild.started] Whether the file had got anywhere before the rebuild. A
 *   rebuild of a load that never started IS that file's first load happening again — none of
 *   the setup has run yet, so all of it still has to, autoplay included. Without this, a
 *   stream re-opened because it never answered would load and then sit there, not playing.
 * @returns {boolean}
 */
export function runsOnRebuild (step, { started = true } = {}) {
  if (!started) return true
  return !PER_FILE_SETUP.includes(step)
}

/**
 * The position and duration the page should show while the element underneath it is being
 * rebuilt.
 *
 * A rebuild empties the element: `duration` becomes NaN and `currentTime` becomes 0, both
 * of which the page reads through two-way bindings. `safeduration` then collapses to the
 * position, the progress bar is fed `0 / 0`, and the seekbar stops saying where playback
 * is — which is what a user watching an audio switch sees. The element is about to be put
 * back exactly where it was, so the page keeps showing that until it is.
 *
 * @param {null | { at: number, duration: number }} rebuild The rebuild in flight, if any.
 * @param {object} live What the element currently reports.
 * @param {number} [live.currentTime]
 * @param {number} [live.duration]
 * @returns {{ position: number, duration: number }}
 */
export function heldPlayback (rebuild, { currentTime = 0, duration = 0 } = {}) {
  if (!rebuild) return { position: currentTime, duration }
  return { position: rebuild.at, duration: rebuild.duration }
}

/** The track list as one line, for the log: which are enabled is the whole question. */
export function describeTracks (tracks) {
  return [...(tracks || [])].map(track => `${track.id}${track.language ? `(${track.language})` : ''}${track.enabled ? '*' : ''}`).join(' ') || 'none'
}
