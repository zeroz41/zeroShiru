// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError, DebridAuthError, DebridNotCachedError, DebridUnavailableError } from './service.js'
import { Availability } from './availability.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

const API = 'https://api.torbox.app/v1/api'
const LIST_LIMIT = 1_000 // the whole account in one request; the API pages at 1000
const SEED_NEVER = 3 // 1 auto, 2 always, 3 never. Shiru only streams, so never seed

// error codes worth explaining, anything else falls back to the API's own detail line
const errorMessages = {
  BAD_TOKEN: 'Invalid TorBox API key',
  AUTH_ERROR: 'TorBox rejected the API key',
  NO_AUTH: 'TorBox requires an API key for this request',
  PLAN_RESTRICTED_FEATURE: 'This TorBox plan does not include the feature Shiru needs',
  ACTIVE_LIMIT: 'Too many active TorBox downloads, wait for one to finish',
  MONTHLY_LIMIT: 'This TorBox account has reached its monthly limit',
  COOLDOWN_LIMIT: 'TorBox is cooling this account down, try again shortly',
  DOWNLOAD_TOO_LARGE: 'This release is larger than the TorBox plan allows',
  DOWNLOAD_SERVER_ERROR: 'TorBox could not reach its download server, try again shortly',
  NO_SERVERS_AVAILABLE_ERROR: 'No TorBox download servers are available right now'
}
// only these mean the key or plan is the problem, the rest are per-request
const authCodes = ['BAD_TOKEN', 'AUTH_ERROR', 'NO_AUTH', 'PLAN_RESTRICTED_FEATURE']
// download_state values that mean the torrent will never finish on its own
const deadStates = /(stalled|error|failed|missing)/i

/**
 * TorBox implementation, see https://api-docs.torbox.app/
 *
 * Three differences from Real-Debrid shape this client: `/torrents/checkcached` answers many
 * hashes in one request, every response is wrapped in `{ success, data }` with failures arriving
 * inside a 200, and `/torrents/requestdl` authenticates with a `token` query parameter while
 * everything else uses a bearer header.
 */
export default class TorBox extends DebridService {
  static id = 'torbox'
  static title = 'TorBox'
  static available = true
  // documented allowance is 300 a minute per endpoint; spending it as if it covered all of them
  // keeps a season pack's worth of link requests well inside it
  static limits = { reservoir: 300, reservoirRefreshAmount: 300, reservoirRefreshInterval: 60_000, maxConcurrent: 3, minTime: 200 }
  // a real cache endpoint, so badges cost one request for the whole results list
  static availabilityCheck = 'batch'
  // hashes travel as repeated query parameters, so the chunk size keeps the URL sane
  static maxBatch = 75

  /** Failures arrive inside a 200, so success is decided here rather than by the status code. */
  unwrap (json) {
    if (!json || typeof json !== 'object' || !('success' in json)) return json
    if (!json.success) throw this.mapError(200, json)
    return json.data
  }

  mapError (status, json) {
    const code = json?.error
    // `detail` is usually a sentence, but a rejected request answers with a list of field
    // problems instead, which is for the log rather than the user
    const detail = typeof json?.detail === 'string' ? json.detail : ''
    const message = errorMessages[code] || detail || (typeof code === 'string' && code) || `Request failed with status ${status}`
    if (authCodes.includes(code) || ((status === 401 || status === 403) && !code)) return new DebridAuthError(message, { status, code })
    return new DebridError(message, { status, code })
  }

  async validate () {
    const user = await this.request(`${API}/user/me?settings=false`)
    if (!user) throw new DebridAuthError('TorBox did not recognise this API key')
    return { username: user.email || user.customer || 'TorBox user', expires: user.premium_expires_at }
  }

