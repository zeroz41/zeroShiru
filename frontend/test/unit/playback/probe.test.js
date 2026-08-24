// The link probe: proof a resolved stream serves bytes, before the player trusts it.
// The bug this answers: TorBox resolved an episode in 707ms and handed back a link whose
// CDN node never sent a single byte — the player spun on it for 45s of re-opens and then
// gave up with a toast, because nothing ever asked the link whether it was alive, and
// nothing knew that re-resolving returns the identical pinned URL.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { probeTarget, probeStream, verifiedStream, bustedUrl, PROBE_BYTES } from '../../../common/modules/playback/probe.js'

/** A response whose body streams the given chunks, or never yields when given none. */
function streamingResponse (chunks, { status = 206, signal } = {}) {
  let index = 0
  return {
    ok: status >= 200 && status < 300,
    status,
    body: {
      getReader: () => ({
        read () {
          if (index < chunks.length) return Promise.resolve({ done: false, value: new Uint8Array(chunks[index++]) })
          if (chunks.ended) return Promise.resolve({ done: true, value: undefined })
          // a sick node: the connection stays open and nothing ever arrives
          return new Promise((resolve, reject) => {
            signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
          })
        },
        cancel: () => Promise.resolve()
      })
    }
  }
}

const FILES = [
  { path: '/Pack/Episode 001.mkv', url: 'https://nexus-143.cdn/dld/aa?token=t' },
  { path: '/Pack/Episode 002.mkv', url: 'https://nexus-145.cdn/dld/bb?token=t' }
]

test('the probe judges the file the resolve picked, not whichever came first', () => {
  // pack files land on different CDN nodes; files come back in torrent order, so the
  // first file's health says nothing about the episode about to play
  assert.equal(probeTarget(FILES, '/Pack/Episode 002.mkv'), FILES[1])
  assert.equal(probeTarget(FILES, null), FILES[0], 'a resolve that named no pick is judged by its first file')
  assert.equal(probeTarget(FILES, '/gone.mkv'), FILES[0], 'a pick that matches nothing falls back rather than probing nothing')
  assert.equal(probeTarget([], '/x.mkv'), null)
  assert.equal(probeTarget(undefined, undefined), null)
})

test('a re-opened stream goes out under a URL the far end has never seen', () => {
  // verified live: the CDN answers 206 with an unknown query parameter appended, and
  // requestdl pins one URL per file, so this is the only new identity available
  assert.equal(bustedUrl('https://cdn/dld/aa?token=t', 1), 'https://cdn/dld/aa?token=t&zsr=1')
  assert.equal(bustedUrl('https://cdn/file.mkv', 2), 'https://cdn/file.mkv?zsr=2')
  assert.equal(bustedUrl('https://cdn/file.mkv', 0), 'https://cdn/file.mkv', 'the first open is the canonical URL')
  assert.equal(bustedUrl(null, 3), '')
})

test('a link is alive only once its body actually streams the probe chunk', async () => {
  let asked = null
  const fetcher = async (url, options) => {
    asked = { url, options }
    return streamingResponse([65536, 65536, 65536, 65536], { signal: options.signal })
  }
  const verdict = await probeStream('https://cdn/a.mkv', { fetcher })
  assert.equal(verdict.alive, true)
  assert.equal(verdict.status, 206)
  assert.equal(verdict.received, PROBE_BYTES)
  assert.equal(asked.options.headers.Range, 'bytes=0-', 'the player asks open-ended: sick nodes serve bounded ranges instantly while starving exactly this request, so any other question blesses dead links')
  assert.equal(asked.options.cache, 'no-store', 'a cached answer would prove nothing about the host')
  assert.equal(asked.options.signal.aborted, true, 'an open-ended request must be torn down once the mark is proven, never left draining the file')
})

test('headers with a body that never arrives is a dead link — the mode that fooled the 2-byte probe', async () => {
  // watched live in gst logs: 206 with full headers in 480ms, then not one byte of body
  const fetcher = async (url, { signal }) => streamingResponse([], { signal })
  const verdict = await probeStream('https://cdn/a.mkv', { fetcher, timeoutMs: 40 })
  assert.equal(verdict.alive, false)
  assert.match(verdict.reason, /did not answer|no data/)
})

test('a body that starts and then starves is dead, and says how far it got', async () => {
  const fetcher = async (url, { signal }) => streamingResponse([1024], { signal })
  const verdict = await probeStream('https://cdn/a.mkv', { fetcher, timeoutMs: 40 })
  assert.equal(verdict.alive, false)
  assert.match(verdict.reason, /stopped after 1024 bytes/)
})

