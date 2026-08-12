// The base class is the contract every debrid service inherits. These tests pin
// the behavior an implementer gets for free, so adding a service stays a matter of
// writing three methods in one file.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import DebridService, { DebridError, DebridNotImplementedError } from '../../../common/modules/debrid/service.js'
import { debridServices } from '../../../common/modules/debrid/services.js'
import RealDebrid from '../../../common/modules/debrid/realdebrid.js'

// read off the registry rather than listed here, so a service added to the app is covered by
// every contract test below without anyone remembering to add it
const IMPLEMENTED = Object.values(debridServices)

/** What a new service looks like on the day someone starts writing it. */
class Template extends DebridService {
  static id = 'template'
  static title = 'Template'
}

/** Captures the request a service would send, without any network. */
function capture (service) {
  const sent = []
  globalThis.fetch = async (url, options) => {
    sent.push({ url, options })
    return { ok: true, status: 200, headers: { get: () => null }, json: async () => ({ type: 'premium', username: 'tester' }) }
  }
  return sent
}

test('an unimplemented service reports itself by name instead of failing obscurely', async () => {
  const service = new Template('key')
  for (const method of ['validate', 'listAvailability', 'resolve', 'fetchListing']) {
    await assert.rejects(service[method]('magnet:?xt=urn:btih:' + 'a'.repeat(40)), error => {
      assert.ok(error instanceof DebridNotImplementedError, `Template.${method} must throw DebridNotImplementedError`)
      assert.ok(error instanceof DebridError, 'templates must still throw a DebridError so callers handle them uniformly')
      assert.match(error.message, /Template/, 'the message must name the service')
      assert.doesNotMatch(error.message, /undefined/)
      return true
    })
  }
  service.destroy()
})

test('a service declares an identity and stays out of the settings menu until finished', () => {
  assert.equal(Template.available, false, 'a half written service must stay hidden')
  for (const Service of IMPLEMENTED) {
    assert.equal(Service.available, true, `${Service.title} is implemented and must be selectable`)
    assert.ok(Service.id && Service.title, `${Service.title} must declare id and title`)
    assert.ok(Service.prototype instanceof DebridService, `${Service.title} must inherit the shared behavior`)
    assert.ok(['batch', 'probe', 'none'].includes(Service.availabilityCheck), `${Service.title} must declare how it can be asked about a release`)
  }
  assert.equal(new Set(IMPLEMENTED.map(Service => Service.id)).size, IMPLEMENTED.length, 'ids key the settings menu and the stored keys, so they must be unique')
})

// every service ends up in one Map keyed by lowercase info hash, which is what lets the app
// hold one badge store and one memory whichever service is configured
test('an implemented service answers about releases in the shared vocabulary', async () => {
  for (const Service of IMPLEMENTED) {
    const service = new Service('key')
    assert.equal(typeof service.checkAvailability, 'function')
    assert.equal(typeof service.listAvailability, 'function')
    assert.equal(Service.availabilityCheck === 'batch' ? typeof service.checkAvailabilityBatch : typeof service.probeAvailability, 'function')
    service.destroy()
  }
})

test('bearer services send the key as an Authorization header', async () => {
  const service = new RealDebrid('secret-key')
  const sent = capture(service)
  await service.validate()
  assert.equal(sent.length, 1)
  assert.equal(sent[0].options.headers.Authorization, 'Bearer secret-key')
  assert.ok(!sent[0].url.includes('secret-key'), 'a bearer key must never leak into the URL')
  service.destroy()
})

test('query authenticated services carry the key as a parameter instead', async () => {
  class QueryService extends DebridService {
    static id = 'query'
    static title = 'Query Service'
    static auth = 'query'
    async validate () { return this.request('https://example.test/user?extra=1') }
  }
  const service = new QueryService('secret-key')
  const sent = capture(service)
  await service.validate()
  const url = new URL(sent[0].url)
  assert.equal(url.searchParams.get('apikey'), 'secret-key')
  assert.equal(url.searchParams.get('extra'), '1', 'existing query parameters must survive')
  assert.equal(sent[0].options.headers.Authorization, undefined, 'query services must not also send a header')
  service.destroy()
})

