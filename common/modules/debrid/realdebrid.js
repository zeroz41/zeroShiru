// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError, DebridAuthError, DebridNotCachedError, DebridTimeoutError, DebridUnavailableError, archiveRx } from './service.js'
import { Availability } from './availability.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

const API = 'https://api.real-debrid.com/rest/1.0'
const LIST_LIMIT = 1_000 // the whole account in one request, newest first

/**
 * What each torrent status means for playback. Magnet conversion and file selection are left out
 * on purpose: they are moments in a torrent's life, not outcomes, so they answer nothing.
 * @type {Record<string, string>}
 */
const statusAvailability = {
  downloaded: Availability.CACHED,
  // being fetched fresh, so Real-Debrid can serve it eventually but not now
  queued: Availability.AVAILABLE,
  downloading: Availability.AVAILABLE,
  uploading: Availability.AVAILABLE,
  compressing: Availability.AVAILABLE,
  // will never complete
  magnet_error: Availability.UNAVAILABLE,
  error: Availability.UNAVAILABLE,
  virus: Availability.UNAVAILABLE,
  dead: Availability.UNAVAILABLE
}

// error_code values worth explaining, anything else falls back to the API's own message
const errorMessages = {
  8: 'Invalid Real-Debrid API key',
  9: 'Real-Debrid denied the request, check the account permissions',
  21: 'Too many active Real-Debrid downloads, wait for one to finish',
  23: 'This Real-Debrid account has exhausted its traffic',
  34: 'Real-Debrid is rate limiting this account, try again shortly',
  35: 'Real-Debrid will not serve this file, pick a different release',
  36: 'Real-Debrid fair usage limit reached'
}
// only these mean the key or account is the problem, the rest are per-request
const authCodes = [8, 9]
// the account cannot take more work right now: rate limited, or at its active torrent cap
const throttleCodes = [21, 34]

/**
 * Real-Debrid implementation, see https://api.real-debrid.com/
 *
 * Two API quirks shape this client:
 * - `/torrents/instantAvailability` is disabled (403 `disabled_endpoint`), so a release can only
 *   be asked about by adding the magnet and reading the status back. Hence `probeAvailability`,
 *   and the base class cap on how many of those a search may cost.
 * - Selecting multiple files can serve one RAR archive instead of individual links, so when that
 *   happens the torrent is re-added selecting only the target file.
 */
export default class RealDebrid extends DebridService {
  static id = 'realdebrid'
  static title = 'Real-Debrid'
  static available = true
  // documented allowance is 250 requests per minute, keep some headroom
  static limits = { reservoir: 200, reservoirRefreshAmount: 200, reservoirRefreshInterval: 60_000, maxConcurrent: 4, minTime: 150 }
  // no cache endpoint any more, so availability has to be probed a hash at a time
  static availabilityCheck = 'probe'

  /**
   * @type {number} Status reads a probe gives a magnet still converting before giving up.
   *
   * Real-Debrid holds the metadata for anything cached, so a cached release reaches file selection
   * within a read or two; one still converting is telling us it is not. Counted in reads rather
   * than seconds so a slow link does not change how many chances it gets. Giving up leaves the
   * release unknown, so the next sweep asks again.
   */
  static probeConversionReads = 2

  /** @param {any} error */
  throttled (error) {
    return super.throttled(error) || throttleCodes.includes(error?.code)
  }

  mapError (status, json) {
    const code = json?.error_code
    const message = errorMessages[code] || json?.error || `Request failed with status ${status}`
    // a blocked or unavailable file also answers 403, and must stay a plain error: an auth error
    // aborts the whole resolve, where one bad file in a pack should only be skipped
    if (authCodes.includes(code) || ((status === 401 || status === 403) && code == null)) return new DebridAuthError(message, { status, code })
    return new DebridError(message, { status, code })
  }

  async validate () {
    const user = await this.request(`${API}/user`)
    if (user?.type !== 'premium') throw new DebridAuthError('Real-Debrid premium is required to stream torrents')
    return { username: user.username, expires: user.expiration }
  }

  /** The whole account in one request, shared by the base class between badges and playback. */
  async fetchListing () {
    return (await this.request(`${API}/torrents?limit=${LIST_LIMIT}`)) || []
  }

  async listAvailability () {
    const torrents = await this.listing()
    const known = new Map()
    for (const torrent of torrents) {
      const state = statusAvailability[torrent.status]
      if (state && torrent.hash) known.set(torrent.hash.toLowerCase(), state)
    }
    return known
  }

