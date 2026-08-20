// The seam between the UI and the debrid core. Everything the old JS provider tests
// covered now lives in crates/debrid; what is left on this side is orchestration, and
// these pin it: which lane a play request goes down, what the user is told when it
// cannot go down either, and how answers reach the badges.
//
// The failures these guard against are all silent ones: a release that should have
// fallen back to torrents and instead showed an error, a wrong-episode refusal treated
// as a service outage, or a badge painted from an account that is no longer configured.
import { test, beforeEach } from 'bun:test'
import assert from 'node:assert/strict'
import { DEBRID } from '@/modules/bridge.js'
import { settings } from '@/modules/settings.js'
import { status } from '@/modules/networking.js'
import { files } from '@/components/MediaHandler.svelte'
import { toast } from 'svelte-sonner'
import {
  streamDebrid, resolveDebridFiles, checkDebridAvailability, cancelDebridAvailability,
  refreshDebridAvailability, testDebrid, debridAvailability, debridReleaseNames,
  debridEnabled, debridTransport, debridOptions, QUEUE_WINDOW
} from '@/modules/debrid/debrid.js'
import { Availability } from '@/modules/debrid/availability.js'
import { get } from 'svelte/store'

const HASH = 'a'.repeat(40)
const MAGNET = `magnet:?xt=urn:btih:${HASH}`

/** A host failure, shaped the way a Tauri command error arrives. */
const failure = (kind, message = kind) => ({ kind, message })

const playerFile = (name = 'Show - 01.mkv') => ({
  infoHash: HASH,
  fileHash: 'f'.repeat(40),
  torrent_name: 'Show',
  name,
  size: 1000,
  path: `/${name}`,
  url: `https://cdn.test/${name}`,
  debrid: true
})

/** Configures an account, since every call needs one. */
function configure ({ service = 'torbox', key = 'k', mode = 'prefer', online = true } = {}) {
  settings.set({ ...settings.value, debridService: service, debridApiKeys: key ? { [service]: key } : {}, debridMode: mode, debridCacheCheck: true })
  status.set(online ? 'online' : 'offline')
}

beforeEach(() => {
  toast.shown.length = 0
  files.set([])
  debridAvailability.set(new Map())
  debridReleaseNames.set(new Map())
  cancelDebridAvailability()
  DEBRID.resolve = async () => ({ hash: HASH, name: 'Show', files: [playerFile()] })
  DEBRID.checkAvailability = async () => ({ answers: {}, names: {}, busy: false })
  DEBRID.unknownHashes = async (service, apiKey, hashes) => hashes
  DEBRID.listAvailability = async () => ({ answers: {}, names: {} })
  DEBRID.remember = async () => {}
  configure()
})

test('the settings menu offers what the host says it has', () => {
  assert.deepEqual(debridOptions.map(option => option.id), ['torbox', 'realdebrid'])
  configure({ service: 'realdebrid' })
  assert.equal(get(debridTransport).title, 'Real-Debrid')
  assert.equal(get(debridTransport).checksAddMagnets, true, 'the UI says when asking costs the account something')
  configure({ service: 'torbox' })
  assert.equal(get(debridTransport).checksAddMagnets, false)
  configure({ service: '' })
  assert.equal(get(debridTransport), null, 'no service selected, nothing to describe')
})

test('no service, or no key, means the request is simply a torrent', async () => {
  configure({ service: '' })
  assert.equal(get(debridEnabled), false)
  assert.equal(await streamDebrid(MAGNET), false, 'unhandled: the torrent client takes it')

  configure({ key: '' })
  assert.equal(await streamDebrid(MAGNET), false)
  assert.equal(toast.shown.length, 0, 'and nothing is said about it, because nothing went wrong')
})

test('debrid only mode explains itself rather than silently playing nothing', async () => {
  configure({ key: '', mode: 'only' })
  assert.equal(await streamDebrid(MAGNET), true, 'handled: only mode never falls back')
  assert.match(toast.shown[0].description, /no API key/i)

  toast.shown.length = 0
  configure({ mode: 'only', online: false })
  assert.equal(await streamDebrid(MAGNET), true)
  assert.match(toast.shown[0].description, /offline/i)
})

test('a resolved release reaches the player as files, and proves itself cached', async () => {
  assert.equal(await streamDebrid(MAGNET, undefined, { episode: 1 }), true)
  assert.equal(files.value.length, 1)
  assert.equal(files.value[0].url, 'https://cdn.test/Show - 01.mkv')
  assert.equal(debridAvailability.value.get(HASH), Availability.CACHED, 'playing it is the best cache answer there is')
})

