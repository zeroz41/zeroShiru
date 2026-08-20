// How an extension's requests get made. Written for a gap the Tauri port opened: Electron ran
// with web security off, so extensions could read any response; a real webview enforces CORS,
// and most of the sites a content source scrapes send no CORS headers. nyaa.si is the plain
// example — the request goes out, the answer is withheld, and the extension reports the source
// as unreachable. Where the host can make the request natively there is no such rule, so it
// does; where it cannot, nothing changes.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { headersOf, normalizeMethod, requestVia } from '../../../common/modules/extensions/transport.js'

const hostAnswer = (over = {}) => ({
  url: 'https://nyaa.si/?q=x',
  status: 200,
  ok: true,
  headers: { 'Content-Type': 'application/xml', 'X-Rate-Limit': '30' },
  body: '<rss></rss>',
  binary: false,
  ...over
})

test('a host that can make the request makes it, and fetch is never asked', async () => {
  let fetched = false
  const asked = []
  const response = await requestVia('https://nyaa.si/?q=x', {}, {
    hostRequest: async (request) => { asked.push(request); return hostAnswer() },
    fetch: async () => { fetched = true }
  })
  assert.equal(fetched, false, 'the webview would only have been refused the answer')
  assert.equal(asked[0].url, 'https://nyaa.si/?q=x')
  assert.equal(await response.text(), '<rss></rss>')
  assert.equal(response.ok, true)
  assert.equal(response.status, 200)
})

test('a host without a native client keeps using fetch', async () => {
  // a TV bootstrap, or a browser: works exactly as well as CORS allows, which is the status quo
  let asked = null
  const response = await requestVia('https://torrentio.strem.fun/manifest.json', { method: 'POST' }, {
    fetch: async (url, options) => { asked = { url, options }; return { ok: true, status: 200 } }
  })
  assert.equal(asked.url, 'https://torrentio.strem.fun/manifest.json')
  assert.equal(asked.options.method, 'POST')
  assert.equal(response.status, 200)
})

test('what comes back is shaped like a Response either way', async () => {
  const response = await requestVia('https://nyaa.si/?q=x', {}, { hostRequest: async () => hostAnswer(), fetch: async () => {} })
  assert.equal(response.headers.get('content-type'), 'application/xml', 'header lookup is case-insensitive')
  assert.equal(response.headers.get('Content-Type'), 'application/xml')
  assert.equal(response.headers.get('nope'), null)
  assert.equal(response.headers.has('x-rate-limit'), true)
  assert.deepEqual(await response.json().catch(() => 'not json'), 'not json')
  assert.ok((await response.arrayBuffer()).byteLength > 0)
})

test('a json body parses the way a source expects', async () => {
  const response = await requestVia('https://feed.animetosho.org/json', {}, {
    hostRequest: async () => hostAnswer({ body: '[{"title":"Frieren"}]' }),
    fetch: async () => {}
  })
  assert.deepEqual(await response.json(), [{ title: 'Frieren' }])
})

test('a redirect is visible, and where it landed is what the response reports', async () => {
  const response = await requestVia('https://nyaa.si/x', {}, {
    hostRequest: async () => hostAnswer({ url: 'https://nyaa.si/final' }),
    fetch: async () => {}
  })
  assert.equal(response.url, 'https://nyaa.si/final')
  assert.equal(response.redirected, true)
})

test('the local network is refused before the host is even asked', async () => {
  let asked = false
  await assert.rejects(
    () => requestVia('http://192.168.1.1/admin', {}, {
      hostRequest: async () => { asked = true; return hostAnswer() },
      fetch: async () => {},
      blocked: (url) => url.includes('192.168')
    }),
    /private or local network/)
  assert.equal(asked, false, 'a native client would have reached it')
})

test('a redirect into the local network is refused after the fact', async () => {
  await assert.rejects(
    () => requestVia('https://example.com/x', {}, {
      hostRequest: async () => hostAnswer({ url: 'http://127.0.0.1:9000/' }),
      fetch: async () => {},
      blocked: (url) => url.includes('127.0.0.1')
    }),
    /redirected to a private or local/)
})

test('only methods a source has business using are passed on', () => {
  assert.equal(normalizeMethod(undefined), 'GET')
  assert.equal(normalizeMethod('post'), 'POST')
  assert.equal(normalizeMethod('HEAD'), 'HEAD')
  assert.equal(normalizeMethod('TRACE'), 'GET', 'anything else reads as a mistake')
  assert.equal(normalizeMethod({}), 'GET')
})

test('headers survive whichever shape they were given in', () => {
  assert.deepEqual(headersOf({ Accept: 'application/json' }), { Accept: 'application/json' })
  assert.deepEqual(headersOf([['Accept', 'text/html']]), { Accept: 'text/html' })
  const headerLike = { forEach: (fn) => fn('bar', 'x-foo') }
  assert.deepEqual(headersOf(headerLike), { 'x-foo': 'bar' }, 'a Headers object')
  assert.deepEqual(headersOf(undefined), {})
})
