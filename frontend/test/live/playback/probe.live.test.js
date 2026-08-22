// Live proof of the three CDN facts the dead-link recovery is built on. Each was verified
// by hand against TorBox on 2026-08-21; these keep them true, because if TorBox changes
// any of them the recovery ladder changes meaning:
//   1. a healthy link streams the probe's proof chunk fast, under the same open-ended
//      range the player sends — that is what makes probing every play affordable, and
//      what makes a silent link a verdict rather than slowness;
//   2. the CDN accepts an unknown query parameter — the stall watchdog re-opens a stream
//      under a busted URL, and if the CDN started 400ing those the re-open would break;
//   3. requestdl pins one URL per (torrent, file) — the reason a dead link is routed
//      around (torrent fallback) instead of "resolved fresh": fresh returns the same URL.
// Opt-in: TORBOX_API_KEY=<key> bun run test:live
import { test, beforeAll, afterAll } from 'bun:test'
import assert from 'node:assert/strict'
import { probeStream, verifiedStream, bustedUrl } from '../../../common/modules/playback/probe.js'
import { resolveTorBox, accountTorrents, deleteTorrent } from '../../tools/live-link.js'

const KEY = process.env.TORBOX_API_KEY
const skip = KEY ? false : 'TORBOX_API_KEY not set'

// public domain, and cached on TorBox, so it exercises the whole path without a real download
const CACHED = process.env.TORBOX_TEST_HASH || 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c'

let before_ = null
let resolved = null
let video = null

beforeAll(async () => {
  if (skip) return
  before_ = await accountTorrents()
  resolved = await resolveTorBox(CACHED, { filter: name => /\.(mp4|mkv|avi)$/i.test(name) })
  video = resolved.files.sort((a, b) => b.size - a.size)[0]
})

afterAll(async () => {
  if (skip) return
  await new Promise(resolve => setTimeout(resolve, 2_000))
  const after_ = await accountTorrents()
  const removed = [...before_].filter(([id]) => !after_.has(id)).map(([id]) => id)
  assert.deepEqual(removed, [], 'nothing here may delete a torrent the account already had')
  for (const [id] of [...after_].filter(([id]) => !before_.has(id))) await deleteTorrent(id)
})

test.skipIf(Boolean(skip))('a healthy link streams the probe fast, so probing every play costs nothing', async () => {
  const verdict = await verifiedStream(video.url)
  assert.equal(verdict.alive, true, `the probe called a live link dead: ${verdict.reason}`)
  assert.equal(verdict.attempts, 1, 'a healthy link must not pay for the retry machinery')
  console.log(`  probe answered in ${verdict.elapsed}ms`)
}, 120_000)

test.skipIf(Boolean(skip))('a probe beside an open stream starves neither — what makes probing a preroll safe', async () => {
  // The stall watchdog probes the link WHILE the player holds its own open-ended request
  // (a starting load that shows no progress for 15s). Measured 2026-08-21: a node serves
  // three concurrent open-ended requests on one link in under 400ms each. If TorBox ever
  // starts serializing connections per link, this fails — and the watchdog's probe would
  // be starving the player it is trying to diagnose, so the plan must change with it.
  const held = new AbortController()
  const stream = await fetch(video.url, { headers: { Range: 'bytes=0-' }, signal: held.signal })
  const reader = stream.body.getReader()
  const first = await reader.read() // the held stream is genuinely delivering, like the player's
  assert.equal(first.done, false)
  try {
    const probe = await probeStream(video.url, { timeoutMs: 8_000 })
    assert.equal(probe.alive, true, `a probe beside an open stream starved (${probe.reason}); the watchdog would misread every slow preroll as dead`)
  } finally {
    reader.cancel().catch(() => {})
    held.abort()
  }
}, 120_000)

test.skipIf(Boolean(skip))('the CDN accepts the cache-busting parameter a stalled re-open goes out under', async () => {
  const probe = await probeStream(bustedUrl(video.url, 1))
  assert.equal(probe.alive, true, `the CDN refused a busted URL (${probe.reason}); stalled re-opens would break`)
}, 120_000)

test.skipIf(Boolean(skip))('requestdl pins one URL per file, so a dead link must be routed around, not re-resolved', async () => {
  const again = await resolveTorBox(CACHED, { filter: name => name === video.name })
  const same = again.files.find(file => file.name === video.name)
  assert.equal(same?.url, video.url, 'TorBox started minting fresh links — the dead-link recovery could re-resolve instead of falling back, see playback/probe.js')
}, 120_000)
