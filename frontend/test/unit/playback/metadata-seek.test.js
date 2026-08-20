// Seeking, resuming and surviving bad connections in the debrid subtitle stream. These drive
// the same DebridMetadata the player uses over the real MKV fixture, moving a fake playback
// clock the way a user moves the seek bar. The failure they were written against: a seek while
// the connection was stalled never restarted the stream, because a seek was only ever noticed
// while chunks were arriving — on a bad link, subtitles died the moment the user jumped ahead.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import DebridMetadata from '../../../common/modules/debrid/metadata.js'
import { FIXTURE, serveRemote, until, subtitleSpy } from './remote.js'

const URL_ = 'https://cdn.example.test/episode.mkv'
const video = { name: '[Group] Show - 01.mkv', url: URL_, size: FIXTURE.length }
// the fixture: 600s, ~69KB, so ~115 bytes of file per second of video
const BYTE_RATE = FIXTURE.length / 600

/** DebridMetadata with test-speed timings: stalls are called in fractions of a second. */
class FastMetadata extends DebridMetadata {
  static STALL_TIMEOUT = 700
  static WATCH_INTERVAL = 100
}

function play (opts = {}) {
  // small chunks so byte budgets measure pacing rather than chunk granularity
  const state = serveRemote(FIXTURE, URL_, { chunkSize: 1024, ...opts })
  const spy = subtitleSpy()
  const clock = { time: opts.time ?? 0 }
  const metadata = new FastMetadata(video, [video], spy, { getTime: () => clock.time })
  return { state, spy, clock, metadata }
}

const cueTimes = spy => spy.seen.subtitles.map(({ subtitle }) => subtitle.time)
const cueNear = (spy, seconds, slack = 45) => cueTimes(spy).some(time => Math.abs(time - seconds * 1_000) <= slack * 1_000)

test('a seek far ahead restarts the stream near the seek instead of reading everything between', async () => {
  const { state, spy, clock, metadata } = play()
  await until(() => spy.seen.subtitles.length >= 3)

  clock.time = 450 // the user jumps to the last quarter
  const target = (450 - 15) * BYTE_RATE // the stream must land a little before the seek
  await until(() => state.requests.some(request => request.start >= target * 0.8 && request.start <= 455 * BYTE_RATE), 8_000)
  const jumpRequest = state.requests.find(request => request.start >= target * 0.8)
  assert.ok(jumpRequest, `a range request must restart near the seek, saw starts: ${state.requests.map(request => request.start).join(', ')}`)

  await until(() => cueNear(spy, 450), 8_000)
  metadata.destroy()
  assert.ok(cueNear(spy, 450), `cues near the seek must stream, saw times: ${[...new Set(cueTimes(spy))].join(', ')}`)
  assert.ok(state.served < FIXTURE.length * 0.8, `the middle of the file must not have been downloaded to get there, served ${state.served}`)
})

test('resuming an episode part-way jumps straight to the resume point', async () => {
  // the player restores watch progress before playback starts, so getTime is already deep into
  // the episode by the time the subtitle stream spins up — the debrid-pack resume case
  const { state, spy, clock, metadata } = play({ time: 450 })
  await until(() => cueNear(spy, 450), 8_000)
  metadata.destroy()
  assert.ok(cueNear(spy, 450), 'subtitles at the resume position must arrive')
  assert.ok(clock.time === 450, 'sanity: playback never moved')
  const sequential = state.requests.filter(request => request.start === 0)
  assert.ok(sequential.every(request => request.served < 25_000), 'the head of the file must not stream past the pacing window on the way')
  assert.ok(state.served < FIXTURE.length * 0.8, `resume must not cost the whole file, served ${state.served}`)
})

test('a seek back before the parsed window restarts the stream behind the seek', async () => {
  const { state, spy, clock, metadata } = play({ time: 450 })
  await until(() => cueNear(spy, 450), 8_000)

  clock.time = 30 // jump back to near the start
  await until(() => cueNear(spy, 30, 30), 8_000)
  metadata.destroy()
  assert.ok(cueNear(spy, 30, 30), `cues near the backward seek must stream, saw: ${[...new Set(cueTimes(spy))].join(', ')}`)
  const restarts = state.requests.filter(request => request.start <= 30 * BYTE_RATE)
  assert.ok(restarts.length >= 1, 'a range request must restart at or before the seek')
})

