// Live Real-Debrid API tests. Opt-in only: they run against your real account
// and are skipped entirely unless REAL_DEBRID_API_KEY is set, e.g.
//   REAL_DEBRID_API_KEY=xxx npm run test:live
// Optionally set RD_TEST_MAGNET to a magnet you know is cached (an anime MKV)
// to exercise episode file mapping and remote subtitle metadata end to end.
// Any torrent the tests add to the account is removed afterwards.
import { test, afterAll } from 'bun:test'
import assert from 'node:assert/strict'
import RealDebrid from '../../../common/modules/debrid/realdebrid.js'
import { DebridNotCachedError, secureFiles } from '../../../common/modules/debrid/service.js'
import { Availability, isAvailability } from '../../../common/modules/debrid/availability.js'

const KEY = process.env.REAL_DEBRID_API_KEY
const skip = KEY ? false : 'REAL_DEBRID_API_KEY not set'

// the canonical webtorrent test torrent, near-certain to be cached on any debrid service
const BBB_HASH = '08ada5a7a6183aae1e09d831df6748d566095a10'
const TEST_MAGNET = process.env.RD_TEST_MAGNET || `magnet:?xt=urn:btih:${BBB_HASH}&dn=Big+Buck+Bunny`

const service = KEY ? new RealDebrid(KEY) : null
const addedHashes = new Set()

/**
 * Fetches, retrying connection failures. Debrid download hosts are fresh CDN endpoints
 * every time, and on a high latency link the TLS connect alone can exceed the default
 * 10s budget. A retry keeps the assertion meaningful instead of testing the weather.
 */
async function fetchWithRetry (url, options, attempts = 3) {
  for (let attempt = 1; ; ++attempt) {
    try {
      return await fetch(url, options)
    } catch (error) {
      if (attempt >= attempts) throw error
      console.log(`  connection to the stream host failed (${error.cause?.code || error.message}), retry ${attempt}/${attempts - 1}`)
      await new Promise(resolve => setTimeout(resolve, 2_000 * attempt))
    }
  }
}

afterAll(async () => {
  if (!service || !addedHashes.size) return
  // remove any torrents the tests added so the account stays clean
  const torrents = await service.request('https://api.real-debrid.com/rest/1.0/torrents?limit=100')
  for (const torrent of torrents || []) {
    if (addedHashes.has(torrent.hash?.toLowerCase())) {
      await service.request(`https://api.real-debrid.com/rest/1.0/torrents/delete/${torrent.id}`, { method: 'DELETE' }).catch(() => {})
      console.log(`Cleaned up test torrent ${torrent.hash}`)
    }
  }
})

test('validate connects to the account', { skip }, async () => {
  const result = await service.validate()
  assert.ok(result.username)
  console.log(`  Connected as ${result.username}, premium until ${result.expires}`)
})

test('listAvailability answers in lowercase hashes and known states', { skip }, async () => {
  const known = await service.listAvailability()
  assert.ok(known instanceof Map)
  for (const [hash, state] of known) {
    assert.match(hash, /^[a-f\d]{40}$/, 'hashes must be comparable to search result hashes')
    assert.ok(isAvailability(state) && state !== Availability.UNKNOWN, `${hash} came back as ${state}`)
  }
  const cached = [...known.values()].filter(state => state === Availability.CACHED).length
  console.log(`  ${known.size} torrents on the account, ${cached} of them streamable now`)
})

// generous because one unrestrict per file in a pack is a lot of round trips on a slow link
test('resolve returns working stream URLs for a cached torrent', { skip, timeout: 300_000 }, async t => {
  const existing = new Set((await service.listAvailability()).keys())
  let resolved
  try {
    resolved = await service.resolve(TEST_MAGNET, { fileFilter: name => /\.(mkv|mp4|srt|ass)$/i.test(name) })
  } catch (error) {
    if (error instanceof DebridNotCachedError) return t.skip('test magnet is not cached on this account, set RD_TEST_MAGNET to a cached one')
    throw error
  }
  if (!existing.has(resolved.hash)) addedHashes.add(resolved.hash)
  assert.ok(resolved.files.length > 0)
  // the DebridFile contract is HTTPS, verified here against what the real API hands back
  assert.ok(resolved.files.every(file => file.url?.startsWith('https://')), 'every stream URL must be HTTPS')
  assert.deepEqual(secureFiles(resolved.files, 'Real-Debrid'), resolved.files, 'no file may be dropped by the HTTPS guard')
  console.log(`  Resolved ${resolved.files.length} files from "${resolved.name}"`)

  // verify the unrestricted link actually serves bytes with range support
  const video = resolved.files.find(file => /\.(mkv|mp4)$/i.test(file.name))
  assert.ok(video, 'expected a video file')
  const res = await fetchWithRetry(video.url, { headers: { Range: 'bytes=0-1023' } })
  assert.ok(res.ok || res.status === 206, `stream URL returned ${res.status}`)
  const buffer = await res.arrayBuffer()
  assert.ok(buffer.byteLength > 0)
  console.log(`  Stream URL is live, range request returned ${buffer.byteLength} bytes (status ${res.status})`)

  // opportunistic remote metadata check when the release is an MKV
  if (video.name.endsWith('.mkv')) {
    const { default: Metadata } = await import('matroska-metadata')
    const controller = new AbortController()
    const remote = {
      name: video.name,
      size: video.size,
      slice: (start = 0) => ({
        stream: () => (async function * () {
          try {
            const res = await fetch(video.url, { headers: { Range: `bytes=${start}-` }, signal: controller.signal })
            yield * res.body
          } catch (error) {
            if (error?.name !== 'AbortError') throw error // our own teardown, mirrors RemoteFile
          }
        })()
      })
    }
    const metadata = new Metadata(remote)
    const tracks = await metadata.getTracks()
    const chapters = await metadata.getChapters().catch(() => [])
    controller.abort()
    metadata.destroy()
    console.log(`  Remote MKV metadata: ${tracks.length} subtitle tracks, ${chapters.length} chapters`)
    assert.ok(Array.isArray(tracks))
  }
})

test('second resolve reuses the account torrent instead of re-adding', { skip, timeout: 60_000 }, async t => {
  let first
  try {
    first = await service.resolve(TEST_MAGNET, { fileFilter: name => /\.(mkv|mp4)$/i.test(name) })
  } catch (error) {
    if (error instanceof DebridNotCachedError) return t.skip('test magnet is not cached on this account')
    throw error
  }
  addedHashes.add(first.hash)
  const torrentsBefore = (await service.request('https://api.real-debrid.com/rest/1.0/torrents?limit=100')).filter(torrent => torrent.hash?.toLowerCase() === first.hash).length
  await service.resolve(TEST_MAGNET, { fileFilter: name => /\.(mkv|mp4)$/i.test(name) })
  const torrentsAfter = (await service.request('https://api.real-debrid.com/rest/1.0/torrents?limit=100')).filter(torrent => torrent.hash?.toLowerCase() === first.hash).length
  assert.equal(torrentsAfter, torrentsBefore, 'resolve must not create duplicate account torrents')
})
