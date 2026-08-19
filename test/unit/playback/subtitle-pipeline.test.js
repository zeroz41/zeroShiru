// The player's Subtitles pipeline: format conversion, track bookkeeping, renderer feeding and
// track auto-selection. This is the consumer of everything DebridMetadata (and the torrent
// client) produces, so a regression here breaks subtitles for both transports at once. The
// browser-only pieces (JASSUB, settings, bridge) are stubbed by the test loader; everything
// else is the real class the player instantiates.
import { test, beforeEach } from 'bun:test'
import assert from 'node:assert/strict'
import Subtitles from '@/modules/subtitles.js'
import JASSUB from 'jassub'
// the '@/' specifier matters: it resolves to the loader's settings stub, the same one
// subtitles.js sees, so the test can steer subtitleLanguage
import { settings } from '@/modules/settings.js'

const assHeader = `[Script Info]
Title: Test
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,Roboto,52
Style: Signs,Roboto,40
Style: Songs,Roboto,44
[Events]
`

const track = (number, overrides = {}) => ({ number, type: 'ass', header: assHeader, language: 'eng', ...overrides })

function player (selectedName = 'Show - 01.mkv') {
  const headers = []
  const subtitles = new Subtitles(null, [], { name: selectedName }, () => headers.push('header'))
  return { subtitles, headers }
}

beforeEach(() => {
  JASSUB.instances.length = 0
  settings.value = { ...settings.value, subtitleLanguage: 'eng' }
})

// --- format conversion, the pure core everything rides on ---

test('SRT converts to ASS dialogue lines with timestamps and formatting intact', () => {
  const srt = '1\n00:00:01,000 --> 00:00:02,500\nHello <i>world</i>\n\n2\n01:02:03,400 --> 01:02:04,000\nSecond\n'
  const lines = Subtitles.convertSubText(srt, 'srt')
  assert.equal(lines.length, 2)
  assert.match(lines[0], /^Dialogue: 0,0:00:01\.00,0:00:02\.50,Default,/)
  assert.ok(lines[0].includes('Hello {\\i1}world{\\i0}'), 'html tags become ASS overrides')
  assert.match(lines[1], /1:02:03\.40,1:02:04\.00/, 'hour timestamps survive')
})

test('multi-line SRT cues become \\N line breaks', () => {
  const [line] = Subtitles.convertSubText('1\n00:00:01,000 --> 00:00:02,000\nfirst\nsecond\n', 'srt')
  assert.ok(line.includes('first\\Nsecond'), line)
})

test('VTT converts through the same path as SRT', () => {
  const vtt = '1\n00:00:05.000 --> 00:00:06.000\nA <b>cue</b>\n'
  const [line] = Subtitles.convertSubText(vtt, 'vtt')
  assert.ok(line.includes('A {\\b1}cue{\\b0}'))
})

test('MicroDVD .sub frames convert using the embedded frame rate', () => {
  const sub = '{1}{1}25\n{25}{50}Hello|world\n{75}{100}Second\n'
  const lines = Subtitles.convertSubText(sub, 'sub')
  assert.ok(lines.length >= 2)
  assert.match(lines[lines.length - 2], /0:00:01\.00.*0:00:02\.00/, '25fps: frame 25 is one second')
  assert.ok(lines[lines.length - 2].includes('Hello\\Nworld'), 'pipes are MicroDVD line breaks')
})

test('ASS text passes through untouched', () => {
  assert.equal(Subtitles.convertSubText(assHeader, 'ass'), assHeader)
})

test('a subtitle with a lying extension is sniffed and converted anyway', () => {
  const srt = '1\n00:00:01,000 --> 00:00:02,000\nmislabeled\n'
  const lines = Subtitles.convertSubText(srt, 'txt')
  assert.ok(Array.isArray(lines) && lines[0].includes('mislabeled'), 'subbers mislabel extensions routinely')
})

test('unconvertible text yields nothing rather than garbage dialogue', () => {
  assert.equal(Subtitles.convertSubText('just some prose, no timestamps', 'txt'), undefined)
})

// --- track handling and the renderer feed ---

test('embedded tracks register headers, parse style maps and spin up the renderer', () => {
  const { subtitles, headers } = player()
  subtitles.handleTracks([track(3)])
  assert.ok(subtitles.headers[3], 'the track is registered under its Matroska number')
  assert.deepEqual(subtitles._stylesMap[3], { Default: 1, Signs: 2, Songs: 3 }, 'styles map to their header order')
  assert.equal(JASSUB.instances.length, 1, 'the renderer starts once tracks exist')
  assert.ok(headers.length > 0, 'the UI is told the track list changed')
  subtitles.destroy()
})

test('cues route to the renderer with resolved style indices', () => {
  const { subtitles } = player()
  subtitles.handleTracks([track(3)])
  subtitles.handleSubtitle({ subtitle: { text: 'styled', time: 0, duration: 2000, style: 'Signs' }, trackNumber: 3 })
  subtitles.handleSubtitle({ subtitle: { text: 'unknown style', time: 100, duration: 2000, style: 'NotThere' }, trackNumber: 3 })
  const [styled, unknown] = JASSUB.instances[0].events
  assert.equal(styled.Style, 2, 'the Signs style index from the header')
  assert.equal(styled.Text, 'styled')
  assert.equal(unknown.Style, 0, 'an unknown style falls back rather than crashing the renderer')
  subtitles.destroy()
})