test('the episode being played is passed to the core, which picks it out of the pack', async () => {
  let asked = null
  DEBRID.resolve = async (service, apiKey, magnet, episode) => {
    asked = { service, apiKey, magnet, episode }
    return { hash: HASH, name: 'Pack', files: [playerFile('Show - 53.mkv')] }
  }
  await streamDebrid(MAGNET, undefined, { episode: 53 })
  assert.deepEqual(asked, { service: 'torbox', apiKey: 'k', magnet: MAGNET, episode: 53 })

  // no episode context: the core is told nothing rather than a NaN
  await streamDebrid(MAGNET, undefined, {})
  assert.equal(asked.episode, undefined)
})

test('a release that provably lacks the episode is refused, never played anyway', async () => {
  DEBRID.resolve = async () => { throw failure('rejected', 'This release holds episodes 459-516, not episode 23.') }
  assert.equal(await streamDebrid(MAGNET, undefined, { episode: 23 }), true, 'handled: falling back would play the wrong episode over torrents too')
  assert.equal(toast.shown[0].title, 'Wrong Release')
  assert.match(toast.shown[0].description, /459-516/)
  assert.equal(files.value.length, 0)
})

test('a release the service does not hold falls back to torrents, and badges what it learned', async () => {
  DEBRID.resolve = async () => { throw failure('not-cached', 'not cached') }
  assert.equal(await streamDebrid(MAGNET), false, 'unhandled: the torrent client takes it')
  assert.equal(debridAvailability.value.get(HASH), Availability.AVAILABLE, 'the service could fetch it, just not now')

  DEBRID.resolve = async () => { throw failure('unavailable', 'dead magnet') }
  assert.equal(await streamDebrid(MAGNET), false)
  assert.equal(debridAvailability.value.get(HASH), Availability.UNAVAILABLE)
})

test('in only mode the same failures stop, and say why', async () => {
  configure({ mode: 'only' })
  DEBRID.resolve = async () => { throw failure('not-cached', 'not cached') }
  assert.equal(await streamDebrid(MAGNET), true, 'only mode never hands over to torrents')
  assert.match(toast.shown[0].description, /different release|only mode/i)
})

test('an error that proves nothing about the release still lets torrents through', async () => {
  DEBRID.resolve = async () => { throw failure('timeout', 'request timed out after 30000ms') }
  assert.equal(await streamDebrid(MAGNET), false)
  assert.equal(debridAvailability.value.has(HASH), false, 'a timeout is not an answer about the release')
  assert.match(toast.shown[0].description, /timed out/)
})

test('answers and release names from the core reach the stores', async () => {
  DEBRID.checkAvailability = async () => ({
    answers: { [HASH]: 'cached', ['b'.repeat(40)]: 'unavailable' },
    names: { [HASH]: '[Group] Show 01-12' },
    busy: false
  })
  DEBRID.unknownHashes = async () => []
  await checkDebridAvailability([HASH])
  // unknownHashes answering empty means everything is known, so nothing is asked
  assert.equal(debridAvailability.value.size, 0, 'a list nothing is unknown in costs no request')

  DEBRID.unknownHashes = async (service, apiKey, hashes) => hashes
  await checkDebridAvailability([HASH])
  assert.equal(debridAvailability.value.get(HASH), Availability.CACHED)
  assert.equal(debridReleaseNames.value.get(HASH), '[Group] Show 01-12', 'the service knows the real name, the source often does not')
  cancelDebridAvailability()
})

/** The queue window the store writes are collected into, plus room to fire. */
const settled = () => new Promise(resolve => setTimeout(resolve, QUEUE_WINDOW + 20))

test('answers pushed while a check is still running badge the list as they land', async () => {
  assert.ok(DEBRID.publishAvailability, 'the module subscribes to the push channel at import')
  DEBRID.publishAvailability(HASH, 'cached')
  await settled()
  assert.equal(debridAvailability.value.get(HASH), Availability.CACHED)
})

