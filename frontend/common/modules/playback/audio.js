// Two rules about the player's audio, both learned from the same complaint: switching
// audio track silenced everything, and switching back did not bring it back.

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
