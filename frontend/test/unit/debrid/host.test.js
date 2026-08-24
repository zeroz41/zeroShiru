// The seam between the UI and the debrid core. Everything the old JS provider tests
// covered now lives in crates/debrid; what is left on this side is orchestration, and
// these pin it: which lane a play request goes down, what the user is told when it
// cannot go down either, and how answers reach the badges.
//
// The failures these guard against are all silent ones: a release that should have
// fallen back to torrents and instead showed an error, a wrong-episode refusal treated
// as a service outage, or a badge painted from an account that is no longer configured.
import { test, beforeEach, afterAll } from 'bun:test'
import assert from 'node:assert/strict'
import { DEBRID } from '@/modules/bridge.js'
import { settings } from '@/modules/settings.js'
import { status } from '@/modules/networking.js'
import { files } from '@/components/MediaHandler.svelte'
import { toast } from 'svelte-sonner'
import {
  streamDebrid, resolveDebridFiles, replayDebridPlayback, checkDebridAvailability, cancelDebridAvailability,
  refreshDebridAvailability, testDebrid, debridAvailability, debridReleaseNames, debridChecking,
  debridEnabled, debridTransport, debridOptions, debridPlayback, debridStatus, boundedDebridPlay,
  DEBRID_PLAY_DEADLINE_MS, QUEUE_WINDOW
} from '@/modules/debrid/debrid.js'
import { Availability } from '@/modules/debrid/availability.js'
import { get } from 'svelte/store'

const HASH = 'a'.repeat(40)
const MAGNET = `magnet:?xt=urn:btih:${HASH}`

/** A host failure, shaped the way a Tauri command error arrives. */
const failure = (kind, message = kind) => ({ kind, message })

/** A request whose finish order the test controls. */
const deferred = () => {
  let resolve
  let reject
  const promise = new Promise((yes, no) => {
    resolve = yes
    reject = no
  })
  return { promise, resolve, reject }
}

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

/** What the CDN answers each probe with, reset to alive per test. See playback/probe.js. */
let probeAnswers = []
let probed = []
let forgotten = []
const realFetch = globalThis.fetch

beforeEach(() => {
  toast.shown.length = 0
  files.set([])
  debridPlayback.set(false)
  debridStatus.set(null)
  debridAvailability.set(new Map())
  debridReleaseNames.set(new Map())
  cancelDebridAvailability()
  DEBRID.resolve = async () => ({ hash: HASH, name: 'Show', files: [playerFile()] })
  DEBRID.watchAvailability = async () => {}
  DEBRID.cancelAvailability = () => {}
  DEBRID.listAvailability = async () => ({ answers: {}, names: {} })
  DEBRID.remember = async () => {}
  DEBRID.forgetResolved = async (...args) => { forgotten.push(args) }
  // an answer event re-arms the once-per-outage toast, so each test starts armed
  DEBRID.publishEvent({ type: 'availability', data: { hash: 'f'.repeat(40), state: 'cached' } })
  cancelDebridAvailability() // and the queued badge from that reset never lands
  // every resolve now probes its link before the play is trusted; a healthy CDN by default
  probeAnswers = []
  probed = []
  forgotten = []
  globalThis.fetch = async url => {
    probed.push(url)
    return probeAnswers.shift() ?? { ok: true, status: 206 }
  }
  configure()
})

afterAll(() => {
  globalThis.fetch = realFetch
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
  assert.match(debridStatus.value, /opening|checking/i, 'the player says what it is waiting for until its first frame arrives')
  assert.equal(debridAvailability.value.get(HASH), Availability.CACHED, 'playing it is the best cache answer there is')
})

test('a renderer deadline releases a native resolve that never settles', async () => {
  assert.ok(DEBRID_PLAY_DEADLINE_MS <= 30_000, 'a play click cannot wait on IPC for a minute')
  let expire
  const pending = boundedDebridPlay(new Promise(() => {}), {
    ms: 25_000,
    schedule: callback => { expire = callback; return 1 },
    cancel: () => {}
  })
  expire()
  await assert.rejects(pending, error => error?.kind === 'timeout' && /25 seconds/i.test(error.message))
})

test('a pending resolve exposes immediate progress instead of looking like a dead click', async () => {
  const host = deferred()
  DEBRID.resolve = () => host.promise
  const playing = streamDebrid(MAGNET, HASH, { episode: 1 })
  assert.equal(debridPlayback.value, true)
  assert.match(debridStatus.value, /resolving cached release/i)
  host.resolve({ hash: HASH, name: 'Show', files: [playerFile()] })
  assert.equal(await playing, true)
})

/** Runs the event loop until `predicate` holds, so a test can watch for something that
 * must happen WITHOUT the thing it is waiting on being what unblocks it. */
