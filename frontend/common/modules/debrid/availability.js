// The vocabulary the whole debrid layer uses to describe a release. Pure data and pure functions,
// free of UI and network imports, so it runs under plain Node for tests.

/**
 * What a debrid service can do with a release right now. Services differ wildly in how well they
 * can answer, but all speak these four values, so the rest of the app never has to care which
 * kind it is talking to.
 */
export const Availability = Object.freeze({
  /** The service holds it and streams it immediately. */
  CACHED: 'cached',
  /** The service does not hold it but can fetch it, which takes longer than playback will wait. */
  AVAILABLE: 'available',
  /** The service cannot serve it at all: a dead magnet, a rejected release, a failed download. */
  UNAVAILABLE: 'unavailable',
  /** Nobody asked, or nothing came back. Never report this as "not cached", it is an absence of an answer. */
  UNKNOWN: 'unknown'
})

/** Every state, best first. The order badges and counters are shown in. */
export const AVAILABILITY_ORDER = Object.freeze([Availability.CACHED, Availability.AVAILABLE, Availability.UNKNOWN, Availability.UNAVAILABLE])

/**
 * How long an answer stays trusted. A hit lasts far longer than a miss: anyone can pull a release
 * into a cache at any moment, but one already held rarely disappears.
 */
export const AVAILABILITY_TTL = Object.freeze({
  [Availability.CACHED]: 6 * 60 * 60_000,
  [Availability.AVAILABLE]: 20 * 60_000,
  [Availability.UNAVAILABLE]: 30 * 60_000,
  [Availability.UNKNOWN]: 0
})

const states = new Set(Object.values(Availability))

/**
 * @param {any} value
 * @returns {value is Availability[keyof Availability]}
 */
export function isAvailability (value) {
  return states.has(value)
}

/**
 * Anything unrecognised reads as unknown, so a service answering something unexpected degrades to
 * "no answer" rather than poisoning the badges.
 * @param {any} value
 * @returns {string}
 */
export function normalizeAvailability (value) {
  return isAvailability(value) ? value : Availability.UNKNOWN
}

/**
 * Whether playback can start on this release now. The one question the player asks.
 * @param {string} state
 */
export function streamsInstantly (state) {
  return state === Availability.CACHED
}

/**
 * A hash's state out of an availability map, defaulting to unknown. The map is keyed by
 * lowercase info hash.
 * @param {Map<string, string> | undefined} availability
 * @param {string | undefined} hash
 * @returns {string}
 */
export function availabilityOf (availability, hash) {
  return (hash && availability?.get(String(hash).toLowerCase())) || Availability.UNKNOWN
}

/**
 * How a state is worded for the user, kept here so it reads the same wherever it appears.
 * @param {string} state
 * @param {string} [title] - The service's display name.
 * @returns {{ label: string, description: string }}
 */
export function describeAvailability (state, title = 'your debrid service') {
  switch (state) {
    case Availability.CACHED:
      return { label: 'Cached', description: `Cached on ${title}, streams instantly with no torrent peers involved.` }
    case Availability.AVAILABLE:
      return { label: 'Available', description: `${title} can fetch this release but does not hold it yet, so it cannot stream right now.` }
    case Availability.UNAVAILABLE:
      return { label: 'Unavailable', description: `${title} cannot serve this release at all.` }
    default:
      return { label: 'Unchecked', description: `${title} has not been asked about this release. It may still stream.` }
  }
}

/**
 * What to tell the user when a check could not be answered, or null when the failure is an answer
 * about a release rather than a problem with the service.
 *
 * Badges going quiet used to be indistinguishable from every release being uncached: the check
 * failed, the failure went to a debug log nobody reads, and the list simply showed nothing while
 * a backing-off timer asked again forever. A service that has stopped answering — one of its
 * endpoints hanging while the rest work is a real and common shape — should say so once.
 *
 * @param {{ kind?: string, message?: string }} [error] - A core error, `{ kind, message }`.
 * @param {string} [title] - The service's display name.
 * @returns {{ title: string, description: string } | null}
 */
export function outageNotice (error, title = 'your debrid service') {
  switch (error?.kind) {
    case 'auth':
      return {
        title: `${title} rejected the key`,
        description: `${error.message || 'The API key was not accepted.'}\nCheck it in the debrid settings.`
      }
    case 'timeout':
      return {
        title: `${title} is not answering`,
        description: 'Cached badges will be missing until it does. Playback is unaffected for releases it has already answered about.'
      }
    case 'network':
      return {
        title: `${title} could not be reached`,
        description: 'Cached badges will be missing until the connection comes back.'
      }
    case 'service':
      return {
        title: `${title} returned an error`,
        description: `${error.message || 'The service could not process the request.'}\nCached badges will be missing until it recovers.`
      }
    // answers about a release rather than problems with the service
    case 'not-cached':
    case 'unavailable':
    case 'rejected':
      return null
    // anything else is a failure nobody wrote a case for — an IPC call that never got
    // as far as the service, a bad argument, a bug here. It used to say nothing at all,
    // which looks exactly like a library where nothing is cached
    default:
      return {
        title: `${title} could not be checked`,
        description: `${error?.message || String(error ?? 'The check failed for an unknown reason.')}\nCached badges will be missing until it works again.`
      }
  }
}