test('a body shorter than the probe that properly ENDS is delivery, not starvation', async () => {
  // tiny files answer short ranges; only silence is a verdict against the host
  const chunks = [512]
  chunks.ended = true
  const verdict = await probeStream('https://cdn/tiny.bin', { fetcher: async (url, { signal }) => streamingResponse(chunks, { signal }) })
  assert.equal(verdict.alive, true)
  assert.equal(verdict.received, 512)
})

test('an error status is a dead link with a name', async () => {
  // an expired debrid token 403s: that is a verdict, not a network hiccup
  const verdict = await probeStream('https://cdn/a.mkv', { fetcher: async () => ({ ok: false, status: 403 }) })
  assert.equal(verdict.alive, false)
  assert.equal(verdict.status, 403)
  assert.match(verdict.reason, /403/)
})

test('silence past the deadline is the dead link this module exists for', async () => {
  // the live failure: connection accepted, not one byte ever sent
  const fetcher = (url, { signal }) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
  })
  const verdict = await probeStream('https://cdn/a.mkv', { fetcher, timeoutMs: 30 })
  assert.equal(verdict.alive, false)
  assert.match(verdict.reason, /did not answer/)
})

test('an unreachable host and a missing fetcher are dead links, never throws', async () => {
  const failed = await probeStream('https://cdn/a.mkv', { fetcher: async () => { throw new TypeError('Failed to fetch') } })
  assert.equal(failed.alive, false)
  assert.match(failed.reason, /unreachable/)
  const nothing = await probeStream('https://cdn/a.mkv', { fetcher: null })
  assert.equal(nothing.alive, false)
  const nowhere = await probeStream(null, { fetcher: async () => ({ ok: true, status: 206 }) })
  assert.equal(nowhere.alive, false)
})

test('one flap is retried once; two misses make a dead link', async () => {
  // a link that answers the second probe is weather, not a verdict — abandoning the
  // debrid stream over it would trade a working play for a torrent download
  let calls = 0
  const flappy = async () => (++calls === 1 ? { ok: false, status: 502 } : { ok: true, status: 206 })
  const slept = []
  const sleep = ms => { slept.push(ms); return Promise.resolve() }
  const recovered = await verifiedStream('https://cdn/a.mkv', { fetcher: flappy, sleep })
  assert.deepEqual({ alive: recovered.alive, attempts: recovered.attempts }, { alive: true, attempts: 2 })
  assert.equal(slept.length, 1, 'and the retry waits out the flap instead of hammering')

  const dead = await verifiedStream('https://cdn/a.mkv', { fetcher: async () => ({ ok: false, status: 502 }), sleep })
  assert.deepEqual({ alive: dead.alive, attempts: dead.attempts }, { alive: false, attempts: 2 })
  assert.match(dead.reason, /502/)
})

test('a healthy link is not slowed down by the retry machinery', async () => {
  let slept = false
  const verdict = await verifiedStream('https://cdn/a.mkv', {
    fetcher: async () => ({ ok: true, status: 206 }),
    sleep: () => { slept = true; return Promise.resolve() }
  })
  assert.deepEqual({ alive: verdict.alive, attempts: verdict.attempts }, { alive: true, attempts: 1 })
  assert.equal(slept, false)
})

// The rule this pins, learned twice the hard way (see the warning in playback/probe.js):
// the probe must never AWAIT the reader's cancellation. Both times the opposite was tried
// the whole suite stayed green — a mock body lets go instantly — and real playback died,
// so the mock here is the one that tells the truth: a cancellation that never settles.
test('a cancellation that never settles cannot hold up the probe', async () => {
  const response = {
    ok: true,
    status: 206,
    body: {
      getReader: () => ({
        read: () => Promise.resolve({ done: false, value: new Uint8Array(PROBE_BYTES) }),
        // the shape of an open-ended range against a CDN that is in no hurry to let go
        cancel: () => new Promise(() => {})
      })
    }
  }
  const verdict = await Promise.race([
    probeStream('https://nexus-143.cdn/dld/aa?token=t', { fetcher: async () => response }),
    new Promise(resolve => setTimeout(() => resolve({ alive: 'hung' }), 1_000))
  ])
  assert.equal(verdict.alive, true, 'awaiting the cancel strands every debrid start at readyState=0')
  assert.equal(verdict.received, PROBE_BYTES)
})
