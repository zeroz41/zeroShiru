// Live tests for the TorBox client. Opt-in, and they use your account:
//
//   TORBOX_API_KEY=<key> npm run test:live
//
// The fixture is Big Buck Bunny, a public domain release that is reliably cached on TorBox and
// small enough to add and remove without moving any real data.
//
// The invariant that matters most, as with the Real-Debrid suite: this file must leave the
// account exactly as it found it. The `after` hook fails loudly if a torrent was left behind,
// and refuses to let anything delete a torrent the account already had.
import { test, beforeAll, afterAll } from 'bun:test'
import assert from 'node:assert/strict'
import TorBox from '../../../common/modules/debrid/torbox.js'
import { DebridNotCachedError } from '../../../common/modules/debrid/service.js'
import { Availability, isAvailability } from '../../../common/modules/debrid/availability.js'

const KEY = process.env.TORBOX_API_KEY
const skip = KEY ? false : 'TORBOX_API_KEY not set'
const API = 'https://api.torbox.app/v1/api'

// public domain, and cached on TorBox, so it exercises the whole resolve without a real download
const CACHED = process.env.TORBOX_TEST_HASH || 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c'
// syntactically valid, but no tracker knows it, so TorBox cannot be holding it
const BOGUS = '0'.repeat(39) + '1'

const service = KEY ? new TorBox(KEY) : null

/** Bookkeeping talks to the API directly, so ground truth survives the client being torn down. */
async function accountTorrents (attempts = 3) {
  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(`${API}/torrents/mylist?bypass_cache=true&limit=1000`, { headers: { Authorization: `Bearer ${KEY}` } })
      const body = await res.json()
      return new Map((body?.data || []).map(torrent => [torrent.id, String(torrent.hash).toLowerCase()]))
    } catch (error) {
      if (attempt >= attempts) throw error
      await new Promise(resolve => setTimeout(resolve, 2_000 * attempt))
    }
  }
}

let before_ = null

beforeAll(async () => {
  if (!service) return
  before_ = await accountTorrents()
})

/** @param {number | string} id */
async function deleteTorrent (id) {
  return fetch(`${API}/torrents/controltorrent`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ torrent_id: id, operation: 'delete' })
  }).catch(() => {})
}

// A resolve that succeeds is *meant* to leave the release on the account — that is the stream
// the user is watching, and Real-Debrid behaves the same way. So this tidies up after the file
// rather than asserting nothing was added; the assertion that nothing is left behind by a
// *failed* resolve lives in the test that provokes one.
afterAll(async () => {
  if (!service) return
  service.destroy()
  await new Promise(resolve => setTimeout(resolve, 2_000))
  const after_ = await accountTorrents()
  const removed = [...before_].filter(([id]) => !after_.has(id)).map(([id]) => id)
  assert.deepEqual(removed, [], 'nothing here may delete a torrent the account already had')

  const added = [...after_].filter(([id]) => !before_.has(id)).map(([id]) => id)
  for (const id of added) await deleteTorrent(id)
  if (!added.length) return
  const cleaned = await accountTorrents()
  assert.deepEqual(added.filter(id => cleaned.has(id)), [], 'this file must not leave torrents on the account')
  console.log(`  cleaned up ${added.length} torrent(s) added by this file`)
})

test('validate reads the account behind the key', { skip, timeout: 60_000 }, async () => {
  const result = await service.validate()
  assert.ok(result.username, 'the settings Test button has a name to show')
  console.log(`  Connected as ${result.username}${result.expires ? `, premium until ${result.expires}` : ''}`)
})

// the reason TorBox is worth having: this is the whole badge story, in one request
test('the cache endpoint answers a whole results list in one request', { skip, timeout: 120_000 }, async () => {
  const calls = []
  const realRequest = service.request
  service.request = async (url, opts) => { calls.push(String(url)); return realRequest(url, opts) }
  // a realistic list: one release TorBox holds, mixed with ones nobody could
  const candidates = [CACHED, BOGUS, '0'.repeat(38) + '22', '0'.repeat(38) + '33']
  const started = Date.now()
  const answers = await service.checkAvailability(candidates)
  service.request = realRequest

  console.log(`  ${answers.size}/${candidates.length} answered in ${((Date.now() - started) / 1000).toFixed(1)}s using ${calls.length} request(s)`)
  assert.equal(calls.length, 1, 'a batch service must answer the whole list in one request')
  assert.equal(answers.size, candidates.length, 'and every result gets a real answer, not just the top of the list')
  assert.equal(answers.get(CACHED), Availability.CACHED)
  for (const hash of candidates.slice(1)) {
    assert.equal(answers.get(hash), Availability.AVAILABLE, 'a hash TorBox does not hold is available, never unavailable')
  }
})

