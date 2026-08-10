// The vocabulary the whole debrid layer uses to describe a release. Pure data and pure
// functions, free of UI and network imports, so it runs under plain Node for tests.

/**
 * What a debrid service can do with a release right now.
 *
 * Services differ wildly in how well they can answer this: some expose a cache endpoint that
 * answers hundreds of hashes in one request, some have to be probed a hash at a time, some
 * cannot be asked at all. They all describe themselves with these four values, so the rest of
 * the app never has to care which kind it is talking to.
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
 * How long an answer stays trusted, in milliseconds.
 *
 * A hit lasts far longer than a miss: anyone can pull a release into a service's cache at any
 * moment, but a release it already holds rarely disappears. Unknown is not an answer, so it is
 * never stored and never expires.
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
 * Anything that is not one of the four states reads as unknown, so a service returning
 * something unexpected degrades to "no answer" rather than poisoning the badges.
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
 * Reads a hash's state out of an availability map, defaulting to unknown.
 * Callers hold magnets and mixed-case hashes, the map is keyed by lowercase info hash.
 * @param {Map<string, string> | undefined} availability
 * @param {string | undefined} hash
 * @returns {string}
 */
export function availabilityOf (availability, hash) {
  return (hash && availability?.get(String(hash).toLowerCase())) || Availability.UNKNOWN
}

/**
 * How a state is worded for the user. Kept here rather than in the components so the four
 * states read consistently wherever they appear, and so the wording is testable.
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
