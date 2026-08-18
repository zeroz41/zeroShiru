// What the debrid layer does on a bad connection, which is the case it was getting wrong.
//
// Measured on a satellite link, one request to Real-Debrid took about a second, so a probe cost
// five or six seconds and a torrent whose metadata Real-Debrid did not already hold burned the
// whole ten second budget and then reported no answer at all. Three of those in a row ended the
// sweep, and nothing ever asked again, which is what left a results list with two badges on it.
//
// These tests pin the three things that changed: time limits that follow the connection rather
// than assuming one, a stalled probe that is abandoned after a fixed number of reads rather than
// a fixed number of seconds, and a sweep whose giving up is temporary.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import DebridService, { DebridError } from '../../../common/modules/debrid/service.js'
import RealDebrid from '../../../common/modules/debrid/realdebrid.js'
import { Availability } from '../../../common/modules/debrid/availability.js'

const HASH = 'a'.repeat(40)
const MAGNET = `magnet:?xt=urn:btih:${HASH}`

class Timed extends DebridService {
  static id = 'timed'
  static title = 'Timed'
}

test('a healthy link gets the time limits as written', () => {
  const service = new Timed('key')
  assert.equal(service.budget('ready'), Timed.timeouts.ready, 'nothing measured yet, so nothing to correct for')
  service.observeLatency(Timed.nominalLatency)
  assert.equal(service.budget('ready'), Timed.timeouts.ready)
  service.observeLatency(10)
  assert.equal(service.budget('ready'), Timed.timeouts.ready, 'a fast link is not given a shorter budget than the default')
})

test('a slow link stretches them, so a poll loop still gets its turns', () => {
  const service = new Timed('key')
  for (let request = 0; request < 20; request++) service.observeLatency(900) // three times what the defaults assume
  assert.ok(service.budget('ready') > Timed.timeouts.ready * 2, `900ms round trips must buy more than double, got ${service.budget('ready')}ms`)
})

test('but only so far, since a link that slow is not one to keep waiting on', () => {
  const service = new Timed('key')
  for (let request = 0; request < 40; request++) service.observeLatency(30_000)
  assert.ok(service.budget('ready') <= Timed.timeouts.ready * 3, 'the stretch is capped')
})

test('the estimate follows the link rather than the worst moment it ever had', () => {
  const service = new Timed('key')
  service.observeLatency(200)
  service.observeLatency(5_000) // one bad request
  const spike = service.latency
  for (let request = 0; request < 10; request++) service.observeLatency(200)
  assert.ok(service.latency < spike / 2, 'a recovered link is noticed within a few requests')
})

/** Installs a fetch mock. Routes match in order by method plus a path substring. */
function mockFetch (routes) {
  const calls = []
  globalThis.fetch = async (url, opts = {}) => {
    const method = opts.method || 'GET'
    calls.push({ url: String(url), method })
    const route = routes.find(route => (route.method || 'GET') === method && String(url).includes(route.path))
    if (!route) throw new Error(`Unexpected request: ${method} ${url}`)
    const body = typeof route.body === 'function' ? route.body() : route.body
    return { ok: true, status: 200, headers: { get: () => null }, json: async () => body }
  }
  return calls
}

// the measurement behind this: a release Real-Debrid holds reaches file selection on the first
// read or two, because it already has the metadata. One still converting after that is telling
// us it is not cached, and the old code sat through the rest of the budget finding that out —
// on a slow link that is most of the time the sweep had for the whole results list
test('a probe gives a stalled magnet a fixed number of reads, not a fixed number of seconds', async () => {
  const service = new RealDebrid('key')
  let reads = 0
  const calls = mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', body: { id: 'abc' } },
    { path: '/torrents/info/', body: () => { reads++; return { status: 'magnet_conversion', filename: '', files: [], links: [] } } },
    { path: '/torrents/delete/', method: 'DELETE', body: null }
  ])
  await assert.rejects(service.probeAvailability(HASH), DebridError, 'a stalled magnet is no answer, so the release stays re-checkable')
  assert.equal(reads, RealDebrid.probeConversionReads, 'exactly the reads it was allowed, however slow the link is')
  assert.equal(calls.filter(call => call.method === 'DELETE').length, 1, 'and the account is left as it was found')
  service.destroy()
})

test('a cached release still answers within those reads', async () => {
  const service = new RealDebrid('key')
  let reads = 0
  mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', body: { id: 'abc' } },
    {
      path: '/torrents/info/',
      body: () => (++reads === 1 ? { status: 'waiting_files_selection', files: [{ id: 1, path: '/a.mkv', bytes: 1 }], links: [] } : { status: 'downloaded', files: [], links: [] })
    },
    { path: '/torrents/selectFiles/', method: 'POST', body: null },
    { path: '/torrents/delete/', method: 'DELETE', body: null }
  ])
  assert.equal(await service.probeAvailability(HASH), Availability.CACHED)
  service.destroy()
})

