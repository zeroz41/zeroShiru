// Subtitle feature-parity test against a real debrid stream.
//
// This drives the actual DebridMetadata class the player uses — not a mirror of it — with
// a stand-in for the Subtitles instance, so what is asserted here is exactly what reaches
// the player: embedded tracks, streamed subtitle events, embedded fonts, chapters, and
// external subtitle files matched to the playing episode.
//
//   TORBOX_API_KEY=<key> TB_TEST_PACK_HASH=<hash of a cached MKV> bun run test:live
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import DebridMetadata from '../../../common/modules/debrid/metadata.js'
import { matchSubtitleFiles } from '../../../common/modules/util.js'
import { resolveTorBox } from '../../tools/live-link.js'
import { skipped } from '../../tools/skip.js'

const KEY = process.env.TORBOX_API_KEY
const HASH = process.env.TB_TEST_PACK_HASH || process.env.TORBOX_TEST_HASH
const EPISODE = process.env.TB_TEST_PACK_EPISODE
const skip = !KEY ? 'TORBOX_API_KEY not set' : (!HASH ? 'TB_TEST_PACK_HASH not set (a cached MKV release)' : false)
// enough of the file to prove subtitle events actually stream, without pulling the whole MKV
const STREAM_BUDGET_MS = 120_000

/**
 * Measures how fast the stream host actually delivers, in bytes per second. Cue streaming
 * is bandwidth-bound: the parser has to read through the container to reach dialogue, so on
 * a link slower than the release's own bitrate, no cues inside a fixed budget is the
 * expected outcome rather than a defect. Measuring lets the test say which one it saw.
 */
async function measureThroughput (url, bytes = 2 * 1024 * 1024) {
  const started = Date.now()
  const res = await fetch(url, { headers: { Range: `bytes=0-${bytes - 1}` } })
  const body = await res.arrayBuffer()
  return body.byteLength / ((Date.now() - started) / 1000)
}

/** Captures everything DebridMetadata would hand to the player's Subtitles instance. */
function subtitleSpy () {
  const seen = { tracks: [], subtitles: [], fonts: [], files: [] }
  return {
    seen,
    handleTracks: tracks => seen.tracks.push(...tracks),
    handleSubtitle: event => seen.subtitles.push(event),
    handleFile: data => seen.fonts.push(data),
    handleSubtitleFile: file => seen.files.push(file)
  }
}

test('a debrid stream feeds the player the same subtitle data a torrent would', { skip, timeout: 300_000 }, async () => {
  const resolved = await resolveTorBox(HASH, { filter: name => /\.(mkv|mp4|ass|srt)$/i.test(name) })
  const videos = resolved.files.filter(file => /\.mkv$/i.test(file.name))
  // play the episode that was asked for, not merely the first file of a pack
  const video = (EPISODE && videos.find(file => file.name.includes(EPISODE))) || videos[0]
  if (!video) {
    return skipped('resolved release holds no MKV, point TB_TEST_PACK_HASH at one that does')
  }
  console.log(`  Playing "${video.name}"`)

  const spy = subtitleSpy()
  const chapters = []
  // getTime far ahead disables the playback pacing, so the test is not gated on real time
  const metadata = new DebridMetadata(video, resolved.files, spy, {
    getTime: () => Number.MAX_SAFE_INTEGER,
    onChapters: found => chapters.push(...found)
  })

  // give the parser a bounded window to produce tracks and stream some subtitle events
  const deadline = Date.now() + STREAM_BUDGET_MS
  while (Date.now() < deadline && spy.seen.subtitles.length < 25) await new Promise(resolve => setTimeout(resolve, 500))
  // read before teardown, destroy() releases the parser this comes from
  const durationMs = await Promise.resolve(metadata.metadata?.duration).catch(() => 0)
  metadata.destroy()

  console.log(`  tracks=${spy.seen.tracks.length} subtitle events=${spy.seen.subtitles.length} fonts=${spy.seen.fonts.length} chapters=${chapters.length} external subs=${spy.seen.files.length}`)

  // external subtitle files must be matched to this episode, never the whole pack
  const expectedExternal = matchSubtitleFiles(resolved.files, video.name)
  assert.equal(spy.seen.files.length, expectedExternal.length, 'external subtitle files must match the shared matcher exactly')

  if (!spy.seen.tracks.length && !expectedExternal.length) {
    return skipped('this release carries no subtitles at all, nothing to compare')
  }

  if (spy.seen.tracks.length) {
    // every track needs the shape Subtitles.handleTracks consumes
    for (const track of spy.seen.tracks) {
      assert.ok(Number.isFinite(track.number), 'a track must carry its number')
      assert.ok(track.type, 'a track must carry its codec type')
    }
    if (!spy.seen.subtitles.length) {
      // no cues: either the pipeline is broken or the link cannot carry the release. The
      // tracks, fonts and chapters above already prove the parser and transport work, so
      // the only question left is whether there was ever enough bandwidth to reach dialogue
      const throughput = await measureThroughput(video.url)
      const bitrate = durationMs > 0 ? video.size / (durationMs / 1_000) : 0
      const summary = `${(throughput / 1024).toFixed(0)} KB/s link vs ${(bitrate / 1024).toFixed(0)} KB/s release`
      if (throughput < bitrate) return skipped(`link too slow to reach dialogue within ${STREAM_BUDGET_MS / 1000}s (${summary}); re-run on a faster connection`)
      assert.fail(`embedded tracks announced themselves but streamed no subtitle events, and bandwidth was sufficient (${summary})`)
    }
    for (const { subtitle, trackNumber } of spy.seen.subtitles.slice(0, 5)) {
      assert.ok(Number.isFinite(trackNumber), 'each event must name its track')
      assert.ok(subtitle && (subtitle.text !== undefined), 'each event must carry subtitle text')
    }
    console.log(`  First cue: "${String(spy.seen.subtitles[0].subtitle.text).slice(0, 60)}"`)
  }

})