  /**
   * The only way Real-Debrid can still be asked about a release: add the magnet and read the
   * status it settles on. A cached torrent reports 'downloaded' within a second of file selection.
   * Costs about five requests, hence the cap in the base class.
   *
   * The torrent is always removed again, and adding a hash the account already holds creates a
   * separate entry, so this can never delete the user's own download.
   * @param {string} hash
   * @returns {Promise<string>}
   */
  async probeAvailability (hash) {
    const magnetURI = RealDebrid.toMagnet(hash)
    if (!magnetURI) throw new DebridError('Not a usable info hash') // no answer, rather than a made up one
    let torrentId = null
    try {
      torrentId = await this.#addAndSelect(magnetURI, () => true, { reads: RealDebrid.probeConversionReads })
      await this.#awaitStatus(torrentId, 'downloaded', this.budget('probe'))
      return Availability.CACHED
    } finally {
      // awaited, so the account is as we found it by the time this answers. Playback and teardown
      // both wait on it, so neither can trip over a half-finished probe
      if (torrentId) await this.release(`${API}/torrents/delete/${torrentId}`)
    }
  }

  async resolve (magnet, { fileFilter = () => true, pickFile, maxFiles = this.config.maxFiles } = {}) {
    const hash = RealDebrid.parseHash(magnet)
    const magnetURI = RealDebrid.toMagnet(magnet)
    let torrentId = null
    let added = false
    try {
      // a cache probe of this same release is about to delete its own torrent, so let it finish
      // first rather than reusing an id that is seconds from disappearing
      await this.probes.get(hash)?.catch(() => {})
      // reuse a torrent that is already on the account instead of adding a duplicate
      const existing = await this.#existingTorrent(hash)
      let info = null
      if (existing?.status === 'waiting_files_selection') {
        // a stale add that never got its files selected, finish the job
        const ids = existing.files.filter(file => fileFilter(file.path)).map(file => file.id)
        await this.request(`${API}/torrents/selectFiles/${existing.id}`, { method: 'POST', body: { files: ids.length ? ids.join(',') : 'all' } })
        torrentId = existing.id
      // mid-conversion counts as not cached here: playback cannot wait for it either way
      } else if (existing && existing.status !== 'downloaded') throw unstreamable(existing.status) ?? new DebridNotCachedError()
      else if (existing) {
        torrentId = existing.id
        info = existing // already confirmed downloaded, with its files and links
      } else {
        torrentId = await this.#addAndSelect(magnetURI, fileFilter)
        added = true
      }
      info ??= await this.#awaitStatus(torrentId, 'downloaded', this.budget('ready'))

      // work out which file playback is after before unrestricting, so a capped pack never drops
      // the wanted episode and archives can be recovered from
      const wanted = info.files.filter(file => fileFilter(file.path)).map(file => ({ id: file.id, path: file.path, size: file.bytes }))
      const target = wanted.length ? (pickFile ? await pickFile(wanted) : [...wanted].sort((a, b) => b.size - a.size)[0]) : null
      let files = await this.#unrestrictLinks(info, fileFilter, maxFiles, target)
      if (target && !files.some(file => file.name === target.path.split('/').pop())) {
        debug(`Re-adding torrent to select only ${target.path}`)
        const retryId = await this.#addAndSelect(magnetURI, null, { fileId: target.id })
        // not awaited: the player is already open waiting on this, cleanup can catch up
        if (added) this.release(`${API}/torrents/delete/${torrentId}`)
        torrentId = retryId
        added = true
        info = await this.#awaitStatus(torrentId, 'downloaded', this.budget('ready'))
        files = await this.#unrestrictLinks(info, fileFilter, 1, null)
        if (!files.length) throw new DebridError('Real-Debrid only serves this torrent as an archive')
      }
      if (!files.length) throw new DebridError('No playable files in this torrent')
      debug(`Resolved ${files.length} files for ${info.filename}`)
      return { hash: info.hash.toLowerCase(), name: info.filename, files }
    } catch (error) {
      // only clean up torrents this call added, never the user's own downloads
      if (added && torrentId) await this.release(`${API}/torrents/delete/${torrentId}`)
      // playback has waited as long as it can, so a magnet still converting is one it cannot use.
      // A probe leaves the same timeout unanswered instead, since Real-Debrid may just be slow
      throw error instanceof DebridTimeoutError ? new DebridNotCachedError() : error
    }
  }