// giving up on a sweep has to be temporary, otherwise a bad minute costs the whole results list
// until the user changes the sort order
test('what a sweep could not answer is still unanswered afterwards, not written off', async () => {
  class Flaky extends DebridService {
    static id = 'flaky'
    static title = 'Flaky'
    static availabilityCheck = 'probe'
    static maxProbes = 10
    broken = true
    async probeAvailability (h) {
      if (this.broken) throw new DebridError('connection reset')
      return Availability.CACHED
    }
  }
  const hashes = Array.from({ length: 10 }, (_, index) => String(index).padStart(40, '0'))
  const service = new Flaky('key')

  const first = await service.checkAvailability(hashes)
  assert.equal(first.size, 0, 'a link that answers nothing badges nothing')
  assert.equal(service.unknownHashes(hashes).length, 10, 'and every release stays askable, rather than being called uncached')

  // the retry the UI schedules, once the link is back
  service.broken = false
  const second = await service.checkAvailability(hashes)
  assert.equal(second.size, 10, 'the same list answers in full on a later attempt')
  assert.equal(service.unknownHashes(hashes).length, 0)
  service.destroy()
})

// A removal that fails is the one thing this client can leave behind on someone's account, and
// the likeliest cause is the link dropping mid-probe — which the limiter deliberately does not
// retry, since retrying while offline only delays the error. Availability checking is always on,
// so this is what keeps "leaves no trace" a guarantee rather than a hope.
test('a removal that failed is tried again before the next check adds anything', async () => {
  const service = new RealDebrid('key')
  let deletes = 0
  let offline = true
  mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', body: { id: 'abc' } },
    { path: '/torrents/info/', body: { status: 'magnet_conversion', files: [], links: [] } },
    {
      path: '/torrents/delete/',
      method: 'DELETE',
      body: () => {
        deletes++
        // the app short-circuits external requests while it considers itself offline, handing
        // back a plain object rather than a Response
        if (offline) throw new Error('offline')
        return null
      }
    }
  ])

  await assert.rejects(service.probeAvailability(HASH), DebridError)
  assert.equal(service.orphaned, 1, 'a torrent this client added and could not remove must be remembered')

  offline = false
  await service.retryCleanup()
  assert.equal(service.orphaned, 0, 'and taken off the account once the link is back')
  assert.ok(deletes > 1, 'which means it really was asked again')
  service.destroy()
})

test('a removal the service says is already gone is not retried forever', async () => {
  const service = new RealDebrid('key')
  mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', body: { id: 'abc' } },
    { path: '/torrents/info/', body: { status: 'magnet_conversion', files: [], links: [] } },
    { path: '/torrents/delete/', method: 'DELETE', status: 404, body: { error: 'unknown_ressource', error_code: 7 } }
  ])
  await assert.rejects(service.probeAvailability(HASH), DebridError)
  assert.equal(service.orphaned, 0, 'already gone is what was wanted, however it got that way')
  service.destroy()
})

test('a removal that keeps being refused is eventually written off rather than retried forever', async () => {
  const service = new RealDebrid('key')
  mockFetch([
    { path: '/torrents/addMagnet', method: 'POST', body: { id: 'abc' } },
    { path: '/torrents/info/', body: { status: 'magnet_conversion', files: [], links: [] } },
    { path: '/torrents/delete/', method: 'DELETE', status: 500, body: { error: 'server error' } }
  ])
  await assert.rejects(service.probeAvailability(HASH), DebridError)
  for (let round = 0; round < 5; round++) await service.retryCleanup()
  assert.equal(service.orphaned, 0, 'a service that will not take the removal is not worth asking forever')
  service.destroy()
})

test('request bodies carry repeated array parameters, which is how a batch check is asked', () => {
  const form = DebridService.encodeBody({ 'items[]': ['one', 'two'], other: 3 }, 'form')
  const params = new URLSearchParams(form.body)
  assert.deepEqual(params.getAll('items[]'), ['one', 'two'], 'joining them into one value is silently read as one nonsense item')
  assert.equal(params.get('other'), '3')

  const multipart = DebridService.encodeBody({ 'magnets[]': ['one', 'two'] }, 'multipart')
  assert.deepEqual(multipart.body.getAll('magnets[]'), ['one', 'two'])

  const json = DebridService.encodeBody({ ids: [1, 2] }, 'json')
  assert.deepEqual(JSON.parse(json.body), { ids: [1, 2] }, 'json keeps an array an array')
})

test('how far down a results list a service looks is its own call', () => {
  assert.equal(RealDebrid.maxAsk, RealDebrid.maxProbes, 'probing bites, so it only asks about the top of the list')
  class Cheap extends DebridService {
    static availabilityCheck = 'batch'
  }
  assert.equal(Cheap.maxAsk, Infinity, 'a real cache endpoint has no reason to stop')
  class Costly extends DebridService {
    static availabilityCheck = 'batch'
    static maxAsk = 10
  }
  assert.equal(Costly.maxAsk, 10, 'a batch that still costs the account per hash can cap itself')
})

test('unusable input never reaches the API as a made up magnet', async () => {
  const service = new RealDebrid('key')
  mockFetch([])
  await assert.rejects(service.probeAvailability('not-a-hash'), DebridError)
  assert.equal(RealDebrid.toMagnet(MAGNET), MAGNET)
  service.destroy()
})