const until = async (predicate, message) => {
  for (let tick = 0; tick < 50; tick++) {
    if (predicate()) return
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  assert.fail(message)
}

test('the player receives the link while the warm-up probe is still reading', async () => {
  const chunk = deferred()
  globalThis.fetch = async url => {
    probed.push(url)
    return {
      ok: true,
      status: 206,
      body: {
        getReader: () => ({
          read: () => chunk.promise,
          cancel: async () => {}
        })
      }
    }
  }

  const playing = streamDebrid(MAGNET, undefined, { episode: 1 })
  // the probe has not delivered a byte yet and must not be in the way: it exists to
  // overlap the warm-up with filename parsing, so gating the link on it simply adds its
  // whole duration to every start. See the warning in modules/playback/probe.js
  await until(() => files.value.length === 1, 'the player was made to wait for the probe before it could start')

  chunk.resolve({ done: false, value: new Uint8Array(262_144) })
  assert.equal(await playing, true)
  assert.equal(files.value.length, 1)
})

test('a late older resolve cannot replace the newer episode in the player', async () => {
  const older = deferred()
  const newer = deferred()
  DEBRID.resolve = async (_service, _key, _magnet, episode) => episode === 1 ? older.promise : newer.promise

  const firstPlay = streamDebrid(MAGNET, undefined, { episode: 1 })
  const latestPlay = streamDebrid(`magnet:?xt=urn:btih:${'b'.repeat(40)}`, undefined, { episode: 2 })

  newer.resolve({ hash: 'b'.repeat(40), name: 'Show', files: [playerFile('Show - 02.mkv')] })
  assert.equal(await latestPlay, true)
  assert.equal(files.value[0].name, 'Show - 02.mkv')

  older.resolve({ hash: HASH, name: 'Show', files: [playerFile('Show - 01.mkv')] })
  assert.equal(await firstPlay, true, 'an obsolete play is consumed instead of falling through to torrents')
  assert.equal(files.value[0].name, 'Show - 02.mkv', 'the last click owns the player regardless of network finish order')
  assert.equal(debridPlayback.value, true)
})

test('a late failure from an older play cannot toast or hand the newer play to torrents', async () => {
  const older = deferred()
  const newer = deferred()
  DEBRID.resolve = async (_service, _key, _magnet, episode) => episode === 1 ? older.promise : newer.promise

  const firstPlay = streamDebrid(MAGNET, undefined, { episode: 1 })
  const latestPlay = streamDebrid(`magnet:?xt=urn:btih:${'b'.repeat(40)}`, undefined, { episode: 2 })
  newer.resolve({ hash: 'b'.repeat(40), name: 'Show', files: [playerFile('Show - 02.mkv')] })
  await latestPlay
  older.reject(failure('timeout', 'old request timed out'))

  assert.equal(await firstPlay, true, 'stale failures are handled silently')
  assert.equal(toast.shown.length, 0)
  assert.equal(files.value[0].name, 'Show - 02.mkv')
  assert.equal(debridPlayback.value, true, 'the obsolete failure cannot release ownership')
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
  let attempts = 0
  DEBRID.resolve = async () => { attempts++; throw failure('timeout', 'request timed out after 30000ms') }
  assert.equal(await streamDebrid(MAGNET), false)
  assert.equal(attempts, 2, 'a timeout gets one bounded resolve retry before the click gives up')
  assert.equal(debridAvailability.value.has(HASH), false, 'a timeout is not an answer about the release')
  assert.match(toast.shown[0].description, /timed out/)
})

test('a resolve timeout that heals on the bounded retry plays without another click', async () => {
  let attempts = 0
  DEBRID.resolve = async () => {
    if (++attempts === 1) throw failure('timeout', 'request timed out after 10000ms')
    return { hash: HASH, name: 'Show', files: [playerFile()] }
  }
  assert.equal(await streamDebrid(MAGNET), true)
  assert.equal(attempts, 2)
  assert.equal(files.value.length, 1)
  assert.equal(toast.shown.length, 0)
})

// --- the resolved link is probed before the play is trusted ---
// The live failure this pins: a resolve succeeded in 707ms and handed back a link whose
// CDN node never sent a single byte. "Cached" describes the service's storage, not the
// one host the link points at — and the link cannot be exchanged for a fresh one, the
// service pins one URL per (torrent, file). So the link is asked for two bytes the moment
// it exists, and a dead one fails the play fast, into the same fallback ladder every
// other resolve failure already takes — instead of a spinner that never ends.

test('a resolved link that never answers falls back to torrents instead of spinning', async () => {
  probeAnswers = [{ ok: false, status: 502 }, { ok: false, status: 502 }]
  assert.equal(await streamDebrid(MAGNET), false, 'unhandled: the torrent client takes it')
  assert.equal(files.value.length, 0, 'the player must not be left holding files that will never play')
  assert.match(toast.shown[0].description, /not answering/)
  assert.equal(probed.length, 2, 'one retry: a single flap is not worth abandoning the stream over')
  await until(() => forgotten.length === 1, 'the dead direct link was not evicted from the host cache')
  assert.deepEqual(forgotten[0], ['torbox', 'k', HASH])
}, 10_000)

test('in only mode a dead link stops and says so, fast, instead of spinning forever', async () => {
  configure({ mode: 'only' })
  probeAnswers = [{ ok: false, status: 403 }, { ok: false, status: 403 }]
  assert.equal(await streamDebrid(MAGNET), true, 'handled: only mode never falls back')
  assert.equal(files.value.length, 0)
  assert.match(toast.shown[0].description, /not answering/)
}, 10_000)

test('a link that flaps once and then answers still plays', async () => {
  probeAnswers = [{ ok: false, status: 502 }, { ok: true, status: 206 }]
  assert.equal(await streamDebrid(MAGNET), true)
  assert.equal(files.value.length, 1, 'the play went through; the flap was weather')
  assert.equal(toast.shown.length, 0)
}, 10_000)

test('the probe asks the file the resolve picked, not whichever file came first', async () => {
  // pack files land on different CDN nodes; the files come back in torrent order
  DEBRID.resolve = async () => ({
    hash: HASH,
    name: 'Pack',
    files: [playerFile('Show - 01.mkv'), playerFile('Show - 02.mkv')],
    target: '/Show - 02.mkv'
  })
  await streamDebrid(MAGNET, undefined, { episode: 2 })
  assert.deepEqual(probed, ['https://cdn.test/Show - 02.mkv'])
})

test('a dying stream can be routed again from the top, exactly as it was played', async () => {
  await streamDebrid(MAGNET, undefined, { episode: 1 })
  const dispatched = []
  globalThis.window = { dispatchEvent: event => dispatched.push(event) }
  try {
    assert.equal(replayDebridPlayback(), true)
    assert.equal(dispatched[0].type, 'add')
    assert.equal(dispatched[0].detail.torrentID, MAGNET)
    assert.deepEqual(dispatched[0].detail.search, { episode: 1 }, 'the same episode, so the same file comes out of the pack')
  } finally {
    delete globalThis.window
  }
})

test('answers and release names from the watch reach the stores', async () => {
  DEBRID.watchAvailability = async (service, apiKey, hashes, requestId) => {
    DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached', name: '[Group] Show 01-12', requestId } })
  }
  await checkDebridAvailability([HASH])
  await settled()
  assert.equal(debridAvailability.value.get(HASH), Availability.CACHED)
  assert.equal(debridReleaseNames.value.get(HASH), '[Group] Show 01-12', 'the service knows the real name, the source often does not')
  cancelDebridAvailability()
})

test('release names ride along on answers and update in place', async () => {
  DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached', name: 'Old name' } })
  await settled()
  assert.equal(debridReleaseNames.value.get(HASH), 'Old name')
  DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached', name: 'New name' } })
  await settled()
  assert.equal(debridReleaseNames.value.get(HASH), 'New name')
  assert.equal(debridAvailability.value.get(HASH), Availability.CACHED)
})

/** The queue window the store writes are collected into, plus room to fire. */
const settled = () => new Promise(resolve => setTimeout(resolve, QUEUE_WINDOW + 20))

test('answers pushed while a check is still running badge the list as they land', async () => {
  assert.ok(DEBRID.publishEvent, 'the module subscribes to the event channel at import')
  DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached' } })
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
    DEBRID.publishEvent({ type: 'availability', data: { hash, state: 'cached' } })
    await new Promise(resolve => setTimeout(resolve, 0)) // a task apiece, as the host delivers them
  }
  await settled()
  stop()
  assert.equal(writes, 1, `three answers must cost one render, took ${writes}`)
  for (const hash of hashes) assert.equal(debridAvailability.value.get(hash), Availability.CACHED)
})

