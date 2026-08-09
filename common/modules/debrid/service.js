import Bottleneck from 'bottleneck'
import Debug from 'debug'
const debug = Debug('ui:debrid')

// This module is intentionally free of UI imports so it can also run under plain Node for testing.

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

/** Thrown when the API key is missing, invalid or the account lacks the required plan. */
export class DebridAuthError extends DebridError {
  constructor (message, opts) {
    super(message, opts)
    this.name = 'DebridAuthError'
  }
}

/** Thrown when the service could not be reached at all, usually because the client is offline. */
export class DebridNetworkError extends DebridError {
  constructor (message, opts) {
    super(message, opts)
    this.name = 'DebridNetworkError'
  }
}

/** Thrown when a torrent is not present in the service's instant cache. */
export class DebridNotCachedError extends DebridError {
  constructor (message = 'Torrent is not cached on the debrid service', opts) {
    super(message, opts)
    this.name = 'DebridNotCachedError'
  }
}

/** Thrown by the base class for any method a service template has not filled in yet. */
export class DebridNotImplementedError extends DebridError {
  /** @param {string} title - The service's display name. */
  constructor (title) {
    super(`${title || 'This debrid service'} support is not implemented yet`)
    this.name = 'DebridNotImplementedError'
  }
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
 * Holds services to the HTTPS half of the DebridFile contract. Debrid links are
 * account bound, so a service handing back cleartext would put the user's traffic
 * and their link on the wire in the clear, silently. Dropped rather than downgraded.
 * @param {DebridFile[]} files
 * @param {string} title - Service name, for the message the user sees.
 * @returns {DebridFile[]} The files safe to stream.
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

// retry policy for the shared limiter, applies to every service
const RATE_LIMIT_RETRIES = 2
const RATE_LIMIT_FALLBACK = 5 // seconds to wait when a 429 carries no retry-after header
const NETWORK_RETRY_DELAY = 3_000

/**
 * Base class for debrid services, providing rate limited requests and typed errors.
 * Implementations only talk HTTP, state is per-instance so services stay swappable.
 *
 * Adding a service means subclassing this, setting the statics below, and
 * implementing the three abstract methods. Nothing outside the new file needs to
 * change apart from one entry in the registry in `debrid.js`. Anything left
 * unimplemented reports itself clearly instead of failing obscurely.
 * @abstract
 */
export default class DebridService {
  /** @type {string} Unique lowercase identifier, e.g. 'realdebrid'. */
  static id = ''
  /** @type {string} Human readable service name. */
  static title = ''
  /** @type {boolean} Only implemented and tested services are offered in the settings menu. */
  static available = false
  /** @type {import('bottleneck').ConstructorOptions} Request rate limits for the service API. */
  static limits = { maxConcurrent: 4, minTime: 250 }
  /** @type {'bearer' | 'query'} How the API key travels: an Authorization header or a query parameter. */
  static auth = 'bearer'
  /** @type {string} Query parameter name used when `auth` is 'query'. */
  static authParam = 'apikey'
  /** Tunable time limits in milliseconds, override only what differs for the service. */
  static timeouts = {
    request: 30_000, // hard limit on a single HTTP request
    select: 12_000, // waiting for the service to accept a magnet and expose its file list
    ready: 5_000, // waiting for a cached torrent to report ready, anything slower is a fresh download
    poll: 1_000, // gap between status polls
    probe: 8_000 // budget for one cache probe, past this the release is not instantly playable
  }

  /** @type {number} Most files one resolve turns into stream links, guards against huge season packs. */
  static maxFiles = 60

  /**
   * @type {'none' | 'batch' | 'probe'} How the service can be asked whether it holds a release.
   * 'batch' services answer for many hashes in one cheap call, which is by far the best case.
   * 'probe' is for services with no such endpoint, where the only way to find out is to add
   * the magnet and read the status back, costing several requests per hash.
   */
  static cacheCheck = 'none'
  /** @type {number} Most hashes one checkCached call probes, since probing is the expensive path. */
  static maxProbes = 10
  /**
   * How long a cache answer stays trusted, in milliseconds. A miss expires far sooner than a
   * hit: anyone can pull a release into the service's cache at any moment, but a release it
   * already holds rarely disappears.
   */
  static cacheTTL = { hit: 6 * 60 * 60_000, miss: 20 * 60_000 }