test('a duplicate cue is dropped, so overlapping parses cannot double-render', () => {
  const { subtitles } = player()
  subtitles.handleTracks([track(3)])
  const cue = { subtitle: { text: 'once', time: 0, duration: 1000 }, trackNumber: 3 }
  subtitles.handleSubtitle(cue)
  subtitles.handleSubtitle({ subtitle: { ...cue.subtitle }, trackNumber: 3 })
  assert.equal(subtitles.tracks[3].length, 1, 'the seek-restart overlap case: the renderer deduplicates')
  subtitles.destroy()
})

test('non-ASS tracks get the default header and their cues converted on the way in', () => {
  const { subtitles } = player()
  subtitles.handleTracks([track(4, { type: 'utf8', header: 'WEBVTT' })])
  assert.ok(subtitles.headers[4].header.includes('[V4+ Styles]'), 'a synthesized ASS header replaces the container one')
  subtitles.handleSubtitle({ subtitle: { text: 'a <i>tag</i> &amp; entity\nsecond', time: 0, duration: 1000 }, trackNumber: 4 })
  const [event] = JASSUB.instances[0].events
  assert.equal(event.Text, 'a {\\i1}tag{\\i0} & entity\\Nsecond', 'tags, entities and newlines all convert')
  subtitles.destroy()
})

// --- track auto-selection, the "wrong subtitles" class of bug ---

test('the configured language wins when a release carries several tracks', () => {
  settings.value = { ...settings.value, subtitleLanguage: 'spa' }
  const { subtitles } = player()
  subtitles.handleTracks([track(3, { language: 'eng' }), track(4, { language: 'spa' })])
  assert.equal(subtitles.current, 4, 'Spanish was asked for')
  subtitles.destroy()
})

test('a missing preferred language falls back to English, then to the first track', () => {
  settings.value = { ...settings.value, subtitleLanguage: 'ger' }
  const { subtitles } = player()
  subtitles.handleTracks([track(3, { language: 'fre' }), track(4, { language: 'eng' })])
  assert.equal(subtitles.current, 4, 'English is the fallback')
  subtitles.destroy()

  const second = player().subtitles
  second.handleTracks([track(5, { language: 'fre' }), track(6, { language: 'jpn' })])
  assert.equal(second.current, 5, 'no English either: the first track')
  second.destroy()
})

test('a track with no language tag counts as English, which most releases rely on', () => {
  const { subtitles } = player()
  subtitles.handleTracks([track(3, { language: null }), track(4, { language: 'spa' })])
  assert.equal(subtitles.current, 3)
  subtitles.destroy()
})

test('a lone track is selected regardless of language settings', () => {
  settings.value = { ...settings.value, subtitleLanguage: 'ger' }
  const { subtitles } = player()
  subtitles.handleTracks([track(3, { language: 'jpn' })])
  assert.equal(subtitles.current, 3)
  subtitles.destroy()
})

test('selecting a track replays its cues into the renderer', () => {
  const { subtitles } = player()
  subtitles.handleTracks([track(3), track(4, { language: 'spa' })])
  subtitles.handleSubtitle({ subtitle: { text: 'spanish cue', time: 0, duration: 1000 }, trackNumber: 4 })
  const renderer = JASSUB.instances[0]
  renderer.events.length = 0
  subtitles.selectCaptions(4)
  assert.equal(subtitles.current, 4)
  assert.equal(renderer.events.length, 1, 'stored cues replay on switch')
  assert.equal(renderer.events[0].Text, 'spanish cue')
  subtitles.destroy()
})

// --- external subtitle files, the debrid pack path ---

test('an external subtitle file becomes a selectable track named by its language suffix', async () => {
  const { subtitles } = player('Show - 01.mkv')
  await subtitles.addSingleSubtitleFile(new File(['1\n00:00:01,000 --> 00:00:02,000\nexternal cue\n'], 'Show - 01.eng.srt'))
  const header = subtitles.headers.find(Boolean)
  assert.ok(header, 'the file registers as a track')
  assert.equal(header.language, 'eng', 'the language comes from the suffix left after the video name')
  assert.ok(header.number >= 100, 'external tracks number after any embedded ones')
  assert.equal(subtitles.current, header.number, 'the first external file self-selects')
  assert.ok(header.header.includes('external cue'), 'converted dialogue lands in the track header')
  subtitles.destroy()
})

test('an external file that is not a subtitle registers nothing playable', async () => {
  const { subtitles } = player()
  await subtitles.addSingleSubtitleFile(new File(['definitely not subtitles'], 'Show - 01.txt'))
  const header = subtitles.headers.find(Boolean)
  assert.ok(!header?.header.includes('definitely not'), 'junk must not become dialogue')
  subtitles.destroy()
})

test('destroy tears the pipeline down without touching a torn-down renderer again', () => {
  const { subtitles } = player()
  subtitles.handleTracks([track(3)])
  const renderer = JASSUB.instances[0]
  subtitles.destroy()
  assert.equal(renderer.destroyed, true)
  assert.equal(subtitles.headers, null)
  assert.doesNotThrow(() => subtitles.destroy(), 'a second destroy is a no-op, not a crash')
})
