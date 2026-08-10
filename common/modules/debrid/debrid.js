import { files } from '@/components/MediaHandler.svelte'
import { settings } from '@/modules/settings.js'
import { status } from '@/modules/networking.js'
import { videoRx, subRx } from '@/modules/util.js'
import { anitomyscript } from '@/modules/anime/anime.js'
import { writable } from 'simple-store-svelte'
import { derived } from 'svelte/store'
import { toast } from 'svelte-sonner'
import RealDebrid from '@/modules/debrid/realdebrid.js'
import AllDebrid from '@/modules/debrid/alldebrid.js'
import TorBox from '@/modules/debrid/torbox.js'
import Premiumize from '@/modules/debrid/premiumize.js'
import DebridService, { availabilityFromError, secureFiles } from '@/modules/debrid/service.js'
import { Availability, describeAvailability } from '@/modules/debrid/availability.js'
import { routeDebrid, debridKey } from '@/modules/debrid/route.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

// register new services here, in the order the settings menu should offer them. A service that
// is still being written stays hidden until its `available` flag is flipped. This registry is
// the only place that touches service classes, everything else in the app goes through the
// stores and functions exported below.
const debridServices = Object.fromEntries([AllDebrid, Premiumize, RealDebrid, TorBox].filter(Service => Service.available).map(Service => [Service.id, Service]))

/** Selectable services for the settings menu, as plain data. */
export const debridOptions = Object.values(debridServices).map(Service => ({ id: Service.id, title: Service.title }))

const REFRESH_INTERVAL = 60_000

// How long to wait before asking a service about the releases it did not manage to answer, and
// how far that wait backs off while it keeps not answering them. A probing service stops its
// sweep whenever the account or the connection is in no state to continue, which on a slow link
// is often, so without this a results list keeps whichever handful of badges it happened to get.
const RETRY_DELAY = 10_000
const MAX_RETRY_DELAY = 4 * 60_000

// user facing messages for the routing policy's blocked outcomes
const blockedMessages = {
  key: () => 'Debrid only mode is on but no API key is set. Add your key in the debrid settings or disable debrid only mode.',
  offline: () => 'Shiru is currently offline, so ' + serviceTitle() + ' cannot be reached.',
  source: () => 'This source only provides a torrent file which debrid cannot resolve yet. Pick a different release or disable debrid only mode.'
}

/** @type {import('@/modules/debrid/service.js').default | null} */
let service = null
let serviceKey = null
let lastRefresh = 0

/** Whether a debrid service is selected and has an API key. */
export const debridEnabled = derived(settings, value => Boolean(debridServices[value.debridService] && debridKey(value)))

/**
 * How playback is routed right now, or null when no debrid service is selected.
 * The single source the UI reads to describe the active transport.
 */
export const debridTransport = derived(settings, value => {
  const Service = debridServices[value.debridService]
  if (!Service) return null
  const only = value.debridMode === 'only'
  return {
    title: Service.title,
    only,
    label: only ? 'Debrid Only' : 'Debrid First',
    description: only
      ? `Debrid Only: playback always uses ${Service.title}, torrents never start.`
      : `Debrid First: releases cached on ${Service.title} stream from it, anything uncached falls back to torrents.`
  }
})

/**
 * What the configured service can do with each release, keyed by lowercase info hash.
 * The one place the UI reads cache state from; anything absent is simply unknown.
 * @type {import('simple-store-svelte').Writable<Map<string, string>>}
 */
export const debridAvailability = writable(new Map())

/** Availability checks in flight, so the UI can show that badges are still filling in. */
export const debridChecking = writable(0)

/**
 * Whether debrid owns what the player is showing. Set the moment playback is routed to a
 * service, before the resolve that takes a few seconds, because the player opens straight
 * away and must not look like a torrent while it waits. Cleared whenever playback goes to
 * the torrent client instead.
 */
export const debridPlayback = writable(false)

// Switching service, or editing the key of the one in use, takes effect immediately: the old
// instance is torn down and the badges are dropped, since they described a different account.
// The next call builds the new one.
settings.subscribe(value => {
  const key = `${value.debridService}:${debridKey(value)}`
  if (serviceKey !== null && serviceKey !== key) {
    service?.destroy()
    service = null
    lastRefresh = 0
    cancelDebridAvailability()
    debridAvailability.set(new Map())
  }
  serviceKey = key
})

function getService () {
  if (service) return service
  const Service = debridServices[settings.value.debridService]
  const apiKey = debridKey(settings.value)
  if (!Service || !apiKey) return null
  debug(`Initializing debrid service ${Service.title}`)
  service = new Service(apiKey)
  return service
}

/** Validates the configured service and API key, used by the settings test button. */
export async function testDebrid () {
  const service = getService()
  if (!service) throw new Error('No debrid service configured')
  if (status.value === 'offline') throw new Error(`Shiru is currently offline, so ${serviceTitle()} cannot be reached`)
  return service.validate()
}

