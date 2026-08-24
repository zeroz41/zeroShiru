// The restart livelock, reproduced against the real streaming stack. main.log
// 2026-08-23 01:24: on a slow link the old watcher aborted the subtitle stream every time
// the playhead's cluster got more than 1MB past the parser — once a second, every restart
// paying connection latency and delivering nothing, for the rest of the episode. These
// tests drive DebridMetadata over the fixture with a playhead that ADVANCES (playback)
// versus one that JUMPS (seeks), and count the connections. The distinction between those
// two is the entire fix.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import DebridMetadata from '../../../common/modules/debrid/metadata.js'
import { FIXTURE, serveRemote, until, subtitleSpy } from './remote.js'

const URL_ = 'https://cdn.example.test/episode.mkv'
const video = { name: '[Group] Show - 01.mkv', url: URL_, size: FIXTURE.length }

class FastMetadata extends DebridMetadata {
  static STALL_TIMEOUT = 5_000
  static WATCH_INTERVAL = 50
  static SETTLE_MS = 200
  /** Tiny slack so the fixture's ~115B/s byte rate can exceed it: 10s ≈ 1.2KB. */
  static DRIFT_SLACK_SECONDS = 10
  static DRIFT_INTERVAL_MS = 1_500
}

const streamRequests = state => state.requests.filter(request => request.openEnded)

test('playback outrunning a slow parser opens catch-up connections at the rate limit, not per tick', async () => {
  // chunks crawl: the parser cannot keep up with a playhead advancing at 4x
  const state = serveRemote(FIXTURE, URL_, { chunkSize: 512, delay: 100 })
  const spy = subtitleSpy()
  const clock = { time: 0 }
  const metadata = new FastMetadata(video, [video], spy, { getTime: () => clock.time })
  const advance = setInterval(() => { clock.time += 1 }, 100) // continuous playback, never a jump
  try {
    await until(() => clock.time >= 120, 30_000)
    const opened = streamRequests(state).length
    // ~12s of wall clock at a 1.5s rate limit allows ~9 catch-ups at the theoretical
    // worst; the old per-tick livelock would have opened one per 50ms watcher tick.
    // What matters is the order of magnitude, and that cues flowed while behind.
    assert.ok(opened <= 12, `continuous playback must not restart the stream per tick, saw ${opened} connections`)
    assert.ok(spy.seen.subtitles.length > 0, 'cues still flow while behind')
  } finally {
    clearInterval(advance)
    metadata.destroy()
  }
}, 40_000)

test('a scrub storm coalesces into one restart after the hand comes off the bar', async () => {
  const state = serveRemote(FIXTURE, URL_, { chunkSize: 1024 })
  const spy = subtitleSpy()
  const clock = { time: 0 }
  const metadata = new FastMetadata(video, [video], spy, { getTime: () => clock.time })
  await until(() => spy.seen.subtitles.length >= 2, 10_000)
  const before = streamRequests(state).length
  // the user drags the bar: a new position every 60ms for a second and a half
  for (let i = 0; i < 25; i++) {
    clock.time = 60 + i * 18
    await new Promise(resolve => setTimeout(resolve, 60))
  }
  const landed = clock.time
  await until(() => streamRequests(state).length > before, 8_000)
  await new Promise(resolve => setTimeout(resolve, 1_200)) // give a storm time to show itself
  const during = streamRequests(state).length - before
  metadata.destroy()
  assert.ok(during <= 2, `a scrub must not open a connection per position, saw ${during}`)
  assert.ok(landed > 400, 'sanity: the scrub went far outside the parsed window')
}, 30_000)

test('a settled seek still restarts promptly — coalescing must not cost responsiveness', async () => {
  const state = serveRemote(FIXTURE, URL_, { chunkSize: 1024 })
  const spy = subtitleSpy()
  const clock = { time: 0 }
  const metadata = new FastMetadata(video, [video], spy, { getTime: () => clock.time })
  await until(() => spy.seen.subtitles.length >= 2, 10_000)
  clock.time = 450
  const jumped = Date.now()
  await until(() => spy.seen.subtitles.some(({ subtitle }) => Math.abs(subtitle.time - 450_000) <= 45_000), 10_000)
  const waited = Date.now() - jumped
  metadata.destroy()
  assert.ok(waited < 8_000, `cues near the seek must arrive promptly, took ${waited}ms`)
}, 30_000)
