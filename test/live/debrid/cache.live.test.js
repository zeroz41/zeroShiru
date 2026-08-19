// Live tests for the Cached badge and the playback fallback behind it.
//
// Real-Debrid has no cache endpoint any more (`/torrents/instantAvailability` answers
// 403 disabled_endpoint), so badges come from two places: the account's own torrent list,
// which is free, and probing the top of the results list, which is not. These tests check
// both against the real API, plus that a resolve which cannot stream says so quickly.
//
// The invariant that matters most: probing must leave the account exactly as it found it.
//
//   REAL_DEBRID_API_KEY=<key> npm run test:live
import { test, beforeAll, afterAll } from 'bun:test'
import assert from 'node:assert/strict'
import RealDebrid from '../../../common/modules/debrid/realdebrid.js'
import { DebridUnstreamableError } from '../../../common/modules/debrid/service.js'
import { Availability } from '../../../common/modules/debrid/availability.js'

const KEY = process.env.REAL_DEBRID_API_KEY
const skip = KEY ? false : 'REAL_DEBRID_API_KEY not set'
const API = 'https://api.real-debrid.com/rest/1.0'

// a syntactically valid hash no tracker will know, so the service cannot hold it
const BOGUS = '0'.repeat(39) + '1'
const service = KEY ? new RealDebrid(KEY) : null

// bookkeeping talks to the API directly rather than through the client under test, so the
// ground truth stays readable after the client has been torn down. Retried because this list
// is a big response and a flaky link dropping it would fail the run for no real reason.
async function accountTorrents (attempts = 3) {
  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(`${API}/torrents?limit=1000`, { headers: { Authorization: `Bearer ${KEY}` } })
      const torrents = (await res.json()) || []
      return new Map(torrents.map(torrent => [torrent.id, torrent.hash.toLowerCase()]))
    } catch (error) {
      if (attempt >= attempts) throw error
      await new Promise(resolve => setTimeout(resolve, 2_000 * attempt))
    }
  }
}

let before_ = null
let badged = []
// hashes this file probed, so cleanup can tell our torrents from everyone else's
const probed = new Set()

beforeAll(async () => {
  if (!service) return
  before_ = await accountTorrents()
  badged = [...await service.listAvailability()].filter(([, state]) => state === Availability.CACHED).map(([hash]) => hash)
})

afterAll(async () => {
  if (!service) return
  service.destroy()
  await new Promise(resolve => setTimeout(resolve, 2_000))
  const after_ = await accountTorrents()
  // only judge the hashes this file touched, other live test files add torrents of their own
  const ours = ([, hash]) => hash === BOGUS || probed.has(hash)
  const added = [...after_].filter(entry => !before_.has(entry[0])).filter(ours).map(([id]) => id)
  const removed = [...before_].filter(entry => !after_.has(entry[0])).map(([id]) => id)
  for (const id of added) await fetch(`${API}/torrents/delete/${id}`, { method: 'DELETE', headers: { Authorization: `Bearer ${KEY}` } }).catch(() => {})
  assert.deepEqual(removed, [], 'nothing here may delete a torrent the user already had')
  assert.deepEqual(added, [], 'a failed resolve must not leave its torrent behind')
})

test('the badge source covers the whole account, not just the first page', { skip, timeout: 120_000 }, async t => {
  const total = before_.size
  console.log(`  account holds ${total} torrents, ${badged.length} of them badgeable`)
  if (total <= 100) return t.skip(`account only holds ${total} torrents, too few to prove paging`)
  const finished = [...before_.values()].length
  assert.ok(badged.length > 100, 'more than one default page has to come back, or most badges are silently missing')
  assert.ok(badged.length <= finished, 'cannot badge more than the account holds')
})

test('badged hashes are lowercase and well formed, so they match search results', { skip, timeout: 120_000 }, async t => {
  if (!badged.length) return t.skip('account has no finished torrents')
  for (const hash of badged) assert.match(hash, /^[a-f\d]{40}$/, `badge hashes must be comparable to result hashes: ${hash}`)
})

