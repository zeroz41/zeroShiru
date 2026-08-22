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
 * the seek target — a sign, a song — is still delivered. A wish, not a promise: it is
 * capped by [CUE_LEAD_BYTES]. */
export const CUE_BACK_SECONDS = 15

/** How many bytes of lead-in are worth waiting for.
 *
 * The lead-in above is spent in SECONDS OF VIDEO, and the user waits in BYTES. On a
 * 1080p file at ~8Mbps, fifteen seconds of video is fifteen megabytes that must be
 * downloaded and parsed before the first cue for where the playhead actually is — the
 * "subtitles take a few seconds to come back after a seek" complaint, measured. On a
 * low-bitrate file the same fifteen seconds is a few hundred kilobytes and costs
 * nothing. So the lead-in is taken while it is cheap and dropped when it is not: past
 * this many bytes the restart lands on the cluster the playhead is actually in, which
 * is the least the file allows and still carries whatever that cluster started. */
export const CUE_LEAD_BYTES = 1_000_000

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
 * the parsed window already covers it. The answer is a cluster boundary, which is exact
 * where the bitrate estimate was a guess.
 *
 * Which boundary is the whole question of how long the user waits. The cluster the
 * playhead sits in is the least that can be read for a cue to appear on screen; earlier
 * clusters only buy lead-in, and they are paid for in downloaded bytes. So the walk back
 * stops at whichever comes first: the lead-in time, or [CUE_LEAD_BYTES].
 *
 * @param {{ time: number, byte: number }[]} index - From parseCues.
 * @param {number} positionSeconds - The playhead.
 * @param {number} timecodeScale - Milliseconds per raw timecode unit (1 for standard files).
 * @param {{ start: number, offset: number }} window - Bytes already fed to the parser.
 * @param {number} [backSeconds]
 * @param {number} [leadBytes]
 * @returns {number | null}
 */
export function cueJumpTarget (index, positionSeconds, timecodeScale, { start, offset }, backSeconds = CUE_BACK_SECONDS, leadBytes = CUE_LEAD_BYTES) {
  if (!index?.length) return null
  const scale = timecodeScale > 0 ? timecodeScale : 1
  const atMs = Math.max(0, positionSeconds * 1_000)
  const wantedMs = Math.max(0, (positionSeconds - backSeconds) * 1_000)
  /** The last cluster starting at or before a moment — the one holding it. Before the
   * first cue, the first cluster is the answer. */
  const clusterAt = whenMs => {
    let at = 0
    for (let entry = 0; entry < index.length; entry++) {
      if (index[entry].time * scale > whenMs) break
      at = entry
    }
    return at
  }
  const playhead = clusterAt(atMs)
  // the lead-in is what the time asks for; the bytes are what the user waits through, so
  // give it up cluster by cluster until it fits the budget. At the end of that walk the
  // worst case is the playhead's own cluster: the least the file can be asked for
  let candidate = clusterAt(wantedMs)
  while (candidate < playhead && index[playhead].byte - index[candidate].byte > leadBytes) candidate++
  const target = index[candidate].byte
  // inside the parsed window means the cues for this position were already delivered
  // (or are about to be, sequentially) — restarting would only re-read them
  if (target >= start && target <= offset) return null
  return target
}

/**
 * The last cluster boundary the parser finished before `byte`, or 0 if none.
 *
 * A parse that has read up to some offset has delivered every cue up to the last cluster
 * it FINISHED — the one it is inside may have handed over only some of its lines. That
 * boundary is what may be remembered as covered; see [mergeCovered].
 *
 * @param {{ time: number, byte: number }[]} index
 * @param {number} byte
 * @returns {number}
 */
export function lastClusterBefore (index, byte) {
  let boundary = 0
  for (const entry of index ?? []) {
    if (entry.byte >= byte) break
    boundary = entry.byte
  }
  return boundary
}

/**
 * Add a parsed byte range to the set of ranges already read, merged and sorted.
 *
 * Why remember at all: a cue handed to the renderer stays there for the session. So the
 * bytes that produced it never need to be downloaded again, and a seek back into them —
 * the ordinary "wait, what did they say" seek — should cost nothing at all. Before this,
 * the stream only knew about the window it was in the middle of, so seeking back to a
 * scene it had already parsed tore the connection down and re-read the whole thing while
 * the user watched an empty screen.
 *
 * @param {{ start: number, end: number }[]} covered
 * @param {number} start
 * @param {number} end - Exclusive.
 * @returns {{ start: number, end: number }[]}
 */
export function mergeCovered (covered, start, end) {
  const ranges = [...(covered ?? [])]
  if (!(end > start)) return ranges
  ranges.push({ start, end })
  ranges.sort((a, b) => a.start - b.start)
  const merged = []
  for (const range of ranges) {
    const last = merged[merged.length - 1]
    if (last && range.start <= last.end) last.end = Math.max(last.end, range.end)
    else merged.push({ ...range })
  }
  return merged
}

/**
 * Whether a byte sits in a range that has already been parsed — meaning its cues are in
 * the renderer and nothing needs to be asked of the link.
 * @param {{ start: number, end: number }[]} covered
 * @param {number} byte
 * @returns {boolean}
 */
export function coversByte (covered, byte) {
  return (covered ?? []).some(range => byte >= range.start && byte < range.end)
}