test('a seek while the connection is stalled still restarts the stream', async () => {
  // the head of the file loads, then the connection dies silently: bytes stop, nothing errors.
  // A seek must abort that read and land near the target anyway — this used to hang forever.
  const { state, spy, clock, metadata } = play({
    behave: (request, position) => request.start === 0 && position >= 8_192 ? 'stall' : undefined
  })
  await until(() => spy.seen.subtitles.length >= 1)

  clock.time = 450
  await until(() => cueNear(spy, 450), 8_000)
  metadata.destroy()
  assert.ok(cueNear(spy, 450), 'the seek must escape the stalled request')
  const stalledRequest = state.requests.find(request => request.start === 0)
  assert.ok(stalledRequest.aborted, 'the stalled request must have been torn down, not left hanging')
})

test('a connection that goes quiet is retried, and subtitles resume where they stopped', async () => {
  // the stream delivers ~8KB then stalls without erroring; the stall watchdog must abort and
  // retry the read rather than trust a dead socket forever
  let stalls = 0
  const { state, spy, metadata } = play({
    behave: (request, position) => {
      if (request.start === 0 && position >= 8_192 && stalls === 0) {
        stalls++
        return 'stall'
      }
    }
  })
  await until(() => state.requests.some(request => request.start >= 4_096 && request.served > 0), 8_000)
  await until(() => spy.seen.subtitles.length >= 8, 8_000)
  metadata.destroy()
  assert.ok(stalls === 1 && spy.seen.subtitles.length >= 8, `the retry must pick the stream back up, got ${spy.seen.subtitles.length} cues`)
  const retry = state.requests.at(-1)
  assert.ok(retry.start >= 4_096, `the retry must resume near where the stall cut off, not from zero, started at ${retry.start}`)
})

test('a connection error mid-stream is retried from the same offset', async () => {
  let dropped = false
  const { state, spy, metadata } = play({
    behave: (request, position) => {
      if (request.start === 0 && position >= 8_192 && !dropped) {
        dropped = true
        return 'error'
      }
    }
  })
  await until(() => spy.seen.subtitles.length >= 8, 10_000)
  metadata.destroy()
  assert.ok(dropped, 'sanity: the error fired')
  assert.ok(spy.seen.subtitles.length >= 8, 'cues keep streaming after the drop')
  const retry = state.requests.find(request => request.start >= 4_096 && request.start <= 12_288)
  assert.ok(retry, `the retry must resume from the failure offset, saw starts: ${state.requests.map(request => request.start).join(', ')}`)
})

test('a link that keeps dying is given up on after its retries, quietly', async () => {
  const { state, metadata } = play({
    behave: (request, position) => position >= 4_096 ? 'error' : undefined
  })
  // three attempts with backoff; wait for the retry loop to exhaust itself
  await until(() => state.requests.filter(request => request.done).length >= 3, 15_000)
  await new Promise(resolve => setTimeout(resolve, 500))
  const attempts = state.requests.length
  await new Promise(resolve => setTimeout(resolve, 1_500))
  assert.ok(state.requests.length - attempts <= 1, 'a dead link must not be retried forever')
  metadata.destroy()
})

test('seeking during the retry backoff of a dead link does not crash the stream', async () => {
  const { spy, clock, metadata } = play({
    behave: (request, position) => request.start < 30_000 && position >= 4_096 ? 'error' : undefined
  })
  await new Promise(resolve => setTimeout(resolve, 300))
  clock.time = 450 // seek while the head of the file refuses to stream
  await until(() => cueNear(spy, 450), 10_000)
  metadata.destroy()
  assert.ok(cueNear(spy, 450), 'the seek target streams fine, so the seek must recover the stream')
})

test('a stream that gave up comes back when the user seeks somewhere that works', async () => {
  // the complaint this answers: subtitles die mid-episode and never return, however far
  // you seek. Three stalls on a busy link is enough to spend the retries, and nothing
  // used to restart the stream afterwards — the loop that noticed seeks had exited
  const { state, spy, clock, metadata } = play({
    // the head of the file is a dead link; everything past the halfway mark streams fine
    behave: (request, position) => request.start < 20_000 && position >= 4_096 ? 'error' : undefined
  })
  await until(() => state.requests.filter(request => request.done).length >= 3, 15_000)
  // and past the last backoff, so the retry loop has really exited: a seek that lands
  // while it is still sleeping is caught by the loop itself and proves nothing
  await new Promise(resolve => setTimeout(resolve, 5_000))
  const spent = state.requests.length
  await new Promise(resolve => setTimeout(resolve, 1_000))
  assert.equal(state.requests.length, spent, 'sanity: the stream has given up, and asks the dead link for nothing')

  clock.time = 450 // the user jumps to the last quarter
  await until(() => cueNear(spy, 450), 10_000)
  metadata.destroy()
  assert.ok(cueNear(spy, 450), `subtitles must resume at the seek, saw times: ${[...new Set(cueTimes(spy))].join(', ')}`)
}, 40_000) // the retry budget plus its backoff has to be spent before the seek means anything
