// The Matroska seek index that makes subtitle restarts exact. Written for the seek bug's
// third life: after a mid-episode skip, subtitles took ten to twenty seconds when the
// bitrate guess landed short, and never came back when it landed long.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { EbmlTagId } from 'ebml-iterator'
import { parseCues, cueJumpTarget, lastClusterBefore, mergeCovered, coversByte, CUE_BACK_SECONDS, CUE_LEAD_BYTES } from '../../../common/modules/playback/cue-index.js'

/** A Cues tag the way ebml-iterator hands it over: CuePoints of CueTime + positions. */
function cuesTag (points) {
  return {
    Children: points.map(([time, cluster]) => ({
      id: EbmlTagId.CuePoint,
      Children: [
        { id: EbmlTagId.CueTime, data: time },
        { id: EbmlTagId.CueTrackPositions, Children: [{ id: EbmlTagId.CueClusterPosition, data: cluster }] }
      ]
    }))
  }
}

test('cue points come out sorted, with the segment offset applied', () => {
  const index = parseCues(cuesTag([[10_000, 5_000], [0, 100], [5_000, 2_500]]), 700)
  assert.deepEqual(index, [
    { time: 0, byte: 800 },
    { time: 5_000, byte: 3_200 },
    { time: 10_000, byte: 5_700 }
  ])
})

test('a cues element with nothing usable is null, not an empty index', () => {
  assert.equal(parseCues(null, 0), null)
  assert.equal(parseCues({ Children: [] }, 0), null)
  // a point missing its position says nothing; a point missing its time says nothing
  assert.equal(parseCues({
    Children: [{ id: EbmlTagId.CuePoint, Children: [{ id: EbmlTagId.CueTime, data: 5 }] }]
  }, 0), null)
})

test('junk children are skipped rather than crashing the parse', () => {
  const tag = cuesTag([[1_000, 500]])
  tag.Children.unshift({ id: 999 }, null)
  assert.deepEqual(parseCues(tag, 0), [{ time: 1_000, byte: 500 }])
})

const index = parseCues(cuesTag([[0, 0], [30_000, 1_000_000], [60_000, 2_000_000], [90_000, 3_000_000]]), 0)

test('a seek past the window restarts at the cluster covering the lead-in, exactly', () => {
  // playhead at 65s, lead-in lands at 50s -> the 30s cluster holds it
  const target = cueJumpTarget(index, 65, 1, { start: 0, offset: 100_000 })
  assert.equal(target, 1_000_000)
})

test('a seek inside the parsed window changes nothing', () => {
  assert.equal(cueJumpTarget(index, 65, 1, { start: 0, offset: 2_500_000 }), null)
})

test('a seek back before the window restarts behind it', () => {
  // parsed 2M..3M, playhead back at 40s -> lead-in at 25s -> first cluster
  assert.equal(cueJumpTarget(index, 40, 1, { start: 2_000_000, offset: 3_000_000 }), 0)
})

test('before the first cue, the first cluster is the answer', () => {
  assert.equal(cueJumpTarget(index, 3, 1, { start: 2_000_000, offset: 3_000_000 }), 0)
})

test('a non-standard timecode scale moves the lookup, not the caller', () => {
  // scale 0.5ms per unit: raw 60_000 is 30s of video, so a playhead at 32s
  // (lead-in 17s) belongs to the raw-30_000 cluster
  const target = cueJumpTarget(index, 17 + CUE_BACK_SECONDS, 0.5, { start: 0, offset: 1 })
  assert.equal(target, 1_000_000)
})

test('an empty index answers nothing', () => {
  assert.equal(cueJumpTarget(null, 65, 1, { start: 0, offset: 0 }), null)
  assert.equal(cueJumpTarget([], 65, 1, { start: 0, offset: 0 }), null)
})

// --- what the user waits through after a seek -----------------------------------------
// The lead-in is spent in seconds of video and paid for in downloaded bytes. On a
// high-bitrate file those are wildly different amounts: fifteen seconds of 1080p is
// fifteen megabytes to pull and parse before a single cue for where the playhead is.
// That download WAS the "subtitles take a few seconds after a seek" complaint.

