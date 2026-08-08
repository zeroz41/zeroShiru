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
import { DebridNotCachedError } from '@/modules/debrid/service.js'
import { routeDebrid } from '@/modules/debrid/route.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

// register new services here, stubs stay hidden from the settings menu until
// their `available` flag is flipped after being implemented and tested
export const debridServices = Object.fromEntries([RealDebrid, AllDebrid, TorBox, Premiumize].filter(Service => Service.available).map(Service => [Service.id, Service]))

const MAX_REMEMBERED = 300

// user facing messages for the routing policy's blocked outcomes
const blockedMessages = {
  key: () => 'Debrid only mode is on but no API key is set. Add your key in the debrid settings or disable debrid only mode.',
  offline: () => 'Shiru is currently offline, so ' + serviceTitle() + ' cannot be reached.',
  source: () => 'This source only provides a torrent file which debrid cannot resolve yet. Pick a different release or disable debrid only mode.'
}

/** @type {import('@/modules/debrid/service.js').default | null} */
let service = null
let serviceKey = null

/** Whether a debrid service is selected and has an API key. */
export const debridEnabled = derived(settings, value => Boolean(debridServices[value.debridService] && value.debridApiKey))

/** Lowercase info hashes known to play instantly on the configured service. */
export const debridCachedHashes = writable(new Set())

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
  const debridOnly = Boolean(debridServices[settings.value.debridService]) && settings.value.debridMode === 'only'
  const route = routeDebrid({
    torrentID,
    hash,
    serviceSelected: Boolean(debridServices[settings.value.debridService]),
    serviceReady: Boolean(getService()),
    offline: status.value === 'offline',
    mode: settings.value.debridMode
  })
  if (route.action === 'torrent') return false
  if (route.action === 'block') {
    toast.error('Debrid', { description: blockedMessages[route.reason]() })
    return true
  }
  try {
    files.set(await resolveDebridFiles(route.id, search))
    return true
  } catch (error) {
    if (error instanceof DebridNotCachedError) {
      debug(`Torrent not cached: ${error.message}`)
      if (!debridOnly) {
        toast('Debrid', { description: 'Not cached on ' + serviceTitle() + ', streaming via torrent instead.' })
        return false
      }
      toast.error('Debrid', { description: 'This torrent is not cached on ' + serviceTitle() + '. Pick a different release or disable debrid only mode.' })
    } else {
      debug('Debrid resolve failed:', error)
      if (!debridOnly) {
        toast.warning('Debrid Error', { description: `${error.message || error}\nStreaming via torrent instead.` })
        return false
      }
      toast.error('Debrid Error', { description: '' + (error.message || error) })
    }
    return true // handled, only mode never falls back to the torrent client
  }
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
  rememberHash(resolved.hash)
  return Promise.all(resolved.files.map(async file => ({
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

let lastRefresh = 0
/**
 * Updates the cached hash set from remembered resolves and, at most once a
 * minute, the list of torrents already downloaded on the account.
 */
export function refreshDebridCache () {
  const service = getService()
  if (!service) return
  const remembered = Object.keys(cache.getEntry(caches.GENERAL, 'debridResolvedHashes')?.[serviceId()] || {})
  if (remembered.length) debridCachedHashes.update(set => new Set([...set, ...remembered]))
  if (Date.now() - lastRefresh < 60_000 || status.value === 'offline') return
  lastRefresh = Date.now()
  service.listCachedHashes().then(hashes => {
    debridCachedHashes.update(set => new Set([...set, ...hashes]))
  }).catch(error => {
    lastRefresh = 0
    debug('Failed to list debrid torrents:', error)
  })
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

/** Remembers a successfully resolved hash per service so results can be badged instantly. */
function rememberHash (hash) {
  debridCachedHashes.update(set => new Set([...set, hash]))
  cache.setEntry(caches.GENERAL, 'debridResolvedHashes', (current = {}) => {
    const hashes = { ...(current[serviceId()] || {}), [hash]: Date.now() }
    const pruned = Object.fromEntries(Object.entries(hashes).sort(([, a], [, b]) => b - a).slice(0, MAX_REMEMBERED))
    return { ...current, [serviceId()]: pruned }
  })
}

async function sha1hex (data) {
  const buffer = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(data))
  return Array.from(new Uint8Array(buffer)).map(byte => byte.toString(16).padStart(2, '0')).join('')
}
