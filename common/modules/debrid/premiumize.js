// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError, DebridAuthError, DebridNotCachedError, DebridUnavailableError } from './service.js'
import { Availability } from './availability.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

const API = 'https://www.premiumize.me/api'

// error codes worth explaining, anything else falls back to the API's own message
const errorMessages = {
  authentication_failed: 'Invalid Premiumize API key',
  permission_denied: 'Premiumize denied the request, check the account',
  account_limit_reached: 'This Premiumize account has used up its fair use points or active jobs',
  service_limit_reached: 'This Premiumize account has reached its limit for this source',
  rate_limit_reached: 'Premiumize is rate limiting this account, try again shortly',
  service_down: 'Premiumize cannot reach this source right now',
  service_unsupported: 'Premiumize cannot process this kind of source',
  link_generation_failed: 'Premiumize could not generate a stream link, try again shortly'
}
// only these mean the key or account is the problem, the rest are per-request
const authCodes = ['authentication_failed', 'permission_denied']
// the account cannot take more work right now, rather than this release being a problem
const throttleCodes = ['rate_limit_reached', 'account_limit_reached', 'service_limit_reached']
// the same request will keep failing, so this release is not one Premiumize can serve
const deadCodes = ['service_unsupported', 'permanent_error']

/**
 * Premiumize implementation, see https://www.premiumize.me/api
 *
 * The easiest service to support, having kept the endpoints the others dropped: `/cache/check`
 * answers a whole results list for free, and `/transfer/directdl` returns every stream link for a
 * magnet in one call without storing anything, so there is no add or cleanup path at all.
 *
 * `/transfer/list` never says which info hash a transfer came from, so badges come from the cache
 * endpoint alone.
 */
export default class Premiumize extends DebridService {
  static id = 'premiumize'
  static title = 'Premiumize'
  static available = true
  // a real cache endpoint, so badges cost one request for the whole results list
  static availabilityCheck = 'batch'
  static maxBatch = 100
  static limits = { maxConcurrent: 3, minTime: 250 } // no documented allowance, so be modest

  /** Failures arrive inside a 200; the payload is top level rather than in an envelope. */
  unwrap (json) {
    if (!json || typeof json !== 'object' || !('status' in json)) return json
    if (json.status === 'error') throw this.mapError(200, json)
    return json
  }

  mapError (status, json) {
    const code = json?.code
    const message = errorMessages[code] || json?.message || `Request failed with status ${status}`
    if (authCodes.includes(code) || ((status === 401 || status === 403) && !code)) return new DebridAuthError(message, { status, code })
    return new DebridError(message, { status, code })
  }

  /** @param {any} error */
  throttled (error) {
    return super.throttled(error) || throttleCodes.includes(error?.code)
  }

  async validate () {
    const account = await this.request(`${API}/account/info`)
    // free accounts stream cached content through the same endpoints, so premium is not required
    if (!account?.customer_id) throw new DebridAuthError('Premiumize did not recognise this API key')
    return { username: `Premiumize ${account.customer_id}`, expires: account.premium_until ? new Date(account.premium_until * 1_000).toISOString() : undefined }
  }

  /** Nothing to read: transfers carry no info hash. The cache endpoint covers this instead. */
  async listAvailability () {
    return new Map()
  }

  /** @see listAvailability - nothing reads the account listing. */
  async fetchListing () {
    return []
  }

  /**
   * One request, however many releases, and it costs the account nothing.
   * @param {string[]} hashes
   */
  async checkAvailabilityBatch (hashes) {
    const checked = await this.request(`${API}/cache/check`, { method: 'POST', body: { 'items[]': hashes.map(hash => Premiumize.toMagnet(hash)) } })
    const cached = checked?.response || [] // parallel arrays indexed by request order, not keyed by hash
    return new Map(hashes.map((hash, index) => [hash, cached[index] ? Availability.CACHED : Availability.AVAILABLE]))
  }

  async resolve (magnet, { fileFilter = () => true, pickFile, maxFiles = this.config.maxFiles } = {}) {
    const hash = Premiumize.parseHash(magnet)
    const magnetURI = Premiumize.toMagnet(magnet)
    if (!magnetURI) throw new DebridError('Premiumize needs a magnet link or info hash to resolve')
    const content = await this.#directdl(magnetURI)
    const wanted = content
      .map(entry => ({ name: filePath(entry).split('/').pop(), path: filePath(entry), size: Number(entry.size) || 0, url: entry.link }))
      .filter(file => fileFilter(file.path))
    if (!wanted.length) throw new DebridError('No playable files in this torrent')
    const target = pickFile ? await pickFile(wanted) : [...wanted].sort((a, b) => b.size - a.size)[0]
    const files = Premiumize.windowFiles(wanted, target, maxFiles)
    const name = torrentName(files)
    debug(`Resolved ${files.length} files for ${name}`)
    return { hash, name, files }
  }

  /**
   * Every stream link for a magnet, read out of the cache in one call. Touches nothing, so a
   * miss comes back empty or as a code rather than needing a check first.
   * @param {string} magnetURI
   * @returns {Promise<any[]>} The transfer's file entries.
   */
  async #directdl (magnetURI) {
    let transfer = null
    try {
      transfer = await this.request(`${API}/transfer/directdl`, { method: 'POST', body: { src: magnetURI } })
    } catch (error) {
      // the API groups its codes by whether the same request could ever succeed, which maps
      // straight onto what playback needs to know
      if (deadCodes.includes(error?.code)) throw new DebridUnavailableError(error.message, { status: error.status, code: error.code })
      if (error?.code === 'not_found') throw new DebridNotCachedError() // it can still fetch it, just not now
      throw error
    }
    const content = (transfer?.content || []).filter(entry => entry?.link)
    if (!content.length) throw new DebridNotCachedError() // directdl only reads the cache
    return content
  }
}

/**
 * Paths arrive without a leading slash; Shiru's file objects are rooted like the torrent client's.
 * @param {any} entry
 */
function filePath (entry) {
  const path = entry?.path || ''
  return path.startsWith('/') ? path : `/${path}`
}

/**
 * A name for the release, which directdl never states: the folder a pack sits under, or the file.
 * @param {{ path: string, name: string }[]} files
 */
function torrentName (files) {
  const [first] = files
  const folder = first.path.split('/')[1]
  return files.every(file => file.path.startsWith(`/${folder}/`)) ? folder : first.name
}
