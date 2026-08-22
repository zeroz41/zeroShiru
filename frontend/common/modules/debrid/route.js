// Pure debrid policy, free of UI imports so it can be tested under plain Node: how a play
// request is routed, which search results are listed, and how a results list is split for
// the modal without churning identities.
import { Availability, AVAILABILITY_ORDER, availabilityOf, streamsInstantly } from './availability.js'

const magnetRx = /^magnet:.*urn:btih:[a-f\d]{40}/i
const hexRx = /^[a-f\d]{40}$/i

/** @param {any} torrentID */
function usable (torrentID) {
  return (typeof torrentID === 'string' && (magnetRx.test(torrentID) || hexRx.test(torrentID)) && torrentID) || null
}

/**
 * Decides how a play request should be handled.
 * @param {Object} options
 * @param {any} options.torrentID - Magnet URI, info hash, .torrent link, or torrent file bytes.
 * @param {any} [options.hash] - Info hash when known, used when the link itself is not resolvable.
 * @param {boolean} options.serviceSelected - A debrid service is selected in settings.
 * @param {boolean} options.serviceReady - The service has an API key configured.
 * @param {boolean} options.offline - The client has no network connection.
 * @param {string} options.mode - The debridMode setting, 'prefer' or 'only'.
 * @returns {{ action: 'torrent', only: boolean } | { action: 'block', reason: 'key' | 'offline' | 'source', only: boolean } | { action: 'resolve', id: string, only: boolean }}
 *   `only` reports whether debrid only mode governs the decision, so callers need not re-derive it.
 */
export function routeDebrid ({ torrentID, hash, serviceSelected, serviceReady, offline, mode }) {
  // with no service selected debrid is entirely out of the picture, only mode included
  if (!serviceSelected) return { action: 'torrent', only: false }
  const only = mode === 'only'
  if (!serviceReady) return only ? { action: 'block', reason: 'key', only } : { action: 'torrent', only }
  if (offline) return only ? { action: 'block', reason: 'offline', only } : { action: 'torrent', only }
  const id = usable(torrentID) || usable(hash)
  if (!id) return only ? { action: 'block', reason: 'source', only } : { action: 'torrent', only }
  return { action: 'resolve', id, only }
}

/**
 * The API key stored for a debrid service. Every service keeps its own, so switching in settings
 * swaps the key rather than losing it, and one service's key can never reach another's API.
 * @param {{ debridApiKeys?: Record<string, string> }} settings
 * @param {string} [service] - Service id, defaulting to the selected one.
 * @returns {string} Empty when that service has no key yet.
 */
export function debridKey (settings, service = settings?.debridService) {
  return (service && settings?.debridApiKeys?.[service]) || ''
}

/**
 * Whether a search result belongs in the listed results rather than the hidden ones. With no
 * filters this is upstream's rule, widened only because a cached release streams without seeders.
 * The cached filter narrows it to confirmed hits, and debrid only mode hides releases the service
 * cannot serve. An *available* release is deliberately not widened in: the service would still
 * have to pull it from the swarm first.
 * @param {{ seeders?: number, source?: { managed?: boolean } }} result
 * @param {string} [availability] - What the service said about this release.
 * @param {{ cachedOnly?: boolean, only?: boolean }} [options] - The debrid filters in force.
 * @returns {boolean}
 */
export function listResult (result, availability, { cachedOnly, only } = {}) {
  const cached = streamsInstantly(availability)
  if (cachedOnly) return cached
  if (only && availability === Availability.UNAVAILABLE) return false
  return result?.seeders > 0 || Boolean(result?.source?.managed) || cached
}

const sameOrder = (a, b) => a.length === b.length && a.every((entry, index) => entry === b[index])

/**
 * Splits sorted results into what is listed and what is hidden, and tallies what the debrid
 * service said about each. A closure so the previous split lives outside any reactive graph.
 *
 * Identity is the contract here: most answers only move the counts, since a seeded release
 * was listed either way, and handing back the same arrays keeps the best-release pick from
 * being redone — which reparses every result, and is what made answers landing feel like a
 * freeze. `cachedKey` is the one thing that must escape that: the pick prefers a cached
 * release, so which listed releases are cached is returned as a comparable string that
 * changes exactly when the answer to "what should the best pick be" might.
 * @returns {(sorted: any[], availability?: Map<string, string>, filters?: { cachedOnly?: boolean, only?: boolean }) => any}
 */
export function createListResults () {
  let previous = null
  return function listResults (sorted, availability, filters) {
    const results = []
    const hiddenResults = []
    const counts = Object.fromEntries(AVAILABILITY_ORDER.map(state => [state, 0]))
    const cachedListed = []
    for (const entry of sorted) {
      const state = availability ? availabilityOf(availability, entry.hash) : Availability.UNKNOWN
      counts[state]++
      // narrows what the rest of the modal sees, so the best pick and autoplay follow it too
      if (listResult(entry, state, filters)) {
        results.push(entry)
        if (state === Availability.CACHED) cachedListed.push(entry.hash)
      } else hiddenResults.push(entry)
    }
    const cachedKey = cachedListed.join()
    if (previous && sameOrder(previous.results, results) && sameOrder(previous.hiddenResults, hiddenResults)) {
      return { ...previous, counts, cachedKey }
    }
    return (previous = { sorted, counts, results, hiddenResults, cachedKey })
  }
}
