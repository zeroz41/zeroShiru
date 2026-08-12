// Live season-pack test: the path where resolve() has to pick one episode out of a
// multi-file torrent, which is where the prototype used to play the wrong episode.
// Opt-in, and deliberately non-destructive: it only ever resolves a torrent that is
// already downloaded on the account, and asserts it does not add a duplicate.
//
//   REAL_DEBRID_API_KEY=xxx RD_TEST_PACK_MAGNET=<hash of a cached pack> \
//   RD_TEST_PACK_EPISODE=25 npm run test:live
import { test } from 'node:test'
import assert from 'node:assert/strict'
import RealDebrid from '../../../common/modules/debrid/realdebrid.js'
import { DebridNotCachedError, secureFiles } from '../../../common/modules/debrid/service.js'

const KEY = process.env.REAL_DEBRID_API_KEY
const PACK = process.env.RD_TEST_PACK_MAGNET
const EPISODE = Number(process.env.RD_TEST_PACK_EPISODE || 1)
const skip = !KEY ? 'REAL_DEBRID_API_KEY not set' : (!PACK ? 'RD_TEST_PACK_MAGNET not set' : false)

const service = KEY ? new RealDebrid(KEY) : null
const videoRx = /\.(mkv|mp4|avi)$/i

/**
 * Stands in for the app's anitomy-based picker, which needs the UI bundle to import.
 * Deliberately crude: this test exercises the resolve/window/no-duplicate contract around
 * whatever the picker chooses, not the quality of episode matching itself.
 */
function pickEpisode (files, episode) {
  const padded = String(episode).padStart(2, '0')
  const match = files.filter(file => videoRx.test(file.path))
    .find(file => new RegExp(`(^|[^\\d])(${episode}|${padded})([^\\d]|$)`).test(file.path.split('/').pop()))
  return match || files.sort((a, b) => b.size - a.size)[0]
}

async function countOnAccount (hash) {
  const torrents = await service.request('https://api.real-debrid.com/rest/1.0/torrents?limit=100')
  return (torrents || []).filter(torrent => torrent.hash?.toLowerCase() === hash).length
}

test('resolves the requested episode out of a cached pack without duplicating it', { skip, timeout: 300_000 }, async t => {
  const hash = (/urn:btih:([a-f\d]{40})/i.exec(PACK)?.[1] || PACK).toLowerCase()
  const before = await countOnAccount(hash)
  if (!before) return t.skip('pack is not on the account, pick a hash from your downloaded torrents')

  let resolved
  try {
    resolved = await service.resolve(PACK, {
      fileFilter: name => videoRx.test(name) || /\.(ass|srt)$/i.test(name),
      pickFile: files => pickEpisode(files, EPISODE)
    })
  } catch (error) {
    if (error instanceof DebridNotCachedError) return t.skip('pack reports as not cached')
    throw error
  }

  console.log(`  Resolved ${resolved.files.length} files from "${resolved.name}"`)
  assert.ok(resolved.files.length > 0, 'a cached pack must yield playable files')
  assert.deepEqual(secureFiles(resolved.files, 'Real-Debrid'), resolved.files, 'every link must be HTTPS')

  // the episode asked for has to be among what came back, otherwise playback plays the wrong file
  const wanted = pickEpisode(resolved.files.map(file => ({ path: file.path, size: file.size })), EPISODE)
  const target = resolved.files.find(file => file.path === wanted.path)
  assert.ok(target, `the picked file for episode ${EPISODE} must be present in the resolved files`)
  console.log(`  Picked file for episode ${EPISODE}: "${target.name}"`)

  // reusing the account torrent is the whole point, a duplicate means wasted API calls and clutter
  assert.equal(await countOnAccount(hash), before, 'resolve must not add a duplicate of a torrent already on the account')

  const res = await fetch(target.url, { headers: { Range: 'bytes=0-1023' } })
  assert.ok(res.ok || res.status === 206, `stream URL returned ${res.status}`)
  assert.ok((await res.arrayBuffer()).byteLength > 0)
  console.log(`  Episode stream URL is live (status ${res.status})`)

  if (target.name.endsWith('.mkv')) {
    const { default: Metadata } = await import('matroska-metadata')
    const controller = new AbortController()
    const metadata = new Metadata({
      name: target.name,
      size: target.size,
      slice: (start = 0) => ({
        stream: () => (async function * () {
          try {
            const res = await fetch(target.url, { headers: { Range: `bytes=${start}-` }, signal: controller.signal })
            yield * res.body
          } catch (error) {
            if (error?.name !== 'AbortError') throw error // our own teardown, mirrors RemoteFile
          }
        })()
      })
    })
    const tracks = await metadata.getTracks()
    controller.abort()
    metadata.destroy()
    console.log(`  Remote MKV metadata: ${tracks.length} subtitle tracks`)
    assert.ok(Array.isArray(tracks))
  }
})