test('a badged release really does resolve to playable HTTPS links', { skip, timeout: 300_000 }, async t => {
  if (!badged.length) return t.skip('account has no finished torrents')
  // the badge promises instant playback, so the first badged release must make good on it
  const resolved = await service.resolve(badged[0], { fileFilter: () => true })
  console.log(`  ${badged[0]} -> ${resolved.files.length} files (${resolved.name})`)
  assert.ok(resolved.files.length > 0, 'a badged release must yield at least one file')
  for (const file of resolved.files) assert.match(file.url, /^https:\/\//, 'every stream link must be HTTPS')
})

test('an unheld release fails fast as not cached, so playback can fall back', { skip, timeout: 180_000 }, async () => {
  const started = Date.now()
  await assert.rejects(() => service.resolve(BOGUS, { fileFilter: () => true }), DebridUnstreamableError)
  const seconds = (Date.now() - started) / 1000
  console.log(`  bogus hash rejected in ${seconds.toFixed(1)}s`)
  // Debrid First falls back to the torrent client on this error, so it is on the play path
  assert.ok(seconds < 60, 'the fallback must not leave the user staring at a stalled player')
})

test('probing confirms a release the account holds, and cleans up after itself', { skip, timeout: 300_000 }, async t => {
  if (!badged.length) return t.skip('account has no finished torrents')
  const target = badged[0]
  probed.add(target)
  service.availabilityState.delete(target) // ask the API rather than replaying a remembered answer
  const started = Date.now()
  const state = await service.probeAvailability(target)
  console.log(`  probed ${target} -> ${state} in ${((Date.now() - started) / 1000).toFixed(1)}s`)
  // the invariant behind the badge: a torrent the account has finished can never probe as a miss
  assert.equal(state, Availability.CACHED, 'a release the account holds must confirm as cached')
})

test('a full sweep confirms the top of a results list without exceeding its cap', { skip, timeout: 900_000 }, async t => {
  if (badged.length < 3) return t.skip('account has too few finished torrents to sweep')
  // a realistic results list: a few releases the account holds, mixed with ones it does not
  const candidates = [...badged.slice(0, 3), BOGUS, '0'.repeat(38) + '22']
  for (const hash of candidates) { probed.add(hash); service.availabilityState.delete(hash) }

  let adds = 0
  let peak = 0
  let inFlight = 0
  const realRequest = service.request
  service.request = async (url, opts) => {
    const isAdd = String(url).includes('/addMagnet')
    if (isAdd) { adds++; peak = Math.max(peak, ++inFlight) }
    try {
      return await realRequest(url, opts)
    } finally {
      if (isAdd) inFlight--
    }
  }
  const started = Date.now()
  const answers = await service.checkAvailability(candidates)
  service.request = realRequest
  const cachedCount = [...answers.values()].filter(state => state === Availability.CACHED).length
  console.log(`  ${answers.size}/${candidates.length} answered (${cachedCount} cached) in ${((Date.now() - started) / 1000).toFixed(0)}s, ${adds} adds, peak concurrent: ${peak}`)

  // the regression guard: a few probes overlap, which is what makes a results list answer in a
  // reasonable time on a slow link, but the fan out stays bounded — Real-Debrid rate limits
  // adding far harder than reading, and every probe in flight owns a torrent on the account
  assert.ok(peak <= service.config.maxProbeConcurrency, `probes must stay within the fan out cap, peaked at ${peak}`)
  assert.ok(adds <= service.config.maxProbes, 'a sweep must never exceed its probe cap')
  for (const hash of badged.slice(0, 3)) {
    assert.ok(!answers.has(hash) || answers.get(hash) === Availability.CACHED, 'a release the account holds may go unanswered, but never come back a miss')
  }
  // a hash no tracker knows must be answered honestly rather than badged
  assert.ok(!answers.has(BOGUS) || answers.get(BOGUS) !== Availability.CACHED, 'an unheld release must never come back cached')
})

// The account listing is the single most expensive read Real-Debrid does — measured at 4.6s for
// 312 torrents — and it used to happen twice: once for badges, once inside every resolve looking
// for a torrent already on the account. This is the test that it now happens once.
test('browsing and then playing reads the account listing once, not twice', { skip, timeout: 180_000 }, async () => {
  service.forgetListing()
  const listings = []
  const realRequest = service.request
  service.request = async (url, opts) => {
    if (String(url).includes('/torrents?')) listings.push(String(url))
    return realRequest(url, opts)
  }
  const started = Date.now()
  await service.listAvailability() // opening the results modal
  const cost = Date.now() - started
  await service.listing() // the resolve looking for an existing torrent
  await service.listing()
  service.request = realRequest
  console.log(`  listing read in ${(cost / 1000).toFixed(1)}s, reused by the play path at no cost`)
  assert.equal(listings.length, 1, 'the play path must not pay for a second full listing')
})

test('refreshing badges is read-only and costs one request', { skip, timeout: 120_000 }, async () => {
  service.forgetListing() // measure a cold refresh, not one riding on the previous test's read
  const calls = []
  const realRequest = service.request
  service.request = async (url, opts) => { calls.push({ url: String(url), method: opts?.method || 'GET' }); return realRequest(url, opts) }
  await service.listAvailability()
  service.request = realRequest
  assert.equal(calls.length, 1, 'badges must not cost a request per release')
  assert.deepEqual(calls.filter(call => call.method !== 'GET'), [], 'refreshing badges must never write to the account')
})
