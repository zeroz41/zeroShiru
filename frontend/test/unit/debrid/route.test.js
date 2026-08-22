// Exhaustive tests for the playback routing policy. Two invariants matter most:
// 1. With no debrid service selected, EVERY input routes to the torrent client
//    exactly like stock Shiru (original torrent behavior untouched).
// 2. In debrid only mode, NO input ever routes to the torrent client.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { routeDebrid, listResult, debridKey, createListResults } from '../../../common/modules/debrid/route.js'
import { Availability } from '../../../common/modules/debrid/availability.js'

const HASH = 'a'.repeat(40)
const MAGNET = `magnet:?xt=urn:btih:${HASH}&dn=Test&tr=http://tracker`
const TORRENT_URL = 'https://nyaa.si/download/1234567.torrent'
const TORRENT_BYTES = new Uint8Array([1, 2, 3])

// every input shape playback can receive: [label, torrentID, hash]
const INPUTS = [
  ['magnet link', MAGNET, HASH],
  ['magnet link without separate hash', MAGNET, undefined],
  ['bare info hash', HASH, HASH],
  ['uppercase info hash', HASH.toUpperCase(), undefined],
  ['.torrent URL with hash (nyaa)', TORRENT_URL, HASH],
  ['.torrent URL without hash', TORRENT_URL, undefined],
  ['.torrent file bytes (clipboard)', TORRENT_BYTES, undefined],
  ['null id with hash', null, HASH],
  ['null id without hash', null, undefined]
]

const ready = { serviceSelected: true, serviceReady: true, offline: false }

test('no service selected: every input routes to the torrent client, both modes', () => {
  for (const [label, torrentID, hash] of INPUTS) {
    for (const mode of ['prefer', 'only']) {
      const route = routeDebrid({ torrentID, hash, serviceSelected: false, serviceReady: false, offline: false, mode })
      assert.deepEqual(route, { action: 'torrent', only: false }, `${label} in ${mode} mode must be untouched stock behavior`)
    }
  }
})

test('debrid only mode never routes to the torrent client, whatever the input or state', () => {
  const states = [
    { ...ready }, // healthy
    { serviceSelected: true, serviceReady: false, offline: false }, // missing key
    { serviceSelected: true, serviceReady: true, offline: true } // offline
  ]
  for (const state of states) {
    for (const [label, torrentID, hash] of INPUTS) {
      const route = routeDebrid({ torrentID, hash, ...state, mode: 'only' })
      assert.notEqual(route.action, 'torrent', `${label} with ${JSON.stringify(state)} must never start a torrent in debrid only mode`)
    }
  }
})

test('resolvable sources resolve through debrid when healthy', () => {
  for (const mode of ['prefer', 'only']) {
    assert.deepEqual(routeDebrid({ torrentID: MAGNET, hash: HASH, ...ready, mode }), { action: 'resolve', id: MAGNET, only: mode === 'only' })
    assert.deepEqual(routeDebrid({ torrentID: HASH, ...ready, mode }), { action: 'resolve', id: HASH, only: mode === 'only' })
    assert.deepEqual(routeDebrid({ torrentID: HASH.toUpperCase(), ...ready, mode }), { action: 'resolve', id: HASH.toUpperCase(), only: mode === 'only' })
  }
})

test('.torrent links resolve through the info hash (nyaa regression)', () => {
  assert.deepEqual(routeDebrid({ torrentID: TORRENT_URL, hash: HASH, ...ready, mode: 'only' }), { action: 'resolve', id: HASH, only: true })
  assert.deepEqual(routeDebrid({ torrentID: TORRENT_BYTES, hash: HASH, ...ready, mode: 'prefer' }), { action: 'resolve', id: HASH, only: false })
})

test('unresolvable sources: prefer falls back, only blocks with a clear reason', () => {
  for (const [label, torrentID, hash] of [['.torrent URL without hash', TORRENT_URL, undefined], ['.torrent file bytes (clipboard)', TORRENT_BYTES, undefined], ['null id without hash', null, undefined]]) {
    assert.deepEqual(routeDebrid({ torrentID, hash, ...ready, mode: 'prefer' }), { action: 'torrent', only: false }, label)
    assert.deepEqual(routeDebrid({ torrentID, hash, ...ready, mode: 'only' }), { action: 'block', reason: 'source', only: true }, label)
  }
})

