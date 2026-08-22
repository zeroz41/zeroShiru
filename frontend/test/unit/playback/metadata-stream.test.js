// The debrid playback pipeline end to end, against a real MKV (test/fixtures/episode.mkv,
// regenerable with test/tools/make-fixture.sh): a 600 second episode with a video track, an
// audio track, ASS and SRT subtitle tracks, chapters and a font attachment, served over mocked
// HTTP range requests. What is asserted is exactly what reaches the player's Subtitles
// instance — this is the parity a debrid stream owes a torrent stream.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { hex2arr, bin2hex } from 'uint8-util'
import DebridMetadata from '../../../common/modules/debrid/metadata.js'
import { FIXTURE, serveRemote, until, subtitleSpy } from './remote.js'

const URL_ = 'https://cdn.example.test/episode.mkv'
const video = { name: '[Group] Show - 01.mkv', url: URL_, size: FIXTURE.length }
const FONT_BYTES = new Uint8Array([0x00, 0x01, 0x00, 0x00, ...Array.from({ length: 64 }, (_, index) => index)])

/** getTime far past the end disables pacing, so the parser reads straight through. */
const UNPACED = () => Number.MAX_SAFE_INTEGER

function play ({ files = [video], getTime = UNPACED, onChapters, extra, playing = files[0] } = {}) {
  const state = serveRemote(FIXTURE, URL_, { extra })
  const spy = subtitleSpy()
  const metadata = new DebridMetadata(playing, files, spy, { getTime, onChapters })
  return { state, spy, metadata }
}

test('embedded subtitle tracks announce themselves with language, codec and name', async () => {
  const { spy, metadata } = play()
  await until(() => spy.seen.tracks.length >= 2)
  metadata.destroy()
  const byNumber = new Map(spy.seen.tracks.map(track => [track.number, track]))
  assert.equal(byNumber.size, 2, 'the fixture carries an ASS and an SRT track')
  const [ass, srt] = [...byNumber.values()]
  assert.equal(ass.type, 'ass')
  assert.equal(ass.language, 'eng')
  assert.equal(ass.name, 'Full Subtitles')
  assert.ok(ass.header.includes('[V4+ Styles]'), 'the ASS header travels with the track')
  assert.ok(ass.header.includes('Style: Signs'), 'custom styles included')
  assert.equal(srt.type, 'utf8')
  assert.equal(srt.language, 'spa')
})

test('subtitle cues stream from both tracks, with the payload the renderer consumes', async () => {
  const { spy, metadata } = play()
  await until(() => spy.seen.subtitles.length >= 85, 15_000)
  metadata.destroy()
  assert.ok(spy.seen.subtitles.length >= 85, `the fixture holds 90 cues, got ${spy.seen.subtitles.length}`)
  const tracks = new Set(spy.seen.subtitles.map(({ trackNumber }) => trackNumber))
  assert.equal(tracks.size, 2, 'both tracks must stream, not only the first')
  const first = spy.seen.subtitles.find(({ subtitle }) => subtitle.text?.includes('ASS cue 000'))
  assert.ok(first, 'the first ASS dialogue must arrive')
  assert.equal(first.subtitle.time, 0)
  assert.equal(first.subtitle.duration, 4000)
  assert.equal(first.subtitle.style, 'Signs', 'cue styling survives the trip')
  const srtCue = spy.seen.subtitles.find(({ subtitle }) => subtitle.text?.includes('SRT cue 001'))
  assert.ok(srtCue, 'SRT cues stream alongside ASS ones')
  assert.equal(srtCue.subtitle.time, 25_000)
})

test('chapters reach the player, which is what section jumping is built on', async () => {
  const chapters = []
  const { metadata } = play({ onChapters: found => chapters.push(...found) })
  await until(() => chapters.length >= 4)
  metadata.destroy()
  assert.deepEqual(chapters.map(chapter => chapter.text), ['Opening', 'Part A', 'Part B', 'Ending'])
  assert.deepEqual(chapters.map(chapter => chapter.start), [0, 150_000, 300_000, 450_000], 'chapter times in milliseconds')
  assert.equal(chapters[3].end, 600_000)
})

test('the embedded font reaches the renderer as a binary string that decodes byte for byte', async () => {
  const { spy, metadata } = play()
  await until(() => spy.seen.fonts.length >= 1)
  metadata.destroy()
  const decoded = hex2arr(bin2hex(spy.seen.fonts[0]))
  assert.equal(decoded.length, 1028, 'the fixture attachment is 1028 bytes')
  assert.deepEqual([...decoded.slice(0, 4)], [0x00, 0x01, 0x00, 0x00], 'and starts with the TTF magic')
})

test('external subtitles are fetched for the playing episode only, exactly as torrents match them', async () => {
  const files = [
    video,
    { name: '[Group] Show - 01.ass', url: 'https://cdn.example.test/01.ass', size: 100 },
    { name: '[Group] Show - 02.mkv', url: 'https://cdn.example.test/02.mkv', size: 100 },
    { name: '[Group] Show - 02.ass', url: 'https://cdn.example.test/02.ass', size: 100 }
  ]
  const sub = new TextEncoder().encode('[Script Info]\nTitle: External')
  const { state, spy, metadata } = play({
    files,
    extra: { 'https://cdn.example.test/01.ass': sub, 'https://cdn.example.test/02.ass': sub }
  })
  await until(() => spy.seen.files.length >= 1)
  metadata.destroy()
  assert.deepEqual(spy.seen.files.map(file => file.name), ['[Group] Show - 01.ass'], 'the other episode\'s subs must not load')
  assert.deepEqual(state.extraFetched, ['https://cdn.example.test/01.ass'], 'and must not even be downloaded')
})

