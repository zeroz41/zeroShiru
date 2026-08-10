// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError, DebridAuthError, DebridNotCachedError, DebridUnavailableError } from './service.js'
import { Availability } from './availability.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

const API = 'https://api.alldebrid.com'
// magnet status and the file tree moved to v4.1, everything else is still v4
const V4 = `${API}/v4`
const V41 = `${API}/v4.1`

/**
 * AllDebrid error codes worth explaining, anything else falls back to the API's own message.
 * https://docs.alldebrid.com/
 */
const errorMessages = {
  AUTH_BAD_APIKEY: 'Invalid AllDebrid API key',
  AUTH_MISSING_APIKEY: 'AllDebrid requires an API key for this request',
  AUTH_BLOCKED: 'AllDebrid has blocked this API key',
  AUTH_USER_BANNED: 'This AllDebrid account is banned',
  MUST_BE_PREMIUM: 'AllDebrid premium is required for this',
  MAGNET_MUST_BE_PREMIUM: 'AllDebrid premium is required to stream torrents',
  MAGNET_TOO_MANY_ACTIVE: 'Too many active AllDebrid magnets, wait for one to finish',
  MAGNET_TOO_LARGE: 'This release is larger than the AllDebrid plan allows',
  MAGNET_INVALID_URI: 'AllDebrid would not accept this magnet',
  MAGNET_NO_SERVER: 'No AllDebrid server is available right now',
  NO_SERVER: 'No AllDebrid server is available right now',
  LINK_TOO_MANY_DOWNLOADS: 'Too many active AllDebrid downloads, wait for one to finish',
  LINK_HOST_UNAVAILABLE: 'AllDebrid cannot serve this file right now',
  LINK_DOWN: 'AllDebrid reports this file as dead',
  FREE_TRIAL_LIMIT_REACHED: 'This AllDebrid trial has reached its limit'
}
// only these mean the key or plan is the problem, the rest are per-request
const authCodes = ['AUTH_BAD_APIKEY', 'AUTH_MISSING_APIKEY', 'AUTH_BLOCKED', 'AUTH_USER_BANNED', 'MUST_BE_PREMIUM', 'MAGNET_MUST_BE_PREMIUM']
// the account cannot take on more work right now, rather than this release being a problem
const throttleCodes = ['MAGNET_TOO_MANY_ACTIVE', 'LINK_TOO_MANY_DOWNLOADS', 'MAGNET_NO_SERVER', 'NO_SERVER']
// AllDebrid will never take this release, whoever asks and whenever
const deadCodes = ['MAGNET_INVALID_URI', 'MAGNET_INVALID_FILE', 'MAGNET_TOO_LARGE']

// statusCode from /magnet/status: 4 is finished, below it the magnet is still being worked on,
// above it every value is a way of having failed. See the status code table in the API docs.
const READY = 4

/**
 * AllDebrid implementation, see https://docs.alldebrid.com/
 *
 * Two things about the API decide the shape of this client:
 * - `/magnet/instant` is gone — the endpoint 404s exactly like one that never existed, and it is
 *   absent from the current docs — so, as on Real-Debrid, the only way to ask about a release is
 *   to put the magnet on the account and read what comes back. AllDebrid answers that in the
 *   upload response itself, and takes many magnets per request, so a whole page of results costs
 *   one upload and one delete each rather than Real-Debrid's five requests per hash. What it
 *   still costs is the account: every magnet checked lands there for a moment, so the base class
 *   cap on how far down a list to look applies here too.
 * - `/magnet/status` describes a magnet by name and progress but never says which info hash it
 *   came from, so an entry cannot be matched back to a release. That rules out reading badges off
 *   the account, and it is why this client reads the account only to know which magnet ids were
 *   already there before it uploaded anything — the ids it did not create are the user's, and
 *   deleting one of those is not a recoverable mistake.
 */
export default class AllDebrid extends DebridService {
  static id = 'alldebrid'
  static title = 'AllDebrid'
  static available = true
  // one upload answers many hashes, so the check batches even though it is not free
  static availabilityCheck = 'batch'
  // ...and what makes it not free: every hash checked lands on the account for a moment
  static checkAddsMagnets = true
  // every hash in a batch briefly owns a magnet on the account, so both the chunk size and how
  // far down a results list this looks stay small. Real-Debrid's probe cap, for the same reason
  static maxBatch = 10
  static maxAsk = 10
  // no documented allowance; modest limits, since uploading is the expensive half of this API
  static limits = { maxConcurrent: 3, minTime: 250 }

  /** AllDebrid wraps every response in `{ status, data, error }` and reports failures with a 200. */
  unwrap (json) {
    if (!json || typeof json !== 'object' || !('status' in json)) return json
    if (json.status !== 'success') throw this.mapError(200, json)
    return json.data
  }

