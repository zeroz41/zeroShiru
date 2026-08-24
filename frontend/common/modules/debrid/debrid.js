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
import { probeTarget, verifiedStream } from '@/modules/playback/probe.js'
import { routeDebrid, debridKey } from '@/modules/debrid/route.js'
import { withDeadline } from '@/modules/lib/deadline.js'
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
/** The renderer never trusts an IPC call to finish eventually. The Rust provider has its
 * own budgets, but a wedged command/bridge is outside those and previously left the play
 * request (and its single-flight key) pending forever. */
export const DEBRID_PLAY_DEADLINE_MS = 30_000
const PLAY_DEADLINE = Symbol('debrid play deadline')

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
/** Identifies the latest results list; older requests may finish but cannot repaint or retry. */
let availabilityGeneration = 0
/** Identifies the latest playback intent; older resolves may finish but cannot own the player. */
let playbackGeneration = 0
/** @type {Map<string, string> | null} Answers waiting to reach the store. */
let queued = null
let queueTimer = null

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

/** User-facing progress for the gap before a file exists. A spinner without a verb looks
 * exactly like a dead click, especially when the cover itself has not painted yet. */
export const debridStatus = writable(null)

/**
 * A hard renderer-side edge around host work. Late host completion is harmless: playback
 * generations already prevent it from owning files, navigation, or fallbacks.
 * @template T
 * @param {Promise<T>} work
 * @param {{ ms?: number, schedule?: (callback: () => void, delay: number) => any, cancel?: (timer: any) => void }} [options]
 * @returns {Promise<T>}
 */
export async function boundedDebridPlay (work, { ms = DEBRID_PLAY_DEADLINE_MS, schedule, cancel } = {}) {
  const result = await withDeadline(Promise.resolve(work), { ms, schedule, cancel, late: () => PLAY_DEADLINE })
  if (result === PLAY_DEADLINE) {
    throw { kind: 'timeout', message: `${serviceTitle()} did not finish preparing this stream within ${Math.round(ms / 1_000)} seconds.` } // eslint-disable-line no-throw-literal
  }
  return result
}

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

// everything the watch reports arrives here: answers as they land, whether a round of
// asking is on the wire, and outages. The core owns the whole retry lifecycle; this side
// only paints. Every event carries the request id of the watch that produced it, and a
// watch may keep reporting after the user switches service or key — without the identity
// check it could repaint the new account with the old one's badges.
DEBRID.onEvent(({ type, data } = {}) => {
  if (data?.requestId != null && data.requestId !== availabilityGeneration) return
  if (type === 'availability') {
    outageReported = false // it is answering, so a later silence is worth saying out loud
    queueAvailability(data.hash, normalizeAvailability(data.state), data.name)
  } else if (type === 'checking') {
    debridChecking.set(data.active ? 1 : 0)
  } else if (type === 'outage') {
    reportOutage(data)
  }
})

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
 * @param {{ current?: () => boolean }} [intent] - Caller ownership check; false means a newer play won.
 */
