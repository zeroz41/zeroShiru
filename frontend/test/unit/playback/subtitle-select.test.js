// The one subtitle chooser: remembered choice first, then the settings language, never a
// fight. Replaces the restore path that matched a rendered label ("ENG (Full Subtitles)")
// against a differently-rendered label ("eng - Full Subtitles") with levenshtein distance
// and got away with it — choices are data now, and legacy labels still land.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { chooseSubtitleTrack, choiceMatches, trackChoice, trackLabel, CHOICE } from '../../../common/modules/playback/subtitle-select.js'

const track = (number, overrides = {}) => ({ number, language: 'eng', type: 'ass', ...overrides })

test('a remembered structured choice finds its track by language and name', () => {
  const tracks = [track(2, { name: 'Signs & Songs' }), track(3, { name: 'Full Subtitles' })]
  const choice = chooseSubtitleTrack(tracks, { remembered: { language: 'eng', name: 'Full Subtitles' }, language: 'eng' })
  assert.deepEqual(choice, { number: 3, score: CHOICE.remembered })
})

test('remembered OFF stays off even with a preferred language configured', () => {
  const choice = chooseSubtitleTrack([track(2)], { remembered: 'OFF', language: 'eng' })
  assert.deepEqual(choice, { number: -1, score: CHOICE.remembered })
})

test('a legacy label string from the old cache still restores the right track', () => {
  const tracks = [track(2, { name: 'Signs & Songs' }), track(3, { name: 'Full Subtitles' })]
  // exactly what the old dropdown persisted
  assert.equal(chooseSubtitleTrack(tracks, { remembered: 'ENG (Full Subtitles)' }).number, 3)
  // and what the old restore path rendered for comparison
  assert.equal(chooseSubtitleTrack(tracks, { remembered: 'eng - Signs & Songs' }).number, 2)
})

test('a remembered language survives the episode renaming its track', () => {
  const tracks = [track(2, { language: 'spa', name: 'Español (LA)' }), track(3, { language: 'eng' })]
  const choice = chooseSubtitleTrack(tracks, { remembered: { language: 'spa', name: 'Spanish' }, language: 'eng' })
  assert.deepEqual(choice, { number: 2, score: CHOICE.remembered }, 'the user chose Spanish, not a string')
})

test('with nothing remembered the settings language decides', () => {
  const tracks = [track(2, { language: 'eng' }), track(3, { language: 'spa' })]
  assert.deepEqual(chooseSubtitleTrack(tracks, { language: 'spa' }), { number: 3, score: CHOICE.language })
})

test('a track NAMED for the wanted language counts, as releases often only name them', () => {
  const tracks = [track(2, { language: 'und', name: 'Spanish (Latin America)' }), track(3, { language: 'eng' })]
  assert.equal(chooseSubtitleTrack(tracks, { language: 'spanish' }).number, 2)
})

test('among matching tracks, full dialogue beats a forced signs track', () => {
  const tracks = [track(2, { forced: true, name: 'Signs' }), track(3, { name: 'Dialogue' })]
  assert.equal(chooseSubtitleTrack(tracks, { language: 'eng' }).number, 3)
})

test('the muxer\'s default flag breaks remaining ties', () => {
  const tracks = [track(2, { default: false }), track(3, { default: true })]
  assert.equal(chooseSubtitleTrack(tracks, { language: 'eng' }).number, 3)
})

test('missing language falls back to English, then to the first track', () => {
  assert.deepEqual(chooseSubtitleTrack([track(2, { language: 'fre' }), track(3, { language: 'eng' })], { language: 'ger' }),
    { number: 3, score: CHOICE.english })
  assert.deepEqual(chooseSubtitleTrack([track(2, { language: 'fre' }), track(3, { language: 'jpn' })], { language: 'ger' }),
    { number: 2, score: CHOICE.fallback })
})

test('a lone track is used whatever its language', () => {
  assert.equal(chooseSubtitleTrack([track(7, { language: 'jpn' })], { language: 'ger' }).number, 7)
})

test('no language preference and nothing remembered selects nothing', () => {
  assert.equal(chooseSubtitleTrack([track(2), track(3)], {}), null,
    'an empty language setting means subtitles stay off unless asked for')
})

test('no tracks yet is not a decision', () => {
  assert.equal(chooseSubtitleTrack([], { remembered: { language: 'eng', name: '' }, language: 'eng' }), null)
})

test('what the picker persists is what the matcher accepts', () => {
  const original = track(4, { language: 'spa', name: 'Foro' })
  assert.ok(choiceMatches(trackChoice(original), original), 'round trip through persistence')
  assert.ok(choiceMatches(trackLabel(original), original), 'and through the rendered label, for old caches')
})
