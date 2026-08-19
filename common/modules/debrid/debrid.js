import { files } from '@/components/MediaHandler.svelte'
import { settings } from '@/modules/settings.js'
import { status } from '@/modules/networking.js'
import { videoRx, subRx, fontRx } from '@/modules/util.js'
import { anitomyscript } from '@/modules/anime/anime.js'
import { writable } from 'simple-store-svelte'
import { derived } from 'svelte/store'
import { toast } from 'svelte-sonner'
import DebridService, { availabilityFromError, secureFiles } from '@/modules/debrid/service.js'
import { pickPackFile, EpisodeNotInPackError } from '@/modules/debrid/pick.js'
import { toPlayerFile } from '@/modules/debrid/identity.js'
import { debridServices, debridService } from '@/modules/debrid/services.js'
import { Availability, describeAvailability } from '@/modules/debrid/availability.js'
import { routeDebrid, debridKey } from '@/modules/debrid/route.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

/** Selectable services for the settings menu, as plain data. */
export const debridOptions = Object.values(debridServices).map(Service => ({ id: Service.id, title: Service.title }))

/** Files worth resolving: the video, its subtitles, and the fonts those subtitles need. */
const playbackRx = new RegExp(`${videoRx.source}|${subRx.source}|${fontRx.source}`, 'i')

const REFRESH_INTERVAL = 60_000

// how long before asking again about releases a check could not answer, and how far that backs
// off while it keeps not answering. Without it a bad minute leaves a results list half badged
const RETRY_DELAY = 10_000
const MAX_RETRY_DELAY = 4 * 60_000

/** What the user is told when the routing policy blocks playback. */
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
export const debridEnabled = derived(settings, value => Boolean(debridService(value.debridService) && debridKey(value)))

/** How playback is routed right now, or null when no service is selected. The UI reads this to describe the active transport. */
export const debridTransport = derived(settings, value => {
  const Service = debridService(value.debridService)
  if (!Service) return null
  const only = value.debridMode === 'only'
  return {
    title: Service.title,
    only,
    checksAddMagnets: Service.checkAddsMagnets,
    label: only ? 'Debrid Only' : 'Debrid First',
    description: only
      ? `Debrid Only: playback always uses ${Service.title}, torrents never start.`
      : `Debrid First: releases cached on ${Service.title} stream from it, anything uncached falls back to torrents.`
  }
})

/**
 * What the service can do with each release, keyed by lowercase info hash. The only place the UI
 * reads cache state from; anything absent is unknown rather than uncached.
 * @type {import('simple-store-svelte').Writable<Map<string, string>>}
 */
export const debridAvailability = writable(new Map())

/** Availability checks in flight, so the UI can show that badges are still filling in. */
export const debridChecking = writable(0)

/**
 * The real name of each release the service has mentioned, keyed by lowercase info hash. Search
 * sources are free to invent a title — one replaces a multi file release's name with
 * `[Group] Show Dual Audio`, which says nothing about which episodes are inside — so the results
 * list judges a release by this name where there is one.
 * @type {import('simple-store-svelte').Writable<Map<string, string>>}
 */
export const debridReleaseNames = writable(new Map())

/**
 * Publishes any release names the service picked up while answering. They ride along on requests
 * the client already makes, so this costs nothing.
 * @param {import('@/modules/debrid/service.js').default} instance
 */
function publishReleaseNames (instance) {
  if (!current(instance) || instance.releaseNames.size === debridReleaseNames.value.size) return
  debridReleaseNames.set(new Map(instance.releaseNames))
}

/**
 * Whether debrid owns what the player is showing. Set the moment playback is routed rather than
 * once it resolves, since the player opens straight away and must not look like a torrent.
 */
export const debridPlayback = writable(false)

// switching service or key takes effect immediately: tear the old instance down and drop the
// badges, which described a different account
settings.subscribe(value => {
  const key = `${value.debridService}:${debridKey(value)}`
  if (serviceKey !== null && serviceKey !== key) {
    service?.destroy()
    service = null
    lastRefresh = 0
    cancelDebridAvailability()
    debridAvailability.set(new Map())
    debridReleaseNames.set(new Map())
  }
  serviceKey = key
})