test('lead-in is given up when it costs more than a moment of downloading', () => {
  // 5s apart, 8MB apart: a 1080p file. Fifteen seconds of lead-in would be 24MB
  const dense = parseCues(cuesTag([[0, 0], [5_000, 8_000_000], [10_000, 16_000_000], [15_000, 24_000_000], [20_000, 32_000_000]]), 0)
  const target = cueJumpTarget(dense, 21, 1, { start: 0, offset: 100 })
  assert.equal(target, 32_000_000, 'the restart must land on the cluster the playhead is in, not fifteen seconds of video earlier')
})

test('lead-in is kept when it is nearly free', () => {
  // the same fifteen seconds on a low-bitrate file is a few hundred KB, and buys the
  // sign or song that was already on screen when the user seeked
  const sparse = parseCues(cuesTag([[0, 0], [5_000, 100_000], [10_000, 200_000], [15_000, 300_000], [20_000, 400_000]]), 0)
  assert.equal(cueJumpTarget(sparse, 21, 1, { start: 0, offset: 100 }), 100_000, 'a cheap lead-in is still worth having')
})

test('the byte budget never lands past the playhead, however dense the file', () => {
  const huge = parseCues(cuesTag([[0, 0], [5_000, CUE_LEAD_BYTES * 40], [10_000, CUE_LEAD_BYTES * 90]]), 0)
  const target = cueJumpTarget(huge, 12, 1, { start: 0, offset: 100 })
  assert.equal(target, CUE_LEAD_BYTES * 90, 'the playhead cluster is the floor: reading later than it would miss the cues entirely')
})

// --- bytes already parsed ---------------------------------------------------------------
// A cue handed to the renderer stays there for the session, so the bytes behind it never
// need asking for twice. Seeking back into a scene already parsed used to tear the
// connection down and re-read the lot while the user watched an empty screen.

test('parsed ranges merge into one another rather than piling up', () => {
  let covered = mergeCovered([], 0, 1_000)
  covered = mergeCovered(covered, 1_000, 2_000) // touching ranges are one range
  assert.deepEqual(covered, [{ start: 0, end: 2_000 }])
  covered = mergeCovered(covered, 5_000, 6_000)
  assert.deepEqual(covered, [{ start: 0, end: 2_000 }, { start: 5_000, end: 6_000 }])
  covered = mergeCovered(covered, 1_500, 5_500) // a range that bridges the gap closes it
  assert.deepEqual(covered, [{ start: 0, end: 6_000 }])
})

test('an empty or backwards range is not a range', () => {
  assert.deepEqual(mergeCovered([], 500, 500), [])
  assert.deepEqual(mergeCovered([], 900, 100), [])
  assert.deepEqual(mergeCovered(null, 0, 10), [{ start: 0, end: 10 }])
})

test('a byte is covered only while it is really inside a parsed range', () => {
  const covered = [{ start: 100, end: 200 }, { start: 400, end: 500 }]
  assert.equal(coversByte(covered, 150), true)
  assert.equal(coversByte(covered, 100), true, 'the first byte of a parsed range was parsed')
  assert.equal(coversByte(covered, 200), false, 'the end is where the parse stopped, not the last byte it read')
  assert.equal(coversByte(covered, 300), false)
  assert.equal(coversByte(null, 150), false)
})

test('coverage is claimed only up to the last cluster the parser finished', () => {
  // the cluster the parser is INSIDE may have handed over only some of its lines; a seek
  // that landed there would show a scene with half its subtitles and nothing to fix it
  const boundaries = [{ time: 0, byte: 0 }, { time: 1, byte: 1_000 }, { time: 2, byte: 2_000 }]
  assert.equal(lastClusterBefore(boundaries, 2_500), 2_000)
  assert.equal(lastClusterBefore(boundaries, 2_000), 1_000, 'a cluster is finished when the parse has passed it, not reached it')
  assert.equal(lastClusterBefore(boundaries, 10), 0)
  assert.equal(lastClusterBefore(null, 5_000), 0, 'no index, no exact boundary, nothing claimed')
})
