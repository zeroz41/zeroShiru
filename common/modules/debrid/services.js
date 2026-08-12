// The service registry. Adding a debrid service means writing its file and listing it here;
// nothing else in the app names a service. No UI imports, so tests can read it under plain Node.
import AllDebrid from './alldebrid.js'
import Premiumize from './premiumize.js'
import RealDebrid from './realdebrid.js'
import TorBox from './torbox.js'

/** In the order the settings menu offers them. Unfinished services stay hidden. */
export const debridServices = Object.fromEntries([AllDebrid, Premiumize, RealDebrid, TorBox]
  .filter(Service => Service.available)
  .map(Service => [Service.id, Service]))

/**
 * The service class for an id, or null.
 * @param {string} [id]
 * @returns {typeof import('./service.js').default | null}
 */
export function debridService (id) {
  return debridServices[id] || null
}
