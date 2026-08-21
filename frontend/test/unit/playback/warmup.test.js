// The connection head start a resolved debrid stream gets. The played file's host is
// cold when the resolve answers — DNS, TCP, TLS, and the CDN's own file lookup all
// still to do — and every one of them was sequential with pressing play until this.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { warmable, warmStream, WARM_LIMIT } from '../../../common/modules/playback/warmup.js'

test('the played file is warmed, and only it by default', () => {
  const files = [
    { url: 'https://cdn.example/target.mkv' },
    { url: 'https://cdn.example/neighbor.mkv' }
  ]
  assert.deepEqual(warmable(files), ['https://cdn.example/target.mkv'])
  assert.equal(WARM_LIMIT, 1)
})

test('what is not a stream is not warmed', () => {
  const files = [
    { url: 'file:///local.mkv' },
    { url: 42 },
    {},
    null,
    { url: 'https://cdn.example/real.mkv' }
  ]
  assert.deepEqual(warmable(files, 5), ['https://cdn.example/real.mkv'])
  assert.deepEqual(warmable(undefined), [])
  assert.deepEqual(warmable([], 0), [])
})

test('duplicates are one greeting, not several', () => {
  const url = 'https://cdn.example/same.mkv'
  assert.deepEqual(warmable([{ url }, { url }], 5), [url])
})

test('warming is a HEAD in no-cors, so no body and no preflight', () => {
  const asked = []
  warmStream([{ url: 'https://cdn.example/target.mkv' }], {
    fetcher: (url, options) => { asked.push({ url, options }); return Promise.resolve() }
  })
  assert.equal(asked.length, 1)
  assert.equal(asked[0].options.method, 'HEAD')
  assert.equal(asked[0].options.mode, 'no-cors')
})

test('a host that refuses costs nothing', async () => {
  const warmed = warmStream([{ url: 'https://cdn.example/target.mkv' }], {
    fetcher: () => Promise.reject(new Error('405'))
  })
  assert.deepEqual(warmed, ['https://cdn.example/target.mkv'])
  await new Promise(resolve => setTimeout(resolve)) // the rejection must land handled
})

test('a fetcher that throws synchronously costs nothing either', () => {
  assert.doesNotThrow(() => warmStream([{ url: 'https://cdn.example/a.mkv' }], {
    fetcher: () => { throw new Error('no network stack') }
  }))
})

test('no fetch on this platform means no warm-up, quietly', () => {
  // null, not undefined: undefined would summon the default, which is the real fetch
  assert.deepEqual(warmStream([{ url: 'https://cdn.example/a.mkv' }], { fetcher: null }), [])
})
