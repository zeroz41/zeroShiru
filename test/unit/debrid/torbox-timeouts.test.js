// TorBox under bad conditions: hung requests, rate limits, and torrents that are slow to appear
// after adding. Playback sits on top of every one of these paths, so each has to end in a typed
// error or a clean recovery within its budget — a hang here is a player that never starts, and
// an unremoved torrent is clutter on the user's account.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import TorBox from '../../../common/modules/debrid/torbox.js'
import { DebridError, DebridNotCachedError } from '../../../common/modules/debrid/service.js'
import { Availability } from '../../../common/modules/debrid/availability.js'

const HASH = 'a'.repeat(40)
const MAGNET = `magnet:?xt=urn:btih:${HASH}`
const videoFilter = name => /\.(mkv|mp4)$/i.test(name)

/** TorBox with test-speed budgets, so poll loops and timeouts run in milliseconds. */
class FastTorBox extends TorBox {
  static timeouts = { ...TorBox.timeouts, request: 150, ready: 400, poll: 50 }
  static limits = { maxConcurrent: 5, minTime: 0 }
}

const ok = data => ({ success: true, error: null, detail: 'ok', data })

function torrent (overrides = {}) {
  return {
    id: 42,
    hash: HASH,
    name: 'Test',
    download_state: 'completed',
    download_finished: true,
    download_present: true,
    progress: 1,
    files: [{ id: 0, name: 'Test/Episode 01.mkv', short_name: 'Episode 01.mkv', size: 1000, mimetype: 'video/x-matroska' }],
    ...overrides
  }
}

/**
 * A fetch mock that honors AbortSignals, which is what request timeouts are made of.
 * Routes match by method and path substring; a route may hang forever.
 */
function mockFetch (routes) {
  const calls = []
  globalThis.fetch = (url, opts = {}) => {
    const method = opts.method || 'GET'
    calls.push({ url: String(url), method })
    const route = routes.find(route => (route.method || 'GET') === method && String(url).includes(route.path))
    if (!route) return Promise.reject(new Error(`Unexpected request: ${method} ${url}`))
    return new Promise((resolve, reject) => {
      const signal = opts.signal
      signal?.addEventListener('abort', () => reject(signal.reason), { once: true })
      if (route.hang) return // resolves only by abort
      const status = route.status ?? 200
      const body = typeof route.body === 'function' ? route.body(String(url)) : route.body
      resolve({
        ok: status >= 200 && status < 300,
        status,
        headers: { get: header => route.headers?.[header.toLowerCase()] ?? null },
        json: async () => body
      })
    })
  }
  return calls
}

test('a request that hangs is cut off at its budget, retried once, and then surfaces', async () => {
  const service = new FastTorBox('key')
  const calls = mockFetch([{ path: '/user/me', hang: true }])
  const started = Date.now()
  await assert.rejects(service.validate(), error => {
    assert.match(String(error.name), /TimeoutError|AbortError/, `a hang must become a timeout, got ${error.name}`)
    return true
  })
  assert.equal(calls.length, 2, 'one retry for what might be a network hiccup, then the error')
  assert.ok(Date.now() - started < 15_000, 'the user is not left waiting on a dead request')
  service.destroy()
})

test('a hung request during resolve does not hang playback', async () => {
  const service = new FastTorBox('key')
  mockFetch([{ path: '/torrents/mylist', hang: true }])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }))
  service.destroy()
})

test('a 429 with retry-after is waited out and the request then succeeds', async () => {
  const service = new FastTorBox('key')
  let attempts = 0
  mockFetch([{
    path: '/user/me',
    get status () { return ++attempts === 1 ? 429 : 200 },
    headers: { 'retry-after': '1' },
    body: () => attempts === 1 ? { success: false, error: 'RATE_LIMIT', detail: 'slow down' } : ok({ email: 'tester@example.test' })
  }])
  const started = Date.now()
  const result = await service.validate()
  assert.equal(result.username, 'tester@example.test')
  assert.ok(Date.now() - started >= 900, 'the retry must actually wait what the API asked for')
  assert.equal(attempts, 2)
  service.destroy()
})

