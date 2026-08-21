// The Matroska seek index, read once and used to land subtitle restarts exactly.
//
// After a seek, the subtitle stream has to restart its range request somewhere. It
// used to guess: average bitrate times the playhead, minus a safety margin. On
// variable-bitrate video the guess misses — land short and the parser chews through
// megabytes it doesn't need before the first cue; land long and the cues for where
// the user actually is never arrive at all. Ten to twenty seconds of missing
// subtitles when it went well, none for the rest of the episode when it didn't.
//
// The file already knows better. Matroska's Cues element maps timestamps to exact
// cluster byte offsets — it is what the video element itself seeks with. One bounded
// range request reads it, and every later seek becomes: look up the cluster at or
// just before the playhead, restart precisely there.
//
// Pure functions: the tag tree goes in, an index comes out, lookups are arithmetic.

import { EbmlTagId } from 'ebml-iterator'

/** Seconds of lead-in parsed before the playhead, so a line that started just before
 * the seek target — a sign, a song — is still delivered. */
export const CUE_BACK_SECONDS = 15

/**
 * A parsed Cues element as a sorted index.
 * @param {{ Children?: any[] } | null | undefined} cuesTag - The EbmlMasterTag for Cues.
 * @param {number} segmentStart - Absolute byte the segment's data starts at; cue
 *   positions are relative to it.
 * @returns {{ time: number, byte: number }[] | null} Sorted by time (raw timecode
 *   units), or null when the element holds nothing usable.
 */
export function parseCues (cuesTag, segmentStart = 0) {
  if (!cuesTag?.Children?.length) return null
  const index = []
  for (const point of cuesTag.Children) {
    if (point?.id !== EbmlTagId.CuePoint) continue
    const time = point.Children?.find(child => child?.id === EbmlTagId.CueTime)?.data
    const positions = point.Children?.find(child => child?.id === EbmlTagId.CueTrackPositions)
    const cluster = positions?.Children?.find(child => child?.id === EbmlTagId.CueClusterPosition)?.data
    if (time == null || cluster == null) continue
    const entry = { time: Number(time), byte: segmentStart + Number(cluster) }
    if (Number.isFinite(entry.time) && Number.isFinite(entry.byte)) index.push(entry)
  }
  if (!index.length) return null
  index.sort((a, b) => a.time - b.time)
  return index
}

/**
 * The byte to restart the subtitle stream at for a playhead position, or null while
 * the parsed window already covers it. The answer is the cluster at or before
 * (position - lead-in), which is exact where the bitrate estimate was a guess.
 *
 * @param {{ time: number, byte: number }[]} index - From parseCues.
 * @param {number} positionSeconds - The playhead.
 * @param {number} timecodeScale - Milliseconds per raw timecode unit (1 for standard files).
 * @param {{ start: number, offset: number }} window - Bytes already fed to the parser.
 * @param {number} [backSeconds]
 * @returns {number | null}
 */
export function cueJumpTarget (index, positionSeconds, timecodeScale, { start, offset }, backSeconds = CUE_BACK_SECONDS) {
  if (!index?.length) return null
  const scale = timecodeScale > 0 ? timecodeScale : 1
  const wantedMs = Math.max(0, (positionSeconds - backSeconds) * 1_000)
  // last cue at or before the wanted time; before the first cue, the first cluster is the answer
  let candidate = index[0]
  for (const entry of index) {
    if (entry.time * scale > wantedMs) break
    candidate = entry
  }
  const target = candidate.byte
  // inside the parsed window means the cues for this position were already delivered
  // (or are about to be, sequentially) — restarting would only re-read them
  if (target >= start && target <= offset) return null
  return target
}
