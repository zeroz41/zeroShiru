import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import RealDebrid from '../../../common/modules/debrid/realdebrid.js'
import { DebridError, DebridAuthError, DebridNotCachedError, DebridUnavailableError } from '../../../common/modules/debrid/service.js'
import { Availability } from '../../../common/modules/debrid/availability.js'

const HASH = 'a'.repeat(40)
const MAGNET = `magnet:?xt=urn:btih:${HASH}&dn=test`
const videoFilter = name => /\.(mkv|mp4)$/i.test(name)

/**
 * Installs a fetch mock. Routes are matched in order by method + path substring;
 * `body` may be a function of the request URL, to vary responses across calls
 * (e.g. status polling, or paging).
 */
function mockFetch (routes) {
  const calls = []
  globalThis.fetch = async (url, opts = {}) => {
    const method = opts.method || 'GET'
    calls.push({ url: String(url), method, body: opts.body })
    const route = routes.find(route => (route.method || 'GET') === method && String(url).includes(route.path))
    if (!route) throw new Error(`Unexpected request: ${method} ${url}`)
    const status = route.status ?? 200
    const body = typeof route.body === 'function' ? route.body(String(url)) : route.body
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: header => route.headers?.[header.toLowerCase()] ?? null },
      json: async () => body
    }
  }
  return calls
}

function downloadedInfo (overrides = {}) {
  return {
    id: 'TORRENT1',
    hash: HASH.toUpperCase(),
    filename: 'Test Torrent',
    status: 'downloaded',
    files: [
      { id: 1, path: '/Test/Episode 01.mkv', bytes: 1000, selected: 1 },
      { id: 2, path: '/Test/readme.txt', bytes: 10, selected: 1 },
      { id: 3, path: '/Test/Episode 02.mkv', bytes: 2000, selected: 1 }
    ],
    links: ['https://rd/link1', 'https://rd/link2', 'https://rd/link3'],
    ...overrides
  }
}

let service
beforeEach(() => {
  service = new RealDebrid('test-key')
})

test('validate accepts premium accounts and rejects free ones', async () => {
  mockFetch([{ path: '/user', body: { username: 'tester', type: 'premium', expiration: '2030-01-01' } }])
  const result = await service.validate()
  assert.equal(result.username, 'tester')

  mockFetch([{ path: '/user', body: { username: 'tester', type: 'free' } }])
  await assert.rejects(new RealDebrid('test-key').validate(), DebridAuthError)
})

// the account list is free badge data for all three answers, not just for what it holds
test('listAvailability reads every account status as what it means for playback', async () => {
  mockFetch([{
    path: '/torrents',
    body: [
      { hash: HASH.toUpperCase(), status: 'downloaded' },
      { hash: 'b'.repeat(40), status: 'downloading' },
      { hash: 'c'.repeat(40), status: 'magnet_error' },
      { hash: 'd'.repeat(40), status: 'virus' },
      { hash: 'e'.repeat(40), status: 'magnet_conversion' }
    ]
  }])
  const known = await service.listAvailability()
  assert.equal(known.get(HASH), Availability.CACHED, 'lowercased, and instantly streamable')
  assert.equal(known.get('b'.repeat(40)), Availability.AVAILABLE, 'still being fetched')
  assert.equal(known.get('c'.repeat(40)), Availability.UNAVAILABLE)
  assert.equal(known.get('d'.repeat(40)), Availability.UNAVAILABLE)
  assert.ok(!known.has('e'.repeat(40)), 'mid-conversion is a moment, not an outcome, so it stays unknown')
})