test('an added torrent that never shows up is errored and taken back off the account', async () => {
  const service = new FastTorBox('key')
  const calls = mockFetch([
    { path: '/torrents/mylist', body: ok([]) },
    { path: '/torrents/checkcached', body: ok([{ hash: HASH }]) },
    { path: '/torrents/createtorrent', method: 'POST', body: ok({ torrent_id: 42, hash: HASH }) },
    { path: '/torrents/controltorrent', method: 'POST', body: ok(true) }
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridError)
  assert.ok(calls.some(call => call.url.includes('controltorrent')), 'the ghost add must not be left on the account')
  service.destroy()
})

test('a "cached" add that turns out to be a fresh download is refused and cleaned up', async () => {
  // the cache check said yes, but the account entry never reports the data present — waiting
  // for a real download would hold the player open for minutes
  const service = new FastTorBox('key')
  let added = false
  const calls = mockFetch([
    { path: '/torrents/mylist', body: () => ok(added ? [torrent({ download_present: false, download_finished: false, progress: 0.1, download_state: 'downloading' })] : []) },
    { path: '/torrents/checkcached', body: ok([{ hash: HASH }]) },
    { path: '/torrents/createtorrent', method: 'POST', body: () => { added = true; return ok({ torrent_id: 42, hash: HASH }) } },
    { path: '/torrents/controltorrent', method: 'POST', body: ok(true) }
  ])
  const started = Date.now()
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridNotCachedError)
  assert.ok(Date.now() - started < 10_000, 'the ready budget bounds the wait')
  assert.ok(calls.some(call => call.url.includes('controltorrent')), 'the torrent this call added must be removed, it is downloading against the user\'s quota')
  service.destroy()
})

