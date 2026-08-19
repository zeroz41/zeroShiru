// The torrent client and debrid playback both pick external subtitle and font files with these
// helpers. If they drift, one lane silently loads the wrong subtitles or renders them with the
// wrong fonts (season packs are the case that bites: every episode ships its own .ass).
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { matchFontFiles, matchSubtitleFiles, matroskaRx } from '../../../common/modules/util.js'

const names = files => files.map(file => file.name)
const toFiles = (...list) => list.map(name => ({ name }))

test('a season pack loads only the playing episode\'s subtitles', () => {
  const files = toFiles(
    '[Group] Show - 01 [1080p].mkv', '[Group] Show - 01 [1080p].ass',
    '[Group] Show - 02 [1080p].mkv', '[Group] Show - 02 [1080p].ass',
    '[Group] Show - 03 [1080p].mkv', '[Group] Show - 03 [1080p].ass'
  )
  assert.deepEqual(names(matchSubtitleFiles(files, '[Group] Show - 02 [1080p].mkv')), ['[Group] Show - 02 [1080p].ass'])
})

test('a single video release takes every subtitle, however the subs are named', () => {
  const files = toFiles('Movie.mkv', 'English.srt', 'Signs.ass', 'Commentary.sub')
  assert.deepEqual(names(matchSubtitleFiles(files, 'Movie.mkv')), ['English.srt', 'Signs.ass', 'Commentary.sub'])
})

test('non subtitle files are never returned', () => {
  const files = toFiles('Show - 01.mkv', 'Show - 01.ass', 'Show - 01.jpg', 'font.ttf', 'readme.nfo')
  assert.deepEqual(names(matchSubtitleFiles(files, 'Show - 01.mkv')), ['Show - 01.ass'])
})

test('a pack with no subtitles for the playing episode returns nothing', () => {
  const files = toFiles('Show - 01.mkv', 'Show - 02.mkv', 'Show - 02.ass')
  assert.deepEqual(matchSubtitleFiles(files, 'Show - 01.mkv'), [])
})

test('the video count can be supplied when the caller already knows it', () => {
  const files = toFiles('Show - 01.ass', 'Show - 02.ass')
  // told there are two videos, subtitles must still be matched by name
  assert.deepEqual(names(matchSubtitleFiles(files, 'Show - 01.mkv', 2)), ['Show - 01.ass'])
  // told there is only one, they all belong to it
  assert.deepEqual(names(matchSubtitleFiles(files, 'Show - 01.mkv', 1)), ['Show - 01.ass', 'Show - 02.ass'])
})

test('empty and malformed inputs are handled without throwing', () => {
  assert.deepEqual(matchSubtitleFiles([], 'Show.mkv'), [])
  assert.deepEqual(matchSubtitleFiles(null, 'Show.mkv'), [])
  assert.deepEqual(matchSubtitleFiles(toFiles('Show.ass'), ''), [])
  assert.deepEqual(matchSubtitleFiles(toFiles('Show.ass'), undefined), [])
})

test('a release\'s fonts are collected, whatever the extension', () => {
  const files = toFiles('Show - 01.mkv', 'Show - 01.ass', 'Arial.ttf', 'Gothic.otf', 'Web.woff2', 'cover.jpg')
  assert.deepEqual(names(matchFontFiles(files)), ['Arial.ttf', 'Gothic.otf', 'Web.woff2'])
})

test('a font shipped once per language is only loaded once', () => {
  // file names are bare, so the same font under two folders collapses to one, as it does for torrents
  assert.equal(matchFontFiles(toFiles('Arial.ttf', 'Arial.ttf', 'Gothic.ttf')).length, 2)
})

test('a release with no fonts is not a problem', () => {
  assert.deepEqual(matchFontFiles(toFiles('Show.mkv', 'Show.ass')), [])
  assert.deepEqual(matchFontFiles([]), [])
  assert.deepEqual(matchFontFiles(null), [])
})

test('only Matroska containers are parsed for embedded metadata', () => {
  for (const name of ['Show.mkv', 'Show.MKV', 'Show.webm']) assert.ok(matroskaRx.test(name), name)
  for (const name of ['Show.mp4', 'Show.avi', 'Show.mkv.mp4', 'mkv.avi']) assert.ok(!matroskaRx.test(name), name)
})