export async function streamDebrid (torrentID, hash, search, { current = () => true } = {}) {
  const generation = ++playbackGeneration
  const active = () => generation === playbackGeneration && current()
  const route = routeDebrid({
    torrentID,
    hash,
    serviceSelected: Boolean(debridService(settings.value.debridService)),
    serviceReady: Boolean(account()),
    offline: status.value === 'offline',
    mode: settings.value.debridMode
  })
  if (route.action === 'torrent') return handOver(false, active)
  const debridOnly = route.only
  if (route.action === 'block') {
    if (active()) toast.error('Debrid', { description: blockedMessages[route.reason]() })
    return handOver(true, active) // nothing plays, so nothing is owned
  }
  // remembered so a stream that dies under the player can be routed again from the top,
  // where a dead link now fails fast into this function's own fallback ladder
  lastPlay = { torrentID, hash, search }
  // claimed before the resolve, which takes seconds the player spends already open
  debridPlayback.set(true)
  debridStatus.set(`Resolving cached release with ${serviceTitle()}…`)
  try {
    const { files: resolved, verified } = await boundedDebridPlay(resolveDebridFiles(route.id, search, { current: active }))
    if (!active()) return true
    // the player takes the files immediately — the probe overlaps filename parsing and
    // episode matching, so a healthy link costs nothing here. Holding the link back until
    // the probe has finished sounds tidier and simply adds the probe's whole duration to
    // every start; see the warning in playback/probe.js before trying it again.
    debridStatus.set(`Opening and checking the ${serviceTitle()} stream…`)
    files.set(resolved)
    const verdict = await verified
    if (!active()) return true
    if (!verdict.alive) {
      // "cached" was the service's claim about its storage; the link's host is the one
      // thing playback actually needs, and it is not answering. Undo the handover so the
      // player is not left spinning over a stream that is never coming
      files.set([])
      throw { kind: 'link-dead', message: `${serviceTitle()} says this release is cached, but its stream host is not answering (${verdict.reason}).` } // eslint-disable-line no-throw-literal
    }
    return true
  } catch (error) {
    // Network completions do not arrive in click order. Once a newer play exists, this
    // result belongs only in the debug timeline: it must not replace files, toast, clear
    // ownership, or tell the old caller to start its torrent.
    if (!active()) return true
    // the release provably lacks the episode: the torrent client holds the same files, so
    // falling back would spend a whole pack's bandwidth to play the wrong episode anyway
    if (error?.kind === 'rejected') {
      debug(`Release does not contain the requested episode: ${reason(error)}`)
      toast.error('Wrong Release', { description: reason(error) })
      return handOver(true, active)
    }
    // playback is the most authoritative answer there is, worth more than the badge
    const proven = provenAvailability(error)
    if (proven) {
      debug(`${serviceTitle()} cannot stream this release: ${reason(error)}`)
      recordAvailability(route.id, proven)
      const { description } = describeAvailability(proven, serviceTitle())
      if (!debridOnly) {
        toast('Debrid', { description: `${description}\nStreaming via torrent instead.` })
        return handOver(false, active)
      }
      toast.error('Debrid', { description: `${description}\nPick a different release or disable debrid only mode.` })
    } else {
      debug('Debrid resolve failed:', error)
      if (!debridOnly) {
        toast.warning('Debrid Error', { description: `${reason(error)}\nStreaming via torrent instead.` })
        return handOver(false, active)
      }
      toast.error('Debrid Error', { description: reason(error) })
    }
    return handOver(true, active) // handled, only mode never falls back to the torrent client
  }
}

/**
 * Releases the player back to the torrent client and reports the routing outcome.
 * @param {boolean} handled - What streamDebrid returns to its caller.
 * @param {() => boolean} [active] - Whether this play still owns global playback state.
 */
function handOver (handled, active = () => true) {
  if (active()) {
    debridPlayback.set(false)
    debridStatus.set(null)
  }
  return handled
}

/**
 * Resolves a magnet to player ready file objects shaped like the torrent client's. The core
 * picks the episode out of a pack, drops anything not streamable over HTTPS, and shapes the
 * files with the shared watch key.
 *
 * The picked file's link is probed as soon as it exists — a resolve can succeed in under a
 * second and hand back a link whose CDN node never sends a byte, and that link cannot be
 * exchanged for a fresh one (the service pins one URL per file). The probe doubles as the
 * stream warm-up: DNS, TLS and the CDN locating the file all happen under it, while the app
 * is still parsing filenames and matching episodes.
 * @param {string} torrentID - Magnet URI or info hash.
 * @param {{ episode?: number }} [search]
 * @param {{ current?: () => boolean }} [intent] Whether this play still owns the player.
 * @returns {Promise<{ files: any[], verified: Promise<{ alive: boolean, reason?: string }> }>}
 *   `verified` never rejects; it answers whether the played file's link serves bytes.
 */
export async function resolveDebridFiles (torrentID, search, { current: ownsPlay = () => true } = {}) {
  const current = account()
  if (!current) throw new Error('No debrid service configured')
  const episode = Number(search?.episode)
  const wantedEpisode = Number.isFinite(episode) ? episode : undefined
  let resolved
  try {
    resolved = await DEBRID.resolve(current.id, current.apiKey, torrentID, wantedEpisode)
  } catch (error) {
    // A timeout proves only that one service chain lost the race with its budget. The
    // core has already put the account into short-probe mode, so exactly one new chain
    // is cheap and gives a transient 10–15s flap a way to heal without another click.
    if (error?.kind !== 'timeout' || !ownsPlay()) throw error
    debug(`Debrid resolve timed out; retrying once while ${current.service.title} is in recovery mode`)
    resolved = await DEBRID.resolve(current.id, current.apiKey, torrentID, wantedEpisode)
  }
  const target = probeTarget(resolved.files, resolved.target)
  const verified = verifiedStream(target?.url).then(async verdict => {
    if (!verdict.alive) {
      console.warn(`[stream] the resolved link for "${target?.name}" is dead after ${verdict.attempts} probe(s): ${verdict.reason}`)
      // Direct links are cached in the host because the provider returns the same URL
      // for a torrent/file pair. A byte probe is the authoritative invalidation signal.
      await Promise.resolve().then(() => DEBRID.forgetResolved(current.id, current.apiKey, resolved.hash))
        .catch(error => debug('Could not invalidate the dead resolved-link cache entry:', error))
    }
    else if (verdict.elapsed > 1_000) console.warn(`[stream] the resolved link took ${verdict.elapsed}ms to answer its range probe`)
    else debug(`Stream link answered its range probe in ${verdict.elapsed}ms`)
    return verdict
  })
  // playing it proves the service holds it, which is the best answer there is
  publishAvailability([[resolved.hash, Availability.CACHED]])
  return { files: resolved.files, verified }
}

