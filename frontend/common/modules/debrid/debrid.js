// The debrid surface the UI talks to. Everything that talks HTTP — providers, availability
// memory, the account listing, rate limits, pack picking — lives in the Rust core behind
// DEBRID; this module holds the stores the UI renders and what to say when a release cannot
// be played.
import { files } from '@/components/MediaHandler.svelte'
import { settings } from '@/modules/settings.js'
import { status } from '@/modules/networking.js'
import { writable } from 'simple-store-svelte'
import { derived } from 'svelte/store'
import { toast } from 'svelte-sonner'
import { DEBRID } from '@/modules/bridge.js'
import { Availability, describeAvailability, normalizeAvailability, outageNotice } from '@/modules/debrid/availability.js'
import { routeDebrid, debridKey } from '@/modules/debrid/route.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

/** The services the host offers, keyed by id. Plain data, inlined by the host at startup. */
const debridServices = Object.fromEntries(DEBRID.services.map(service => [service.id, service]))

/** Selectable services for the settings menu, as plain data. */
export const debridOptions = DEBRID.services.map(({ id, title }) => ({ id, title }))

/**
 * The service description for an id, or null.
 * @param {string} [id]
 */
function debridService (id) {
  return debridServices[id] || null
}

const REFRESH_INTERVAL = 60_000

// how long before asking again about releases a check could not answer, and how far that backs
// off while it keeps not answering. Without it a bad minute leaves a results list half badged
const RETRY_DELAY = 10_000
const MAX_RETRY_DELAY = 4 * 60_000

/** What the user is told when the routing policy blocks playback. */
const blockedMessages = {
  key: () => 'Debrid only mode is on but no API key is set. Add your key in the debrid settings or disable debrid only mode.',
  offline: () => 'zeroShiru is currently offline, so ' + serviceTitle() + ' cannot be reached.',
  source: () => 'This source only provides a torrent file which debrid cannot resolve yet. Pick a different release or disable debrid only mode.'
}

/**
 * The service and key calls are made with, or null when debrid is not configured.
 * @param {any} [value] - Settings to read, defaulting to the current ones.
 */
function account (value = settings.value) {
  const service = debridService(value.debridService)
  const apiKey = debridKey(value)
  return service && apiKey ? { id: service.id, apiKey, service } : null
}

/** The configured account as one string, so a change is a comparison. */
let serviceKey = null
let lastRefresh = 0

/** Whether a debrid service is selected and has an API key. */
export const debridEnabled = derived(settings, value => Boolean(account(value)))