// The badge source, and the reason it asks for a large limit: an account under test held 312
// torrents, of which the API's default page size would have badged 100.
test('listAvailability reads the whole account in one request', async () => {
  const torrents = Array.from({ length: 312 }, (_, i) => ({ hash: String(i).padStart(40, '0'), status: 'downloaded' }))
  const calls = mockFetch([{ path: '/torrents', body: torrents }])
  const hashes = await service.listAvailability()
  assert.equal(hashes.size, 312, 'the whole account must be badged, not just the first page')
  const listCalls = calls.filter(call => call.url.includes('/torrents?'))
  assert.equal(listCalls.length, 1, 'and it must cost one request')
  assert.ok(Number(new URL(listCalls[0].url).searchParams.get('limit')) > 100, 'so the limit has to beat the default page size')
})

test('resolve unrestricts cached torrents with aligned links', async () => {
  let infoCalls = 0
  const calls = mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', status: 201, body: { id: 'TORRENT1' } },
    { path: '/torrents/info/TORRENT1', body: () => ++infoCalls === 1 ? downloadedInfo({ status: 'waiting_files_selection', links: [] }) : downloadedInfo() },
    { path: '/torrents/selectFiles/TORRENT1', method: 'POST', status: 204, body: null },
    { path: '/unrestrict/link', method: 'POST', body: { filename: 'direct.mkv', filesize: 1000, download: 'https://rd/direct.mkv', mimeType: 'video/x-matroska' } },
    { path: '/torrents', body: [] }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.hash, HASH)
  assert.equal(resolved.name, 'Test Torrent')
  assert.deepEqual(resolved.files.map(file => file.path), ['/Test/Episode 01.mkv', '/Test/Episode 02.mkv'])
  assert.ok(resolved.files.every(file => file.url === 'https://rd/direct.mkv'))
  // the readme's link must be skipped via alignment, not position guessing
  const unrestricted = calls.filter(call => call.url.includes('/unrestrict/link')).map(call => new URLSearchParams(call.body).get('link'))
  assert.deepEqual(unrestricted, ['https://rd/link1', 'https://rd/link3'])
})

test('resolve unrestricts all links and filters by filename when counts differ', async () => {
  // real RD behavior: the cached copy may serve fewer links than files selected,
  // e.g. 3 selected files but a single link for just the video
  let unrestrictCalls = 0
  const calls = mockFetch([
    { path: '/torrents/info/TORRENT9', body: downloadedInfo({ id: 'TORRENT9', links: ['https://rd/video', 'https://rd/poster'] }) },
    { path: '/torrents', body: [{ id: 'TORRENT9', hash: HASH, status: 'downloaded' }] },
    { path: '/unrestrict/link', method: 'POST', body: () => ++unrestrictCalls === 1 ? { filename: 'Episode 01.mkv', filesize: 1000, download: 'https://rd/direct.mkv', mimeType: 'video/x-matroska' } : { filename: 'poster.jpg', filesize: 50, download: 'https://rd/poster.jpg', mimeType: 'image/jpeg' } }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter, pickFile: files => files.find(file => file.path.includes('Episode 01')) })
  assert.deepEqual(resolved.files.map(file => file.name), ['Episode 01.mkv'])
  assert.equal(calls.filter(call => call.url.includes('/unrestrict/link')).length, 2)
})