  mapError (status, json) {
    const code = json?.error?.code
    const message = errorMessages[code] || json?.error?.message || `Request failed with status ${status}`
    if (authCodes.includes(code) || ((status === 401 || status === 403) && !code)) return new DebridAuthError(message, { status, code })
    return new DebridError(message, { status, code })
  }

  /** @param {any} error */
  throttled (error) {
    return super.throttled(error) || throttleCodes.includes(error?.code)
  }

  async validate () {
    const user = (await this.request(`${V4}/user`))?.user
    if (!user) throw new DebridAuthError('AllDebrid did not recognise this API key')
    if (!user.isPremium && !user.isTrial) throw new DebridAuthError('AllDebrid premium is required to stream torrents')
    return { username: user.username || user.email || 'AllDebrid user', expires: user.premiumUntil ? new Date(user.premiumUntil * 1_000).toISOString() : undefined }
  }

  /**
   * The account's magnets. Read only to tell this client's magnets from the user's own, never for
   * badges: the entries carry no info hash, so there is no way to say which release one describes.
   */
  async fetchListing () {
    return this.#magnets()
  }

  /** @see fetchListing - the account listing carries no info hashes, so nothing can be read off it. */
  async listAvailability () {
    return new Map()
  }

  /**
   * Uploads the hashes, reads the `ready` flag the upload answers with, and takes back off the
   * account everything this call put there.
   *
   * The account is read first rather than afterwards, because that read is the only thing that
   * says which magnet ids existed before: an upload of a magnet the account already holds answers
   * with the existing entry, so without it a check would happily delete the user's own magnet.
   * @param {string[]} hashes
   */
  async checkAvailabilityBatch (hashes) {
    const existing = await this.#accountIds({ fresh: true })
    const uploaded = await this.#upload(hashes)
    const answers = new Map()
    const ours = []
    for (const entry of uploaded) {
      if (entry?.id != null && !existing.has(String(entry.id))) ours.push(entry.id)
      const hash = AllDebrid.parseHash(entry?.hash || entry?.magnet)
      if (!hash) continue
      // a rejected magnet is an answer when the rejection is about the release itself, and no
      // answer at all when it is about the account being busy
      if (entry.error) {
        if (deadCodes.includes(entry.error.code)) answers.set(hash, Availability.UNAVAILABLE)
        else debug(`AllDebrid did not answer for ${hash}: ${entry.error.code}`)
        continue
      }
      answers.set(hash, entry.ready ? Availability.CACHED : Availability.AVAILABLE)
    }
    await this.#deleteAll(ours)
    return answers
  }

  async resolve (magnet, { fileFilter = () => true, pickFile, maxFiles = this.config.maxFiles } = {}) {
    const hash = AllDebrid.parseHash(magnet)
    const magnetURI = AllDebrid.toMagnet(magnet)
    if (!magnetURI) throw new DebridError('AllDebrid needs a magnet link or info hash to resolve')
    // same reason as the availability check: only the ids that were not here a moment ago are
    // ours to remove again if this resolve cannot go through
    const existing = await this.#accountIds({ fresh: true })
    const [uploaded] = await this.#upload([magnetURI])
    if (uploaded?.error) throw uploadError(uploaded.error)
    const id = uploaded?.id
    if (id == null) throw new DebridError('AllDebrid did not report the magnet back after adding it')
    const added = !existing.has(String(id))
    try {
      if (!uploaded.ready) throw new DebridNotCachedError()
      const magnetInfo = (await this.#magnets(id))[0]
      // the upload already said this one is ready, so an empty read is the request failing rather
      // than an answer about the release, and must not be reported as one
      if (!magnetInfo) throw new DebridError('AllDebrid did not report the magnet back after adding it')
      const state = magnetAvailability(magnetInfo)
      if (state === Availability.UNAVAILABLE) throw new DebridUnavailableError(`AllDebrid could not process this torrent (${magnetInfo.status || 'failed'})`)
      if (state !== Availability.CACHED) throw new DebridNotCachedError()

      const wanted = flattenFiles(await this.#files(magnetInfo)).filter(file => fileFilter(file.path))
      if (!wanted.length) throw new DebridError('No playable files in this torrent')
      const target = pickFile ? await pickFile(wanted) : [...wanted].sort((a, b) => b.size - a.size)[0]
      const files = await this.#unlockLinks(AllDebrid.windowFiles(wanted, target, maxFiles))
      if (!files.length) throw new DebridError('AllDebrid returned no links for this torrent')
      debug(`Resolved ${files.length} files for ${magnetInfo.filename}`)
      return { hash, name: magnetInfo.filename, files }
    } catch (error) {
      // only clean up a magnet this call put on the account, never the user's own
      if (added) await this.#delete(id)
      throw error
    }
  }

  /**
   * Adds magnets, which is also how AllDebrid is asked whether it holds them: the response says
   * `ready` per magnet. Takes many at once, and answers about each one separately.
   * @param {string[]} magnetsOrHashes
   * @returns {Promise<any[]>}
   */
  async #upload (magnetsOrHashes) {
    const uploaded = await this.request(`${V4}/magnet/upload`, { method: 'POST', body: { 'magnets[]': magnetsOrHashes } })
    this.forgetListing() // the account has magnets the remembered listing does not
    return uploaded?.magnets || []
  }

  /**
   * The account's magnets, or one of them by id.
   * @param {string | number} [id]
   * @returns {Promise<any[]>}
   */
  async #magnets (id) {
    const data = await this.request(`${V41}/magnet/status`, { method: 'POST', body: id != null ? { id } : {} })
    // asking for one id has answered with a bare object rather than a list
    const magnets = data?.magnets
    return !magnets ? [] : Array.isArray(magnets) ? magnets : [magnets]
  }

