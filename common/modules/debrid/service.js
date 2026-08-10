import Bottleneck from 'bottleneck'
import { Availability, AVAILABILITY_TTL, normalizeAvailability } from './availability.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

// No UI imports here, so this module also runs under plain Node for testing.

export class DebridError extends Error {
  /**
   * @param {string} message
   * @param {{ status?: number, code?: string | number }} [opts]
   */
  constructor (message, { status, code } = {}) {
    super(message)
    this.name = 'DebridError'
    this.status = status
    this.code = code
  }
}

/** The API key is missing, invalid, or the account lacks the required plan. */
export class DebridAuthError extends DebridError {
  constructor (message, opts) {
    super(message, opts)
    this.name = 'DebridAuthError'
  }
}

/** The service could not be reached at all, usually because the client is offline. */
export class DebridNetworkError extends DebridError {
  constructor (message, opts) {
    super(message, opts)
    this.name = 'DebridNetworkError'
  }
}

/**
 * Playback cannot use this release now, carrying the availability it proves. Callers read
 * `availability` off the error rather than matching on error types.
 * @abstract
 */
export class DebridUnstreamableError extends DebridError {
  /** @type {string} What this error proves about the release. */
  availability = Availability.UNKNOWN
}

/** The service would have to download the torrent before it could stream it. */
export class DebridNotCachedError extends DebridUnstreamableError {
  constructor (message = 'Torrent is not cached on the debrid service', opts) {
    super(message, opts)
    this.name = 'DebridNotCachedError'
    this.availability = Availability.AVAILABLE
  }
}

/** The service cannot serve this release at all: a dead magnet, a rejected or failed torrent. */
export class DebridUnavailableError extends DebridUnstreamableError {
  constructor (message = 'The debrid service cannot serve this torrent', opts) {
    super(message, opts)
    this.name = 'DebridUnavailableError'
    this.availability = Availability.UNAVAILABLE
  }
}

/** Thrown by the base class for any method a service has not filled in yet. */
export class DebridNotImplementedError extends DebridError {
  /** @param {string} title - The service's display name. */
  constructor (title) {
    super(`${title || 'This debrid service'} support is not implemented yet`)
    this.name = 'DebridNotImplementedError'
  }
}

/**
 * What an error proves about a release, or null when it proves nothing. A timeout or a rate
 * limit describes the moment, not the release, so it leaves it unknown and re-checkable.
 * @param {any} error
 * @returns {string | null}
 */
export function availabilityFromError (error) {
  return error instanceof DebridUnstreamableError ? normalizeAvailability(error.availability) : null
}

/**
 * @typedef {Object} DebridFile
 * @property {string} name - File name without directories.
 * @property {string} path - Path within the torrent, always starting with a slash.
 * @property {number} size - File size in bytes.
 * @property {string} url - Direct stream URL, must be HTTPS, the player streams it as is.
 * @property {string} [type] - MIME type when the service reports one.
 */

/**
 * @typedef {Object} DebridResolved
 * @property {string} hash - Lowercase info hash.
 * @property {string} name - Torrent name.
 * @property {DebridFile[]} files - Streamable files, in torrent order.
 */

/**
 * Drops any link that is not HTTPS. Debrid links are account bound, so a cleartext one would put
 * the user's traffic and their link on the wire in the clear.
 * @param {DebridFile[]} files
 * @param {string} title - Service name, for the message the user sees.
 * @returns {DebridFile[]}
 */