test('answers that arrive as separate events still reach the list as one write', async () => {
  // each answer crosses from the host as its own event, so collecting them in a microtask
  // coalesced nothing: a sweep of a long list re-rendered the results once per hash
  const hashes = ['a', 'b', 'c'].map(letter => letter.repeat(40))
  let writes = 0
  const stop = debridAvailability.subscribe(() => { writes++ })
  writes = 0 // the subscription itself fires once
  for (const hash of hashes) {
    DEBRID.publishAvailability(hash, 'cached')
    await new Promise(resolve => setTimeout(resolve, 0)) // a task apiece, as the host delivers them
  }
  await settled()
  stop()
  assert.equal(writes, 1, `three answers must cost one render, took ${writes}`)
  for (const hash of hashes) assert.equal(debridAvailability.value.get(hash), Availability.CACHED)
})

test('an unknown state clears a badge rather than painting a wrong one', async () => {
  DEBRID.publishAvailability(HASH, 'cached')
  await settled()
  DEBRID.publishAvailability(HASH, 'nonsense from a future service')
  await settled()
  assert.equal(debridAvailability.value.has(HASH), false)
})

test('badges from a request that outlived its account are dropped', async () => {
  let release = null
  DEBRID.checkAvailability = () => new Promise(resolve => { release = () => resolve({ answers: { [HASH]: 'cached' }, names: {}, busy: false }) })
  const checking = checkDebridAvailability([HASH])
  while (!release) await Promise.resolve() // the check reads unknownHashes first
  configure({ service: 'realdebrid', key: 'other' }) // the user switched accounts mid-flight
  release()
  await checking
  assert.equal(debridAvailability.value.size, 0, "badging a new account with the old account's answers is worse than no badges")
})

test('a release with no hash cannot silence the whole list', async () => {
  // one source listing an entry it has no info hash for used to cross the seam as a null
  // in a typed array, where the host refused the call outright: every badge on the screen
  // stayed empty, and the failure said nothing about any release so nothing was said at all
  let asked = null
  DEBRID.unknownHashes = async (service, apiKey, hashes) => { asked = hashes; return hashes }
  DEBRID.checkAvailability = async (service, apiKey, hashes) => ({
    answers: Object.fromEntries(hashes.map(hash => [hash, 'cached'])),
    names: {},
    busy: false
  })

  await checkDebridAvailability([HASH, undefined, null, '', 'b'.repeat(40)])
  assert.deepEqual(asked, [HASH, 'b'.repeat(40)], 'the releases that do have a hash are still asked about')
  assert.equal(debridAvailability.value.get(HASH), Availability.CACHED)
  cancelDebridAvailability()

  // and a list with nothing askable in it costs no request at all
  asked = null
  await checkDebridAvailability([undefined, null])
  assert.equal(asked, null)
})

test('a check that fails for no named reason still tells the user once', async () => {
  DEBRID.unknownHashes = async (service, apiKey, hashes) => hashes
  DEBRID.checkAvailability = async () => { throw new TypeError('invalid args for command debrid_check_availability') }
  toast.shown.length = 0
  await checkDebridAvailability([HASH])
  cancelDebridAvailability()
  assert.equal(toast.shown.length, 1, 'missing badges must never be indistinguishable from nothing being cached')
  assert.match(toast.shown[0].description, /invalid args/)
})

test('nothing is asked while offline, or with cache checking turned off', async () => {
  let asked = 0
  DEBRID.checkAvailability = async () => { asked++; return { answers: {}, names: {}, busy: false } }

  configure({ online: false })
  await checkDebridAvailability([HASH])
  configure({ online: true })
  settings.set({ ...settings.value, debridCacheCheck: false })
  await checkDebridAvailability([HASH])
  assert.equal(asked, 0)
})

test('the account listing is read at most once a minute', async () => {
  let reads = 0
  DEBRID.listAvailability = async () => { reads++; return { answers: { [HASH]: 'cached' }, names: {} } }
  refreshDebridAvailability()
  refreshDebridAvailability()
  await new Promise(resolve => setTimeout(resolve, 10))
  assert.equal(reads, 1, 'the free badge source is free because it is not read per keystroke')
  assert.equal(debridAvailability.value.get(HASH), Availability.CACHED)
})

test('the settings test button needs an account and a connection', async () => {
  configure({ key: '' })
  await assert.rejects(testDebrid(), /No debrid service configured/)
  configure({ online: false })
  await assert.rejects(testDebrid(), /offline/)
  configure()
  assert.deepEqual(await testDebrid(), { username: 'tester' })
})

test('resolving without an account is an error, not a silent empty file list', async () => {
  configure({ key: '' })
  await assert.rejects(resolveDebridFiles(MAGNET), /No debrid service configured/)
})
