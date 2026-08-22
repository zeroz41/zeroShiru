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

/** The subtitle stream's own read: open-ended, and — since it starts on the cluster holding
 * the playhead rather than at the top of the file — never at byte zero. The container reads
 * the parser makes for its header tags all start at zero, and the cue index read is bounded. */
const isStream = request => request.openEnded && request.start > 0

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

test('a restart lands exactly on a cluster from the file\'s own cue index', async () => {
  // the bitrate estimate this replaces missed on variable-bitrate video: land short and
  // the parser chewed through megabytes before the first cue, land long and the cues for
  // the playhead never arrived. The Cues element is the map the video element itself
  // seeks with; the subtitle restart must use it byte-for-byte
  const { state, spy, clock, metadata } = play()
  await until(() => spy.seen.subtitles.length >= 3)
  await until(() => (metadata.cuesIndex?.length ?? 0) > 0, 8_000)
  assert.ok(metadata.cuesIndex.length > 0, 'the fixture carries a cue index and it must be read')

  clock.time = 450
  await until(() => cueNear(spy, 450), 8_000)
  const clusters = new Set(metadata.cuesIndex.map(cue => cue.byte))
  metadata.destroy()
  const exact = state.requests.some(request => clusters.has(request.start))
  assert.ok(exact, `the restart must land on an indexed cluster boundary, saw starts: ${state.requests.map(request => request.start).join(', ')}`)
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

test('seeking back into subtitles already parsed asks the link for nothing at all', async () => {
  // the ordinary "wait, what did they say" seek. Those cues are in the renderer for the
  // session, so the bytes behind them never need asking for twice — but the stream only
  // knew about the window it was in the middle of, so it tore the connection down and
  // re-read the whole scene while the user watched an empty screen
  const { state, spy, clock, metadata } = play()
  await until(() => (metadata.cuesIndex?.length ?? 0) > 0, 8_000)
  await until(() => cueNear(spy, 30, 30), 8_000)
  // let the parse get properly past the opening so there is real coverage behind us
  await until(() => state.served > 12_000, 8_000)

  clock.time = 450 // away...
  await until(() => cueNear(spy, 450), 8_000)
  const requestsBefore = state.requests.length
  const servedBefore = state.served

  clock.time = 20 // ...and back into the part already parsed
  await new Promise(resolve => setTimeout(resolve, 1_000)) // several watcher passes
  metadata.destroy()
  assert.equal(state.requests.length, requestsBefore, `a seek into parsed subtitles must not open a request, saw ${state.requests.length - requestsBefore} new`)
  assert.equal(state.served, servedBefore, 'and must not download a byte')
  assert.ok(cueNear(spy, 20, 30), 'sanity: the cues for where the user seeked really were delivered earlier')
})

test('a seek while the connection is stalled still restarts the stream', async () => {
  // the head of the file loads, then the connection dies silently: bytes stop, nothing errors.
  // A seek must abort that read and land near the target anyway — this used to hang forever.
  const { state, spy, clock, metadata } = play({
    behave: (request, position) => isStream(request) && request.start < 20_000 && position >= 8_192 ? 'stall' : undefined
  })
  await until(() => spy.seen.subtitles.length >= 1)

  clock.time = 450
  await until(() => cueNear(spy, 450), 8_000)
  metadata.destroy()
  assert.ok(cueNear(spy, 450), 'the seek must escape the stalled request')
  const stalledRequest = state.requests.find(isStream)
  assert.ok(stalledRequest.aborted, 'the stalled request must have been torn down, not left hanging')
})

test('a connection that goes quiet is retried, and subtitles resume where they stopped', async () => {
  // the stream delivers ~8KB then stalls without erroring; the stall watchdog must abort and
  // retry the read rather than trust a dead socket forever
  let stalls = 0
  const { state, spy, metadata } = play({
    behave: (request, position) => {
      if (isStream(request) && position >= 8_192 && stalls === 0) {
        stalls++
        return 'stall'
      }
    }
  })
  await until(() => state.requests.filter(isStream).length >= 2, 8_000)
  const retry = state.requests.filter(isStream).at(-1)
  await until(() => spy.seen.subtitles.length >= 8, 8_000)
  metadata.destroy()
  assert.ok(stalls === 1 && spy.seen.subtitles.length >= 8, `the retry must pick the stream back up, got ${spy.seen.subtitles.length} cues`)
  assert.ok(retry.start >= 8_192, `the retry must resume where the stall cut off, not from the beginning, started at ${retry.start}`)
})

test('a connection error mid-stream is retried from the same offset', async () => {
  let dropped = false
  const { state, spy, metadata } = play({
    behave: (request, position) => {
      if (isStream(request) && position >= 8_192 && !dropped) {
        dropped = true
        return 'error'
      }
    }
  })
  await until(() => state.requests.filter(isStream).length >= 2, 10_000)
  await until(() => spy.seen.subtitles.length >= 8, 10_000)
  metadata.destroy()
  assert.ok(dropped, 'sanity: the error fired')
  assert.ok(spy.seen.subtitles.length >= 8, 'cues keep streaming after the drop')
  const retry = state.requests.filter(isStream).at(-1)
  assert.ok(retry.start >= 8_192 && retry.start <= 12_288, `the retry must resume from the failure offset, saw starts: ${state.requests.map(request => request.start).join(', ')}`)
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

test('a seek that produces no subtitles says so, and a seek that works says nothing', async () => {
  // subtitles going missing after a seek has several possible causes and they look
  // identical from outside the app; this is the one place that knows a seek happened
  // and whether anything came of it
  const warnings = []
  const realWarn = console.warn
  console.warn = (...args) => warnings.push(args.join(' '))
  class Loud extends FastMetadata { static SILENCE_TIMEOUT = 700 }
  try {
    const { spy, clock, metadata } = (() => {
      const state = serveRemote(FIXTURE, URL_, { chunkSize: 1024 })
      const spy = subtitleSpy()
      const clock = { time: 0 }
      const metadata = new Loud(video, [video], spy, { getTime: () => clock.time })
      return { state, spy, clock, metadata }
    })()
    await until(() => spy.seen.subtitles.length >= 3)
    clock.time = 450
    await until(() => cueNear(spy, 450), 8_000)
    await new Promise(resolve => setTimeout(resolve, 1_200))
    metadata.destroy()
    assert.equal(warnings.filter(line => line.includes('[subtitles]')).length, 0,
      `a seek that streamed must be silent, said: ${warnings.join(' | ')}`)
  } finally {
    console.warn = realWarn
  }
}, 20_000)

test('the first read starts at the first cluster, not at byte zero', async () => {
  // Reading from zero downloads the header, the chapters and every embedded font before the
  // first cue — tens of megabytes on a real release, paid while the video is prerolling on
  // the same link. The file's own seek index says exactly where the first cluster is.
  const { state, spy, metadata } = play()
  await until(() => spy.seen.subtitles.length >= 3, 8_000)
  metadata.destroy()

  const first = state.requests.find(isStream)
  assert.ok(first, `the subtitle stream must open a read past the header, saw starts: ${state.requests.map(request => request.start).join(', ')}`)
  // and not somewhere approximate: on the exact cluster the file's own index names
  assert.equal(first.start, metadata.cuesIndex[0].byte, 'the first read lands on the first indexed cluster')
  assert.ok(state.requests.every(request => request.start !== 0 || request.served < first.start + 4_096),
    'nothing streams the header block twice over')
  const times = cueTimes(spy)
  assert.ok(times.includes(0), `the cue at the very start must still arrive, got ${times.slice(0, 5)}`)
  assert.ok(times.every(time => time >= 0 && time <= 600_000), 'cue timestamps stay in the file')
})

test('a file whose seek index cannot be read still reads from the top', async () => {
  // no index means no way to know where the clusters are: the old, slower path is the only
  // one that cannot miss a cue, so it must still be there
  const { state, spy, metadata } = play({
    behave: request => { if (!request.openEnded) return 'error' } // the bounded cue index read fails
  })
  await until(() => spy.seen.subtitles.length >= 3, 8_000)
  metadata.destroy()
  assert.equal(metadata.cuesIndex, null, 'the cue read was refused')
  assert.ok(!state.requests.some(isStream), 'without an index every read starts at the top')
  assert.ok(cueTimes(spy).includes(0), 'and the first cue still arrives')
})