test('resolve recovers from an RD generated archive by re-adding with a single file', async () => {
  // real RD behavior: selecting multiple files can serve one RAR archive, the
  // client must re-add the torrent selecting only the target file
  let phase = 'archive'
  const calls = mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', status: 201, body: () => ({ id: phase === 'archive' ? 'FIRST' : 'RETRY' }) },
    { path: '/torrents/info/FIRST', body: () => downloadedInfo({ id: 'FIRST', links: ['https://rd/archive'] }) },
    { path: '/torrents/info/RETRY', body: () => downloadedInfo({ id: 'RETRY', status: phase === 'selecting' ? 'waiting_files_selection' : 'downloaded', files: [{ id: 3, path: '/Test/Episode 02.mkv', bytes: 2000, selected: phase === 'selecting' ? 0 : 1 }], links: phase === 'selecting' ? [] : ['https://rd/single'] }) },
    { path: '/torrents/selectFiles/RETRY', method: 'POST', status: 204, body: () => { phase = 'done'; return null } },
    { path: '/torrents/selectFiles/FIRST', method: 'POST', status: 204, body: null },
    { path: '/torrents/delete/FIRST', method: 'DELETE', status: 204, body: null },
    { path: '/unrestrict/link', method: 'POST', body: () => phase === 'done' ? { filename: 'Episode 02.mkv', filesize: 2000, download: 'https://rd/direct2.mkv', mimeType: 'video/x-matroska' } : { filename: 'Test.rar', filesize: 3000, download: 'https://rd/archive.rar', mimeType: 'application/x-rar-compressed' } },
    { path: '/torrents', body: [] }
  ])
  const originalInfo = calls // first add returns FIRST, archive detected, retry adds RETRY
  let firstInfoServed = false
  const original = globalThis.fetch
  globalThis.fetch = async (url, opts) => {
    // FIRST needs waiting_files_selection once before selection, downloaded after
    if (String(url).includes('/torrents/info/FIRST') && !firstInfoServed) {
      firstInfoServed = true
      return { ok: true, status: 200, headers: { get: () => null }, json: async () => downloadedInfo({ id: 'FIRST', status: 'waiting_files_selection', links: [] }) }
    }
    if (String(url).includes('/torrents/addMagnet') && firstInfoServed) phase = 'selecting'
    return original(url, opts)
  }
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter, pickFile: files => files.sort((a, b) => b.size - a.size)[0] })
  assert.deepEqual(resolved.files.map(file => file.name), ['Episode 02.mkv'])
  assert.equal(resolved.files[0].url, 'https://rd/direct2.mkv')
  await new Promise(resolve => setTimeout(resolve, 400))
  assert.ok(originalInfo.some(call => call.method === 'DELETE' && call.url.includes('/torrents/delete/FIRST')), 'replaced torrent must be cleaned up')
})

test('resolve deletes its own magnet when the torrent is not cached', async () => {
  const calls = mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', status: 201, body: { id: 'TORRENT1' } },
    { path: '/torrents/info/TORRENT1', body: () => downloadedInfo({ status: 'waiting_files_selection', links: [] }) },
    { path: '/torrents/selectFiles/TORRENT1', method: 'POST', status: 204, body: null },
    { path: '/torrents/delete/TORRENT1', method: 'DELETE', status: 204, body: null },
    { path: '/torrents', body: [] }
  ])
  // after selection the torrent goes to queued, i.e. a fresh download
  let selected = false
  const original = globalThis.fetch
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes('/selectFiles/')) selected = true
    if (String(url).includes('/torrents/info/') && selected) return { ok: true, status: 200, headers: { get: () => null }, json: async () => downloadedInfo({ status: 'queued', links: [] }) }
    return original(url, opts)
  }
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridNotCachedError)
  await new Promise(resolve => setTimeout(resolve, 400)) // cleanup delete is fire and forget
  assert.ok(calls.some(call => call.method === 'DELETE' && call.url.includes('/torrents/delete/TORRENT1')))
})

// found against the live API: a hash Real-Debrid cannot find peers for sits in magnet_conversion
// until the budget runs out. Playback cannot wait, so it has to read as "not cached" and fall back
// to the torrent, rather than as a raw error the user is shown and the badge learns nothing from.
test('a magnet that never converts is not cached as far as playback is concerned', async () => {
  // the budget running out is the whole point, so shorten it rather than sit through the real one
  class Impatient extends RealDebrid {
    static timeouts = { ...RealDebrid.timeouts, select: 300, poll: 50 }
  }
  const service = new Impatient('test-key')
  const calls = mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', status: 201, body: { id: 'TORRENT1' } },
    { path: '/torrents/info/TORRENT1', body: { id: 'TORRENT1', status: 'magnet_conversion', files: [], links: [] } },
    { path: '/torrents/delete/TORRENT1', method: 'DELETE', status: 204, body: null },
    { path: '/torrents', body: [] }
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridNotCachedError)
  assert.ok(calls.some(call => call.method === 'DELETE'), 'and the magnet it added is taken back off the account')
})

