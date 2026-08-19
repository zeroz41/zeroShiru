// TorBox against a mocked API. No live key exists yet, so these pin the request shapes and the
// response handling the implementation was written against: the `{ success, data }` envelope,
// the bulk cache check, and the one endpoint that authenticates differently from the rest.
import { test, beforeEach, afterEach } from 'bun:test'
import assert from 'node:assert/strict'
import TorBox from '../../../common/modules/debrid/torbox.js'
import { DebridError, DebridAuthError, DebridNotCachedError, DebridUnavailableError } from '../../../common/modules/debrid/service.js'
import { Availability } from '../../../common/modules/debrid/availability.js'

const HASH = 'a'.repeat(40)
const MAGNET = `magnet:?xt=urn:btih:${HASH}&dn=test`
const videoFilter = name => /\.(mkv|mp4)$/i.test(name)

/** Installs a fetch mock. Routes match in order by method plus a path substring. */
function mockFetch (routes) {
  const calls = []
  globalThis.fetch = async (url, opts = {}) => {
    const method = opts.method || 'GET'
    calls.push({ url: String(url), method, body: opts.body, headers: opts.headers })
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

/** The envelope every TorBox response arrives in. */
const ok = data => ({ success: true, error: null, detail: 'ok', data })
const fail = (error, detail = 'nope') => ({ success: false, error, detail, data: null })

function torrent (overrides = {}) {
  return {
    id: 42,
    hash: HASH.toUpperCase(),
    name: 'Test Torrent',
    download_state: 'completed',
    download_finished: true,
    download_present: true,
    progress: 1,
    files: [
      { id: 0, name: 'Test/Episode 01.mkv', short_name: 'Episode 01.mkv', size: 1000, mimetype: 'video/x-matroska' },
      { id: 1, name: 'Test/readme.txt', short_name: 'readme.txt', size: 10, mimetype: 'text/plain' },
      { id: 2, name: 'Test/Episode 02.mkv', short_name: 'Episode 02.mkv', size: 2000, mimetype: 'video/x-matroska' }
    ],
    ...overrides
  }
}

/**
 * A service whose rate limiter is out of the way. The pack test below is about which files come
 * back, not about pacing, and a 60 link pack at the real limits spends twelve seconds proving it.
 */
function unthrottled () {
  class Unthrottled extends TorBox {
    static limits = { maxConcurrent: 20, minTime: 0 }
  }
  return new Unthrottled('test-key')
}

let service
beforeEach(() => {
  service = new TorBox('test-key')
})
afterEach(() => service?.destroy())

test('validate reads the account behind the key', async () => {
  mockFetch([{ path: '/user/me', body: ok({ email: 'tester@example.test', plan: 2, premium_expires_at: '2030-01-01' }) }])
  const result = await service.validate()
  assert.equal(result.username, 'tester@example.test')
  assert.equal(result.expires, '2030-01-01')
})

// TorBox reports plenty of failures with a 200 and success:false, so the envelope has to be
// what decides, not the status code
test('a failure inside a 200 response is still a typed error', async () => {
  mockFetch([{ path: '/user/me', body: fail('BAD_TOKEN') }])
  await assert.rejects(service.validate(), error => {
    assert.ok(error instanceof DebridAuthError, 'a bad key must abort rather than be retried per request')
    assert.match(error.message, /API key/)
    return true
  })
})

test('a per-request failure stays a plain error, so one bad call cannot look like a bad key', async () => {
  mockFetch([{ path: '/user/me', body: fail('ACTIVE_LIMIT') }])
  await assert.rejects(service.validate(), error => {
    assert.ok(error instanceof DebridError && !(error instanceof DebridAuthError))
    assert.match(error.message, /active TorBox downloads/)
    return true
  })
})

test('an unknown error code still reports what the API said', async () => {
  mockFetch([{ path: '/user/me', status: 500, body: fail('SOME_NEW_CODE', 'the disk fell over') }])
  await assert.rejects(service.validate(), error => {
    assert.match(error.message, /disk fell over/)
    return true
  })
})

// the reason TorBox is worth having: one request badges a whole results list
test('the cache endpoint answers many hashes in a single request', async () => {
  const hashes = Array.from({ length: 5 }, (_, index) => String(index).padStart(40, '0'))
  const calls = mockFetch([{ path: '/torrents/checkcached', body: ok([{ hash: hashes[1].toUpperCase(), name: 'Cached One', size: 1 }]) }])
  const answers = await service.checkAvailability(hashes)
  assert.equal(calls.length, 1, 'a batch service must not be asked per hash')
  assert.equal(answers.get(hashes[1]), Availability.CACHED)
  for (const hash of [hashes[0], hashes[2], hashes[3], hashes[4]]) {
    assert.equal(answers.get(hash), Availability.AVAILABLE, 'not cached means TorBox would fetch it, not that it cannot')
  }
  assert.equal(calls[0].url.match(/hash=/g).length, 5, 'every hash travels in the one request')
})

// the endpoint has answered in both shapes over its life, and either is just "TorBox holds it"
test('the cache endpoint is understood whether it answers a list or a map', async () => {
  mockFetch([{ path: '/torrents/checkcached', body: ok({ [HASH]: { name: 'Cached One', size: 1, hash: HASH } }) }])
  const answers = await service.checkAvailability([HASH])
  assert.equal(answers.get(HASH), Availability.CACHED)
})

test('an empty cache answer is an answer, not a failure', async () => {
  mockFetch([{ path: '/torrents/checkcached', body: ok(null) }])
  const answers = await service.checkAvailability([HASH])
  assert.equal(answers.get(HASH), Availability.AVAILABLE)
})

test('listAvailability reads every account torrent as what it means for playback', async () => {
  mockFetch([{
    path: '/torrents/mylist',
    body: ok([
      torrent(),
      torrent({ id: 2, hash: 'b'.repeat(40), download_present: false, download_finished: false, progress: 0.3, download_state: 'downloading' }),
      torrent({ id: 3, hash: 'c'.repeat(40), download_present: false, download_finished: false, download_state: 'stalled (no seeds)' })
    ])
  }])
  const known = await service.listAvailability()
  assert.equal(known.get(HASH), Availability.CACHED, 'held, and lowercased')
  assert.equal(known.get('b'.repeat(40)), Availability.AVAILABLE)
  assert.equal(known.get('c'.repeat(40)), Availability.UNAVAILABLE, 'a stalled torrent will never finish on its own')
})

test('resolve streams a torrent the account already holds, without adding it again', async () => {
  const calls = mockFetch([
    { path: '/torrents/mylist', body: ok([torrent()]) },
    { path: '/torrents/requestdl', body: url => ok(`https://torbox.test/dl/${new URL(url).searchParams.get('file_id')}`) }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.hash, HASH, 'the hash comes back lowercased, the key everything else is stored under')
  assert.equal(resolved.name, 'Test Torrent')
  assert.deepEqual(resolved.files.map(file => file.path), ['/Test/Episode 01.mkv', '/Test/Episode 02.mkv'], 'rooted paths, and the readme filtered out')
  assert.deepEqual(resolved.files.map(file => file.name), ['Episode 01.mkv', 'Episode 02.mkv'])
  assert.ok(!calls.some(call => call.url.includes('createtorrent')), 'a torrent already on the account must be reused')
  assert.ok(resolved.files.every(file => file.url.startsWith('https://')))
  // the same file shape Real-Debrid produces, MIME type included, since the player reads it
  assert.deepEqual(resolved.files.map(file => file.type), ['video/x-matroska', 'video/x-matroska'])
  for (const file of resolved.files) assert.deepEqual(Object.keys(file).sort(), ['name', 'path', 'size', 'type', 'url'])
})

// TorBox authenticates this one endpoint with a query token, everything else with a bearer header
test('the link endpoint carries the key the way it expects, and no other one does', async () => {
  const calls = mockFetch([
    { path: '/torrents/mylist', body: ok([torrent()]) },
    { path: '/torrents/requestdl', body: ok('https://torbox.test/dl/0') }
  ])
  await service.resolve(MAGNET, { fileFilter: name => name.includes('Episode 01') })
  const list = calls.find(call => call.url.includes('/torrents/mylist'))
  const link = calls.find(call => call.url.includes('/torrents/requestdl'))
  assert.equal(list.headers.Authorization, 'Bearer test-key')
  assert.ok(!list.url.includes('test-key'), 'a bearer key must never leak into a URL')
  assert.equal(new URL(link.url).searchParams.get('token'), 'test-key')
  assert.equal(link.headers.Authorization, undefined, 'and the token endpoint must not also send a header')
})

test('an uncached release is refused before anything lands on the account', async () => {
  const calls = mockFetch([
    { path: '/torrents/mylist', body: ok([]) },
    { path: '/torrents/checkcached', body: ok([]) }
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridNotCachedError)
  assert.ok(!calls.some(call => call.url.includes('createtorrent')), 'asking is free, so nothing is queued onto the account to find out')
})

test('a cached release is added and then streamed', async () => {
  let added = false
  const calls = mockFetch([
    { path: '/torrents/mylist', body: () => ok(added ? [torrent()] : []) },
    { path: '/torrents/checkcached', body: ok([{ hash: HASH }]) },
    { path: '/torrents/createtorrent', method: 'POST', body: () => { added = true; return ok({ torrent_id: 42, hash: HASH }) } },
    { path: '/torrents/requestdl', body: ok('https://torbox.test/dl/0') }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.files.length, 2)
  const create = calls.find(call => call.url.includes('createtorrent'))
  assert.ok(create.body instanceof FormData, 'createtorrent documents multipart')
  assert.equal(create.body.get('magnet'), MAGNET)
  assert.equal(create.body.get('allow_zip'), 'false', 'a zipped pack is not something the player can seek in')
  assert.equal(create.body.get('seed'), '3', 'Shiru only streams, it must never leave the account seeding')
})

test('a torrent the account holds but cannot finish is unavailable, not uncached', async () => {
  mockFetch([{ path: '/torrents/mylist', body: ok([torrent({ download_present: false, download_finished: false, download_state: 'error' })]) }])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridUnavailableError)
})

test('a torrent still downloading on the account is not deleted out from under the user', async () => {
  const calls = mockFetch([{ path: '/torrents/mylist', body: ok([torrent({ download_present: false, download_finished: false, progress: 0.5, download_state: 'downloading' })]) }])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridNotCachedError)
  assert.ok(!calls.some(call => call.url.includes('controltorrent')), 'only torrents this client added may be removed')
})

// the account can already hold a release the listing missed a moment earlier, and a torrent
// this client did not create is never its to delete
test('a duplicate add is never treated as this client\'s torrent', async () => {
  let seen = false
  const calls = mockFetch([
    { path: '/torrents/mylist', body: () => ok(seen ? [torrent({ files: [{ id: 0, name: 'Test/readme.txt', size: 10 }] })] : []) },
    { path: '/torrents/checkcached', body: ok([{ hash: HASH }]) },
    { path: '/torrents/createtorrent', method: 'POST', body: () => { seen = true; return fail('DUPLICATE_ITEM') } },
    { path: '/torrents/controltorrent', method: 'POST', body: ok(true) }
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridError)
  assert.ok(!calls.some(call => call.url.includes('controltorrent')), 'a torrent the account already had must survive a failed resolve')
})

test('a resolve that fails after adding takes its own torrent back off the account', async () => {
  let added = false
  const calls = mockFetch([
    { path: '/torrents/mylist', body: () => ok(added ? [torrent({ files: [{ id: 0, name: 'Test/readme.txt', size: 10 }] })] : []) },
    { path: '/torrents/checkcached', body: ok([{ hash: HASH }]) },
    { path: '/torrents/createtorrent', method: 'POST', body: () => { added = true; return ok({ torrent_id: 42, hash: HASH }) } },
    { path: '/torrents/controltorrent', method: 'POST', body: ok(true) }
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridError)
  const cleanup = calls.find(call => call.url.includes('controltorrent'))
  assert.ok(cleanup, 'the torrent this call created must not be left behind')
  assert.deepEqual(JSON.parse(cleanup.body), { torrent_id: 42, operation: 'delete' })
})

test('a pack is capped around the episode being played, in torrent order', async () => {
  const files = Array.from({ length: 150 }, (_, index) => ({ id: index, name: `Pack/Episode ${String(index + 1).padStart(3, '0')}.mkv`, size: 1000 }))
  const service = unthrottled()
  mockFetch([
    { path: '/torrents/mylist', body: ok([torrent({ name: 'Big Pack', files })]) },
    { path: '/torrents/requestdl', body: url => ok(`https://torbox.test/dl/${new URL(url).searchParams.get('file_id')}`) }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter, maxFiles: 60, pickFile: candidates => candidates.find(file => file.path === '/Pack/Episode 100.mkv') })
  assert.equal(resolved.files.length, 60, 'the cap is respected')
  assert.ok(resolved.files.some(file => file.path === '/Pack/Episode 100.mkv'), 'the requested episode must survive it')
  assert.ok(resolved.files.some(file => file.path === '/Pack/Episode 099.mkv'), 'and its neighbours, for in-player navigation')
  const paths = resolved.files.map(file => file.path)
  assert.deepEqual(paths, [...paths].sort(), 'files stay in torrent order')
})

test('one dead file in a pack does not sink the whole resolve', async () => {
  let call = 0
  mockFetch([
    { path: '/torrents/mylist', body: ok([torrent()]) },
    { path: '/torrents/requestdl', get status () { return ++call === 1 ? 500 : 200 }, body: () => call === 1 ? fail('DOWNLOAD_SERVER_ERROR') : ok('https://torbox.test/dl/2') }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.files.length, 1, 'the surviving file must still play')
})

test('an auth failure while fetching links still surfaces as an auth error', async () => {
  mockFetch([
    { path: '/torrents/mylist', body: ok([torrent()]) },
    { path: '/torrents/requestdl', status: 403, body: fail('BAD_TOKEN') }
  ])
  // every link would fail for the same reason, so this is not a per file problem to skip
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridAuthError)
})

test('a torrent with nothing playable in it says so', async () => {
  mockFetch([{ path: '/torrents/mylist', body: ok([torrent({ files: [{ id: 0, name: 'Test/readme.txt', size: 10 }] })]) }])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), /No playable files/)
})

test('resolve refuses a source it cannot turn into a hash instead of guessing', async () => {
  mockFetch([])
  await assert.rejects(service.resolve('https://nyaa.si/download/1.torrent'), DebridError)
})

test('requires an api key', async () => {
  await assert.rejects(new TorBox('').validate(), DebridAuthError)
})