/**
 * Attempts to stream a torrent through the configured debrid service.
 * Returns true when playback was handled, either with resolved files or a
 * final error in debrid only mode. Returns false to fall back to torrents.
 * The routing policy lives in route.js, debrid only never reaches the torrent client.
 * @param {string} torrentID - Magnet URI, info hash, or .torrent link.
 * @param {string} [hash] - Info hash when known.
 * @param {{ episode?: number }} [search] - Playback context for picking the right file in packs.
 */
export async function streamDebrid (torrentID, hash, search) {
  const serviceSelected = Boolean(debridServices[settings.value.debridService])
  const route = routeDebrid({
    torrentID,
    hash,
    serviceSelected,
    // only build the service once the selection alone cannot decide the outcome
    serviceReady: serviceSelected && Boolean(getService()),
    offline: status.value === 'offline',
    mode: settings.value.debridMode
  })
  if (route.action === 'torrent') return handOver(false)
  const debridOnly = route.only
  if (route.action === 'block') {
    toast.error('Debrid', { description: blockedMessages[route.reason]() })
    return handOver(true) // nothing plays, so nothing is owned
  }
  // claimed before the resolve, which takes seconds the player spends already open
  debridPlayback.set(true)
  try {
    files.set(await resolveDebridFiles(route.id, search))
    return true
  } catch (error) {
    // playback is the most authoritative answer there is, so whatever it just proved about
    // the release is worth more than the badge that sent the user here
    const proven = availabilityFromError(error)
    if (proven) {
      debug(`${serviceTitle()} cannot stream this release: ${error.message}`)
      recordAvailability(route.id, proven)
      const { description } = describeAvailability(proven, serviceTitle())
      if (!debridOnly) {
        toast('Debrid', { description: `${description}\nStreaming via torrent instead.` })
        return handOver(false)
      }
      toast.error('Debrid', { description: `${description}\nPick a different release or disable debrid only mode.` })
    } else {
      debug('Debrid resolve failed:', error)
      if (!debridOnly) {
        toast.warning('Debrid Error', { description: `${error.message || error}\nStreaming via torrent instead.` })
        return handOver(false)
      }
      toast.error('Debrid Error', { description: '' + (error.message || error) })
    }
    return handOver(true) // handled, only mode never falls back to the torrent client
  }
}

/**
 * Releases the player back to the torrent client and reports the routing outcome.
 * @param {boolean} handled - What streamDebrid returns to its caller.
 */
function handOver (handled) {
  debridPlayback.set(false)
  return handled
}

/**
 * Resolves a magnet to player ready file objects shaped like the torrent client's.
 * @param {string} torrentID - Magnet URI or info hash.
 * @param {{ episode?: number }} [search]
 */
export async function resolveDebridFiles (torrentID, search) {
  const service = getService()
  const episode = Number(search?.episode)
  const resolved = await service.resolve(torrentID, {
    fileFilter: name => videoRx.test(name) || subRx.test(name),
    pickFile: Number.isFinite(episode) ? files => pickEpisodeFile(files, episode) : undefined
  })
  const files = secureFiles(resolved.files, serviceTitle())
  if (files.length !== resolved.files.length) debug(`Discarded ${resolved.files.length - files.length} non-HTTPS links from ${serviceTitle()}`)
  // playing it proves the service holds it, which is the best answer there is
  recordAvailability(resolved.hash, Availability.CACHED)
  return Promise.all(files.map(async file => ({
    infoHash: resolved.hash,
    fileHash: await sha1hex(`${resolved.hash}:${file.name}:${file.size}`), // same key the torrent client uses, so watch progress is shared
    torrent_name: resolved.name,
    name: file.name,
    type: file.type,
    size: file.size,
    path: file.path,
    url: file.url,
    debrid: true
  })))
}

/**
 * Refreshes what the account itself says, which every service can answer for free: what it
 * holds streams instantly, what it is still fetching does not, what failed on it never will.
 * One request a minute at most.
 */
export function refreshDebridAvailability () {
  const active = getService()
  if (!active) return
  if (Date.now() - lastRefresh < REFRESH_INTERVAL || status.value === 'offline') return
  lastRefresh = Date.now()
  active.listAvailability().then(known => {
    for (const [hash, state] of known) active.remember(hash, state)
    if (current(active)) publishAvailability(known)
  }).catch(error => {
    lastRefresh = 0
    debug('Failed to list debrid torrents:', error)
  })
}

/**
 * Whether answers from this instance still describe the configured account. A request in flight
 * outlives a settings change — a probe sweep by seconds, a slow list by longer — and badging a
 * new account with the previous one's answers is worse than having no badges at all.
 * @param {import('@/modules/debrid/service.js').default} instance
 */
function current (instance) {
  return instance === service
}

/** @type {ReturnType<typeof setTimeout> | null} A retry waiting to ask about what went unanswered. */
let retry = null
let retryDelay = RETRY_DELAY