  /** @param {string} apiKey */
  constructor (apiKey) {
    this.apiKey = apiKey
    this.rateLimitPromise = null
    /** @type {Map<string, { cached: boolean, at: number }>} What the service has already said about a hash. */
    this.cacheState = new Map()
    /** @type {Map<string, Promise<boolean>>} Probes in flight, so the same hash is never asked about twice at once. */
    this.probes = new Map()
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

  /** The subclass's static configuration, typed so implementations get completions. */
  get config () {
    return /** @type {typeof DebridService} */ (this.constructor)
  }

  /**
   * The lowercase info hash of a magnet URI or bare hash, empty when there is none.
   * Every service takes the same input shape, so the parsing lives here once.
   * @param {any} magnetOrHash
   * @returns {string}
   */
  static parseHash (magnetOrHash) {
    if (typeof magnetOrHash !== 'string') return ''
    return (magnetHashRx.exec(magnetOrHash)?.[1] || (bareHashRx.test(magnetOrHash) ? magnetOrHash : '')).toLowerCase()
  }

  /**
   * Normalizes a magnet URI or bare info hash into a magnet URI to hand to the API.
   * @param {any} magnetOrHash
   * @returns {string} Empty when the input holds no usable hash.
   */
  static toMagnet (magnetOrHash) {
    if (typeof magnetOrHash === 'string' && magnetOrHash.startsWith('magnet:')) return magnetOrHash
    const hash = this.parseHash(magnetOrHash)
    return hash ? `magnet:?xt=urn:btih:${hash}` : ''
  }

  /**
   * Applies the service's authentication scheme to an outgoing request.
   * @param {string} url
   * @returns {{ url: string, headers: Record<string, string> }}
   */
  authorize (url) {
    if (this.config.auth !== 'query') return { url, headers: { Authorization: `Bearer ${this.apiKey}` } }
    const target = new URL(url)
    target.searchParams.set(this.config.authParam, this.apiKey)
    return { url: target.href, headers: {} }
  }

  /**
   * @param {string} url - Absolute request URL.
   * @param {{ method?: string, body?: Record<string, string>, timeout?: number }} [opts] - Body is sent form-encoded.
   */
  async #request (url, { method = 'GET', body, timeout = this.config.timeouts.request } = {}) {
    await this.rateLimitPromise
    if (!this.apiKey) throw new DebridAuthError('No debrid API key configured')
    const authorized = this.authorize(url)
    debug(`${method} ${url}`) // logged before authorization so query-parameter keys never reach the log
    const res = await fetch(authorized.url, {
      method,
      headers: { ...authorized.headers, ...(body ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}) },
      body: body && new URLSearchParams(body).toString(),
      signal: AbortSignal.timeout(timeout)
    })
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
    return res.json().catch(() => null) // some endpoints return an empty body on success
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
   * Caps a pack's file list, keeping a window centred on the file playback wants rather
   * than its first N entries. Every service hits this: a season pack can hold hundreds of
   * files, the wanted episode is often a late one, and dropping it forces an expensive
   * re-add. Torrent order is preserved so in-player next/previous still works.
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
   * Turns candidate files into stream links concurrently, skipping the individual ones the
   * service cannot serve. Packs really do contain dead files (Real-Debrid answers
   * `hoster_unavailable`), and one of those must not fail the whole resolve. Authentication
   * failures still abort, since every other link would fail for the same reason.
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
   * Records what is known about a release so later checks are free. Playback feeds this
   * too: a resolve that succeeded proves the service holds it, a not-cached error proves
   * it does not, and neither costs a request to find out again.
   * @param {string} magnetOrHash
   * @param {boolean} cached
   */
  remember (magnetOrHash, cached) {
    const hash = DebridService.parseHash(magnetOrHash)
    if (hash) this.cacheState.set(hash, { cached, at: Date.now() })
  }

  /**
   * A remembered answer that has not expired, or undefined when the hash needs asking about.
   * @param {string} hash
   * @returns {boolean | undefined}
   */
  #recall (hash) {
    const known = this.cacheState.get(hash)
    if (!known) return undefined
    if (Date.now() - known.at < (known.cached ? this.config.cacheTTL.hit : this.config.cacheTTL.miss)) return known.cached
    this.cacheState.delete(hash) // stale, ask again
    return undefined
  }

  /**
   * The given hashes that nothing is known about yet, in the order supplied. Callers use
   * this to skip work entirely rather than to decide what to ask about, which checkCached
   * does itself.
   * @param {string[]} magnetsOrHashes
   * @returns {string[]}
   */
  unknownHashes (magnetsOrHashes) {
    return DebridService.#normalize(magnetsOrHashes).filter(hash => this.#recall(hash) === undefined && !this.probes.has(hash))
  }

