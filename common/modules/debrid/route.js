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
 * @returns {{ action: 'torrent' } | { action: 'block', reason: 'key' | 'offline' | 'source' } | { action: 'resolve', id: string }}
 */
export function routeDebrid ({ torrentID, hash, serviceSelected, serviceReady, offline, mode }) {
  if (!serviceSelected) return { action: 'torrent' }
  const debridOnly = mode === 'only'
  if (!serviceReady) return debridOnly ? { action: 'block', reason: 'key' } : { action: 'torrent' }
  if (offline) return debridOnly ? { action: 'block', reason: 'offline' } : { action: 'torrent' }
  const id = usable(torrentID) || usable(hash)
  if (!id) return debridOnly ? { action: 'block', reason: 'source' } : { action: 'torrent' }
  return { action: 'resolve', id }
}
