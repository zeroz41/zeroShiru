// The blob store that pins shown art in renderer memory. The invariants that matter:
// bytes are bounded, eviction revokes, a fetch that fails degrades to the URL itself
// (pinning is an upgrade, never a gate), and two askers cost one request.
import { test, beforeEach } from 'bun:test'
import assert from 'node:assert/strict'
import { pin, heldNow, isHeld, heldStats, releaseAll, IMAGE_STORE_BYTE_LIMIT } from '@/modules/lib/image-store.js'

let served
let revoked
let objects
const fetcherFor = bytes => async url => ({ ok: true, blob: async () => ({ size: bytes, url }) })
const failing = async () => ({ ok: false })
const seams = () => ({
  createObjectURL: blob => { const object = `blob:${objects++}`; served.set(object, blob); return object },
  revokeObjectURL: object => revoked.push(object)
})

beforeEach(() => {
  served = new Map()
  revoked = []
  objects = 0
  releaseAll(() => {})
})

test('pinned bytes come back as an object URL, and asking again is free', async () => {
  const options = { fetcher: fetcherFor(1000), ...seams() }
  const first = await pin('shiru-media://localhost/a.jpg', options)
  assert.match(first, /^blob:/)
  assert.equal(isHeld('shiru-media://localhost/a.jpg'), true)
  let fetches = 0
  const counting = { fetcher: async () => { fetches++ }, ...seams() }
  assert.equal(await pin('shiru-media://localhost/a.jpg', counting), first)
  assert.equal(fetches, 0, 'held bytes cost no request')
})

test('a failed fetch answers with the url itself and pins nothing', async () => {
  const options = { fetcher: failing, ...seams() }
  assert.equal(await pin('https://cdn/dead.jpg', options), 'https://cdn/dead.jpg')
  assert.equal(isHeld('https://cdn/dead.jpg'), false)
  assert.equal(await pin('data:image/gif;base64,x', seams()), 'data:image/gif;base64,x', 'data URIs are already memory')
})

test('the byte budget is a budget: the least recently touched art is let go, revoked', async () => {
  const big = Math.floor(IMAGE_STORE_BYTE_LIMIT / 3) + 1
  const options = { fetcher: fetcherFor(big), ...seams() }
  const first = await pin('https://cdn/one.jpg', options)
  await pin('https://cdn/two.jpg', options)
  // touching one keeps it fresh; adding a third must evict two, not one
  heldNow('https://cdn/one.jpg')
  await pin('https://cdn/three.jpg', options)
  assert.equal(isHeld('https://cdn/one.jpg'), true, 'recently shown art survives')
  assert.equal(isHeld('https://cdn/two.jpg'), false)
  assert.equal(isHeld('https://cdn/three.jpg'), true)
  assert.ok(revoked.length >= 1, 'evicted object URLs are revoked, not leaked')
  assert.ok(!revoked.includes(first), 'the surviving object URL is untouched')
  assert.ok(heldStats().bytes <= IMAGE_STORE_BYTE_LIMIT)
})

test('two askers for the same url share one fetch', async () => {
  let fetches = 0
  const slow = { fetcher: async () => { fetches++; await new Promise(resolve => setTimeout(resolve, 10)); return { ok: true, blob: async () => ({ size: 10 }) } }, ...seams() }
  const [a, b] = await Promise.all([pin('https://cdn/same.jpg', slow), pin('https://cdn/same.jpg', slow)])
  assert.equal(a, b)
  assert.equal(fetches, 1)
})
