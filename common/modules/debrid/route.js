// Pure debrid policy, free of UI imports so it can be tested under plain Node.
// Two decisions live here: how a play request is routed (debrid only mode must never
// reach the torrent client, whatever the input), and which search results are listed.
import { Availability, streamsInstantly } from './availability.js'

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
 *   `only` reports whether debrid only mode governs this decision, so callers never
 *   have to re-derive the fallback rules that were already applied here.
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
 * The API key stored for a debrid service.
 *
 * Every service keeps its own, so switching between them in settings swaps the key rather than
 * losing it, and an account on one service can never be addressed with another's key. The
 * settings tab and the playback module both read through here so they cannot disagree about
 * which key is in play.
 * @param {{ debridApiKeys?: Record<string, string> }} settings
 * @param {string} [service] - Service id, defaulting to the selected one.
 * @returns {string} Empty when that service has no key yet.
 */
export function debridKey (settings, service = settings?.debridService) {
  return (service && settings?.debridApiKeys?.[service]) || ''
}

/**
 * Whether a search result belongs in the listed results rather than the hidden ones.
 *
 * With no filters on this is upstream's rule, widened only by the fact that a cached release
 * streams without seeders. The two debrid cases that narrow it:
 * - the cached filter shows nothing but confirmed cached releases;
 * - debrid only mode hides releases the service has said it cannot serve, since with no
 *   torrent client to fall back on those cannot play at all.
 *
 * An *available* release is deliberately not widened in: the service would still have to pull
 * it from the swarm, so a seederless one is no more playable than it was without debrid.
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