test('answers are remembered, so re-checking the same search is free', { skip, timeout: 60_000 }, async () => {
  const calls = []
  const realRequest = service.request
  service.request = async (url, opts) => { calls.push(String(url)); return realRequest(url, opts) }
  await service.checkAvailability([CACHED, BOGUS])
  service.request = realRequest
  assert.equal(calls.length, 0, 'everything here was answered by the previous test')
})

test('listAvailability answers in lowercase hashes and known states', { skip, timeout: 120_000 }, async () => {
  const known = await service.listAvailability()
  for (const [hash, state] of known) {
    assert.match(hash, /^[a-f\d]{40}$/, 'hashes must be comparable to search result hashes')
    assert.ok(isAvailability(state) && state !== Availability.UNKNOWN, `${hash} came back as ${state}`)
  }
  console.log(`  account holds ${known.size} torrents`)
})

// the fix for a full account listing sitting on the play path
test('browsing and then playing reads the account listing once, not twice', { skip, timeout: 120_000 }, async () => {
  service.forgetListing()
  const listings = []
  const realRequest = service.request
  service.request = async (url, opts) => {
    if (String(url).includes('/torrents/mylist') && !String(url).includes('id=')) listings.push(String(url))
    return realRequest(url, opts)
  }
  const started = Date.now()
  await service.listAvailability() // opening the results modal
  const afterBadges = Date.now() - started
  await service.listing() // the resolve looking for an existing torrent
  service.request = realRequest
  console.log(`  listing read in ${(afterBadges / 1000).toFixed(1)}s, reused by the play path at no cost`)
  assert.equal(listings.length, 1, 'the play path must not pay for a second full listing')
})

test('an uncached release is refused without anything landing on the account', { skip, timeout: 120_000 }, async () => {
  const before = await accountTorrents()
  const started = Date.now()
  await assert.rejects(() => service.resolve(BOGUS, { fileFilter: () => true }), DebridNotCachedError)
  const seconds = (Date.now() - started) / 1000
  console.log(`  bogus hash rejected in ${seconds.toFixed(1)}s`)
  // Debrid First falls back to the torrent client on this, so it is on the play path
  assert.ok(seconds < 30, 'the fallback must not leave the user staring at a stalled player')
  const after = await accountTorrents()
  assert.deepEqual([...after.keys()].filter(id => !before.has(id)), [], 'asking is free, so nothing may be queued onto the account to find out')
})

test('a cached release resolves to playable HTTPS links', { skip, timeout: 300_000 }, async () => {
  const started = Date.now()
  const resolved = await service.resolve(CACHED, { fileFilter: name => /\.(mp4|mkv|avi)$/i.test(name) })
  console.log(`  ${resolved.name} -> ${resolved.files.length} file(s) in ${((Date.now() - started) / 1000).toFixed(1)}s`)
  assert.equal(resolved.hash, CACHED, 'the hash comes back lowercased, the key everything else is stored under')
  assert.ok(resolved.files.length > 0)
  for (const file of resolved.files) {
    assert.match(file.url, /^https:\/\//, 'every stream link must be HTTPS')
    assert.ok(file.path.startsWith('/'), 'paths are rooted, like the torrent client\'s')
    assert.ok(file.size > 0)
  }
})

test('a resolved link actually serves the file', { skip, timeout: 300_000 }, async () => {
  const resolved = await service.resolve(CACHED, { fileFilter: name => /\.(mp4|mkv|avi)$/i.test(name) })
  const file = resolved.files[0]
  // one small range, which is all the player needs to start, and all this test needs to prove it
  const res = await fetch(file.url, { headers: { range: 'bytes=0-2047' } })
  assert.ok(res.ok, `the stream link must serve bytes, got ${res.status}`)
  const bytes = new Uint8Array(await res.arrayBuffer())
  console.log(`  ${file.name}: ${res.status}, ${bytes.length} bytes`)
  assert.ok(bytes.length > 0, 'and actual data')
})

test('playing a release twice does not add it twice', { skip, timeout: 300_000 }, async () => {
  const before = await accountTorrents()
  await service.resolve(CACHED, { fileFilter: name => /\.(mp4|mkv|avi)$/i.test(name) })
  const after = await accountTorrents()
  const added = [...after.keys()].filter(id => !before.has(id))
  assert.deepEqual(added, [], 'the second play must reuse the torrent the first one added')
})
