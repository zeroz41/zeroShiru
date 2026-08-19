// AllDebrid against a mocked API. No live key exists yet, so these pin the request shapes and
// the response handling the implementation was written against: the `{ status, data }` envelope,
// the upload response that doubles as the cache answer, and the nested file tree.
//
// The endpoint list was checked against the live API unauthenticated: `/v4/magnet/upload` and
// `/v4.1/magnet/status` answer AUTH_MISSING_APIKEY, while `/v4/magnet/instant` answers the same
// 404 as an endpoint that never existed. That is why availability is read off the upload here.
//
// The invariant these tests exist for: a check must never delete a magnet the user already had.
import { test, beforeEach, afterEach } from 'bun:test'
import assert from 'node:assert/strict'
import AllDebrid from '../../../common/modules/debrid/alldebrid.js'
import { DebridError, DebridAuthError, DebridNotCachedError, DebridUnavailableError } from '../../../common/modules/debrid/service.js'
import { Availability } from '../../../common/modules/debrid/availability.js'

const HASH = 'a'.repeat(40)
const OTHER = 'b'.repeat(40)
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
    const body = typeof route.body === 'function' ? route.body(String(url), opts) : route.body
    return { ok: status >= 200 && status < 300, status, headers: { get: () => null }, json: async () => body }
  }
  return calls
}

/** The envelope every AllDebrid response arrives in. */
const ok = data => ({ status: 'success', data })
const fail = (code, message = 'nope') => ({ status: 'error', error: { code, message } })

/** The status route, which every path through this client reads first. */
const statusRoute = (magnets = []) => ({ path: '/magnet/status', method: 'POST', body: ok({ magnets }) })
const deleteRoute = () => ({ path: '/magnet/delete', method: 'POST', body: ok({ message: 'Magnet was successfully deleted' }) })

/** The file tree AllDebrid answers with: `n` name, `s` size, `l` link, `e` folder children. */
const files = [
  { n: 'Test Pack', e: [{ n: 'Episode 01.mkv', s: 1000, l: 'https://alldebrid.test/f/1' }, { n: 'readme.txt', s: 10, l: 'https://alldebrid.test/f/2' }] },
  { n: 'extra.mkv', s: 2000, l: 'https://alldebrid.test/f/3' }
]

let service
beforeEach(() => {
  service = new AllDebrid('test-key')
})
afterEach(() => service?.destroy())

test('the key travels as a bearer header, never in the URL', async () => {
  const calls = mockFetch([{ path: '/v4/user', body: ok({ user: { username: 'tester', isPremium: true, premiumUntil: 1799999999 } }) }])
  const account = await service.validate()
  assert.equal(calls[0].headers.Authorization, 'Bearer test-key')
  assert.ok(!calls[0].url.includes('test-key'), 'the key must stay out of logs and CDN caches')
  assert.equal(account.username, 'tester')
  assert.match(account.expires, /^\d{4}-/, 'the expiry is handed to the UI as a date string')
})

test('an account without premium cannot stream torrents and is told so', async () => {
  mockFetch([{ path: '/v4/user', body: ok({ user: { username: 'tester', isPremium: false, isTrial: false } }) }])
  await assert.rejects(service.validate(), DebridAuthError)
})

test('a rejected key is an auth error, whatever the HTTP status says', async () => {
  mockFetch([{ path: '/v4/user', body: fail('AUTH_BAD_APIKEY', 'bad key') }])
  await assert.rejects(service.validate(), error => {
    assert.ok(error instanceof DebridAuthError)
    assert.match(error.message, /Invalid AllDebrid API key/)
    return true
  })
})

test('one upload answers a whole batch of hashes', async () => {
  const calls = mockFetch([
    statusRoute(),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 1, ready: true }, { hash: OTHER, id: 2, ready: false }] }) },
    deleteRoute()
  ])
  const answers = await service.checkAvailability([HASH, OTHER])
  assert.equal(answers.get(HASH), Availability.CACHED)
  assert.equal(answers.get(OTHER), Availability.AVAILABLE, 'not ready means it would have to fetch it')
  const uploads = calls.filter(call => call.url.includes('/magnet/upload'))
  assert.equal(uploads.length, 1, 'both hashes go up in one request')
  assert.equal(new URLSearchParams(uploads[0].body).getAll('magnets[]').length, 2, 'as two parameters, not one joined value')
})