test('missing key: prefer falls back, only blocks', () => {
  const state = { serviceSelected: true, serviceReady: false, offline: false }
  assert.deepEqual(routeDebrid({ torrentID: MAGNET, hash: HASH, ...state, mode: 'prefer' }), { action: 'torrent', only: false })
  assert.deepEqual(routeDebrid({ torrentID: MAGNET, hash: HASH, ...state, mode: 'only' }), { action: 'block', reason: 'key', only: true })
})

test('offline: prefer falls back, only blocks', () => {
  const state = { serviceSelected: true, serviceReady: true, offline: true }
  assert.deepEqual(routeDebrid({ torrentID: MAGNET, hash: HASH, ...state, mode: 'prefer' }), { action: 'torrent', only: false })
  assert.deepEqual(routeDebrid({ torrentID: MAGNET, hash: HASH, ...state, mode: 'only' }), { action: 'block', reason: 'offline', only: true })
})

test('malformed ids are never treated as resolvable', () => {
  for (const bad of ['magnet:?xt=urn:btih:tooshort', 'a'.repeat(39), 'a'.repeat(41), 'ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ', 12345, {}, '']) {
    const route = routeDebrid({ torrentID: bad, hash: bad, ...ready, mode: 'only' })
    assert.deepEqual(route, { action: 'block', reason: 'source', only: true }, `${String(bad).slice(0, 20)} must not resolve`)
  }
})

// The results list has the same "debrid off changes nothing" invariant as routing:
// with nothing known and the filters off, listResult must reproduce upstream's rule
// (seeded, or served by a managed source) for every result shape.
test('with debrid off the listing rule is exactly upstream behavior', () => {
  const shapes = [
    { label: 'seeded', result: { seeders: 5 }, upstream: true },
    { label: 'unseeded', result: { seeders: 0 }, upstream: false },
    { label: 'seeders missing', result: {}, upstream: false },
    { label: 'seeders undefined', result: { seeders: undefined }, upstream: false },
    { label: 'managed source, unseeded', result: { seeders: 0, source: { managed: true } }, upstream: true },
    { label: 'unmanaged source, unseeded', result: { seeders: 0, source: { managed: false } }, upstream: false },
    { label: 'seeded and managed', result: { seeders: 9, source: { managed: true } }, upstream: true }
  ]
  for (const { label, result, upstream } of shapes) {
    // cached is false and cachedOnly is undefined/false whenever no service is configured
    for (const state of [Availability.UNKNOWN, undefined]) {
      assert.equal(listResult(result, state, {}), upstream, label)
      assert.equal(listResult(result, state), upstream, `${label} (no filters passed at all)`)
    }
  }
})

test('a cached release lists even with no seeders, and the filter hides everything else', () => {
  const unseeded = { seeders: 0 }
  const seeded = { seeders: 20 }
  // debrid on, filter off: cached widens the list, it never narrows it
  assert.equal(listResult(unseeded, Availability.CACHED, {}), true, 'cached but unseeded still streams')
  assert.equal(listResult(seeded, Availability.UNKNOWN, {}), true, 'unchecked but seeded still plays as a torrent')
  // filter on: only a confirmed cached release counts
  assert.equal(listResult(seeded, Availability.UNKNOWN, { cachedOnly: true }), false, 'seeded but unchecked is hidden')
  assert.equal(listResult(unseeded, Availability.CACHED, { cachedOnly: true }), true, 'cached is listed')
  assert.equal(listResult({ seeders: 0, source: { managed: true } }, Availability.AVAILABLE, { cachedOnly: true }), false, 'not even a managed source bypasses the filter')
})

// 'available' means the service could fetch it from the swarm, which needs the same peers a
// torrent would. Treating it like 'cached' would list dead releases as if they streamed.
test('an available release is not treated as cached', () => {
  assert.equal(listResult({ seeders: 0 }, Availability.AVAILABLE, {}), false, 'the service still needs peers to fetch it')
  assert.equal(listResult({ seeders: 20 }, Availability.AVAILABLE, {}), true, 'seeders alone still list it, as upstream')
  assert.equal(listResult({ seeders: 20 }, Availability.AVAILABLE, { cachedOnly: true }), false, 'the cached filter means cached')
})