/** How playback is routed right now, or null when no service is selected. The UI reads this to describe the active transport. */
export const debridTransport = derived(settings, value => {
  const service = debridService(value.debridService)
  if (!service) return null
  const only = value.debridMode === 'only'
  return {
    title: service.title,
    only,
    checksAddMagnets: service.check_adds_magnets,
    label: only ? 'Debrid Only' : 'Debrid First',
    description: only
      ? `Debrid Only: playback always uses ${service.title}, torrents never start.`
      : `Debrid First: releases cached on ${service.title} stream from it, anything uncached falls back to torrents.`
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
 * Whether debrid owns what the player is showing. Set the moment playback is routed rather than
 * once it resolves, since the player opens straight away and must not look like a torrent.
 */
export const debridPlayback = writable(false)

// switching service or key takes effect immediately: drop the badges, which described a
// different account. The core keeps its own memory per (service, key), so nothing else to do
settings.subscribe(value => {
  const key = `${value.debridService}:${debridKey(value)}`
  if (serviceKey !== null && serviceKey !== key) {
    lastRefresh = 0
    cancelDebridAvailability()
    debridAvailability.set(new Map())
    debridReleaseNames.set(new Map())
  }
  serviceKey = key
})

// answers pushed by a check while it is still running, so a probing service badges the list as
// it goes instead of all at once when the sweep ends
DEBRID.onAvailability((hash, state) => queueAvailability(hash, normalizeAvailability(state)))

/** Validates the configured service and API key, used by the settings test button. */
export async function testDebrid () {
  const current = account()
  if (!current) throw new Error('No debrid service configured')
  if (status.value === 'offline') throw new Error(`zeroShiru is currently offline, so ${serviceTitle()} cannot be reached`)
  return DEBRID.validate(current.id, current.apiKey)
}

/**
 * What a failed call proves about a release, or null when it proves nothing. A timeout or a rate
 * limit describes the moment, not the release, so it leaves it unknown and re-checkable.
 * @param {any} error - A host failure `{ kind, message }`, or any thrown value.
 */
function provenAvailability (error) {
  if (error?.kind === 'not-cached') return Availability.AVAILABLE
  if (error?.kind === 'unavailable') return Availability.UNAVAILABLE
  return null
}

/**
 * What to show the user for a failure, whether it came from the host or from here.
 * @param {any} error
 */
function reason (error) {
  return error?.message || String(error)
}

/**
 * Streams a torrent through the configured debrid service. Returns true when playback was
 * handled, false to fall back to torrents. Routing policy lives in route.js.
 * @param {string} torrentID - Magnet URI, info hash, or .torrent link.
 * @param {string} [hash] - Info hash when known.
 * @param {{ episode?: number }} [search] - Playback context, for picking the right file in packs.
 */
export async function streamDebrid (torrentID, hash, search) {
  const route = routeDebrid({
    torrentID,
    hash,
    serviceSelected: Boolean(debridService(settings.value.debridService)),
    serviceReady: Boolean(account()),
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
    if (error?.kind === 'rejected') {
      debug(`Release does not contain the requested episode: ${reason(error)}`)
      toast.error('Wrong Release', { description: reason(error) })
      return handOver(true)
    }
    // playback is the most authoritative answer there is, worth more than the badge
    const proven = provenAvailability(error)
    if (proven) {
      debug(`${serviceTitle()} cannot stream this release: ${reason(error)}`)
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
        toast.warning('Debrid Error', { description: `${reason(error)}\nStreaming via torrent instead.` })
        return handOver(false)
      }
      toast.error('Debrid Error', { description: reason(error) })
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
 * Resolves a magnet to player ready file objects shaped like the torrent client's. The core
 * picks the episode out of a pack, drops anything not streamable over HTTPS, and shapes the
 * files with the shared watch key.
 * @param {string} torrentID - Magnet URI or info hash.
 * @param {{ episode?: number }} [search]
 */
export async function resolveDebridFiles (torrentID, search) {
  const current = account()
  if (!current) throw new Error('No debrid service configured')
  const episode = Number(search?.episode)
  const resolved = await DEBRID.resolve(current.id, current.apiKey, torrentID, Number.isFinite(episode) ? episode : undefined)
  // playing it proves the service holds it, which is the best answer there is
  publishAvailability([[resolved.hash, Availability.CACHED]])
  return resolved.files
}

/** Refreshes what the account itself says, which is free. One request a minute at most. */
export function refreshDebridAvailability () {
  const current = account()
  if (!current) return
  if (Date.now() - lastRefresh < REFRESH_INTERVAL || status.value === 'offline') return
  lastRefresh = Date.now()
  DEBRID.listAvailability(current.id, current.apiKey).then(known => {
    if (isCurrent(current)) publish(known)
  }).catch(error => {
    lastRefresh = 0
    debug('Failed to list debrid torrents:', error)
  })
}

/**
 * Whether answers still describe the configured account. A request in flight outlives a settings
 * change, and badging a new account with the old one's answers is worse than no badges at all.
 * @param {{ id: string, apiKey: string }} used
 */
function isCurrent (used) {
  return serviceKey === `${used.id}:${used.apiKey}`
}

/** @type {ReturnType<typeof setTimeout> | null} A retry waiting to ask about what went unanswered. */
let retry = null
let retryDelay = RETRY_DELAY

/**
 * The hashes out of a results list that a service can actually be asked about. A source is
 * free to list a release it has no info hash for — a link to a torrent file, an entry whose
 * feed left the field out — and those are not questions. They used to cross the host seam as
 * nulls in a typed array, where one of them failed the whole call and left every badge on the
 * screen empty, silently, because the failure said nothing about any release.
 * @param {(string | undefined | null)[]} hashes
 * @returns {string[]}
 */
function askable (hashes) {
  const asked = (hashes || []).filter(hash => typeof hash === 'string' && hash)
  if (asked.length !== (hashes?.length ?? 0)) debug(`${(hashes?.length ?? 0) - asked.length} of ${hashes?.length} results have no hash to ask about`)
  return asked
}

/**
 * Asks the service about the releases on screen, so badges say what it can actually do with them
 * rather than only what the account has touched. Answers are remembered by the core, so browsing
 * the same show again is free. A service may answer only part of the list, so whatever is left is
 * asked about again on a backing off timer until it is done or the user moves on.
 * @param {(string | undefined | null)[]} results - Result hashes, most relevant first, since probing
 *   bites from the front. Entries without a hash are dropped rather than asked about.
 */
export async function checkDebridAvailability (results) {
  cancelDebridAvailability() // this list supersedes whatever the last one was waiting to retry
  const current = account()
  // every reason not to ask is said out loud: an empty badge column has looked the same
  // for all of them, and telling them apart from the outside is impossible
  const declined = !current
    ? 'no debrid account is configured'
    : !settings.value.debridCacheCheck
      ? 'cache checking is turned off in settings'
      : status.value === 'offline'
        ? 'the app believes it is offline'
        : null
  if (declined) return debug(`Not asking about ${results?.length ?? 0} releases: ${declined}`)
  const hashes = askable(results)
  if (!hashes.length) return debug('Not asking: none of the results carry an info hash')
  const pending = await DEBRID.unknownHashes(current.id, current.apiKey, hashes)
  if (!pending.length) return debug(`All ${hashes.length} releases already have an answer`)
  debug(`Asking ${serviceTitle()} about ${pending.length} of ${hashes.length} releases`)
  let busy = false
  debridChecking.update(count => count + 1)
  try {
    const answered = await DEBRID.checkAvailability(current.id, current.apiKey, hashes)
    busy = answered.busy // a check already owned the service, so this call only read memory back
    outageReported = false // it is talking again, so a later silence is worth saying out loud
    if (isCurrent(current)) publish(answered)
  } catch (error) {
    debug('Availability check failed:', error)
    reportOutage(error)
  } finally {
    debridChecking.update(count => count - 1)
  }
  if (!isCurrent(current)) return
  const left = await DEBRID.unknownHashes(current.id, current.apiKey, hashes)
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

/**
 * Whether the user has already been told the service went quiet. Said once per outage: the check
 * retries on a backing off timer, and a toast per attempt would be its own kind of broken.
 */
let outageReported = false

/** Says once that the service is not answering, so missing badges are not a silent mystery. */
function reportOutage (error) {
  if (outageReported) return
  const notice = outageNotice(error, serviceTitle())
  if (!notice) return
  outageReported = true
  toast.error(notice.title, { description: notice.description, duration: 12_000 })
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
 * Publishes one reply from the core: the answers it carries, and any release names that rode
 * along with them for free.
 * @param {{ answers?: Record<string, string>, names?: Record<string, string> }} reply
 */
function publish (reply) {
  publishAvailability(Object.entries(reply?.answers || {}))
  const names = Object.entries(reply?.names || {})
  if (names.length !== debridReleaseNames.value.size) debridReleaseNames.set(new Map(names))
}

/**
 * Records one answer the app proved for itself, in both the core's memory and the badges.
 * @param {string} magnetOrHash
 * @param {string} state - An `Availability` value.
 */
function recordAvailability (magnetOrHash, state) {
  const hash = /[a-f\d]{40}/i.exec(magnetOrHash)?.[0]?.toLowerCase()
  if (!hash) return
  const current = account()
  if (current) DEBRID.remember(current.id, current.apiKey, hash, state)
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