test('a torrent that settles while being polled resolves as soon as it is ready', async () => {
  const service = new FastTorBox('key')
  let added = false
  let polls = 0
  mockFetch([
    {
      path: '/torrents/mylist',
      body: url => {
        if (!added) return ok([])
        // the freshly added torrent finishes settling on the second status poll
        if (String(url).includes('id=')) return ok(++polls < 2 ? torrent({ download_present: false, download_finished: false, progress: 0.9, download_state: 'downloading' }) : torrent())
        return ok([])
      }
    },
    { path: '/torrents/checkcached', body: ok([{ hash: HASH }]) },
    { path: '/torrents/createtorrent', method: 'POST', body: () => { added = true; return ok({ torrent_id: 42, hash: HASH }) } },
    { path: '/torrents/requestdl', body: ok('https://torbox.test/dl/0') }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.files.length, 1)
  assert.ok(polls >= 2, 'the poll loop must have run more than once')
  service.destroy()
})

test('polling a fresh add bypasses TorBox\'s listing cache', async () => {
  const service = new FastTorBox('key')
  let added = false
  const calls = mockFetch([
    { path: '/torrents/mylist', body: url => ok(added && String(url).includes('id=') ? torrent() : []) },
    { path: '/torrents/checkcached', body: ok([{ hash: HASH }]) },
    { path: '/torrents/createtorrent', method: 'POST', body: () => { added = true; return ok({ torrent_id: 42, hash: HASH }) } },
    { path: '/torrents/requestdl', body: ok('https://torbox.test/dl/0') }
  ])
  await service.resolve(MAGNET, { fileFilter: videoFilter })
  const poll = calls.find(call => call.url.includes('id=42'))
  assert.ok(poll, 'the fresh torrent is read back by id')
  assert.ok(poll.url.includes('bypass_cache=true'), 'a status poll answered from cache would spin forever')
  service.destroy()
})

test('a slow link stretches the ready budget instead of misreading cached as fresh', () => {
  const service = new FastTorBox('key')
  const healthy = service.budget('ready')
  for (let i = 0; i < 20; i++) service.observeLatency(FastTorBox.nominalLatency * 3)
  assert.ok(service.budget('ready') > healthy * 2, 'three-times-nominal round trips must buy a bigger budget')
  assert.ok(service.budget('ready') <= healthy * 3, 'but the stretch is capped')
  service.destroy()
})

// --- rate limiting, measured live: a 60-link burst earned a 429 with retry-after: 300 ---

test('a rate limit too long to wait out surfaces immediately instead of freezing playback', async () => {
  const service = new FastTorBox('key')
  const calls = mockFetch([{
    path: '/user/me',
    status: 429,
    headers: { 'retry-after': '300' },
    body: { success: false, error: 'RATE_LIMIT', detail: 'too many requests' }
  }])
  const started = Date.now()
  await assert.rejects(service.validate(), error => {
    assert.equal(error.status, 429)
    return true
  })
  assert.ok(Date.now() - started < 5_000, 'five minutes of frozen player is worse than an honest error')
  assert.equal(calls.length, 1, 'waiting less than asked would only collect another 429, so there is no retry')
  service.destroy()
})

test('a pack resolve asks for a bounded number of links, the played episode\'s first', async () => {
  const files = Array.from({ length: 103 }, (_, index) => ({ id: index, name: `Pack/Episode ${String(index + 1).padStart(3, '0')}.mkv`, size: 1000, mimetype: 'video/x-matroska' }))
  const service = new FastTorBox('key')
  const calls = mockFetch([
    { path: '/torrents/mylist', body: ok([torrent({ name: 'Big Pack', files })]) },
    { path: '/torrents/requestdl', body: url => ok(`https://torbox.test/dl/${new URL(url).searchParams.get('file_id')}`) }
  ])
  const resolved = await service.resolve(MAGNET, {
    fileFilter: videoFilter,
    pickFile: candidates => candidates.find(file => file.path === '/Pack/Episode 050.mkv')
  })
  const links = calls.filter(call => call.url.includes('requestdl'))
  assert.ok(links.length <= TorBox.maxFiles, `a ${links.length}-link burst is how the live account earned a five minute ban`)
  assert.equal(new URL(links[0].url).searchParams.get('file_id'), '49', 'the played episode\'s link must be requested before any neighbor\'s')
  assert.ok(resolved.files.some(file => file.path === '/Pack/Episode 050.mkv'), 'and it must be in the result')
  const paths = resolved.files.map(file => file.path)
  assert.deepEqual(paths, [...paths].sort(), 'files still come back in torrent order')
  service.destroy()
})

test('a rate-limited neighbor link is skipped rather than stalling the episode', async () => {
  const service = new FastTorBox('key')
  mockFetch([
    { path: '/torrents/mylist', body: ok([torrent({ files: [
      { id: 0, name: 'Test/Episode 01.mkv', size: 1000, mimetype: 'video/x-matroska' },
      { id: 1, name: 'Test/Episode 02.mkv', size: 1000, mimetype: 'video/x-matroska' }
    ] })]) },
    {
      path: '/torrents/requestdl',
      get status () { return this._url?.includes('file_id=1') ? 429 : 200 },
      headers: { 'retry-after': '300' },
      body: function (url) { this._url = url; return url.includes('file_id=1') ? { success: false, error: 'RATE_LIMIT', detail: 'slow down' } : ok('https://torbox.test/dl/0') }
    }
  ])
  const started = Date.now()
  const resolved = await service.resolve(MAGNET, {
    fileFilter: videoFilter,
    pickFile: candidates => candidates.find(file => file.path === '/Test/Episode 01.mkv')
  })
  assert.ok(Date.now() - started < 5_000, 'one throttled neighbor must not hold the play back')
  assert.deepEqual(resolved.files.map(file => file.path), ['/Test/Episode 01.mkv'], 'the episode plays, the neighbor is dropped')
  service.destroy()
})

test('a pickFile refusal propagates intact and takes an added torrent back off the account', async () => {
  // the picker refusing to guess (EpisodeNotInPackError) must reach streamDebrid as-is for its
  // no-fallback handling, and must not leave the just-added pack on the account
  class Refusal extends Error {}
  const service = new FastTorBox('key')
  let added = false
  const calls = mockFetch([
    { path: '/torrents/mylist', body: () => ok(added ? [torrent()] : []) },
    { path: '/torrents/checkcached', body: ok([{ hash: HASH }]) },
    { path: '/torrents/createtorrent', method: 'POST', body: () => { added = true; return ok({ torrent_id: 42, hash: HASH }) } },
    { path: '/torrents/controltorrent', method: 'POST', body: ok(true) }
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter, pickFile: () => { throw new Refusal('not in this pack') } }), Refusal)
  assert.ok(calls.some(call => call.url.includes('controltorrent')), 'the pack this call added must be removed again')
  service.destroy()
})