/**
 * Asks the service about the releases the user is looking at, so the badges say what it can
 * actually do with them rather than only what this account has touched before. The service
 * decides how: one batch call where its API offers a cache endpoint, a capped number of probes
 * where it does not. Answers are remembered, so browsing the same show again is free.
 *
 * A service is allowed to come back having answered only part of the list — a probing one stops
 * the moment the account or the link says it should — so whatever is still unanswered is asked
 * about again on a backing off timer until the list is done or the user moves on.
 * @param {string[]} hashes - Candidate info hashes, most relevant first, since probing bites from the front.
 */
export async function checkDebridAvailability (hashes) {
  cancelDebridAvailability() // this list supersedes whatever the last one was still waiting to retry
  const active = getService()
  if (!active || !settings.value.debridCacheCheck || status.value === 'offline') return
  const pending = active.unknownHashes(hashes)
  if (!pending.length) return // everything here already has an answer
  // a sweep already running owns the service, so this call only reads back what is remembered
  // and must not read its own lack of progress as the service refusing to answer
  const busy = active.sweeping
  debridChecking.update(count => count + 1)
  try {
    // badge each release as its answer lands rather than when the sweep ends, so a probing
    // service marks the list up as it goes instead of all at once a minute later
    await active.checkAvailability(hashes, { onAnswer: (hash, state) => { if (current(active)) queueAvailability(hash, state) } })
  } catch (error) {
    debug('Availability check failed:', error)
  } finally {
    debridChecking.update(count => count - 1)
  }
  if (!current(active)) return
  const left = active.unknownHashes(hashes)
  if (!left.length) {
    retryDelay = RETRY_DELAY
    return
  }
  // answering something means the service is willing to talk, so the next attempt starts over at
  // the short wait. Only a round that got nowhere backs off, which is what keeps a service that
  // is genuinely refusing from being asked every ten seconds for as long as the modal is open
  if (busy || left.length < pending.length) retryDelay = RETRY_DELAY
  else retryDelay = Math.min(retryDelay * 2, MAX_RETRY_DELAY)
  debug(`${left.length} of ${pending.length} releases unanswered, asking again in ${retryDelay}ms`)
  retry = setTimeout(() => checkDebridAvailability(hashes), retryDelay)
}

/** Drops a pending retry, for when the results it described are no longer on screen. */
export function cancelDebridAvailability () {
  if (retry) clearTimeout(retry)
  retry = null
}

/**
 * Picks the file for the requested episode out of a pack using the same
 * anitomy parsing the rest of the app relies on, largest file as fallback.
 * @param {{ id: number, path: string, size: number }[]} files
 * @param {number} episode
 */
async function pickEpisodeFile (files, episode) {
  const videoFiles = files.filter(({ path }) => videoRx.test(path))
  if (videoFiles.length <= 1) return videoFiles[0] || files[0]
  try {
    const parsed = await anitomyscript(videoFiles.map(({ path }) => path.split('/').pop()))
    const match = parsed?.findIndex(parse => Number(parse.episode_number) === episode)
    if (match >= 0) return videoFiles[match]
  } catch (error) {
    debug('Failed to parse pack file names:', error)
  }
  return videoFiles.sort((a, b) => b.size - a.size)[0]
}

function serviceTitle () {
  return debridServices[settings.value.debridService]?.title || 'debrid'
}

/**
 * Records one answer in both the service's memory and the badges, so the next search does not
 * repeat a check playback has already settled.
 * @param {string} magnetOrHash
 * @param {string} state - An `Availability` value.
 */
function recordAvailability (magnetOrHash, state) {
  const hash = DebridService.parseHash(magnetOrHash)
  if (!hash) return
  service?.remember(hash, state)
  publishAvailability([[hash, state]])
}

/** @type {Map<string, string> | null} Answers waiting to reach the store. */
let queued = null

/**
 * Collects answers arriving in one go into a single store write. A batch service answers a
 * whole results list inside one loop, and writing per hash would re-render the list as many
 * times; a probing service answers once every few seconds, so each still lands on its own.
 * @param {string} hash
 * @param {string} state
 */
function queueAvailability (hash, state) {
  if (!queued) {
    queued = new Map()
    queueMicrotask(() => {
      const answers = queued
      queued = null
      publishAvailability(answers)
    })
  }
  queued.set(hash, state)
}

/**
 * Publishes answers to the UI in one write.
 * @param {Iterable<[string, string]>} answers
 */
function publishAvailability (answers) {
  const entries = [...answers]
  if (!entries.length) return
  debridAvailability.update(known => {
    const next = new Map(known)
    for (const [hash, state] of entries) {
      if (state === Availability.UNKNOWN) next.delete(hash)
      else next.set(hash, state)
    }
    return next
  })
}

async function sha1hex (data) {
  const buffer = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(data))
  return Array.from(new Uint8Array(buffer)).map(byte => byte.toString(16).padStart(2, '0')).join('')
}