test('a seek far into the file restarts the subtitle stream near the seek', { skip, timeout: 300_000 }, async () => {
  const resolved = await resolveTorBox(HASH, { filter: name => /\.mkv$/i.test(name) })
  const video = resolved.files[0]
  if (!video) {
    return skipped('resolved release holds no MKV')
  }

  // observe every range request DebridMetadata makes, the restart shows up here
  const rangeStarts = []
  const realFetch = globalThis.fetch
  globalThis.fetch = (url, opts) => {
    const range = opts?.headers?.Range
    if (typeof range === 'string' && url === video.url) rangeStarts.push(Number(/bytes=(\d+)-/.exec(range)?.[1]))
    return realFetch(url, opts)
  }

  let time = 0
  const spy = subtitleSpy()
  const metadata = new DebridMetadata(video, resolved.files, spy, { getTime: () => time })
  try {
    if (!(await metadata.metadata.getTracks()).length) return skipped('this release has no embedded subtitles to stream')
    const durationSeconds = (await metadata.metadata.duration) / 1_000

    // let the sequential stream get going, then seek to the last quarter of the episode.
    // No events are demanded yet, on a slow connection the head of the file may still
    // be downloading, which is exactly the situation a seek must escape from
    await new Promise(resolve => setTimeout(resolve, 10_000))
    const before = spy.seen.subtitles.length
    time = durationSeconds * 0.75

    // the parser must land near the seek rather than reading everything in between.
    // The parity test already proves sustained streaming, one cue from out there is
    // proof enough here without leaning on a slow connection
    const deadline = Date.now() + 120_000
    while (Date.now() < deadline && spy.seen.subtitles.length - before < 1) await new Promise(resolve => setTimeout(resolve, 500))
    const jumped = rangeStarts.filter(start => start > video.size / 2)
    const after = spy.seen.subtitles.length - before
    console.log(`  range requests: [${rangeStarts.join(', ')}], events before seek=${before}, after=${after}`)

    // this is the behavior under test, and it costs one small request rather than bandwidth:
    // the parser must restart out near the seek instead of reading everything in between
    assert.ok(jumped.length, 'a range request must restart in the second half of the file')

    // whether a cue then arrives in time is a question about the link, not about the seek, so
    // it is held to the same bandwidth check the parity test uses rather than failing the run
    if (!after) {
      const throughput = await measureThroughput(video.url)
      const bitrate = video.size / durationSeconds
      const summary = `${(throughput / 1024).toFixed(0)} KB/s link vs ${(bitrate / 1024).toFixed(0)} KB/s release`
      if (throughput < bitrate) return skipped(`seek restarted correctly, but the link cannot reach dialogue within 120s (${summary}); re-run on a faster connection`)
      assert.fail(`the stream restarted at the seek but no cues followed, and bandwidth was sufficient (${summary})`)
    }
  } finally {
    metadata.destroy()
    globalThis.fetch = realFetch
  }
})
