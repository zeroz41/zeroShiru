// Pure playback routing policy, free of UI imports so it can be tested under
// plain Node. This is the single decision point for debrid vs torrent playback:
// debrid only mode must never route to the torrent client, whatever the input.

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
