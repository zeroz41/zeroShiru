// Live tests for what the player actually does with a TorBox stream link: byte-range semantics.
// Seeking, resume, and the subtitle streamer all depend on the CDN honoring Range requests at
// arbitrary offsets with 206 + Content-Range — a server that answers 200 with the whole file
// makes every seek re-download from zero and stalls the player. Opt-in:
//
//   TORBOX_API_KEY=<key> npm run test:live
//
// Uses the same public-domain fixture as the TorBox suite, resolves it once, and probes the
// link the way the <video> element and DebridMetadata do. Leaves the account as the other
// TorBox live file does: anything this file adds is removed again afterwards.
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import TorBox from '../../../common/modules/debrid/torbox.js'
import DebridMetadata from '../../../common/modules/debrid/metadata.js'
import { matchSubtitleFiles } from '../../../common/modules/util.js'

const KEY = process.env.TORBOX_API_KEY
const skip = KEY ? false : 'TORBOX_API_KEY not set'
const API = 'https://api.torbox.app/v1/api'

// public domain, and cached on TorBox, so it exercises the whole path without a real download
const CACHED = process.env.TORBOX_TEST_HASH || 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c'

const service = KEY ? new TorBox(KEY) : null

async function accountTorrents () {
  const res = await fetch(`${API}/torrents/mylist?bypass_cache=true&limit=1000`, { headers: { Authorization: `Bearer ${KEY}` } })
  const body = await res.json()
  return new Map((body?.data || []).map(torrent => [torrent.id, String(torrent.hash).toLowerCase()]))
}

let before_ = null
/** @type {import('../../../common/modules/debrid/service.js').DebridResolved} */
let resolved = null
let video = null

before(async () => {
  if (!service) return
  before_ = await accountTorrents()
  resolved = await service.resolve(CACHED, { fileFilter: name => /\.(mp4|mkv|avi)$/i.test(name) })
  video = resolved.files.sort((a, b) => b.size - a.size)[0]
  console.log(`  streaming "${video.name}" (${(video.size / 1e6).toFixed(1)} MB)`)
})

after(async () => {
  if (!service) return
  service.destroy()
  await new Promise(resolve => setTimeout(resolve, 2_000))
  const after_ = await accountTorrents()
  const removed = [...before_].filter(([id]) => !after_.has(id)).map(([id]) => id)
  assert.deepEqual(removed, [], 'nothing here may delete a torrent the account already had')
  const added = [...after_].filter(([id]) => !before_.has(id)).map(([id]) => id)
  for (const id of added) {
    await fetch(`${API}/torrents/controltorrent`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ torrent_id: id, operation: 'delete' })
    }).catch(() => {})
  }
  if (added.length) console.log(`  cleaned up ${added.length} torrent(s) added by this file`)
})

/** One range request, answering with what the player cares about. */
async function range (headerValue) {
  const res = await fetch(video.url, { headers: { Range: headerValue } })
  const body = new Uint8Array(await res.arrayBuffer())
  return { status: res.status, contentRange: res.headers.get('content-range'), length: body.length, body }
}

test('the head of the file serves with a correct 206, which playback start needs', { skip, timeout: 120_000 }, async () => {
  const res = await range('bytes=0-1023')
  assert.equal(res.status, 206, 'a 200 here means the server ignores ranges and seeking is broken')
  assert.equal(res.length, 1024, 'exactly the bytes asked for')
  assert.match(res.contentRange || '', new RegExp(`bytes 0-1023/${video.size}`), 'Content-Range must carry the real file size, the player sizes its seek bar from it')
})

test('a seek lands mid-file: ranges at arbitrary offsets serve correctly', { skip, timeout: 120_000 }, async () => {
  // the offsets a real seek bar produces: nowhere near cluster or chunk boundaries
  for (const fraction of [0.25, 0.5, 0.75]) {
    const start = Math.floor(video.size * fraction) + 12_345
    const res = await range(`bytes=${start}-${start + 4_095}`)
    assert.equal(res.status, 206, `seek to ${Math.round(fraction * 100)}% must serve a partial response`)
    assert.equal(res.length, 4_096)
    assert.match(res.contentRange || '', new RegExp(`bytes ${start}-${start + 4095}/${video.size}`))
  }
})

