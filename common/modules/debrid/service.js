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

/**
 * @typedef {Object} DebridFile
 * @property {string} name - File name without directories.
 * @property {string} path - Path within the torrent, always starting with a slash.
 * @property {number} size - File size in bytes.
 * @property {string} url - Direct HTTPS stream URL.
 * @property {string} [type] - MIME type when the service reports one.
 */

/**
 * @typedef {Object} DebridResolved
 * @property {string} hash - Lowercase info hash.
 * @property {string} name - Torrent name.
 * @property {DebridFile[]} files - Streamable files, in torrent order.
 */

/**
 * Base class for debrid services, providing rate limited requests and typed errors.
 * Implementations only talk HTTP, state is per-instance so services stay swappable.
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

  /** @param {string} apiKey */
  constructor (apiKey) {
    this.apiKey = apiKey
    this.rateLimitPromise = null
    this.limiter = new Bottleneck(/** @type {typeof DebridService} */(this.constructor).limits)
    this.limiter.on('failed', (error, jobInfo) => {
      if (error instanceof DebridNetworkError) return // offline, retrying just delays the error
      if (error instanceof DebridError && error.status === 429 && jobInfo.retryCount < 2) {
        const time = (Number(error.retryAfter) || 5) * 1_000
        debug(`Rate limited by ${/** @type {typeof DebridService} */(this.constructor).title}, retrying in ${time}ms`)
        if (!this.rateLimitPromise) this.rateLimitPromise = new Promise(resolve => setTimeout(resolve, time).unref?.()).then(() => { this.rateLimitPromise = null })
        return time
      }
      if (!(error instanceof DebridError) && jobInfo.retryCount < 1) return 3_000 // single retry for network hiccups
    })
    this.request = this.limiter.wrap(this.#request.bind(this))
  }

  /**
   * @param {string} url - Absolute request URL.
   * @param {{ method?: string, body?: Record<string, string>, timeout?: number }} [opts] - Body is sent form-encoded.
   */
  async #request (url, { method = 'GET', body, timeout = 30_000 } = {}) {
    await this.rateLimitPromise
    if (!this.apiKey) throw new DebridAuthError('No debrid API key configured')
    debug(`${method} ${url}`)
    const res = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${this.apiKey}`, ...(body ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}) },
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
   * Verifies the API key and that the account can stream torrents.
   * @abstract
   * @returns {Promise<{ username: string, expires?: string }>}
   */
  async validate () { throw new Error('Not implemented') }

  /**
   * Lists info hashes that are already downloaded on the account, used for instant playback badges.
   * @abstract
   * @returns {Promise<string[]>} Lowercase info hashes.
   */
  async listCachedHashes () { throw new Error('Not implemented') }

  /**
   * Resolves a magnet to direct stream URLs, throws DebridNotCachedError when the
   * service would have to download the torrent first.
   * @abstract
   * @param {string} magnet - Magnet URI or bare info hash.
   * @param {{ fileFilter?: (name: string) => boolean, maxFiles?: number }} [opts]
   * @returns {Promise<DebridResolved>}
   */
  async resolve (magnet, opts) { throw new Error('Not implemented') }

  /** Cancels queued requests, the instance must not be used afterwards. */
  destroy () {
    this.limiter.stop({ dropWaitingJobs: true }).catch(() => {})
  }
}