// the same timeout during a badge check proves nothing: Real-Debrid may simply be slow, and
// calling it a miss is what empties the badges on exactly the rarer titles
test('the same timeout during a probe leaves the release unanswered instead', async () => {
  mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', status: 201, body: { id: 'TORRENT1' } },
    { path: '/torrents/info/TORRENT1', body: { id: 'TORRENT1', status: 'magnet_conversion', files: [], links: [] } },
    { path: '/torrents/delete/TORRENT1', method: 'DELETE', status: 204, body: null }
  ])
  await assert.rejects(service.probeAvailability(HASH), error => {
    assert.ok(!(error instanceof DebridNotCachedError), 'no answer is not a negative answer')
    assert.ok(error instanceof DebridError)
    return true
  })
  assert.equal(service.availabilityState.size, 0, 'and nothing is remembered, so the next sweep asks again')
})

test('resolve reuses a downloaded torrent already on the account', async () => {
  const calls = mockFetch([
    { path: '/torrents/info/TORRENT9', body: downloadedInfo({ id: 'TORRENT9' }) },
    { path: '/torrents', body: [{ id: 'TORRENT9', hash: HASH, status: 'downloaded' }] },
    { path: '/unrestrict/link', method: 'POST', body: { download: 'https://rd/direct.mkv', mimeType: 'video/x-matroska' } }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.files.length, 2)
  assert.ok(!calls.some(call => call.url.includes('addMagnet')), 'must not add a duplicate torrent')
})

test('resolve treats an account torrent still downloading as not cached, without deleting it', async () => {
  const calls = mockFetch([
    { path: '/torrents', body: [{ id: 'TORRENT9', hash: HASH, status: 'downloading' }] }
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridNotCachedError)
  assert.ok(!calls.some(call => call.method === 'DELETE'), 'must never delete torrents it did not add')
})

test('resolve fails when the torrent has no links at all', async () => {
  mockFetch([
    { path: '/torrents/info/TORRENT9', body: downloadedInfo({ id: 'TORRENT9', links: [] }) },
    { path: '/torrents', body: [{ id: 'TORRENT9', hash: HASH, status: 'downloaded' }] }
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridError)
})

test('maps auth failures to DebridAuthError', async () => {
  mockFetch([{ path: '/user', status: 401, body: { error: 'bad_token', error_code: 8 } }])
  await assert.rejects(service.validate(), DebridAuthError)
})

test('retries once on 429 with retry-after', async () => {
  let calls = 0
  mockFetch([{
    path: '/user',
    get status () { return ++calls === 1 ? 429 : 200 },
    headers: { 'retry-after': '1' },
    body: () => calls === 1 ? { error: 'too_many_requests' } : { username: 'tester', type: 'premium' }
  }])
  const result = await service.validate()
  assert.equal(result.username, 'tester')
  assert.equal(calls, 2)
})

test('requires an api key', async () => {
  await assert.rejects(new RealDebrid('').validate(), DebridAuthError)
})

// A pack larger than maxFiles cannot be unrestricted whole. Truncating to the first N
// used to drop the requested episode, which then triggered a re-add and left a duplicate
// torrent on the account on every play of a late episode.
function packInfo (count) {
  const files = Array.from({ length: count }, (_, index) => ({
    id: index + 1,
    path: `/Pack/Episode ${String(index + 1).padStart(3, '0')}.mkv`,
    bytes: 1000,
    selected: 1
  }))
  return { id: 'PACK1', hash: HASH.toUpperCase(), filename: 'Big Pack', status: 'downloaded', files, links: files.map((_, index) => `https://rd/link${index + 1}`) }
}

/** Routes a resolve of an already-downloaded pack, unrestricting by link name. */
/**
 * A service whose rate limiter is out of the way. The pack tests below are about which files come
 * back, not about pacing, and a 60 link pack at the real limits spends nine seconds proving it.
 */
function unthrottled () {
  class Unthrottled extends RealDebrid {
    static limits = { maxConcurrent: 20, minTime: 0 }
  }
  return new Unthrottled('test-key')
}

function mockPack (count) {
  const info = packInfo(count)
  return mockFetch([
    { path: '/torrents?limit', body: [{ id: 'PACK1', hash: HASH, status: 'downloaded' }] },
    { path: '/torrents/info/', body: info },
    { path: '/unrestrict/link', method: 'POST', body: () => ({ download: 'https://cdn/file.mkv', filesize: 1000 }) }
  ])
}

test('a capped pack keeps the requested episode instead of the first N files', async () => {
  const wantedPath = '/Pack/Episode 100.mkv'
  const service = unthrottled()
  mockPack(150)
  const resolved = await service.resolve(MAGNET, {
    fileFilter: videoFilter,
    maxFiles: 60,
    pickFile: files => files.find(file => file.path === wantedPath)
  })
  assert.equal(resolved.files.length, 60, 'the cap is still respected')
  assert.ok(resolved.files.some(file => file.path === wantedPath), 'the requested episode must survive the cap')
  // neighbours are kept so in-player next/previous still works around the playing episode
  assert.ok(resolved.files.some(file => file.path === '/Pack/Episode 099.mkv'), 'the previous episode should be in the window')
  assert.ok(resolved.files.some(file => file.path === '/Pack/Episode 101.mkv'), 'the next episode should be in the window')
})

test('a capped pack preserves torrent order and never re-adds', async () => {
  const service = unthrottled()
  const calls = mockPack(150)
  const resolved = await service.resolve(MAGNET, {
    fileFilter: videoFilter,
    maxFiles: 60,
    pickFile: files => files.find(file => file.path === '/Pack/Episode 150.mkv')
  })
  assert.ok(resolved.files.some(file => file.path === '/Pack/Episode 150.mkv'), 'the last episode must be reachable')
  const paths = resolved.files.map(file => file.path)
  assert.deepEqual(paths, [...paths].sort(), 'files stay in torrent order for episode navigation')
  assert.ok(!calls.some(call => call.url.includes('/torrents/addMagnet')), 'a reused account torrent must never be re-added')
})

test('a pack within the cap is returned whole', async () => {
  mockPack(10)
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter, maxFiles: 60 })
  assert.equal(resolved.files.length, 10)
})

// Real packs contain the odd dead file: a live 150-file pack returned RD error_code 19
// (hoster_unavailable, HTTP 503) on one link, which used to fail the entire resolve.
test('one dead file in a pack does not sink the whole resolve', async () => {
  let call = 0
  mockFetch([
    { path: '/torrents?limit', body: [{ id: 'PACK1', hash: HASH, status: 'downloaded' }] },
    { path: '/torrents/info/', body: downloadedInfo() },
    {
      path: '/unrestrict/link',
      method: 'POST',
      get status () { return ++call === 1 ? 503 : 200 },
      body: () => call === 1 ? { error: 'hoster_unavailable', error_code: 19 } : { download: 'https://cdn/file.mkv', filesize: 1000 }
    }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.files.length, 1, 'the surviving file must still play')
})

test('an auth failure while unrestricting still surfaces as an auth error', async () => {
  mockFetch([
    { path: '/torrents?limit', body: [{ id: 'PACK1', hash: HASH, status: 'downloaded' }] },
    { path: '/torrents/info/', body: downloadedInfo() },
    { path: '/unrestrict/link', method: 'POST', status: 401, body: { error: 'bad_token', error_code: 8 } }
  ])
  // every link would fail for the same reason, so this is not a per file problem to skip
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridAuthError)
})

// Regression: the probe used to fire its delete without awaiting it, so it answered while it
// still owned a torrent on the account. Playback reusing that hash, or the service being torn
// down, could then trip over a torrent that was seconds from disappearing.
test('a probe removes its torrent before it answers', async () => {
  const calls = mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', status: 201, body: { id: 'PROBE1' } },
    { path: '/torrents/selectFiles', method: 'POST', status: 204, body: null },
    { path: '/torrents/info/', body: downloadedInfo({ id: 'PROBE1' }) },
    { path: '/torrents/delete/', method: 'DELETE', status: 204, body: null }
  ])
  assert.equal(await service.probeAvailability(HASH), Availability.CACHED)
  const deletes = calls.filter(call => call.method === 'DELETE')
  assert.deepEqual(deletes.map(call => call.url.split('/').pop()), ['PROBE1'], 'the probe must clean up after itself')
})