  /** Lowercase, deduplicated hashes, order preserved. */
  static #normalize (magnetsOrHashes) {
    return [...new Set((magnetsOrHashes || []).map(entry => DebridService.parseHash(entry)).filter(Boolean))]
  }

  /**
   * Reports which of the given releases the service can stream instantly.
   *
   * Remembered answers come back for free. Whatever is left is asked about in the cheapest
   * way the service supports: one batch call where the API offers a cache endpoint, or a
   * capped number of probes where it does not, because a probe costs several requests.
   * Hashes that stay unanswered are simply absent from `checked`, which callers must treat
   * as "unknown" rather than "not cached".
   * @param {string[]} magnetsOrHashes - Candidates, most relevant first, since the cap bites from the end.
   * @param {{ probe?: boolean, limit?: number }} [opts]
   * @returns {Promise<{ cached: Set<string>, checked: Set<string> }>}
   */
  async checkCached (magnetsOrHashes, { probe = true, limit = this.config.maxProbes } = {}) {
    const cached = new Set()
    const checked = new Set()
    const unknown = []
    for (const hash of DebridService.#normalize(magnetsOrHashes)) {
      const known = this.#recall(hash)
      if (known === undefined) unknown.push(hash)
      else {
        checked.add(hash)
        if (known) cached.add(hash)
      }
    }
    if (!unknown.length || this.config.cacheCheck === 'none') return { cached, checked }

    if (this.config.cacheCheck === 'batch') {
      const hits = await this.checkCachedBatch(unknown)
      for (const hash of unknown) {
        const hit = hits.has(hash)
        this.remember(hash, hit)
        checked.add(hash)
        if (hit) cached.add(hash)
      }
      return { cached, checked }
    }

    if (!probe) return { cached, checked }
    const targets = unknown.slice(0, Math.max(0, limit))
    if (targets.length < unknown.length) debug(`Probing ${targets.length} of ${unknown.length} unknown hashes, the rest stay unknown`)
    await Promise.all(targets.map(async hash => {
      try {
        if (await this.#probe(hash)) cached.add(hash)
        checked.add(hash)
      } catch (error) {
        if (error instanceof DebridAuthError) throw error // the key is wrong, every other probe would fail too
        debug(`Cache probe failed for ${hash}: ${error.message}`)
      }
    }))
    return { cached, checked }
  }

  /** Runs one probe, sharing a single request with any caller already waiting on that hash. */
  #probe (hash) {
    let pending = this.probes.get(hash)
    if (!pending) {
      pending = this.probeCached(hash)
        .then(result => {
          this.remember(hash, result)
          return result
        })
        .finally(() => this.probes.delete(hash))
      this.probes.set(hash, pending)
    }
    return pending
  }

  /**
   * Asks the service about many releases at once. Implement this for any API that exposes a
   * cache endpoint, and set `cacheCheck` to 'batch': it is one request instead of dozens.
   * @abstract
   * @param {string[]} hashes - Lowercase info hashes.
   * @returns {Promise<Set<string>>} The subset the service can stream instantly.
   */
  async checkCachedBatch (hashes) { throw new DebridNotImplementedError(this.config.title) }

  /**
   * Determines whether one release is cached, for services with no cache endpoint.
   * Implementations must leave the account exactly as they found it, and must resolve
   * false rather than throwing when the answer is simply "no".
   * @abstract
   * @param {string} hash - Lowercase info hash.
   * @returns {Promise<boolean>}
   */
  async probeCached (hash) { throw new DebridNotImplementedError(this.config.title) }

  /**
   * Verifies the API key and that the account can stream torrents.
   * @abstract
   * @returns {Promise<{ username: string, expires?: string }>}
   */
  async validate () { throw new DebridNotImplementedError(this.config.title) }

  /**
   * Lists info hashes that are already downloaded on the account, used for instant playback badges.
   * Services with a real cache-check endpoint can answer this far more completely than
   * Real-Debrid can, the app treats the result as a hint either way.
   * @abstract
   * @returns {Promise<string[]>} Lowercase info hashes.
   */
  async listCachedHashes () { throw new DebridNotImplementedError(this.config.title) }

  /**
   * Resolves a magnet to direct stream URLs, throws DebridNotCachedError when the
   * service would have to download the torrent first. Returned URLs must be HTTPS.
   * @abstract
   * @param {string} magnet - Magnet URI or bare info hash.
   * @param {{ fileFilter?: (name: string) => boolean, pickFile?: (files: { id: number, path: string, size: number }[]) => Promise<any>, maxFiles?: number }} [opts]
   * @returns {Promise<DebridResolved>}
   */
  async resolve (magnet, opts) { throw new DebridNotImplementedError(this.config.title) }

  /** Cancels queued requests, the instance must not be used afterwards. */
  destroy () {
    this.cacheState.clear()
    this.probes.clear()
    this.limiter.stop({ dropWaitingJobs: true }).catch(() => {})
  }
}