test('a pickFile refusal never deletes a pack the account already had', async () => {
  class Refusal extends Error {}
  const service = new FastTorBox('key')
  const calls = mockFetch([{ path: '/torrents/mylist', body: ok([torrent()]) }])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter, pickFile: () => { throw new Refusal('not in this pack') } }), Refusal)
  assert.ok(!calls.some(call => call.url.includes('controltorrent')), 'only torrents this client added may be removed')
  service.destroy()
})

// --- the real release name, which is what makes a junk search title survivable ---
//
// SeaDex replaces a multi file release's name with `[Group] Show Dual Audio`, so the results list
// cannot tell a two episode fix release from a full series batch. TorBox names the release it is
// answering about, in requests the client already makes, so the truth costs nothing.

test('the cache check records the real name of every release it confirms', async () => {
  const service = new FastTorBox('key')
  const other = 'b'.repeat(40)
  mockFetch([{
    path: '/torrents/checkcached',
    body: ok([
      { hash: HASH.toUpperCase(), name: '[F-R] One Piece 0487+0490 v3 (WEB 1080p)', size: 2_865_536_643 },
      { hash: other, name: '[F-R] One Piece 0001-0782 (Batch)', size: 1 }
    ])
  }])
  await service.checkAvailability([HASH, other])
  assert.equal(service.releaseName(HASH), '[F-R] One Piece 0487+0490 v3 (WEB 1080p)', 'the name a search source invented is not the one to judge by')
  assert.equal(service.releaseName(other), '[F-R] One Piece 0001-0782 (Batch)')
  assert.equal(service.releaseName('c'.repeat(40)), undefined, 'nothing is invented for a release it never mentioned')
  service.destroy()
})

test('the account listing records names too, so a known release needs no request at all', async () => {
  const service = new FastTorBox('key')
  mockFetch([{ path: '/torrents/mylist', body: ok([torrent({ name: '[F-R] One Piece 0487+0490 v3 (WEB 1080p)' })]) }])
  await service.listAvailability()
  assert.equal(service.releaseName(HASH), '[F-R] One Piece 0487+0490 v3 (WEB 1080p)')
  service.destroy()
})

test('a nameless answer records nothing rather than an empty name', async () => {
  const service = new FastTorBox('key')
  mockFetch([{ path: '/torrents/checkcached', body: ok([{ hash: HASH }]) }])
  await service.checkAvailability([HASH])
  assert.equal(service.releaseName(HASH), undefined)
  service.destroy()
})

test('the cache endpoint is still understood when it answers keyed by hash', async () => {
  const service = new FastTorBox('key')
  mockFetch([{ path: '/torrents/checkcached', body: ok({ [HASH]: { name: '[F-R] One Piece 0487+0490 v3', size: 1 } }) }])
  const answers = await service.checkAvailability([HASH])
  assert.equal(answers.get(HASH), Availability.CACHED, 'the map shape must keep working')
  assert.equal(service.releaseName(HASH), '[F-R] One Piece 0487+0490 v3', 'and still yield the name')
  service.destroy()
})