test('external fonts are fetched and forwarded alongside embedded ones', async () => {
  const files = [video, { name: 'Gothic.ttf', url: 'https://cdn.example.test/gothic.ttf', size: FONT_BYTES.length }]
  const { spy, metadata } = play({ files, extra: { 'https://cdn.example.test/gothic.ttf': FONT_BYTES } })
  await until(() => spy.seen.fonts.length >= 2)
  metadata.destroy()
  const decoded = spy.seen.fonts.map(font => hex2arr(bin2hex(font)))
  assert.ok(decoded.some(bytes => bytes.length === FONT_BYTES.length && bytes[0] === 0 && bytes[3] === 0), 'the external font arrives intact')
})

test('a non-Matroska file skips container parsing but still loads its external subtitles', async () => {
  const mp4 = { name: 'Show - 01.mp4', url: 'https://cdn.example.test/show.mp4', size: 1000 }
  const sub = new TextEncoder().encode('1\n00:00:01,000 --> 00:00:02,000\nhi\n')
  const files = [mp4, { name: 'Show - 01.srt', url: 'https://cdn.example.test/01.srt', size: sub.length }]
  const state = serveRemote(FIXTURE, URL_, { extra: { 'https://cdn.example.test/01.srt': sub } })
  const spy = subtitleSpy()
  const metadata = new DebridMetadata(mp4, files, spy, { getTime: UNPACED })
  await until(() => spy.seen.files.length >= 1)
  metadata.destroy()
  assert.equal(spy.seen.files[0].name, 'Show - 01.srt')
  assert.equal(state.requests.length, 0, 'no range request may touch a container the parser cannot read')
})

test('pacing holds the parser near the playback position instead of downloading the file', async () => {
  // playback sits at 0:00; the streaming read may buffer the pacing window ahead (120s of
  // video, ~14KB of this fixture) and no further. The header reads the parser makes on top are
  // small and bounded, so total transfer stays a fraction of the file.
  const { state, spy, metadata } = play({ getTime: () => 0 })
  await until(() => spy.seen.subtitles.length >= 5)
  await new Promise(resolve => setTimeout(resolve, 1_500)) // give an unpaced bug time to run away
  const streaming = state.requests.at(-1)
  const times = spy.seen.subtitles.map(({ subtitle }) => subtitle.time)
  metadata.destroy()
  assert.ok(streaming.served < 25_000, `the streaming read must stop near the pacing window, served ${streaming.served}`)
  assert.ok(state.served < FIXTURE.length * 0.8, `most of the file must stay undownloaded, served ${state.served} of ${FIXTURE.length}`)
  assert.ok(Math.max(...times) < 300_000, `cues far past the pacing window must not have streamed yet, saw one at ${Math.max(...times)}ms`)
})

test('destroy aborts every range request in flight', async () => {
  const { state, spy, metadata } = play({ getTime: () => 0 })
  await until(() => spy.seen.subtitles.length >= 1)
  metadata.destroy()
  await until(() => state.requests.every(request => request.done || request.aborted))
  assert.ok(state.requests.every(request => request.done || request.aborted), 'a torn down player must not keep downloading')
  const events = spy.seen.subtitles.length
  await new Promise(resolve => setTimeout(resolve, 300))
  assert.equal(spy.seen.subtitles.length, events, 'no events after destroy')
})

test('every read the parser opens stops early, and lets go of its connection', async () => {
  // Each container tag the parser wants opens `bytes=0-` — the whole file — and breaks out
  // the moment it has its tag. The abort in the stream's `finally` is the only thing that
  // ends those requests, so NOTHING may be awaited before it.
  //
  // A caution, because this test would not have caught the bug that prompted it: the mock's
  // body is an async generator and lets go the instant it is abandoned, where a real network
  // stream does not. An `await reader.cancel()` was once put in front of that abort to tidy
  // an AbortError out of the log; every suite here stayed green and the user could not play
  // anything. Treat teardown order in RemoteFile as something tests cannot fully vouch for.
  const { state, spy, metadata } = play({ getTime: () => 0 })
  await until(() => spy.seen.subtitles.length >= 3, 8_000)
  metadata.destroy()
  await until(() => state.requests.every(request => request.done || request.aborted), 3_000)
  const holding = state.requests.filter(request => !request.done && !request.aborted)
  assert.deepEqual(holding.map(request => request.start), [], 'every read must have let go of its connection')
  const runaway = state.requests.filter(request => request.served > 30_000)
  assert.deepEqual(runaway.map(request => request.start), [], 'no read may drain the file looking for a tag')
  assert.ok(state.served < FIXTURE.length, `starting up must not cost the file once over, served ${state.served} of ${FIXTURE.length}`)
})