test('an unknown state clears a badge rather than painting a wrong one', async () => {
  DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached' } })
  await settled()
  DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'nonsense from a future service' } })
  await settled()
  assert.equal(debridAvailability.value.has(HASH), false)
})

test('checking events drive the badges-still-filling-in store', async () => {
  DEBRID.publishEvent({ type: 'checking', data: { active: true } })
  assert.equal(get(debridChecking), 1)
  DEBRID.publishEvent({ type: 'checking', data: { active: false } })
  assert.equal(get(debridChecking), 0)
})

test('an outage is said once, and an answer re-arms the toast', async () => {
  toast.shown.length = 0
  DEBRID.publishEvent({ type: 'outage', data: { kind: 'timeout', message: 'TorBox is not answering' } })
  DEBRID.publishEvent({ type: 'outage', data: { kind: 'timeout', message: 'TorBox is not answering' } })
  assert.equal(toast.shown.length, 1, 'a watch retries on its own; a toast per retry would be its own kind of broken')
  // an answer means the service is talking again, so the next silence is news
  DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached' } })
  DEBRID.publishEvent({ type: 'outage', data: { kind: 'timeout', message: 'quiet again' } })
  assert.equal(toast.shown.length, 2)
  await settled()
})

test('badges from a watch that outlived its account are dropped', async () => {
  let leak = null
  DEBRID.watchAvailability = async (service, apiKey, hashes, requestId) => {
    leak = () => DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached', requestId } })
  }
  await checkDebridAvailability([HASH])
  configure({ service: 'realdebrid', key: 'other' }) // the user switched accounts mid-watch
  leak()
  await settled()
  assert.equal(debridAvailability.value.size, 0, "badging a new account with the old account's answers is worse than no badges")
})

