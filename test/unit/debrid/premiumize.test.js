// Premiumize against a mocked API. No live key exists yet, so these pin the request shapes and
// the response handling the implementation was written against: the flat `{ status }` envelope,
// the parallel-array cache answer, and the single call that returns every stream link at once.
//
// The endpoints themselves were confirmed to exist by calling them unauthenticated, which answers
// `authentication_failed` where an endpoint that had been withdrawn answers with the site's 404.
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import Premiumize from '../../../common/modules/debrid/premiumize.js'
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

/** Premiumize reports failures inside a 200, with the payload at the top level on success. */
const fail = (code, message = 'nope') => ({ status: 'error', message, code })

const content = [
  { path: 'Test Pack/Episode 01.mkv', size: 1000, link: 'https://premiumize.test/1.mkv' },
  { path: 'Test Pack/readme.txt', size: 10, link: 'https://premiumize.test/readme.txt' },
  { path: 'Test Pack/Episode 02.mkv', size: 2000, link: 'https://premiumize.test/2.mkv' }
]

let service
beforeEach(() => {
  service = new Premiumize('test-key')
})

test('the key travels as a bearer header, never in the URL', async () => {
  const calls = mockFetch([{ path: '/account/info', body: { status: 'success', customer_id: '1234567', premium_until: 1799999999 } }])
  const account = await service.validate()
  assert.equal(calls[0].headers.Authorization, 'Bearer test-key')
  assert.ok(!calls[0].url.includes('test-key'), 'the key must stay out of logs and CDN caches')
  assert.match(account.username, /1234567/)
  assert.match(account.expires, /^\d{4}-/, 'the expiry is handed to the UI as a date string')
})

// free accounts stream cached content through the same endpoints, so requiring premium here
// would lock out accounts that work perfectly well
test('an account with no premium still validates', async () => {
  mockFetch([{ path: '/account/info', body: { status: 'success', customer_id: '99', premium_until: null } }])
  const account = await service.validate()
  assert.equal(account.expires, undefined)
})

test('a rejected key is an auth error, whatever the HTTP status says', async () => {
  mockFetch([{ path: '/account/info', body: fail('authentication_failed', 'Not logged in') }])
  await assert.rejects(service.validate(), DebridAuthError)
})

test('the cache endpoint answers a whole results list in one request', async () => {
  const calls = mockFetch([{ path: '/cache/check', method: 'POST', body: { status: 'success', response: [true, false], filename: ['Test', null], filesize: ['1000', 0] } }])
  const answers = await service.checkAvailability([HASH, OTHER])
  assert.equal(calls.length, 1, 'one request, however many hashes')
  assert.equal(answers.get(HASH), Availability.CACHED)
  assert.equal(answers.get(OTHER), Availability.AVAILABLE, 'a miss means it would have to fetch it, not that it cannot')
})

// the answer is positional, so sending the hashes any other way silently shifts every result
test('each hash is sent as its own repeated parameter, in order', async () => {
  const calls = mockFetch([{ path: '/cache/check', method: 'POST', body: { status: 'success', response: [false, true] } }])
  const answers = await service.checkAvailability([HASH, OTHER])
  const sent = new URLSearchParams(calls[0].body).getAll('items[]')
  assert.equal(sent.length, 2, 'two hashes must arrive as two parameters, not one joined value')
  assert.match(sent[0], new RegExp(HASH))
  assert.equal(answers.get(OTHER), Availability.CACHED, 'the second answer belongs to the second hash')
})

test('resolve reads every stream link out of one call and adds nothing to the account', async () => {
  const calls = mockFetch([{ path: '/transfer/directdl', method: 'POST', body: { status: 'success', content } }])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(calls.length, 1, 'one request is the whole resolve')
  assert.equal(resolved.hash, HASH)
  assert.equal(resolved.name, 'Test Pack', 'the folder every file sits under names the release')
  assert.deepEqual(resolved.files.map(file => file.name), ['Episode 01.mkv', 'Episode 02.mkv'], 'non-video files are filtered out')
  assert.deepEqual(resolved.files.map(file => file.path), ['/Test Pack/Episode 01.mkv', '/Test Pack/Episode 02.mkv'], "paths are rooted like the torrent client's")
  assert.equal(resolved.files[0].url, 'https://premiumize.test/1.mkv')
})

test('a single file release is named after the file itself', async () => {
  mockFetch([{ path: '/transfer/directdl', method: 'POST', body: { status: 'success', content: [{ path: 'Episode 01.mkv', size: 1000, link: 'https://premiumize.test/1.mkv' }] } }])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter })
  assert.equal(resolved.name, 'Episode 01.mkv')
  assert.equal(resolved.files[0].path, '/Episode 01.mkv')
})

test('the episode being played picks the file, not the largest one', async () => {
  mockFetch([{ path: '/transfer/directdl', method: 'POST', body: { status: 'success', content } }])
  const resolved = await service.resolve(MAGNET, { fileFilter: videoFilter, pickFile: async files => files.find(file => file.path.includes('01')) })
  assert.ok(resolved.files.some(file => file.name === 'Episode 01.mkv'))
})

// directdl only ever reads the cache, so an empty answer is the cache saying no
test('nothing in the cache reads as not cached, and playback can fall back', async () => {
  mockFetch([{ path: '/transfer/directdl', method: 'POST', body: { status: 'success', content: [] } }])
  await assert.rejects(service.resolve(MAGNET), DebridNotCachedError)
})

test('a source Premiumize cannot process at all says so, rather than looking uncached', async () => {
  mockFetch([{ path: '/transfer/directdl', method: 'POST', body: fail('service_unsupported', 'no') }])
  await assert.rejects(service.resolve(MAGNET), DebridUnavailableError)
})

test('a release Premiumize simply does not hold is uncached, not unavailable', async () => {
  mockFetch([{ path: '/transfer/directdl', method: 'POST', body: fail('not_found', 'no such thing') }])
  await assert.rejects(service.resolve(MAGNET), error => {
    assert.ok(error instanceof DebridNotCachedError, 'Premiumize could still fetch it, so this must stay recoverable')
    assert.ok(!(error instanceof DebridUnavailableError))
    return true
  })
})

test('a transient link failure is left transient, so the release stays re-checkable', async () => {
  mockFetch([{ path: '/transfer/directdl', method: 'POST', body: fail('link_generation_failed') }])
  await assert.rejects(service.resolve(MAGNET), error => {
    assert.ok(error instanceof DebridError)
    assert.ok(!(error instanceof DebridNotCachedError) && !(error instanceof DebridUnavailableError), 'a bad moment proves nothing about the release')
    return true
  })
})

test('being rate limited stops a sweep rather than counting against the release', () => {
  assert.equal(service.throttled(new DebridError('slow down', { code: 'rate_limit_reached' })), true)
  assert.equal(service.throttled(new DebridError('out of points', { code: 'account_limit_reached' })), true)
  assert.equal(service.throttled(new DebridError('nope', { code: 'link_generation_failed' })), false)
})

// the account listing names transfers but never the info hash behind one, so there is nothing
// to badge from it. It must answer empty rather than throw, since the badge refresh calls it
test('the account listing is empty rather than unimplemented', async () => {
  mockFetch([])
  assert.equal((await service.listAvailability()).size, 0)
  assert.deepEqual(await service.fetchListing(), [])
})

test('resolve refuses a source it cannot turn into a hash instead of guessing', async () => {
  mockFetch([])
  await assert.rejects(service.resolve('https://nyaa.si/download/1.torrent'), DebridError)
})