export function secureFiles (files, title) {
  const secure = (files || []).filter(file => /^https:\/\//i.test(file?.url))
  if (!secure.length) throw new DebridError(`${title} returned no secure stream links`)
  return secure
}

/** Archives a service may serve instead of streamable files, when it repacks a selection. */
export const archiveRx = /\.(rar|zip|7z)$/i

const magnetHashRx = /urn:btih:([a-f\d]{40})/i
const bareHashRx = /^[a-f\d]{40}$/i

const RATE_LIMIT_RETRIES = 2
const RATE_LIMIT_FALLBACK = 5 // seconds to wait when a 429 carries no retry-after header
const NETWORK_RETRY_DELAY = 3_000
const MAX_PROBE_FAILURES = 3 // consecutive unanswered probes before a sweep gives up
const MAX_STRETCH = 3 // how far a poll budget may stretch on a slow link
const MAX_CLEANUP_ATTEMPTS = 3

/**
 * Base class for debrid services: rate limited requests, typed errors, availability bookkeeping.
 * Implementations only talk HTTP, state is per-instance so services stay swappable.
 *
 * Adding a service means subclassing this, setting the statics below, and implementing the
 * abstract methods. Nothing outside the new file changes apart from one registry entry in
 * `debrid.js`.
 * @abstract
 */
export default class DebridService {
  /** @type {string} Unique lowercase identifier, e.g. 'realdebrid'. */
  static id = ''
  /** @type {string} Human readable service name. */
  static title = ''
  /** @type {boolean} Only implemented services are offered in the settings menu. */
  static available = false
  /** @type {import('bottleneck').ConstructorOptions} Request rate limits for the service API. */
  static limits = { maxConcurrent: 4, minTime: 250 }
  /** @type {'bearer' | 'query'} How the API key travels: an Authorization header or a query parameter. */
  static auth = 'bearer'
  /** @type {string} Query parameter name used when `auth` is 'query'. */
  static authParam = 'apikey'
  /** @type {'form' | 'json' | 'multipart'} How request bodies are encoded, overridable per request. */
  static encoding = 'form'

  /** Time limits in milliseconds. All but `request` are poll budgets, read through `budget()`. */
  static timeouts = {
    request: 30_000, // hard ceiling on one round trip, deliberately does not stretch
    select: 12_000, // waiting for the service to accept a magnet and expose its file list
    ready: 5_000, // waiting for a cached torrent to report ready, anything slower is a fresh download
    poll: 1_000, // gap between status polls
    probe: 10_000 // tighter than `select`: a probe that drags on spends requests playback needs
  }

  /** @type {number} Round trip time the limits above are written for, in milliseconds. */
  static nominalLatency = 300

  /** @type {number} Probes running at once. Small, since each briefly owns a torrent on the account. */
  static maxProbeConcurrency = 3

  /** @type {number} Most files one resolve turns into stream links, guards against huge season packs. */
  static maxFiles = 60

  /**
   * @type {'batch' | 'probe' | 'none'} How the service can be asked about a release it has not
   * seen. 'batch' answers many hashes per request, 'probe' adds the magnet and reads the status
   * back, 'none' leaves badges to `listAvailability`.
   */
  static availabilityCheck = 'none'

  /** @type {number} Hashes per batch request. */
  static maxBatch = 100

  /**
   * Whether asking about a release puts a magnet on the account rather than reading a cache
   * index. Two things follow: only one such check may be in flight, and a hash the answer leaves
   * out is unasked rather than "not cached".
   * @returns {boolean}
   */
  static get checkAddsMagnets () {
    return this.availabilityCheck === 'probe'
  }

  /** @type {number} Most probes one results list may cost, since each is several requests. */
  static maxProbes = 10

  /** How far down a results list this service looks. Override where a batch still pays per hash. */
  static get maxAsk () {
    return this.availabilityCheck === 'probe' ? this.maxProbes : Infinity
  }

  /** @type {Record<string, number>} How long each answer stays trusted, overridable per service. */
  static availabilityTTL = AVAILABILITY_TTL

  /** @type {number} How long the account listing is reused. Matched to the badge refresh. */
  static listingTTL = 60_000

  /** @type {{ at: number, promise: Promise<any[]> } | null} The listing read, shared by everyone waiting on it. */
  #listing = null

  /** @type {Map<string, { url: string, opts: any, attempts: number }>} Removals that failed, to try again. */
  #orphans = new Map()

  /** @param {string} apiKey */
  constructor (apiKey) {
    this.apiKey = apiKey
    this.rateLimitPromise = null
    /** @type {number} Rolling estimate of one round trip, 0 until the first answer. */
    this.latency = 0
    /** @type {Map<string, { state: string, at: number }>} What the service has already said about a hash. */
    this.availabilityState = new Map()
    /** @type {Map<string, Promise<string>>} Probes in flight, so a hash is never asked about twice at once. */
    this.probes = new Map()
    /** @type {boolean} Whether a check that adds magnets is running, since only one may be. */
    this.sweeping = false
    this.limiter = new Bottleneck(this.config.limits)
    this.limiter.on('failed', (error, jobInfo) => {
      if (error instanceof DebridNetworkError) return // offline, retrying just delays the error
      if (error instanceof DebridError && error.status === 429 && jobInfo.retryCount < RATE_LIMIT_RETRIES) {
        const time = (Number(error.retryAfter) || RATE_LIMIT_FALLBACK) * 1_000
        debug(`Rate limited by ${this.config.title}, retrying in ${time}ms`)
        if (!this.rateLimitPromise) this.rateLimitPromise = new Promise(resolve => setTimeout(resolve, time).unref?.()).then(() => { this.rateLimitPromise = null })
        return time
      }
      if (!(error instanceof DebridError) && jobInfo.retryCount < 1) return NETWORK_RETRY_DELAY // single retry for network hiccups
    })
    this.request = this.limiter.wrap(this.#request.bind(this))
  }

  /**
   * Undoes something this client created on the account. Never throws: it runs from `finally`,
   * where it would mask the real failure. A removal that fails is remembered and retried, since
   * the limiter does not retry the offline case that most often causes one.
   * @param {string} url
   * @param {Parameters<DebridService['request']>[1]} [opts]
   */
  async release (url, opts) {
    try {
      await this.request(url, { method: 'DELETE', ...opts })
      this.#orphans.delete(url)
    } catch (error) {
      if (error?.status === 404) return this.#orphans.delete(url) // already gone is what we wanted
      const attempts = (this.#orphans.get(url)?.attempts ?? 0) + 1
      debug(`Cleanup failed for ${url} (attempt ${attempts}): ${error.message}`)
      if (attempts < MAX_CLEANUP_ATTEMPTS) this.#orphans.set(url, { url, opts, attempts })
      else this.#orphans.delete(url)
    } finally {
      this.forgetListing() // the account just changed, whether or not the removal worked
    }
  }

  /**
   * Retries removals that failed earlier. Only ever replays a removal `release()` was already
   * asked to make, so it can no more reach a torrent the user wanted than the original call
   * could. Never persisted: a stale id would eventually name something else.
   */
  async retryCleanup () {
    const pending = [...this.#orphans.values()]
    if (!pending.length) return
    debug(`Retrying ${pending.length} removal(s) that failed earlier`)
    await Promise.all(pending.map(entry => this.release(entry.url, entry.opts)))
  }

  /** How many removals are still outstanding. */
  get orphaned () {
    return this.#orphans.size
  }

  /**
   * The account's own torrent listing, read at most once per `listingTTL` and shared by every
   * caller. Both the badge refresh and every resolve want it, and reading it per play put a full
   * listing on the play path. An entry can be a minute stale, so callers confirm it before
   * acting on its id.
   * @param {{ fresh?: boolean }} [opts] - `fresh` forces a read, for polling a change just made.
   * @returns {Promise<any[]>}
   */
  listing ({ fresh = false } = {}) {
    const known = this.#listing
    if (!fresh && known && Date.now() - known.at < this.config.listingTTL) return known.promise
    const entry = { at: Date.now(), promise: this.fetchListing() }
    entry.promise.catch(() => { if (this.#listing === entry) this.#listing = null }) // never remember a failed read
    this.#listing = entry
    return entry.promise
  }

  /** Drops the remembered listing, because the account just changed. */
  forgetListing () {
    this.#listing = null
  }

  /**
   * Reads the account's torrents. Everything else goes through `listing()`.
   * @abstract
   * @returns {Promise<any[]>}
   */
  async fetchListing () { throw new DebridNotImplementedError(this.config.title) }

  /** The subclass's static configuration, typed so implementations get completions. */
  get config () {
    return /** @type {typeof DebridService} */ (this.constructor)
  }

  /**
   * The lowercase info hash of a magnet URI or bare hash, empty when there is none.
   * @param {any} magnetOrHash
   * @returns {string}
   */
  static parseHash (magnetOrHash) {
    if (typeof magnetOrHash !== 'string') return ''
    return (magnetHashRx.exec(magnetOrHash)?.[1] || (bareHashRx.test(magnetOrHash) ? magnetOrHash : '')).toLowerCase()
  }

  /**
   * A magnet URI to hand to the API, from a magnet URI or bare info hash.
   * @param {any} magnetOrHash
   * @returns {string} Empty when the input holds no usable hash.
   */
  static toMagnet (magnetOrHash) {
    if (typeof magnetOrHash === 'string' && magnetOrHash.startsWith('magnet:')) return magnetOrHash
    const hash = this.parseHash(magnetOrHash)
    return hash ? `magnet:?xt=urn:btih:${hash}` : ''
  }

  /**
   * Applies the service's authentication scheme. Some APIs authenticate one odd endpoint
   * differently, hence the per-request override.
   * @param {string} url
   * @param {{ auth?: 'bearer' | 'query', authParam?: string }} [override]
   * @returns {{ url: string, headers: Record<string, string> }}
   */
  authorize (url, { auth = this.config.auth, authParam = this.config.authParam } = {}) {
    if (auth !== 'query') return { url, headers: { Authorization: `Bearer ${this.apiKey}` } }
    const target = new URL(url)
    target.searchParams.set(authParam, this.apiKey)
    return { url: target.href, headers: {} }
  }

  /**
   * Encodes a request body. An array value becomes the same key repeated per item, which is how
   * `name[]` parameters are read; joining them into one value is silently taken as one item.
   * @param {Record<string, any>} body
   * @param {'form' | 'json' | 'multipart'} encoding
   * @returns {{ body: any, headers: Record<string, string> }}
   */
  static encodeBody (body, encoding) {
    if (encoding === 'json') return { body: JSON.stringify(body), headers: { 'Content-Type': 'application/json' } }
    const fields = Object.entries(body).flatMap(([key, value]) => Array.isArray(value) ? value.map(item => [key, item]) : [[key, value]])
    if (encoding === 'multipart') {
      const form = new FormData()
      for (const [key, value] of fields) form.append(key, String(value))
      return { body: form, headers: {} } // fetch sets the content type, boundary included
    }
    const params = new URLSearchParams()
    for (const [key, value] of fields) params.append(key, String(value))
    return { body: params.toString(), headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
  }

  /**
   * @param {string} url - Absolute request URL.
   * @param {{ method?: string, body?: Record<string, any>, encoding?: 'form' | 'json' | 'multipart', auth?: 'bearer' | 'query', authParam?: string, timeout?: number }} [opts]
   */
  async #request (url, { method = 'GET', body, encoding = this.config.encoding, auth, authParam, timeout = this.config.timeouts.request } = {}) {
    await this.rateLimitPromise
    if (!this.apiKey) throw new DebridAuthError('No debrid API key configured')
    const authorized = this.authorize(url, { auth, authParam })
    const encoded = body ? DebridService.encodeBody(body, encoding) : null
    debug(`${method} ${url}`) // logged before authorization so query-parameter keys never reach the log
    const sent = Date.now()
    const res = await fetch(authorized.url, {
      method,
      headers: { ...authorized.headers, ...encoded?.headers },
      body: encoded?.body,
      signal: AbortSignal.timeout(timeout)
    })
    this.observeLatency(Date.now() - sent) // only round trips that came back, so a timeout cannot inflate it
    // the app short-circuits external requests while it considers itself offline,
    // handing back a plain object instead of a Response
    if (typeof res?.json !== 'function') throw new DebridNetworkError(res?.message?.replace(/^failed to fetch: /i, '') || 'Network request failed')
    if (!res?.ok) {
      let json = null
      try { json = await res.json() } catch {}
      const error = this.mapError(res.status, json)
      if (error.status === 429) error.retryAfter = res.headers?.get('retry-after')
      throw error
    }
    if (res.status === 204) return null
    return this.unwrap(await res.json().catch(() => null)) // some endpoints return an empty body on success
  }

  /**
   * Folds one round trip into the latency estimate, weighted towards recent requests.
   * @param {number} ms
   */
  observeLatency (ms) {
    this.latency = this.latency ? Math.round(this.latency * 0.7 + ms * 0.3) : ms
  }

  /**
   * A poll budget stretched to fit the connection in use, up to `MAX_STRETCH`. The defaults are
   * written for a healthy link; on a slow one the same budget buys a single request, so every
   * poll loop times out and reports no answer.
   * @param {string} kind - A key of the service's `timeouts`.
   * @returns {number}
   */
  budget (kind) {
    const base = this.config.timeouts[kind]
    return Math.round(base * Math.min(Math.max(1, this.latency / this.config.nominalLatency), MAX_STRETCH))
  }

  /**
   * Whether an error means the service wants fewer requests rather than that this release is a
   * problem. A sweep stops on one. Override for service specific codes.
   * @param {any} error
   * @returns {boolean}
   */
  throttled (error) {
    return error?.status === 429
  }

  /**
   * Unpacks a successful response body. Override for APIs that wrap everything in an envelope and
   * report failures inside a 200 — throwing from here routes those through the same typed errors.
   * @param {any} json
   * @returns {any}
   */
  unwrap (json) {
    return json
  }

  /**
   * Maps an HTTP error response to a typed error, override for service specific codes.
   * @param {number} status
   * @param {any} json - Parsed error body, may be null.
   * @returns {DebridError}
   */
  mapError (status, json) {
    const message = json?.error || json?.message || `Request failed with status ${status}`
    if (status === 401 || status === 403) return new DebridAuthError(message, { status, code: json?.error_code })
    return new DebridError(message, { status, code: json?.error_code })
  }

  /**
   * Caps a pack's file list around the file playback wants rather than taking the first N. The
   * wanted episode is often a late one, and dropping it forces an expensive re-add. Torrent order
   * is preserved so in-player next/previous still works.
   * @template T
   * @param {T[]} files - Candidate files, in torrent order.
   * @param {T | null} target - The file playback asked for, or null when there is none.
   * @param {number} [maxFiles]
   * @param {(file: T) => any} [key] - Identity used to locate the target among the candidates.
   * @returns {T[]}
   */
  static windowFiles (files, target, maxFiles = this.maxFiles, key = file => file?.path) {
    if (files.length <= maxFiles) return files
    const index = target ? files.findIndex(file => key(file) === key(target)) : -1
    const start = index < 0 ? 0 : Math.min(Math.max(0, index - (maxFiles >> 1)), files.length - maxFiles)
    debug(`Pack holds ${files.length} files, taking ${maxFiles} from index ${start}`)
    return files.slice(start, start + maxFiles)
  }

  /**
   * Turns candidates into stream links concurrently, skipping ones the service cannot serve —
   * packs do contain dead files, and one must not fail the whole resolve. Auth failures still
   * abort, since every other link would fail the same way.
   * @template T
   * @param {T[]} candidates
   * @param {(candidate: T) => Promise<DebridFile | null>} toFile - Unrestricts one file, may return null to drop it.
   * @param {(candidate: T) => string} [describe] - Names a candidate for the debug log.
   * @returns {Promise<DebridFile[]>}
   */
  async mapFiles (candidates, toFile, describe = candidate => candidate?.path || 'file') {
    const files = await Promise.all(candidates.map(async candidate => {
      try {
        return await toFile(candidate)
      } catch (error) {
        if (error instanceof DebridAuthError) throw error
        debug(`Skipping ${describe(candidate)}: ${error.message}`)
        return null
      }
    }))
    return files.filter(Boolean)
  }

  /**
   * Records what is known about a release so later checks are free. Playback feeds this too.
   * Unknown is not an answer, so recording it forgets what was there.
   * @param {string} magnetOrHash
   * @param {string} state - An `Availability` value.
   */
  remember (magnetOrHash, state) {
    const hash = DebridService.parseHash(magnetOrHash)
    if (!hash) return
    const known = normalizeAvailability(state)
    if (known === Availability.UNKNOWN) this.availabilityState.delete(hash)
    else this.availabilityState.set(hash, { state: known, at: Date.now() })
  }

  /**
   * A remembered answer that has not expired, or undefined when the hash needs asking about.
   * @param {string} hash
   * @returns {string | undefined}
   */
  #recall (hash) {
    const known = this.availabilityState.get(hash)
    if (!known) return undefined
    if (Date.now() - known.at < (this.config.availabilityTTL[known.state] ?? 0)) return known.state
    this.availabilityState.delete(hash) // stale, ask again
    return undefined
  }

  /**
   * The given hashes nothing is known about yet, in the order supplied. Callers use this to skip
   * work entirely, not to decide what to ask about.
   * @param {string[]} magnetsOrHashes
   * @returns {string[]}
   */
  unknownHashes (magnetsOrHashes) {
    return DebridService.#normalize(magnetsOrHashes, this.config.maxAsk).filter(hash => this.#recall(hash) === undefined && !this.probes.has(hash))
  }

  /**
   * Lowercase, deduplicated hashes, order preserved.
   * @param {string[]} magnetsOrHashes
   * @param {number} [limit] - Stop after this many, so a long list costs nothing to trim.
   */
  static #normalize (magnetsOrHashes, limit = Infinity) {
    const hashes = new Set()
    for (const entry of magnetsOrHashes || []) {
      const hash = DebridService.parseHash(entry)
      if (hash) hashes.add(hash)
      if (hashes.size >= limit) break
    }
    return [...hashes]
  }

  /**
   * What the service can do with each of the given releases. Remembered answers come back free,
   * the rest are asked about the cheapest way the service supports. Hashes that stay unanswered
   * are absent from the result, which callers must read as unknown rather than "not cached".
   * @param {string[]} magnetsOrHashes - Candidates, most relevant first, since probing bites from the front.
   * @param {{ onAnswer?: (hash: string, state: string) => void }} [opts] - Fires as each answer lands.
   * @returns {Promise<Map<string, string>>} Hash to `Availability`, answered hashes only.
   */
  async checkAvailability (magnetsOrHashes, { onAnswer } = {}) {
    const answers = new Map()
    const mode = this.config.availabilityCheck
    const candidates = DebridService.#normalize(magnetsOrHashes, this.config.maxAsk)
    const unknown = []
    for (const hash of candidates) {
      const known = this.#recall(hash)
      if (known === undefined) unknown.push(hash)
      else answers.set(hash, known)
    }
    if (!unknown.length || mode === 'none') return answers

    const answer = (hash, state) => {
      answers.set(hash, state)
      onAnswer?.(hash, state)
    }

    // one at a time where asking adds magnets: services rate limit adding far harder than
    // reading, so overlapping checks do not answer faster, they get refused
    if (this.config.checkAddsMagnets) {
      if (this.sweeping) return answers
      this.sweeping = true
    }
    try {
      if (this.orphaned) await this.retryCleanup() // clear our own leftovers before adding more
      if (mode === 'batch') await this.#batch(unknown, answer)
      else await this.#sweep(unknown, answer)
    } finally {
      this.sweeping = false
    }
    return answers
  }

  /**
   * Asks about the hashes in as few requests as the service allows.
   * @param {string[]} hashes
   * @param {(hash: string, state: string) => void} answer
   */
  async #batch (hashes, answer) {
    for (let index = 0; index < hashes.length; index += this.config.maxBatch) {
      const chunk = hashes.slice(index, index + this.config.maxBatch)
      const states = await this.checkAvailabilityBatch(chunk)
      for (const hash of chunk) {
        // a cache endpoint that answered without mentioning a hash has said it does not hold it.
        // A check that adds magnets has only said it never got to it
        const state = normalizeAvailability(states?.get(hash) ?? (this.config.checkAddsMagnets ? Availability.UNKNOWN : Availability.AVAILABLE))
        this.remember(hash, state)
        if (state !== Availability.UNKNOWN) answer(hash, state)
      }
    }
  }

  /**
   * Probes hashes a few at a time, stopping early once the service is in no state to answer more.
   * Stopping is not finishing: what is left stays unknown and the caller comes back to it.
   * @param {string[]} hashes
   * @param {(hash: string, state: string) => void} answer
   */
  async #sweep (hashes, answer) {
    const queue = [...hashes]
    let failures = 0
    let stopped = null
    const worker = async () => {
      while (queue.length && !stopped) {
        const hash = queue.shift()
        try {
          answer(hash, await this.#probe(hash))
          failures = 0
        } catch (error) {
          if (error instanceof DebridAuthError) { stopped = error; return } // every other probe would fail too
          debug(`Availability probe failed for ${hash}: ${error.message}`)
          if (this.throttled(error) || ++failures >= MAX_PROBE_FAILURES) stopped = error
        }
      }
    }
    await Promise.all(Array.from({ length: Math.min(this.config.maxProbeConcurrency, queue.length) }, worker))
    if (stopped) debug(`Probe sweep stopped with ${queue.length} hashes left to ask about: ${stopped.message}`)
    if (stopped instanceof DebridAuthError) throw stopped
  }

  /**
   * Runs one probe, shared with any caller already waiting on that hash. Only a reported state or
   * a definite error counts as an answer; anything else throws, so the release stays re-checkable.
   * @param {string} hash
   * @returns {Promise<string>} Never resolves to `unknown`.
   */
  #probe (hash) {
    let pending = this.probes.get(hash)
    if (!pending) {
      pending = this.probeAvailability(hash)
        .then(normalizeAvailability, error => {
          const proven = availabilityFromError(error)
          if (!proven) throw error
          return proven
        })
        .then(state => {
          if (state === Availability.UNKNOWN) throw new DebridError(`${this.config.title} gave no usable answer for ${hash}`)
          this.remember(hash, state)
          return state
        })
        .finally(() => this.probes.delete(hash))
      this.probes.set(hash, pending)
    }
    return pending
  }

  /**
   * What the service can do with one release, for APIs with no cache endpoint. Must leave the
   * account exactly as it found it. Return an `Availability`, or throw `DebridNotCachedError` /
   * `DebridUnavailableError`. Let everything else throw untyped: the base class reads any other
   * error as "no answer".
   * @abstract
   * @param {string} hash - Lowercase info hash.
   * @returns {Promise<string>}
   */
  async probeAvailability (hash) { throw new DebridNotImplementedError(this.config.title) }

  /**
   * Asks about many releases at once, for APIs with a cache endpoint. Chunking to `maxBatch` is
   * already done. Hashes left out are recorded as available unless `checkAddsMagnets`.
   * @abstract
   * @param {string[]} hashes - Lowercase info hashes.
   * @returns {Promise<Map<string, string>>} Hash to `Availability`.
   */
  async checkAvailabilityBatch (hashes) { throw new DebridNotImplementedError(this.config.title) }

  /**
   * Verifies the API key and that the account can stream torrents.
   * @abstract
   * @returns {Promise<{ username: string, expires?: string }>}
   */
  async validate () { throw new DebridNotImplementedError(this.config.title) }

  /**
   * What the account itself says: what it holds is cached, what it is fetching is available, what
   * failed on it is unavailable. The free badge source, where the API exposes info hashes.
   * @abstract
   * @returns {Promise<Map<string, string>>} Lowercase info hash to `Availability`.
   */
  async listAvailability () { throw new DebridNotImplementedError(this.config.title) }

  /**
   * Resolves a magnet to direct stream URLs. Throws `DebridNotCachedError` when the service would
   * have to download it first, `DebridUnavailableError` when it cannot serve it. URLs must be HTTPS.
   * @abstract
   * @param {string} magnet - Magnet URI or bare info hash.
   * @param {{ fileFilter?: (name: string) => boolean, pickFile?: (files: { id: number, path: string, size: number }[]) => Promise<any>, maxFiles?: number }} [opts]
   * @returns {Promise<DebridResolved>}
   */
  async resolve (magnet, opts) { throw new DebridNotImplementedError(this.config.title) }

  /** Cancels queued requests, the instance must not be used afterwards. */
  destroy () {
    this.availabilityState.clear()
    this.sweeping = false
    // running probes own a torrent until they tear it down, so the limiter has to outlive them,
    // and anything left unremoved gets a last attempt — nothing else holds those ids
    const pending = [...this.probes.values()]
    this.probes.clear()
    Promise.allSettled(pending)
      .then(() => this.retryCleanup())
      .catch(() => {})
      .finally(() => this.limiter.stop({ dropWaitingJobs: true }).catch(() => {}))
  }
}