test('switching accounts stops the watch in the core', async () => {
  let cancels = 0
  DEBRID.cancelAvailability = () => { cancels++ }
  configure({ service: 'realdebrid', key: 'other' })
  assert.ok(cancels >= 1, 'the core must not keep asking about a list for an account that is gone')
})

test('a slower old watch cannot repaint after a newer one took over', async () => {
  const newerHash = 'b'.repeat(40)
  const watches = []
  DEBRID.watchAvailability = async (service, apiKey, hashes, requestId) => { watches.push(requestId) }
  await checkDebridAvailability([HASH])
  await checkDebridAvailability([newerHash])
  assert.equal(typeof watches[0], 'number', 'the host needs an opaque request identity, never the API key')
  DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached', name: 'Old list', requestId: watches[0] } })
  DEBRID.publishEvent({ type: 'availability', data: { hash: newerHash, state: 'cached', name: 'New list', requestId: watches[1] } })
  await settled()
  assert.equal(debridAvailability.value.has(HASH), false, 'late answers do not repaint a list the user left')
  assert.equal(debridAvailability.value.get(newerHash), Availability.CACHED)
  assert.equal(debridReleaseNames.value.get(newerHash), 'New list')
  cancelDebridAvailability()
})

test('queued badge events are discarded when the account changes', async () => {
  DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached' } })
  configure({ service: 'realdebrid', key: 'other' })
  await settled()
  assert.equal(debridAvailability.value.has(HASH), false, 'an event from the old account must not land after its badges were cleared')
})

test('queued badge events are discarded when a newer results list takes over', async () => {
  const newerHash = 'b'.repeat(40)
  DEBRID.publishEvent({ type: 'availability', data: { hash: HASH, state: 'cached' } })
  await checkDebridAvailability([newerHash])
  await settled()
  assert.equal(debridAvailability.value.has(HASH), false, 'a late render batch must not badge a list the user left')
})

test('a release with no hash cannot silence the whole list', async () => {
  // one source listing an entry it has no info hash for used to cross the seam as a null
  // in a typed array, where the host refused the call outright: every badge on the screen
  // stayed empty, and the failure said nothing about any release so nothing was said at all
  let asked = null
  DEBRID.watchAvailability = async (service, apiKey, hashes) => { asked = hashes }
  await checkDebridAvailability([HASH, undefined, null, '', 'b'.repeat(40)])
  assert.deepEqual(asked, [HASH, 'b'.repeat(40)], 'the releases that do have a hash are still asked about')
  cancelDebridAvailability()

  // and a list with nothing askable in it costs no watch at all, and stops the old one
  asked = null
  let cancels = 0
  DEBRID.cancelAvailability = () => { cancels++ }
  await checkDebridAvailability([undefined, null])
  assert.equal(asked, null)
  assert.ok(cancels >= 1, 'the old watch described a list that is gone')
})

test('a watch that fails to start still tells the user once', async () => {
  DEBRID.watchAvailability = async () => { throw new TypeError('invalid args for command debrid_watch_availability') }
  toast.shown.length = 0
  await checkDebridAvailability([HASH])
  cancelDebridAvailability()
  assert.equal(toast.shown.length, 1, 'missing badges must never be indistinguishable from nothing being cached')
  assert.match(toast.shown[0].description, /invalid args/)
})

test('nothing is asked while offline, or with cache checking turned off', async () => {
  let asked = 0
  DEBRID.watchAvailability = async () => { asked++ }

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