// the reason this client reads the account before it uploads anything: an upload of a magnet the
// account already holds answers with the existing entry, so without that read the cleanup below
// would delete one of the user's own magnets
test('a check removes only the magnets it created, never one the user already had', async () => {
  const calls = mockFetch([
    statusRoute([{ id: 1, filename: 'Already Here', statusCode: 4 }]),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 1, ready: true }, { hash: OTHER, id: 2, ready: false }] }) },
    deleteRoute()
  ])
  await service.checkAvailability([HASH, OTHER])
  const deleted = calls.filter(call => call.url.includes('/magnet/delete')).map(call => new URLSearchParams(call.body).get('id'))
  assert.deepEqual(deleted, ['2'], "the magnet that was already on the account must survive the check")
})

test('a magnet AllDebrid will never take is an answer, and a busy account is not', async () => {
  mockFetch([
    statusRoute(),
    {
      path: '/magnet/upload',
      method: 'POST',
      body: ok({ magnets: [{ magnet: HASH, error: { code: 'MAGNET_INVALID_URI', message: 'no' } }, { magnet: OTHER, error: { code: 'MAGNET_TOO_MANY_ACTIVE', message: 'busy' } }] })
    },
    deleteRoute()
  ])
  const answers = await service.checkAvailability([HASH, OTHER])
  assert.equal(answers.get(HASH), Availability.UNAVAILABLE, 'a rejected magnet is settled')
  assert.equal(answers.has(OTHER), false, 'a busy account proves nothing about the release, so it stays unknown')
  assert.deepEqual(service.unknownHashes([OTHER]), [OTHER], 'and it is asked about again later')
})

// unlike a real cache endpoint, an upload answers about exactly the magnets it managed to take,
// so a hash it never mentions has not been called uncached
test('a hash the upload never mentions stays unknown rather than being badged', async () => {
  mockFetch([
    statusRoute(),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 1, ready: true }] }) },
    deleteRoute()
  ])
  const answers = await service.checkAvailability([HASH, OTHER])
  assert.equal(answers.get(HASH), Availability.CACHED)
  assert.equal(answers.has(OTHER), false)
  assert.deepEqual(service.unknownHashes([OTHER]), [OTHER])
})

test('a cached release is uploaded once and then streamed', async () => {
  const calls = mockFetch([
    statusRoute([{ id: 7, filename: 'Test Pack', statusCode: 4, files }]),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 7, ready: true, name: 'Test Pack' }] }) },
    { path: '/link/unlock', body: url => ok({ link: `https://cdn.alldebrid.test/${url.slice(-1)}.mkv`, filename: 'Episode 01.mkv', filesize: 1000 }) }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.hash, HASH)
  assert.equal(resolved.name, 'Test Pack')
  assert.deepEqual(resolved.files.map(file => file.path), ['/Test Pack/Episode 01.mkv', '/extra.mkv'], 'the file tree flattens into rooted paths, folders and all')
  assert.ok(resolved.files.every(file => file.url.startsWith('https://cdn.')), 'every file is unlocked into a direct link')
  assert.equal(calls.filter(call => call.url.includes('/magnet/delete')).length, 0, 'a release that played stays on the account, like every other service')
})

// asking about one magnet by id is documented to answer with its files inline; the dedicated
// endpoint is the fallback for when it does not, since that is the shape most likely to differ
// from the docs once this runs against a real account
test('a status read without a file tree falls back to the files endpoint', async () => {
  const calls = mockFetch([
    statusRoute([{ id: 7, filename: 'Test Pack', statusCode: 4 }]),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 7, ready: true }] }) },
    { path: '/magnet/files', method: 'POST', body: ok({ magnets: [{ id: '7', files }] }) },
    { path: '/link/unlock', body: ok({ link: 'https://cdn.alldebrid.test/ok.mkv', filesize: 1000 }) }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.files.length, 2)
  assert.equal(new URLSearchParams(calls.find(call => call.url.includes('/magnet/files')).body).getAll('id[]').length, 1)
})

