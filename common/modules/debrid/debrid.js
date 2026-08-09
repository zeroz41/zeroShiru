import { files } from '@/components/MediaHandler.svelte'
import { settings } from '@/modules/settings.js'
import { cache, caches } from '@/modules/cache.js'
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
import DebridService, { DebridNotCachedError, secureFiles } from '@/modules/debrid/service.js'
import { routeDebrid } from '@/modules/debrid/route.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

// register new services here, implementation templates stay hidden from the settings
// menu until their `available` flag is flipped after being implemented and tested.
// This registry is the only place that touches service classes, everything else in
// the app goes through the stores and functions exported below.
const debridServices = Object.fromEntries([RealDebrid, AllDebrid, TorBox, Premiumize].filter(Service => Service.available).map(Service => [Service.id, Service]))

/** Selectable services for the settings menu, as plain data. */
export const debridOptions = Object.values(debridServices).map(Service => ({ id: Service.id, title: Service.title }))

const MAX_REMEMBERED = 300
const REFRESH_INTERVAL = 60_000

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
export const debridEnabled = derived(settings, value => Boolean(debridServices[value.debridService] && value.debridApiKey))

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

/** Lowercase info hashes known to play instantly on the configured service. */
export const debridCachedHashes = writable(new Set())

/** Cache checks in flight, so the UI can show that badges are still filling in. */
export const debridChecking = writable(0)

/**
 * Whether debrid owns what the player is showing. Set the moment playback is routed to a
 * service, before the resolve that takes a few seconds, because the player opens straight
 * away and must not look like a torrent while it waits. Cleared whenever playback goes to
 * the torrent client instead.
 */
export const debridPlayback = writable(false)

settings.subscribe(value => {
  const key = `${value.debridService}:${value.debridApiKey}`
  if (serviceKey !== null && serviceKey !== key) {
    service?.destroy()
    service = null
    lastRefresh = 0
    debridCachedHashes.set(new Set())
  }
  serviceKey = key
})

function getService () {
  if (service) return service
  const Service = debridServices[settings.value.debridService]
  if (!Service || !settings.value.debridApiKey) return null
  debug(`Initializing debrid service ${Service.title}`)
  service = new Service(settings.value.debridApiKey)
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
    if (error instanceof DebridNotCachedError) {
      debug(`Torrent not cached: ${error.message}`)
      forgetHash(route.id) // the badge was wrong, or it aged out of the cache
      if (!debridOnly) {
        toast('Debrid', { description: 'Not cached on ' + serviceTitle() + ', streaming via torrent instead.' })
        return handOver(false)
      }
      toast.error('Debrid', { description: 'This torrent is not cached on ' + serviceTitle() + '. Pick a different release or disable debrid only mode.' })
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
  // playing it is the most authoritative cache answer there is, so no probe repeats it
  service.remember(resolved.hash, true)
  rememberHashes([resolved.hash])
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
 * Updates the cached hash set from remembered resolves and, at most once a
 * minute, the list of torrents already downloaded on the account.
 */
export function refreshDebridCache () {
  const service = getService()
  if (!service) return
  const remembered = Object.keys(cache.getEntry(caches.GENERAL, 'debridResolvedHashes')?.[serviceId()] || {})
  if (remembered.length) {
    debridCachedHashes.update(set => new Set([...set, ...remembered]))
    for (const hash of remembered) service.remember(hash, true) // never pay to re-check these
  }
  if (Date.now() - lastRefresh < REFRESH_INTERVAL || status.value === 'offline') return
  lastRefresh = Date.now()
  service.listCachedHashes().then(hashes => {
    debridCachedHashes.update(set => new Set([...set, ...hashes]))
    for (const hash of hashes) service.remember(hash, true)
  }).catch(error => {
    lastRefresh = 0
    debug('Failed to list debrid torrents:', error)
  })
}

/**
 * Fills in cache state for the releases the user is looking at, so badges reflect what the
 * service can actually stream rather than only what this account has touched before. The
 * service decides how: one batch call where its API offers a cache endpoint, capped probing
 * where it does not. Answers are remembered, so browsing the same show again is free.
 * @param {string[]} hashes - Candidate info hashes, most relevant first, the cap bites from the end.
 */
export async function probeDebridCache (hashes) {
  const service = getService()
  if (!service || !settings.value.debridCacheCheck || status.value === 'offline') return
  if (!service.unknownHashes(hashes).length) return // everything here already has an answer
  debridChecking.update(count => count + 1)
  try {
    const { cached } = await service.checkCached(hashes)
    if (cached.size) rememberHashes([...cached])
  } catch (error) {
    debug('Cache check failed:', error)
  } finally {
    debridChecking.update(count => count - 1)
  }
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

function serviceId () {
  return settings.value.debridService
}

function serviceTitle () {
  return debridServices[serviceId()]?.title || 'debrid'
}

/**
 * Drops a hash the service turned out not to hold, from the badge store, the persisted
 * list and the service's own memory. Without all three the next search would badge it
 * again from persistence, and playback would fail the same way a second time.
 * @param {string} magnetOrHash
 */
function forgetHash (magnetOrHash) {
  const hash = DebridService.parseHash(magnetOrHash)
  if (!hash) return
  service?.remember(hash, false)
  debridCachedHashes.update(set => {
    const next = new Set(set)
    next.delete(hash)
    return next
  })
  cache.setEntry(caches.GENERAL, 'debridResolvedHashes', (current = {}) => {
    const kept = { ...(current[serviceId()] || {}) }
    delete kept[hash]
    return { ...current, [serviceId()]: kept }
  })
}

/** Remembers hashes the service is known to hold, so results can be badged instantly. */
function rememberHashes (hashes) {
  debridCachedHashes.update(set => new Set([...set, ...hashes]))
  cache.setEntry(caches.GENERAL, 'debridResolvedHashes', (current = {}) => {
    const now = Date.now()
    const merged = { ...(current[serviceId()] || {}), ...Object.fromEntries(hashes.map(hash => [hash, now])) }
    const pruned = Object.fromEntries(Object.entries(merged).sort(([, a], [, b]) => b - a).slice(0, MAX_REMEMBERED))
    return { ...current, [serviceId()]: pruned }
  })
}

async function sha1hex (data) {
  const buffer = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(data))
  return Array.from(new Uint8Array(buffer)).map(byte => byte.toString(16).padStart(2, '0')).join('')
}
