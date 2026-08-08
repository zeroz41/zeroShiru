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
    poll: 1_000 // gap between status polls
  }

  /** @type {number} Most files one resolve turns into stream links, guards against huge season packs. */
  static maxFiles = 60

  /** @param {string} apiKey */
  constructor (apiKey) {
    this.apiKey = apiKey
    this.rateLimitPromise = null
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
    this.limiter.stop({ dropWaitingJobs: true }).catch(() => {})
  }
}