// the upload already said the release was ready, so an empty status read is the request failing.
// Reporting that as "not cached" would badge a cached release wrong for the next twenty minutes
test('a status read that comes back empty is a failure, not an answer about the release', async () => {
  mockFetch([
    statusRoute(),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 7, ready: true }] }) },
    deleteRoute()
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), error => {
    assert.ok(error instanceof DebridError)
    assert.ok(!(error instanceof DebridNotCachedError), 'nothing was proved about the release')
    return true
  })
})

// checking costs the account, so two overlapping checks must not both upload. The results list
// re-runs this reactively, so without the guard a re-sort would double the magnets added
test('only one check runs at a time, since each one puts magnets on the account', async () => {
  const calls = mockFetch([
    statusRoute(),
    { path: '/magnet/upload', method: 'POST', body: async () => ok({ magnets: [{ hash: HASH, id: 1, ready: true }] }) },
    deleteRoute()
  ])
  await Promise.all([service.checkAvailability([HASH]), service.checkAvailability([HASH])])
  assert.equal(calls.filter(call => call.url.includes('/magnet/upload')).length, 1)
})

test('an uncached release is taken back off the account instead of being left downloading', async () => {
  const calls = mockFetch([
    statusRoute(),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 9, ready: false }] }) },
    deleteRoute()
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridNotCachedError)
  assert.deepEqual(calls.filter(call => call.url.includes('/magnet/delete')).map(call => new URLSearchParams(call.body).get('id')), ['9'])
})

test('a release the account was already holding is never deleted by a failed resolve', async () => {
  const calls = mockFetch([
    statusRoute([{ id: 9, filename: 'The users own', statusCode: 1 }]),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 9, ready: false }] }) },
    deleteRoute()
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridNotCachedError)
  assert.equal(calls.filter(call => call.url.includes('/magnet/delete')).length, 0)
})

test('a magnet that failed on the account is unavailable, not uncached', async () => {
  mockFetch([
    statusRoute([{ id: 7, filename: 'Broken', statusCode: 15 }]),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 7, ready: true }] }) },
    deleteRoute()
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridUnavailableError)
})

test('one dead file in a pack does not sink the whole resolve', async () => {
  let unlocks = 0
  mockFetch([
    statusRoute([{ id: 7, filename: 'Test Pack', statusCode: 4, files }]),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 7, ready: true }] }) },
    { path: '/link/unlock', body: () => (++unlocks === 1 ? fail('LINK_DOWN', 'dead') : ok({ link: 'https://cdn.alldebrid.test/ok.mkv', filesize: 1000 })) }
  ])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.files.length, 1, 'the file that still works is streamed')
})

test('an auth failure while unlocking still surfaces as an auth error', async () => {
  mockFetch([
    statusRoute([{ id: 7, filename: 'Test Pack', statusCode: 4, files }]),
    { path: '/magnet/upload', method: 'POST', body: ok({ magnets: [{ hash: HASH, id: 7, ready: true }] }) },
    { path: '/link/unlock', body: fail('AUTH_BAD_APIKEY', 'bad key') },
    deleteRoute()
  ])
  await assert.rejects(service.resolve(MAGNET, { fileFilter: videoFilter }), DebridAuthError)
})

test('being told the account is busy stops a sweep rather than counting against the release', () => {
  assert.equal(service.throttled(new DebridError('busy', { code: 'MAGNET_TOO_MANY_ACTIVE' })), true)
  assert.equal(service.throttled(new DebridError('slow down', { status: 429 })), true)
  assert.equal(service.throttled(new DebridError('dead', { code: 'LINK_DOWN' })), false)
})

// magnet/status describes a magnet by name and progress and never says which info hash it came
// from, so there is nothing to badge from it. It must answer empty rather than throw
test('the account listing yields no badges, because it carries no info hashes', async () => {
  mockFetch([])
  assert.equal((await service.listAvailability()).size, 0)
})

test('resolve refuses a source it cannot turn into a hash instead of guessing', async () => {
  mockFetch([])
  await assert.rejects(service.resolve('https://nyaa.si/download/1.torrent'), DebridError)
})