  /**
   * The account's entry for an info hash, or null. Read back by id because the listing can be a
   * minute stale, so one deleted elsewhere must read as absent rather than fail the resolve.
   * @param {string} hash
   * @returns {Promise<any | null>}
   */
  async #existingTorrent (hash) {
    if (!hash) return null
    const listed = (await this.listing()).find(torrent => torrent.hash?.toLowerCase() === hash)
    if (!listed) return null
    try {
      return await this.request(`${API}/torrents/info/${listed.id}`)
    } catch (error) {
      if (error.status !== 404) throw error
      debug(`Account listing named a torrent that is gone (${listed.id}), adding the magnet instead`)
      this.forgetListing()
      return null
    }
  }

  /**
   * Adds a magnet and selects either the files matching the filter or one specific file.
   * @param {string} magnetURI
   * @param {((name: string) => boolean) | null} fileFilter
   * @param {{ fileId?: number, reads?: number }} [opts] - `fileId` selects one file outright,
   *   `reads` caps how many status reads the magnet gets to convert, for probes.
   * @returns {Promise<string>} The new torrent id.
   */
  async #addAndSelect (magnetURI, fileFilter, { fileId, reads } = {}) {
    const torrentId = (await this.request(`${API}/torrents/addMagnet`, { method: 'POST', body: { magnet: magnetURI } }))?.id
    this.forgetListing() // the account has a torrent the remembered listing does not
    try {
      const info = await this.#awaitStatus(torrentId, 'waiting_files_selection', this.budget('select'), reads)
      if (info.status === 'waiting_files_selection') {
        const ids = fileId ? [fileId] : info.files.filter(file => fileFilter(file.path)).map(file => file.id)
        await this.request(`${API}/torrents/selectFiles/${torrentId}`, { method: 'POST', body: { files: ids.length ? ids.join(',') : 'all' } })
      }
      return torrentId
    } catch (error) {
      // awaited, so this call has undone itself by the time it reports failure
      if (torrentId) await this.release(`${API}/torrents/delete/${torrentId}`)
      throw error
    }
  }

  /**
   * Unrestricts a torrent's links into direct stream files. The cached copy may serve fewer links
   * than files selected, so filter by path when the lists align and by filename otherwise.
   * Archives are dropped; the caller recovers via single file selection.
   * @param {any} info
   * @param {(name: string) => boolean} fileFilter
   * @param {number} maxFiles
   * @param {{ path: string } | null} [target] - The file playback wants, kept inside the cap.
   */
  async #unrestrictLinks (info, fileFilter, maxFiles, target) {
    if (!info.links?.length) throw new DebridError('Real-Debrid returned no links for this torrent')
    const selected = info.files.filter(file => file.selected)
    const aligned = info.links.length === selected.length
    const candidates = RealDebrid.windowFiles(aligned
      ? selected.map((file, index) => ({ link: info.links[index], path: file.path, size: file.bytes })).filter(file => fileFilter(file.path))
      : info.links.map(link => ({ link })), target, maxFiles)
    // dead files are skipped by mapFiles; the caller checks the wanted episode came back
    return this.mapFiles(candidates, async ({ link, path, size }) => {
      const unrestricted = await this.request(`${API}/unrestrict/link`, { method: 'POST', body: { link } })
      const name = path?.split('/').pop() || unrestricted.filename
      if (!path && !fileFilter(name)) return null
      if (archiveRx.test(name) && !selected.some(file => file.path.endsWith(name))) return null // RD packed the selection into an archive
      return { name, path: path || `/${name}`, size: unrestricted.filesize || size, url: unrestricted.download, type: unrestricted.mimeType }
    }, candidate => candidate.path || candidate.link)
  }

  /**
   * Polls torrent info until it reaches the wanted status.
   * @param {string} id
   * @param {string} wanted
   * @param {number} timeout - Deadline in milliseconds.
   * @param {number} [reads] - Status reads allowed, for callers that want a fixed number of chances.
   */
  async #awaitStatus (id, wanted, timeout, reads = Infinity) {
    const started = Date.now()
    for (let read = 1; ; read++) {
      const info = await this.request(`${API}/torrents/info/${id}`)
      if (info.status === wanted || (wanted === 'waiting_files_selection' && info.status === 'downloaded')) return info
      const settled = unstreamable(info.status)
      if (settled) throw settled
      // a rare release can sit in magnet_conversion a while, so running out of time proves nothing
      // about it. Callers decide: playback treats it as uncached, a probe leaves it re-checkable
      if (read >= reads || Date.now() - started > timeout) throw new DebridTimeoutError(`Timed out waiting for Real-Debrid (${info.status})`)
      await new Promise(resolve => setTimeout(resolve, this.config.timeouts.poll).unref?.())
    }
  }
}

/**
 * The typed answer a settled status stands for, or null while the torrent is still deciding.
 * @param {string} status
 * @returns {import('./service.js').DebridUnstreamableError | null}
 */
function unstreamable (status) {
  switch (statusAvailability[status]) {
    case Availability.UNAVAILABLE: return new DebridUnavailableError(`Real-Debrid could not process this torrent (${status})`)
    case Availability.AVAILABLE: return new DebridNotCachedError()
    default: return null
  }
}