// in debrid only mode there is no torrent client to fall back on, so a release the service has
// said it cannot serve can never play, and belongs with the hidden results
test('debrid only mode hides what the service cannot serve', () => {
  const seeded = { seeders: 20 }
  assert.equal(listResult(seeded, Availability.UNAVAILABLE, { only: true }), false, 'unplayable in only mode')
  assert.equal(listResult(seeded, Availability.UNAVAILABLE, {}), true, 'but it still plays as a torrent in debrid first')
  assert.equal(listResult(seeded, Availability.UNKNOWN, { only: true }), true, 'unchecked releases still list, they may well stream')
  assert.equal(listResult(seeded, Availability.CACHED, { only: true }), true)
})

// --- per service API keys ---
// Each service stores its own key, so a user with two accounts can switch between them in
// settings without retyping, and a key can never be sent to the service it does not belong to.
// The settings tab and the playback module both read through this, so they cannot disagree.

const KEYS = { debridService: 'realdebrid', debridApiKeys: { realdebrid: 'rd-key', torbox: 'tb-key' } }

test('each service gets its own key, and switching selects the other one', () => {
  assert.equal(debridKey(KEYS), 'rd-key', 'the selected service by default')
  assert.equal(debridKey({ ...KEYS, debridService: 'torbox' }), 'tb-key', 'switching swaps the key rather than losing it')
  assert.equal(debridKey(KEYS, 'torbox'), 'tb-key', 'and any service can be asked about by name')
})

test('a service with no key yet reads as empty, not as another service\'s key', () => {
  assert.equal(debridKey({ ...KEYS, debridService: 'alldebrid' }), '', 'never fall back to whatever key happens to exist')
  assert.equal(debridKey({ debridService: 'realdebrid', debridApiKeys: {} }), '')
  assert.equal(debridKey({ debridService: 'none', debridApiKeys: { none: 'nonsense' } }), 'nonsense', 'no special casing, the caller checks the service')
})

test('missing or half built settings never throw and never invent a key', () => {
  for (const settings of [undefined, null, {}, { debridService: 'realdebrid' }, { debridApiKeys: { realdebrid: 'rd' } }]) {
    assert.equal(debridKey(settings), '', `${JSON.stringify(settings)} must read as no key`)
  }
  assert.equal(debridKey({ debridApiKeys: { realdebrid: 'rd' } }, 'realdebrid'), 'rd', 'unless the service is named explicitly')
})

// --- splitting the results list without churning identities ---
// The contract the modal leans on: answers that only move the counts hand back the same
// arrays (so the expensive best-release pick is not redone per answer), while `cachedKey`
// changes exactly when which listed releases are cached changes — the one signal that must
// escape the identity freeze, because autoplay picking an uncached release while answers
// were still arriving was choosing a guaranteed resolve failure over a stream.

const HASH_A = 'a'.repeat(40)
const HASH_B = 'b'.repeat(40)
const seededResult = hash => ({ hash, seeders: 12 })

test('count-only answers keep the array identities but move the cached key', () => {
  const listResults = createListResults()
  const sorted = [seededResult(HASH_A), seededResult(HASH_B)]
  const first = listResults(sorted, new Map())
  assert.equal(first.cachedKey, '')
  const second = listResults(sorted, new Map([[HASH_B, Availability.CACHED]]))
  assert.equal(second.results, first.results, 'a seeded release was listed either way, so the pick input is unchanged')
  assert.equal(second.cachedKey, HASH_B, 'but which releases are cached is a new question for the pick')
  assert.equal(second.counts[Availability.CACHED], 1)
})

test('an answer that changes membership hands back new arrays', () => {
  const listResults = createListResults()
  const seedless = { hash: HASH_A, seeders: 0 }
  const sorted = [seedless, seededResult(HASH_B)]
  const before = listResults(sorted, new Map())
  assert.deepEqual(before.results.map(result => result.hash), [HASH_B], 'a seedless release starts hidden')
  const after = listResults(sorted, new Map([[HASH_A, Availability.CACHED]]))
  assert.notEqual(after.results, before.results)
  assert.deepEqual(after.results.map(result => result.hash), [HASH_A, HASH_B], 'cached streams without seeders, so it surfaces')
  assert.equal(after.cachedKey, HASH_A)
})