/** What streamDebrid last routed to a service, so the player can ask for it to be played
 * again from the top when the stream dies under it. */
let lastPlay = null

/**
 * Routes the last debrid play again, through the same path a play click takes — resolve,
 * link probe, and on a dead link the fallback to torrents or an honest error. This is the
 * player's escalation for a stream that stopped answering mid-flight and would not come
 * back: not a reload of a dead address, a fresh decision about how to play the release.
 * @returns {boolean} Whether there was a play to route again.
 */
export function replayDebridPlayback () {
  if (!lastPlay) return false
  window.dispatchEvent(new CustomEvent('add', { detail: { torrentID: lastPlay.torrentID, hash: lastPlay.hash, search: lastPlay.search } }))
  return true
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
 * Points the core's availability watch at the releases on screen, so badges say what the
 * service can actually do with them rather than only what the account has touched. The
 * core owns the whole lifecycle — remembered answers, check rounds, backing-off retries —
 * and pushes every answer as an event the moment it lands; this call only starts the
 * watch and returns. A new list replaces the old watch, in the core.
 * @param {(string | undefined | null)[]} results - Result hashes, most relevant first.
 *   Entries without a hash are dropped rather than asked about.
 */
export async function checkDebridAvailability (results) {
  clearQueuedAvailability()
  const generation = ++availabilityGeneration
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
  if (declined) {
    DEBRID.cancelAvailability() // whatever list the old watch described is gone
    return debug(`Not asking about ${results?.length ?? 0} releases: ${declined}`)
  }
  const hashes = askable(results)
  if (!hashes.length) {
    DEBRID.cancelAvailability()
    return debug('Not asking: none of the results carry an info hash')
  }
  debug(`Watching ${hashes.length} releases with ${serviceTitle()}`)
  try {
    await DEBRID.watchAvailability(current.id, current.apiKey, hashes, generation)
  } catch (error) {
    debug('Availability watch failed to start:', error)
    if (generation === availabilityGeneration) reportOutage(error)
  }
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

/** Stops the watch, for when the results it described are no longer on screen. */
export function cancelDebridAvailability () {
  availabilityGeneration++
  clearQueuedAvailability()
  debridChecking.set(0)
  DEBRID.cancelAvailability()
}

function clearQueuedAvailability () {
  if (queueTimer) clearTimeout(queueTimer)
  queueTimer = null
  queued = null
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
  const current = debridReleaseNames.value
  if (names.length !== current.size || names.some(([hash, name]) => current.get(hash) !== name)) {
    debridReleaseNames.set(new Map(names))
  }
}

/**
 * Publishes names that arrived riding on watch answers, without dropping what is known.
 * @param {Iterable<[string, string]>} names
 */
function publishNames (names) {
  const entries = [...names]
  if (!entries.length) return
  const current = debridReleaseNames.value
  if (entries.every(([hash, name]) => current.get(hash) === name)) return
  const next = new Map(current)
  for (const [hash, name] of entries) next.set(hash, name)
  debridReleaseNames.set(next)
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

/** How long answers are collected for before one write reaches the UI. */
export const QUEUE_WINDOW = 50

/**
 * Collects answers arriving together into one store write, so a batch answer does not re-render
 * the list once per hash. A probing service answers slowly enough that each still lands alone.
 * @param {string} hash
 * @param {string} state
 * @param {string} [name] - The service's own name for the release, when it gave one.
 */
function queueAvailability (hash, state, name) {
  if (!queued) {
    queued = new Map()
    // a task, not a microtask: each answer crosses from the host as its own event, so a
    // microtask drains between every one of them and coalesces nothing at all
    queueTimer = setTimeout(() => {
      const answers = queued
      queued = null
      queueTimer = null
      const entries = [...answers]
      publishAvailability(entries.map(([hash, entry]) => [hash, entry.state]))
      publishNames(entries.filter(([, entry]) => entry.name).map(([hash, entry]) => [hash, entry.name]))
    }, QUEUE_WINDOW)
  }
  queued.set(hash, { state, name })
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
