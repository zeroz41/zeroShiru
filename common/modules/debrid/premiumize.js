// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError, DebridAuthError, DebridNotCachedError, DebridUnavailableError } from './service.js'
import { Availability } from './availability.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

const API = 'https://www.premiumize.me/api'

/**
 * Premiumize error codes worth explaining, anything else falls back to the API's own message.
 * https://www.premiumize.me/api
 */
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
// the account cannot take on more work right now, rather than this release being a problem
const throttleCodes = ['rate_limit_reached', 'account_limit_reached', 'service_limit_reached']
// the same request will keep failing, so this release is not one Premiumize can serve
const deadCodes = ['service_unsupported', 'permanent_error']

/**
 * Premiumize implementation, see https://www.premiumize.me/api
 *
 * The easiest of the services to support, because it kept the two endpoints the others dropped:
 * - `/cache/check` answers a whole results list in one request and costs the account nothing, so
 *   every release can carry a real badge.
 * - `/transfer/directdl` returns every stream link for a magnet in a single call, reading the
 *   cache without storing anything. Nothing is ever added to the user's cloud, which is why this
 *   client has no cleanup path at all.
 *
 * The one thing it cannot do is describe the account: `/transfer/list` names transfers but never
 * says which info hash a transfer came from, so `listAvailability` has nothing to report and
 * badges come from the cache endpoint alone.
 */
export default class Premiumize extends DebridService {
  static id = 'premiumize'
  static title = 'Premiumize'
  static available = true
  // a real cache endpoint, so badges cost one request for the whole results list
  static availabilityCheck = 'batch'
  // hashes travel in the POST body rather than the URL, so the chunk size is about keeping one
  // request's work reasonable rather than about URL length
  static maxBatch = 100
  // no documented allowance, so this is deliberately modest: the two endpoints in use here are
  // one request per results list and one per playback
  static limits = { maxConcurrent: 3, minTime: 250 }

  /**
   * Premiumize reports business failures inside a 200 with `{ status: 'error', message, code }`,
   * and returns its payload at the top level rather than in an envelope.
   */
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

  /**
   * Nothing to read: `/transfer/list` describes transfers by name and progress and never carries
   * the info hash they came from, so an entry cannot be matched to a release in the results list.
   * Premiumize does not need it — its cache endpoint answers about any release, whether or not
   * the account has ever touched it, which is the thing an account listing is a substitute for
   * everywhere else.
   */
  async listAvailability () {
    return new Map()
  }

  /** @see listAvailability - the account listing carries no info hashes, so nothing reads it. */
  async fetchListing () {
    return []
  }

  /**
   * One request, however many releases, and it costs the account nothing.
   * @param {string[]} hashes
   */
  async checkAvailabilityBatch (hashes) {
    const checked = await this.request(`${API}/cache/check`, { method: 'POST', body: { 'items[]': hashes.map(hash => Premiumize.toMagnet(hash)) } })
    // the answer is parallel arrays indexed by request order rather than a map keyed by hash
    const cached = checked?.response || []
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
   * Reads every stream link for a magnet out of the cache in one call.
   *
   * Unlike the services that have to put a torrent on the account to find out, this touches
   * nothing, so there is no cleanup path and no reason to check the cache first — a miss simply
   * comes back empty or as a code, and both are turned into the answer they stand for here.
   * @param {string} magnetURI
   * @returns {Promise<any[]>} The transfer's file entries.
   */
  async #directdl (magnetURI) {
    let transfer = null
    try {
      transfer = await this.request(`${API}/transfer/directdl`, { method: 'POST', body: { src: magnetURI } })
    } catch (error) {
      // Premiumize groups its codes by whether the same request could ever succeed, which maps
      // straight onto what playback needs to know
      if (deadCodes.includes(error?.code)) throw new DebridUnavailableError(error.message, { status: error.status, code: error.code })
      if (error?.code === 'not_found') throw new DebridNotCachedError() // it can still fetch it, just not now
      throw error
    }
    const content = (transfer?.content || []).filter(entry => entry?.link)
    // directdl only ever reads the cache, so nothing to hand back means nothing is held
    if (!content.length) throw new DebridNotCachedError()
    return content
  }
}

/**
 * Premiumize reports a file's path inside the source without a leading slash. Shiru's file
 * objects use a rooted path, like the torrent client's.
 * @param {any} entry
 */
function filePath (entry) {
  const path = entry?.path || ''
  return path.startsWith('/') ? path : `/${path}`
}

/**
 * A name for the release, which directdl never states outright. Everything in a pack sits under
 * one folder, so that folder is the torrent name; a single file release is its own name.
 * @param {{ path: string, name: string }[]} files
 */
function torrentName (files) {
  const [first] = files
  const folder = first.path.split('/')[1]
  return files.every(file => file.path.startsWith(`/${folder}/`)) ? folder : first.name
}