  /**
   * A magnet's file tree. Asking about one magnet by id is documented to answer with its files
   * inline, and the dedicated endpoint is the fallback for when it does not — the two carry the
   * same tree, so nothing downstream has to know which one it came from.
   * @param {any} magnetInfo
   * @returns {Promise<any[]>}
   */
  async #files (magnetInfo) {
    if (magnetInfo.files?.length) return magnetInfo.files
    const data = await this.request(`${V4}/magnet/files`, { method: 'POST', body: { 'id[]': [magnetInfo.id] } })
    return data?.magnets?.[0]?.files || []
  }

  /**
   * The magnet ids currently on the account, as strings so they compare cleanly whichever way
   * the API types them.
   * @param {{ fresh?: boolean }} [opts]
   * @returns {Promise<Set<string>>}
   */
  async #accountIds (opts) {
    return new Set((await this.listing(opts)).map(entry => String(entry?.id)))
  }

  /**
   * Turns the wanted files into direct stream links. A dead file inside a pack is skipped rather
   * than failing the whole resolve, the same rule every service follows.
   * @param {{ path: string, size: number, link: string }[]} wanted
   */
  async #unlockLinks (wanted) {
    return this.mapFiles(wanted, async file => {
      const unlocked = await this.request(`${V4}/link/unlock?link=${encodeURIComponent(file.link)}`)
      if (!unlocked?.link) return null
      return { name: file.path.split('/').pop(), path: file.path, size: unlocked.filesize || file.size, url: unlocked.link }
    })
  }

  /** @param {(string | number)[]} ids */
  async #deleteAll (ids) {
    await Promise.all(ids.map(id => this.#delete(id)))
  }

  /** @param {string | number} id */
  async #delete (id) {
    await this.release(`${V4}/magnet/delete`, { method: 'POST', body: { id } })
  }
}

/**
 * The typed answer a rejected upload stands for. A release AllDebrid will never take is an
 * answer; anything else is the account or the moment, which proves nothing about the release.
 * @param {{ code?: string, message?: string }} error
 */
function uploadError (error) {
  const message = errorMessages[error?.code] || error?.message || 'AllDebrid would not accept this magnet'
  if (deadCodes.includes(error?.code)) return new DebridUnavailableError(message, { code: error?.code })
  return new DebridError(message, { code: error?.code })
}

/**
 * What the account says about one of its magnets, read from the status code table in the API
 * docs: one value means finished, everything below it is still in progress, everything above it
 * is a way of having failed.
 * @param {any} magnet
 * @returns {string}
 */
function magnetAvailability (magnet) {
  const code = Number(magnet?.statusCode)
  if (!Number.isFinite(code)) return Availability.UNKNOWN
  if (code === READY) return Availability.CACHED
  return code < READY ? Availability.AVAILABLE : Availability.UNAVAILABLE
}

/**
 * Flattens AllDebrid's file tree into rooted paths, like the torrent client's file objects.
 * An entry is a folder when it carries children in `e`, and a file when it carries a link in
 * `l`; names are in `n` and sizes in `s`.
 * @param {any[]} entries
 * @param {string} [prefix]
 * @returns {{ path: string, size: number, link: string }[]}
 */
function flattenFiles (entries, prefix = '') {
  return (entries || []).flatMap(entry => {
    const path = `${prefix}/${entry?.n || ''}`
    if (Array.isArray(entry?.e)) return flattenFiles(entry.e, path)
    return entry?.l ? [{ path, size: Number(entry.s) || 0, link: entry.l }] : []
  })
}