// probing tells the two negatives apart, which is the whole reason a Real-Debrid search can
// show more than "cached or who knows"
test('a probe separates a release RD would fetch from one it can never serve', async () => {
  for (const [status, expected] of [['downloading', DebridNotCachedError], ['queued', DebridNotCachedError], ['magnet_error', DebridUnavailableError], ['dead', DebridUnavailableError]]) {
    const calls = mockFetch([
      { path: '/torrents/addMagnet', method: 'POST', status: 201, body: { id: 'PROBE2' } },
      { path: '/torrents/selectFiles', method: 'POST', status: 204, body: null },
      { path: '/torrents/info/', body: downloadedInfo({ id: 'PROBE2', status }) },
      { path: '/torrents/delete/', method: 'DELETE', status: 204, body: null }
    ])
    await assert.rejects(() => new RealDebrid('test-key').probeAvailability(HASH), expected, status)
    assert.equal(calls.filter(call => call.method === 'DELETE').length, 1, `a ${status} probe must not leave a torrent on the account`)
  }
})

test('a probe refuses to invent an answer for an unusable hash', async () => {
  mockFetch([])
  await assert.rejects(() => service.probeAvailability('not-a-hash'), DebridError)
})

// playback reads the same typed errors the probe does, so a fallback and a badge always agree
test('resolve reports a dead account torrent as unavailable rather than uncached', async () => {
  mockFetch([
    { path: '/torrents/info/TORRENT9', body: downloadedInfo({ id: 'TORRENT9', status: 'error' }) },
    { path: '/torrents', body: [{ id: 'TORRENT9', hash: HASH, status: 'error' }] }
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridUnavailableError)
})

// the listing is shared and up to a minute old, so an id it names may already be gone. That has
// to read as "not on the account" and add the magnet, not fail the play the user just started.
test('a torrent deleted since the listing was read is added again rather than failing playback', async () => {
  let deleted = true
  const calls = mockFetch([
    { path: '/torrents/info/GONE', get status () { return deleted ? 404 : 200 }, body: { error: 'unknown_ressource', error_code: 7 } },
    { path: '/torrents/addMagnet', method: 'POST', status: 201, body: { id: 'FRESH' } },
    { path: '/torrents/info/FRESH', body: () => downloadedInfo({ id: 'FRESH' }) },
    { path: '/torrents/selectFiles/FRESH', method: 'POST', status: 204, body: null },
    { path: '/unrestrict/link', method: 'POST', body: { filename: 'direct.mkv', filesize: 1000, download: 'https://rd/direct.mkv' } },
    { path: '/torrents', body: [{ id: 'GONE', hash: HASH, status: 'downloaded' }] }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.files.length, 2, 'playback still gets its files')
  assert.ok(calls.some(call => call.url.includes('addMagnet')), 'the magnet is added instead of reusing a dead id')
  assert.ok(!calls.some(call => call.method === 'DELETE'), 'and nothing is deleted on the way')
})
