// The player's own rules, pulled out of PlayerPage.svelte so they can be tested at all.
// Each answers a bug the user hit: switching audio track silenced everything, the
// loading spinner stuck forever, and thumbnail drawing raced the stream it was drawn from.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { audioSelectionWrites, safeGain } from '../../../common/modules/playback/audio.js'
import { showsSpinner } from '../../../common/modules/playback/buffering.js'
import { thumbnailHorizon, THUMBNAIL_LOOKAHEAD_SECONDS } from '../../../common/modules/playback/thumbnails.js'

const tracks = [{ id: 'jpn' }, { id: 'eng' }, { id: 'spa' }]

test('the wanted audio track is enabled before any other is turned off', () => {
  const writes = audioSelectionWrites(tracks, 'spa')
  assert.deepEqual(writes[0], { id: 'spa', enabled: true }, 'an instant with nothing selected is what silenced the element')
  assert.deepEqual(writes.slice(1), [{ id: 'jpn', enabled: false }, { id: 'eng', enabled: false }])
  // and at no point in the sequence is every track off
  let enabled = new Set(['jpn'])
  for (const write of writes) {
    write.enabled ? enabled.add(write.id) : enabled.delete(write.id)
    assert.ok(enabled.size > 0, `nothing is selected after writing ${write.id}=${write.enabled}`)
  }
  assert.deepEqual([...enabled], ['spa'])
})

test('switching to the track that is already playing still ends with it enabled', () => {
  assert.deepEqual(audioSelectionWrites(tracks, 'jpn')[0], { id: 'jpn', enabled: true })
})

test('a track that is not there is not worth muting everything for', () => {
  assert.deepEqual(audioSelectionWrites(tracks, 'fre'), [])
  assert.deepEqual(audioSelectionWrites([], 'jpn'), [])
  assert.deepEqual(audioSelectionWrites(null, 'jpn'), [])
})

test('a remembered boost with no usable amount is no boost, never silence', () => {
  assert.equal(safeGain(0), 1, 'zero gain is silence the volume slider cannot undo')
  assert.equal(safeGain(undefined), 1)
  assert.equal(safeGain(null), 1)
  assert.equal(safeGain(NaN), 1)
  assert.equal(safeGain(-2), 1)
  assert.equal(safeGain('nonsense'), 1)
  assert.equal(safeGain(2.5), 2.5, 'and a real boost is still restored')
  assert.equal(safeGain('1.5'), 1.5)
})

test('the spinner asks the element, and a stray waiting event cannot force it', () => {
  // the bug: `on:waiting={showBuffering}` handed the DOM event in as "skip the check"
  assert.equal(showsSpinner({ readyState: 4 }), false, 'an element that can play is not buffering')
  assert.equal(showsSpinner({ readyState: 3 }), false)
  assert.equal(showsSpinner({ readyState: 2 }), true, 'and one that has run out of data is')
  assert.equal(showsSpinner({ forced: {}, readyState: 4 }), false, 'only a real boolean forces it')
  assert.equal(showsSpinner({ forced: true, readyState: 4 }), true)
})

test('an external player answers for itself', () => {
  assert.equal(showsSpinner({ externalPlayback: true, externalPlayerReady: false, readyState: 4 }), true)
  assert.equal(showsSpinner({ externalPlayback: true, externalPlayerReady: true, readyState: 0 }), false)
  assert.equal(showsSpinner({ externalPlayback: true, externalPlayerReady: true, forced: true }), false)
})

test('thumbnails on a torrent only cover what has been downloaded', () => {
  assert.equal(thumbnailHorizon({ duration: 1_000, bufferPercent: 40, currentTime: 0 }), 400)
  assert.equal(thumbnailHorizon({ duration: 1_000, bufferPercent: 0, currentTime: 900 }), 0, 'nothing downloaded is nothing to draw')
})

test('thumbnails on a reachable file stay near the playhead instead of racing the stream', () => {
  const early = thumbnailHorizon({ duration: 10_000, currentTime: 0, reachable: true })
  assert.equal(early, THUMBNAIL_LOOKAHEAD_SECONDS, 'scrubbing the whole file at once starved the player it was drawn from')
  assert.equal(thumbnailHorizon({ duration: 10_000, currentTime: 1_200, reachable: true }), 1_200 + THUMBNAIL_LOOKAHEAD_SECONDS)
  assert.equal(thumbnailHorizon({ duration: 600, currentTime: 500, reachable: true }), 600, 'and never past the end of the file')
})

test('an unknown duration is not a horizon of zero', () => {
  // zero would read as "done", and the thumbnails would silently never be drawn
  assert.ok(Number.isNaN(thumbnailHorizon({ duration: NaN, reachable: true })))
  assert.ok(Number.isNaN(thumbnailHorizon({ duration: 0, bufferPercent: 100 })))
  assert.ok(Number.isNaN(thumbnailHorizon({ duration: Infinity, currentTime: 10, reachable: true })))
})
