// The Matroska seek index that makes subtitle restarts exact. Written for the seek bug's
// third life: after a mid-episode skip, subtitles took ten to twenty seconds when the
// bitrate guess landed short, and never came back when it landed long.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { EbmlTagId } from 'ebml-iterator'
import { parseCues, cueJumpTarget, CUE_BACK_SECONDS } from '../../../common/modules/playback/cue-index.js'

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