test('the authentication parameter name is overridable per service', () => {
  class TokenService extends DebridService {
    static auth = 'query'
    static authParam = 'token'
  }
  const { url } = new TokenService('abc').authorize('https://example.test/user')
  assert.equal(new URL(url).searchParams.get('token'), 'abc')
})

test('timeouts and file caps are inherited and overridable', () => {
  assert.ok(DebridService.timeouts.request > 0 && DebridService.timeouts.poll > 0)
  for (const key of ['request', 'select', 'ready', 'poll']) {
    assert.ok(Number.isFinite(RealDebrid.timeouts[key]), `RealDebrid must inherit a numeric ${key} timeout`)
  }
  assert.ok(RealDebrid.maxFiles > 1, 'season packs need a sane default file cap')

  class ImpatientService extends DebridService {
    static timeouts = { ...DebridService.timeouts, ready: 1 }
  }
  assert.equal(ImpatientService.timeouts.ready, 1)
  assert.equal(ImpatientService.timeouts.request, DebridService.timeouts.request, 'unset timeouts still come from the base')
})

test('magnet parsing is inherited, so no service reimplements it', () => {
  const HASH = 'a1b2c3d4e5'.repeat(4)
  for (const Service of [DebridService, Template, ...IMPLEMENTED]) {
    assert.equal(Service.parseHash(`magnet:?xt=urn:btih:${HASH}&dn=Show`), HASH)
    assert.equal(Service.parseHash(HASH.toUpperCase()), HASH, 'hashes normalize to lowercase')
    assert.equal(Service.toMagnet(HASH), `magnet:?xt=urn:btih:${HASH}`)
  }
  // an existing magnet is handed back untouched, trackers and all
  const magnet = `magnet:?xt=urn:btih:${HASH}&tr=http%3A%2F%2Ftracker`
  assert.equal(DebridService.toMagnet(magnet), magnet)
})

test('unusable sources yield no hash rather than a malformed magnet', () => {
  for (const bad of ['', 'a'.repeat(39), 'a'.repeat(41), 'zzzz', 'https://nyaa.si/download/1.torrent', null, undefined, 12345, {}, new Uint8Array([1, 2])]) {
    assert.equal(DebridService.parseHash(bad), '', `${String(bad).slice(0, 20)} must not parse`)
    assert.equal(DebridService.toMagnet(bad), '', `${String(bad).slice(0, 20)} must not become a magnet`)
  }
})

// APIs disagree about request bodies, and one service can disagree with itself between
// endpoints, so the encoding is a knob rather than a fork in each implementation
test('request bodies are encoded the way the endpoint asks for', () => {
  const form = DebridService.encodeBody({ magnet: 'magnet:?xt=1', seed: 3 }, 'form')
  assert.equal(form.headers['Content-Type'], 'application/x-www-form-urlencoded')
  assert.equal(new URLSearchParams(form.body).get('magnet'), 'magnet:?xt=1')

  const json = DebridService.encodeBody({ torrent_id: 7, operation: 'delete' }, 'json')
  assert.equal(json.headers['Content-Type'], 'application/json')
  assert.deepEqual(JSON.parse(json.body), { torrent_id: 7, operation: 'delete' })

  const multipart = DebridService.encodeBody({ magnet: 'magnet:?xt=1' }, 'multipart')
  assert.ok(multipart.body instanceof FormData)
  assert.equal(multipart.body.get('magnet'), 'magnet:?xt=1')
  assert.equal(multipart.headers['Content-Type'], undefined, 'fetch must set the boundary itself')
})

test('one endpoint can authenticate differently from the rest of a service', () => {
  const service = new RealDebrid('secret-key') // a bearer service by default
  assert.equal(service.authorize('https://example.test/a').headers.Authorization, 'Bearer secret-key')
  const odd = service.authorize('https://example.test/dl?file=1', { auth: 'query', authParam: 'token' })
  assert.equal(new URL(odd.url).searchParams.get('token'), 'secret-key')
  assert.equal(new URL(odd.url).searchParams.get('file'), '1', 'existing parameters must survive')
  assert.equal(odd.headers.Authorization, undefined)
  service.destroy()
})

test('a service instance reads its own static configuration', () => {
  const service = new RealDebrid('key')
  assert.equal(service.config.id, 'realdebrid')
  assert.equal(service.config.title, 'Real-Debrid')
  service.destroy()
})