function getService () {
  if (service) return service
  const Service = debridService(settings.value.debridService)
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
 * Streams a torrent through the configured debrid service. Returns true when playback was
 * handled, false to fall back to torrents. Routing policy lives in route.js.
 * @param {string} torrentID - Magnet URI, info hash, or .torrent link.
 * @param {string} [hash] - Info hash when known.
 * @param {{ episode?: number }} [search] - Playback context, for picking the right file in packs.
 */
export async function streamDebrid (torrentID, hash, search) {
  const serviceSelected = Boolean(debridService(settings.value.debridService))
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
    // the release provably lacks the episode: the torrent client holds the same files, so
    // falling back would spend a whole pack's bandwidth to play the wrong episode anyway
    if (error instanceof EpisodeNotInPackError) {
      debug(`Release does not contain the requested episode: ${error.message}`)
      toast.error('Wrong Release', { description: error.message })
      return handOver(true)
    }
    // playback is the most authoritative answer there is, worth more than the badge
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
    fileFilter: name => playbackRx.test(name),
    pickFile: Number.isFinite(episode) ? files => pickPackFile(files, episode, anitomyscript, { maxFiles: service.config.maxFiles }) : undefined
  })
  const secure = secureFiles(resolved.files, serviceTitle())
  if (secure.length !== resolved.files.length) debug(`Discarded ${resolved.files.length - secure.length} non-HTTPS links from ${serviceTitle()}`)
  // playing it proves the service holds it, which is the best answer there is
  recordAvailability(resolved.hash, Availability.CACHED)
  return Promise.all(secure.map(file => toPlayerFile(resolved, file)))
}

/** Refreshes what the account itself says, which is free. One request a minute at most. */
export function refreshDebridAvailability () {
  const active = getService()
  if (!active) return
  if (Date.now() - lastRefresh < REFRESH_INTERVAL || status.value === 'offline') return
  lastRefresh = Date.now()
  active.listAvailability().then(known => {
    for (const [hash, state] of known) active.remember(hash, state)
    if (current(active)) publishAvailability(known)
    publishReleaseNames(active)
  }).catch(error => {
    lastRefresh = 0
    debug('Failed to list debrid torrents:', error)
  })
}

/**
 * Whether answers from this instance still describe the configured account. A request in flight
 * outlives a settings change, and badging a new account with the old one's answers is worse than
 * no badges at all.
 * @param {import('@/modules/debrid/service.js').default} instance
 */
function current (instance) {
  return instance === service
}

/** @type {ReturnType<typeof setTimeout> | null} A retry waiting to ask about what went unanswered. */
let retry = null
let retryDelay = RETRY_DELAY

/**
 * Asks the service about the releases on screen, so badges say what it can actually do with them
 * rather than only what the account has touched. Answers are remembered, so browsing the same show
 * again is free. A service may answer only part of the list, so whatever is left is asked about
 * again on a backing off timer until it is done or the user moves on.
 * @param {string[]} hashes - Candidates, most relevant first, since probing bites from the front.
 */
export async function checkDebridAvailability (hashes) {
  cancelDebridAvailability() // this list supersedes whatever the last one was waiting to retry
  const active = getService()
  if (!active || !settings.value.debridCacheCheck || status.value === 'offline') return
  const pending = active.unknownHashes(hashes)
  if (!pending.length) return // everything here already has an answer
  // a check already running owns the service, so this call only reads back what is remembered
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
    publishReleaseNames(active)
  }
  if (!current(active)) return
  const left = active.unknownHashes(hashes)
  if (!left.length) {
    retryDelay = RETRY_DELAY
    return
  }
  // any progress means the service is willing to talk, so start over at the short wait. Only a
  // round that got nowhere backs off
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

function serviceTitle () {
  return debridService(settings.value.debridService)?.title || 'debrid'
}

/**
 * Records one answer in both the service's memory and the badges.
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
 * Collects answers arriving together into one store write, so a batch answer does not re-render
 * the list once per hash. A probing service answers slowly enough that each still lands alone.
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

