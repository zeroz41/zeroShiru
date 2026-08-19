// Live season-pack test for TorBox: resolve a multi-file torrent and pick one episode out of
// it with the app's real picker (pick.js + the real anitomy WASM, which the test loader can now
// run under Node). Non-destructive: it only uses a torrent already downloaded on the account,
// preferring one named by TB_TEST_PACK_HASH, otherwise the largest multi-video torrent it
// finds. Skips when the account holds no packs.
//
// The episode asked for is read out of the pack itself (the median parsed episode number), so
// the test asserts exact identity — "the file that plays IS episode N" — on whatever pack the
// account happens to hold, absolute numbering included.
//
//   TORBOX_API_KEY=<key> [TB_TEST_PACK_HASH=<hash>] [TB_TEST_PACK_EPISODE=<n>] npm run test:live
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import TorBox from '../../../common/modules/debrid/torbox.js'
import { pickEpisodeFile } from '../../../common/modules/debrid/pick.js'
import { secureFiles } from '../../../common/modules/debrid/service.js'
import { videoRx } from '../../../common/modules/util.js'

const KEY = process.env.TORBOX_API_KEY
const skip = KEY ? false : 'TORBOX_API_KEY not set'
const service = KEY ? new TorBox(KEY) : null

test('picks the requested episode out of a real pack and its link serves bytes', { skip, timeout: 300_000 }, async t => {
  const { default: anitomy } = await import('anitomyscript')
  const wantedHash = process.env.TB_TEST_PACK_HASH?.toLowerCase()

  // find a pack the account already finished downloading, so nothing is added or removed
  const listing = await service.listing()
  const finished = listing.filter(torrent => torrent?.download_present && Array.isArray(torrent.files))
  const packs = finished.filter(torrent => torrent.files.filter(file => videoRx.test(file?.name || file?.short_name || '')).length >= 3)
  const pack = (wantedHash && finished.find(torrent => String(torrent.hash).toLowerCase() === wantedHash)) || packs.sort((a, b) => b.files.length - a.files.length)[0]
  if (!pack) {
    service.destroy()
    return t.skip('account holds no finished multi-episode torrents; set TB_TEST_PACK_HASH to one')
  }
  console.log(`  pack: "${pack.name}" (${pack.files.length} files)`)

  // ask for an episode the pack really holds: the median of what its file names parse to,
  // unless the run pins one. This is what exercises absolute numbering (a pack of 0131-0206
  // is asked for episode ~168, not episode 2)
  const names = pack.files.map(file => String(file?.name || file?.short_name || '').split('/').pop()).filter(name => videoRx.test(name))
  const parsed = await anitomy(names)
  const numbers = parsed.map(parse => Number(parse.episode_number)).filter(Number.isFinite).sort((a, b) => a - b)
  const episode = Number(process.env.TB_TEST_PACK_EPISODE || numbers[Math.floor(numbers.length / 2)])
  if (!Number.isFinite(episode)) {
    service.destroy()
    return t.skip('the pack\'s file names parse to no episode numbers to ask for')
  }

  const resolved = await service.resolve(String(pack.hash).toLowerCase(), {
    fileFilter: name => videoRx.test(name) || /\.(ass|srt)$/i.test(name),
    pickFile: files => pickEpisodeFile(files, episode, anitomy)
  })

  assert.ok(resolved.files.length > 0, 'a cached pack must yield playable files')
  assert.ok(resolved.files.length <= TorBox.maxFiles + 5, `a pack resolve must stay within the link window, got ${resolved.files.length}`)
  assert.deepEqual(secureFiles(resolved.files, 'TorBox'), resolved.files, 'every link must be HTTPS')

  // exact identity: the file the picker names must parse back to the episode asked for
  const videos = resolved.files.filter(file => videoRx.test(file.name))
  const wanted = await pickEpisodeFile(videos.map(file => ({ path: file.path, size: file.size })), episode, anitomy)
  const target = resolved.files.find(file => file.path === wanted?.path)
  assert.ok(target, `the picked file for episode ${episode} must be present in the resolved files`)
  const [check] = await anitomy([target.name])
  assert.equal(Number(check.episode_number), episode, `asked for episode ${episode}, "${target.name}" is what would play`)
  console.log(`  episode ${episode} -> "${target.name}"`)

  // and its link must actually serve, mid-file included, or seeking in the episode is broken
  const head = await fetch(target.url, { headers: { Range: 'bytes=0-1023' } })
  assert.ok(head.ok || head.status === 206, `stream URL answered ${head.status}`)
  assert.ok((await head.arrayBuffer()).byteLength > 0)
  const middle = Math.floor(target.size / 2)
  const mid = await fetch(target.url, { headers: { Range: `bytes=${middle}-${middle + 1023}` } })
  assert.equal(mid.status, 206, 'a mid-file range must serve partial content, or seeks re-download the episode')
  await mid.arrayBuffer()
  console.log(`  episode link serves head and mid-file ranges (status ${head.status}/${mid.status})`)

  // the account is left exactly as found: resolve reused the existing torrent
  const after = await service.listing({ fresh: true })
  assert.equal(after.filter(torrent => String(torrent.hash).toLowerCase() === String(pack.hash).toLowerCase()).length, 1, 'resolve must reuse the pack, not add a duplicate')
  service.destroy()
})
