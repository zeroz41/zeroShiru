// Resume identity. Watch progress and resume positions are stored under
// fileHash = sha1(`${infoHash}:${name}:${size}`), computed by the torrent client with node
// crypto and by the debrid lane with WebCrypto. If they ever disagree — different digest,
// different encoding, different seed format — every debrid play of a release watched over
// torrents (or the other way round) silently starts from zero, which shows up to the user as
// "resume is broken on debrid". These tests hold the two implementations to byte equality.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
const makeHash = data => createHash('sha1').update(data).digest('hex')
import { sha1hex, toPlayerFile } from '../../../common/modules/debrid/identity.js'

const HASH = 'a'.repeat(40)

const resolved = { hash: HASH, name: '[Group] Show Season 1 [1080p]' }
const debridFile = (name, size, extra = {}) => ({ name, path: `/${resolved.name}/${name}`, size, url: `https://cdn.example.test/${encodeURIComponent(name)}`, type: 'video/x-matroska', ...extra })

/** What webtorrent's torrentReady produces for the same file of the same torrent. */
const torrentKey = (name, size) => makeHash(`${HASH}:${name}:${size}`)

test('the debrid watch key equals the torrent client\'s for the same file', async () => {
  const file = await toPlayerFile(resolved, debridFile('[Group] Show - 01 [1080p].mkv', 734_003_200))
  assert.equal(file.fileHash, torrentKey('[Group] Show - 01 [1080p].mkv', 734_003_200), 'debrid and torrent playback must share watch progress')
})

test('non-ASCII names hash identically in both lanes', async () => {
  // node crypto hashes strings as UTF-8, WebCrypto goes through TextEncoder: same bytes, but
  // only as long as nobody changes an encoding. Names like these are routine in real releases.
  for (const name of ['[グループ] ソードアート・オンライン - 01.mkv', 'Show – 01 (BD·1080p) é.mkv', '★☆Show☆★ - 01.mkv']) {
    const file = await toPlayerFile(resolved, debridFile(name, 1000))
    assert.equal(file.fileHash, torrentKey(name, 1000), name)
  }
})

test('every episode of a pack gets its own key', async () => {
  const files = await Promise.all(Array.from({ length: 100 }, (_, index) => toPlayerFile(resolved, debridFile(`Show - ${String(index + 1).padStart(3, '0')}.mkv`, 1000))))
  assert.equal(new Set(files.map(file => file.fileHash)).size, 100, 'colliding keys would make episodes share a resume position')
})

test('the same episode from a different release keys separately', async () => {
  const otherRelease = { hash: 'b'.repeat(40), name: 'Other' }
  const a = await toPlayerFile(resolved, debridFile('Show - 01.mkv', 1000))
  const b = await toPlayerFile(otherRelease, debridFile('Show - 01.mkv', 1000))
  assert.notEqual(a.fileHash, b.fileHash, 'the info hash is part of the identity')
})

test('size differences key separately, so a v2 re-release does not inherit stale progress', async () => {
  const a = await toPlayerFile(resolved, debridFile('Show - 01.mkv', 1000))
  const b = await toPlayerFile(resolved, debridFile('Show - 01.mkv', 1001))
  assert.notEqual(a.fileHash, b.fileHash)
})

// the key is name-based, not path-based, in BOTH lanes: a pack shipping the same basename under
// two folders collides. That is today's shared contract; this test documents it so a change in
// either lane (adding path, for instance) shows up as a deliberate break instead of a drift.
test('identity ignores the folder, matching the torrent client exactly', async () => {
  const a = await toPlayerFile(resolved, debridFile('Show - 01.mkv', 1000, { path: '/Season 1/Show - 01.mkv' }))
  const b = await toPlayerFile(resolved, debridFile('Show - 01.mkv', 1000, { path: '/Season 2/Show - 01.mkv' }))
  assert.equal(a.fileHash, b.fileHash, 'both lanes key by basename today; change them together or not at all')
})

test('sha1hex agrees with node crypto over every byte value that fits in a name', async () => {
  const gnarly = String.fromCharCode(...Array.from({ length: 0x300 }, (_, code) => code || 0x20))
  assert.equal(await sha1hex(gnarly), makeHash(gnarly))
})

test('the player file keeps the shape the player and watch store read', async () => {
  const file = await toPlayerFile(resolved, debridFile('Show - 01.mkv', 1000))
  assert.deepEqual(Object.keys(file).sort(), ['debrid', 'fileHash', 'infoHash', 'name', 'path', 'size', 'torrent_name', 'type', 'url'])
  assert.equal(file.infoHash, HASH)
  assert.equal(file.debrid, true, 'the player badges and buffers debrid streams differently')
  assert.equal(file.torrent_name, resolved.name)
  assert.match(file.fileHash, /^[a-f\d]{40}$/)
})