  /**
   * The account's torrents. TorBox caches this itself, which is faster for the badge listing;
   * `bypass_cache` is only worth its latency when polling a change just made.
   * @param {{ id?: string | number, fresh?: boolean }} [opts]
   * @returns {Promise<any[]>}
   */
  async #accountTorrents ({ id, fresh } = {}) {
    const query = `limit=${LIST_LIMIT}${id != null ? `&id=${id}` : ''}${fresh ? '&bypass_cache=true' : ''}`
    const data = await this.request(`${API}/torrents/mylist?${query}`)
    // asking for one id answers with a bare object rather than a list
    return !data ? [] : Array.isArray(data) ? data : [data]
  }

  /** The whole account in one request, shared by the base class between badges and playback. */
  async fetchListing () {
    return this.#accountTorrents()
  }

  async listAvailability () {
    const known = new Map()
    for (const torrent of await this.listing()) {
      if (torrent?.hash) known.set(String(torrent.hash).toLowerCase(), torrentAvailability(torrent))
    }
    return known
  }

  /**
   * One request answers the whole results list. Hashes left out are not cached, which the base
   * class records as available.
   * @param {string[]} hashes
   */
  async checkAvailabilityBatch (hashes) {
    const query = hashes.map(hash => `hash=${hash}`).join('&')
    const data = await this.request(`${API}/torrents/checkcached?${query}&format=list`)
    // the endpoint has answered in both shapes over its life: a list of entries, or an object
    // keyed by hash. Both carry the same thing, which is simply "TorBox holds this one".
    const cached = Array.isArray(data) ? data.map(entry => entry?.hash) : Object.keys(data || {})
    const answers = new Map(hashes.map(hash => [hash, Availability.AVAILABLE]))
    for (const hash of cached) {
      const key = String(hash || '').toLowerCase()
      if (answers.has(key)) answers.set(key, Availability.CACHED)
    }
    return answers
  }

  async resolve (magnet, { fileFilter = () => true, pickFile, maxFiles = this.config.maxFiles } = {}) {
    const hash = TorBox.parseHash(magnet)
    if (!hash) throw new DebridError('TorBox needs a magnet link or info hash to resolve')
    const magnetURI = TorBox.toMagnet(magnet)
    let torrent = await this.#existingTorrent(hash)
    let added = false
    try {
      if (!torrent) {
        // ask before adding: the answer is free, and adding an uncached torrent spends from a
        // much tighter allowance (60 an hour) than a cached add does
        if ((await this.checkAvailabilityBatch([hash])).get(hash) !== Availability.CACHED) throw new DebridNotCachedError()
        ;({ torrent, added } = await this.#add(magnetURI, hash))
      }
      const state = torrentAvailability(torrent)
      if (state === Availability.UNAVAILABLE) throw new DebridUnavailableError(`TorBox could not process this torrent (${torrent.download_state || 'failed'})`)
      if (state !== Availability.CACHED) throw new DebridNotCachedError()

      const wanted = (torrent.files || []).filter(file => fileFilter(filePath(file))).map(file => ({ id: file.id, path: filePath(file), size: file.size, type: file.mimetype }))
      if (!wanted.length) throw new DebridError('No playable files in this torrent')
      const target = pickFile ? await pickFile(wanted) : [...wanted].sort((a, b) => b.size - a.size)[0]
      const files = await this.#requestLinks(torrent, TorBox.windowFiles(wanted, target, maxFiles))
      if (!files.length) throw new DebridError('TorBox returned no links for this torrent')
      debug(`Resolved ${files.length} files for ${torrent.name}`)
      return { hash: String(torrent.hash || hash).toLowerCase(), name: torrent.name, files }
    } catch (error) {
      // only clean up a torrent this call put on the account, never the user's own
      if (added && torrent?.id) await this.#delete(torrent.id)
      throw error
    }
  }

  /**
   * Adds a magnet and reads back the account entry for it. `added` reports whether this call is
   * what put it there, which is the only thing that makes it ours to remove again.
   * @param {string} magnetURI
   * @param {string} hash
   * @returns {Promise<{ torrent: any, added: boolean }>}
   */
  async #add (magnetURI, hash) {
    // allow_zip off keeps a pack as individual files rather than one archive the player cannot seek
    const created = await this.request(`${API}/torrents/createtorrent`, {
      method: 'POST',
      encoding: 'multipart',
      body: { magnet: magnetURI, seed: SEED_NEVER, allow_zip: false }
    }).catch(error => {
      // the account already held it, which is an answer rather than a failure
      if (error.code !== 'DUPLICATE_ITEM') throw error
      return null
    })
    this.forgetListing() // the account has a torrent the remembered listing does not
    const id = created?.torrent_id
    try {
      return { torrent: await this.#awaitTorrent(id, hash), added: id != null }
    } catch (error) {
      // awaited, so this call has undone itself by the time it reports failure
      if (id != null) await this.#delete(id)
      throw error
    }
  }

  /**
   * Waits for a freshly added torrent to show up and settle. A cached release is complete the
   * moment TorBox accepts it, so anything slower reads as a fresh download.
   * @param {string | number | undefined} id
   * @param {string} hash
   */
  async #awaitTorrent (id, hash) {
    const started = Date.now()
    while (true) {
      // deliberately unshared and uncached: this is polling a change made a moment ago
      const torrent = id != null ? (await this.#accountTorrents({ id, fresh: true }))[0] : (await this.#accountTorrents({ fresh: true })).find(entry => String(entry?.hash || '').toLowerCase() === hash)
      if (torrent && torrentAvailability(torrent) !== Availability.AVAILABLE) return torrent
      if (Date.now() - started > this.budget('ready')) {
        if (torrent) return torrent
        throw new DebridError('TorBox did not report the torrent back after adding it')
      }
      await new Promise(resolve => setTimeout(resolve, this.config.timeouts.poll).unref?.())
    }
  }

  /**
   * The account's entry for an info hash, which is how a release already there is reused rather
   * than added twice. Read back by id because the listing can be a minute stale, so one deleted
   * elsewhere must read as absent rather than fail the resolve.
   * @param {string} hash
   * @param {{ listed?: boolean }} [opts] - `listed` false skips the listing, for a hash known to be absent from it.
   * @returns {Promise<any | null>}
   */
  async #existingTorrent (hash, { listed = true } = {}) {
    if (!hash) return null
    const known = listed ? (await this.listing()).find(torrent => String(torrent?.hash || '').toLowerCase() === hash) : null
    if (!known) return null
    // a failed read reads as "gone": the caller then checks the cache and adds the magnet, which
    // fails loudly enough if the API is really unreachable
    const [confirmed] = await this.#accountTorrents({ id: known.id, fresh: true }).catch(() => [])
    if (!confirmed) {
      debug(`Account listing named a torrent that is gone (${known.id}), adding the magnet instead`)
      this.forgetListing()
    }
    return confirmed || null
  }

  /**
   * Turns the wanted files into direct stream links, skipping dead ones.
   * @param {any} torrent
   * @param {{ id: number, path: string, size: number, type?: string }[]} wanted
   */
  async #requestLinks (torrent, wanted) {
    return this.mapFiles(wanted, async file => {
      // this one endpoint takes the key as a query parameter instead of a bearer header
      const url = await this.request(`${API}/torrents/requestdl?torrent_id=${torrent.id}&file_id=${file.id}&redirect=false`, { auth: 'query', authParam: 'token' })
      if (typeof url !== 'string') return null
      return { name: file.path.split('/').pop(), path: file.path, size: file.size, url, type: file.type }
    })
  }

  /** @param {string | number} id */
  async #delete (id) {
    await this.release(`${API}/torrents/controltorrent`, { method: 'POST', encoding: 'json', body: { torrent_id: id, operation: 'delete' } })
  }
}

/**
 * What the account says about one of its torrents. `download_present` means the data really is on
 * TorBox's servers, which is the only thing that makes a release streamable now.
 * @param {any} torrent
 * @returns {string}
 */
function torrentAvailability (torrent) {
  if (torrent?.download_present || (torrent?.download_finished && torrent?.progress === 1)) return Availability.CACHED
  if (deadStates.test(torrent?.download_state || '')) return Availability.UNAVAILABLE
  return Availability.AVAILABLE
}

/**
 * Full path is in `name`, bare filename in `short_name`, neither rooted. Shiru's file objects are.
 * @param {any} file
 */
function filePath (file) {
  const path = file?.name || file?.short_name || ''
  return path.startsWith('/') ? path : `/${path}`
}