test('an open-ended range from a seek point streams, the way <video> requests it', { skip, timeout: 120_000 }, async () => {
  const start = Math.floor(video.size * 0.6)
  const res = await fetch(video.url, { headers: { Range: `bytes=${start}-` } })
  assert.equal(res.status, 206)
  const reader = res.body.getReader()
  const { value } = await reader.read()
  await reader.cancel()
  assert.ok(value?.length > 0, 'bytes must flow from the seek point without buffering the whole tail')
})

test('the very end of the file serves, which MKV metadata (cues, attachments) often needs', { skip, timeout: 120_000 }, async () => {
  const start = video.size - 1024
  const res = await range(`bytes=${start}-${video.size - 1}`)
  assert.equal(res.status, 206, 'seek-to-end and duration probing read here')
  assert.equal(res.length, 1024)
})

test('two overlapping ranges stream concurrently, as video playback plus subtitle parsing do', { skip, timeout: 120_000 }, async () => {
  // during playback the <video> element holds one connection and DebridMetadata a second
  const [head, tail] = await Promise.all([range('bytes=0-65535'), range(`bytes=${Math.floor(video.size / 2)}-${Math.floor(video.size / 2) + 65_535}`)])
  assert.equal(head.status, 206)
  assert.equal(tail.status, 206)
  assert.equal(head.length, 65_536)
  assert.equal(tail.length, 65_536)
})

test('seek latency: first byte from a cold mid-file offset arrives fast enough to not stall', { skip, timeout: 120_000 }, async () => {
  const start = Math.floor(video.size * 0.8) + 7
  const began = Date.now()
  const res = await fetch(video.url, { headers: { Range: `bytes=${start}-` } })
  const reader = res.body.getReader()
  const { value } = await reader.read()
  const firstByte = Date.now() - began
  await reader.cancel()
  console.log(`  first byte after a cold 80% seek: ${firstByte}ms`)
  assert.ok(value?.length > 0)
  assert.ok(firstByte < 15_000, `a seek that takes ${firstByte}ms reads as a hung player`)
})

test('ranged reads agree with each other byte for byte', { skip, timeout: 120_000 }, async () => {
  // a CDN edge serving different bytes for the same range corrupts playback undetectably
  const start = Math.floor(video.size * 0.3)
  const [a, b] = await Promise.all([range(`bytes=${start}-${start + 2_047}`), range(`bytes=${start}-${start + 2_047}`)])
  assert.deepEqual(a.body, b.body)
  const inner = await range(`bytes=${start + 512}-${start + 1_023}`)
  assert.deepEqual(inner.body, a.body.slice(512, 1_024), 'a sub-range must be a slice of the larger read')
})

test('DebridMetadata streams real subtitle metadata from the live link where the container has any', { skip, timeout: 180_000 }, async t => {
  if (!/\.mkv$/i.test(video.name)) return t.skip(`fixture resolves to ${video.name}, no Matroska metadata to stream`)
  const seen = { tracks: [], subtitles: [], fonts: [], files: [] }
  const spy = {
    handleTracks: tracks => seen.tracks.push(...tracks),
    handleSubtitle: event => seen.subtitles.push(event),
    handleFile: data => seen.fonts.push(data),
    handleSubtitleFile: file => seen.files.push(file)
  }
  const metadata = new DebridMetadata(video, resolved.files, spy, { getTime: () => Number.MAX_SAFE_INTEGER })
  const tracks = await metadata.metadata.getTracks().catch(() => [])
  metadata.destroy()
  assert.equal(seen.files.length, matchSubtitleFiles(resolved.files, video.name).length, 'external subs must match the shared matcher')
  console.log(`  ${tracks.length} embedded subtitle tracks in the live fixture`)
})
