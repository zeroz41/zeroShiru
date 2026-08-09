// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError, DebridAuthError, DebridNotCachedError, archiveRx } from './service.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

const API = 'https://api.real-debrid.com/rest/1.0'
// how much of the account's torrent history to read for reuse and cache badges
const LIST_LIMIT = 100
// statuses that mean the torrent will never complete
const deadStatuses = ['magnet_error', 'error', 'virus', 'dead']
// statuses that mean the torrent is being fetched fresh, so it was never cached
const downloadingStatuses = ['queued', 'downloading', 'uploading', 'compressing']

// https://api.real-debrid.com/ error_code values worth explaining, anything else
// falls back to the message the API sends
const errorMessages = {
  8: 'Invalid Real-Debrid API key',
  9: 'Real-Debrid denied the request, check the account permissions',
  21: 'Too many active Real-Debrid downloads, wait for one to finish',
  23: 'This Real-Debrid account has exhausted its traffic',
  34: 'Real-Debrid is rate limiting this account, try again shortly',
  35: 'Real-Debrid has blocked this release for copyright reasons, pick a different one',
  36: 'Real-Debrid fair usage limit reached'
}
// only these mean the key or account is the problem, the rest are per-request
const authCodes = [8, 9]

/**
 * Real-Debrid implementation, see https://api.real-debrid.com/
 *
 * Two quirks discovered against the live API shape this client:
 * - There is no instant availability endpoint anymore, cache state is only found
 *   out by adding a magnet: a cached torrent reports 'downloaded' right after file
 *   selection, anything queued for a fresh download is not cached and gets removed.
 * - Selecting multiple files can serve a single RAR archive instead of individual
 *   links, so when that happens the torrent is re-added selecting only the target
 *   file, which always yields a direct streamable link.
 */
export default class RealDebrid extends DebridService {
  static id = 'realdebrid'
  static title = 'Real-Debrid'
  static available = true
  // documented allowance is 250 requests per minute, keep some headroom
  static limits = { reservoir: 200, reservoirRefreshAmount: 200, reservoirRefreshInterval: 60_000, maxConcurrent: 4, minTime: 150 }
  // no cache endpoint exists any more, so cache state has to be probed a hash at a time
  static cacheCheck = 'probe'

  mapError (status, json) {
    const code = json?.error_code
    const message = errorMessages[code] || json?.error || `Request failed with status ${status}`
    // a blocked or unavailable file also answers 403, and must stay a plain error: an auth
    // error aborts the whole resolve, where one bad file in a pack should only be skipped
    if (authCodes.includes(code) || ((status === 401 || status === 403) && code == null)) return new DebridAuthError(message, { status, code })
    return new DebridError(message, { status, code })
  }

  async validate () {
    const user = await this.request(`${API}/user`)
    if (user?.type !== 'premium') throw new DebridAuthError('Real-Debrid premium is required to stream torrents')
    return { username: user.username, expires: user.expiration }
  }

  /** The account's recent torrents, the one list both cache badges and torrent reuse read from. */
  async #accountTorrents () {
    return (await this.request(`${API}/torrents?limit=${LIST_LIMIT}`)) || []
  }

  /**
   * Finds out whether Real-Debrid can stream a release right now. Since
   * `/torrents/instantAvailability` was disabled the only way to ask is to add the magnet
   * and read the status it settles on: a cached torrent reports 'downloaded' within about a
   * second of file selection, anything else is being fetched fresh. Costs roughly five
   * requests, which is why the base class caps how many of these run per search.
   *
   * The torrent is always removed again. Adding a hash the account already holds creates a
   * separate entry with its own id, so this can never delete the user's own download.
   * @param {string} hash
   * @returns {Promise<boolean>}
   */
  async probeCached (hash) {
    const magnetURI = RealDebrid.toMagnet(hash)
    if (!magnetURI) return false
    const timeout = this.config.timeouts.probe
    let torrentId = null
    try {
      torrentId = await this.#addAndSelect(magnetURI, () => true, undefined, timeout)
      return (await this.#awaitStatus(torrentId, 'downloaded', timeout)).status === 'downloaded'
    } catch (error) {
      if (error instanceof DebridAuthError) throw error // the key is the problem, not this release
      return false // not cached, unrecognized, or too slow to settle: not instantly playable
    } finally {
      if (torrentId) this.request(`${API}/torrents/delete/${torrentId}`, { method: 'DELETE' }).catch(() => {})
    }
  }

  async listCachedHashes () {
    const torrents = await this.#accountTorrents()
    return torrents.filter(torrent => torrent.status === 'downloaded').map(torrent => torrent.hash.toLowerCase())
  }

  async resolve (magnet, { fileFilter = () => true, pickFile, maxFiles = this.config.maxFiles } = {}) {
    const hash = RealDebrid.parseHash(magnet)
    const magnetURI = RealDebrid.toMagnet(magnet)
    let torrentId = null
    let added = false
    try {
      // reuse a torrent that is already on the account instead of adding a duplicate
      const existing = hash && (await this.#accountTorrents()).find(torrent => torrent.hash.toLowerCase() === hash)
      if (existing?.status === 'waiting_files_selection') {
        // a stale add that never got its files selected, finish the job
        const info = await this.request(`${API}/torrents/info/${existing.id}`)
        const ids = info.files.filter(file => fileFilter(file.path)).map(file => file.id)
        await this.request(`${API}/torrents/selectFiles/${existing.id}`, { method: 'POST', body: { files: ids.length ? ids.join(',') : 'all' } })
        torrentId = existing.id
      } else if (existing && existing.status !== 'downloaded') throw new DebridNotCachedError()
      else if (existing) torrentId = existing.id
      else {
        torrentId = await this.#addAndSelect(magnetURI, fileFilter)
        added = true
      }
      let info = await this.#awaitStatus(torrentId, 'downloaded', this.config.timeouts.ready)

      // work out which single file playback is really after before unrestricting, so a
      // capped pack never drops the wanted episode, and so archives and reused torrents
      // that are missing it can be recovered from
      const wanted = info.files.filter(file => fileFilter(file.path)).map(file => ({ id: file.id, path: file.path, size: file.bytes }))
      const target = wanted.length ? (pickFile ? await pickFile(wanted) : [...wanted].sort((a, b) => b.size - a.size)[0]) : null
      let files = await this.#unrestrictLinks(info, fileFilter, maxFiles, target)
      if (target && !files.some(file => file.name === target.path.split('/').pop())) {
        debug(`Re-adding torrent to select only ${target.path}`)
        const retryId = await this.#addAndSelect(magnetURI, null, target.id)
        if (added) this.request(`${API}/torrents/delete/${torrentId}`, { method: 'DELETE' }).catch(() => {})
        torrentId = retryId
        added = true
        info = await this.#awaitStatus(torrentId, 'downloaded', this.config.timeouts.ready)
        files = await this.#unrestrictLinks(info, fileFilter, 1, null)
        if (!files.length) throw new DebridError('Real-Debrid only serves this torrent as an archive')
      }
      if (!files.length) throw new DebridError('No playable files in this torrent')
      debug(`Resolved ${files.length} files for ${info.filename}`)
      return { hash: info.hash.toLowerCase(), name: info.filename, files }
    } catch (error) {
      // only clean up torrents this call added, never the user's own downloads
      if (added && torrentId) this.request(`${API}/torrents/delete/${torrentId}`, { method: 'DELETE' }).catch(() => {})
      throw error
    }
  }

  /**
   * Adds a magnet and selects either the files matching the filter or one specific file.
   * @param {string} magnetURI
   * @param {((name: string) => boolean) | null} fileFilter
   * @param {number} [fileId]
   * @param {number} [timeout] - Budget for the service to accept the magnet, shortened for cache probes.
   * @returns {Promise<string>} The new torrent id.
   */
  async #addAndSelect (magnetURI, fileFilter, fileId, timeout = this.config.timeouts.select) {
    const torrentId = (await this.request(`${API}/torrents/addMagnet`, { method: 'POST', body: { magnet: magnetURI } }))?.id
    try {
      const info = await this.#awaitStatus(torrentId, 'waiting_files_selection', timeout)
      if (info.status === 'waiting_files_selection') {
        const ids = fileId ? [fileId] : info.files.filter(file => fileFilter(file.path)).map(file => file.id)
        await this.request(`${API}/torrents/selectFiles/${torrentId}`, { method: 'POST', body: { files: ids.length ? ids.join(',') : 'all' } })
      }
      return torrentId
    } catch (error) {
      if (torrentId) this.request(`${API}/torrents/delete/${torrentId}`, { method: 'DELETE' }).catch(() => {})
      throw error
    }
  }

  /**
   * Unrestricts a torrent's links into direct stream files. The cached copy may
   * serve fewer links than the files selected: when the lists align filter by
   * path up front, otherwise unrestrict and filter by the reported filename.
   * RD-generated archives are dropped, the caller recovers via single file selection.
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
    // dead files inside a pack are skipped by mapFiles, the caller checks separately that
    // the episode actually wanted came back and recovers if it did not
    return this.mapFiles(candidates, async ({ link, path, size }) => {
      const unrestricted = await this.request(`${API}/unrestrict/link`, { method: 'POST', body: { link } })
      const name = path?.split('/').pop() || unrestricted.filename
      if (!path && !fileFilter(name)) return null
      if (archiveRx.test(name) && !selected.some(file => file.path.endsWith(name))) return null // RD packed the selection into an archive
      return { name, path: path || `/${name}`, size: unrestricted.filesize || size, url: unrestricted.download, type: unrestricted.mimeType }
    }, candidate => candidate.path || candidate.link)
  }

  /**
   * Polls torrent info until it reaches the wanted status. Anything queued for a
   * fresh download means the torrent is not in the instant cache.
   * @param {string} id
   * @param {string} wanted
   * @param {number} timeout
   */
  async #awaitStatus (id, wanted, timeout) {
    const started = Date.now()
    while (true) {
      const info = await this.request(`${API}/torrents/info/${id}`)
      if (info.status === wanted || (wanted === 'waiting_files_selection' && info.status === 'downloaded')) return info
      if (deadStatuses.includes(info.status)) throw new DebridError(`Real-Debrid could not process this torrent (${info.status})`)
      if (downloadingStatuses.includes(info.status)) throw new DebridNotCachedError()
      if (Date.now() - started > timeout) {
        if (info.status === 'magnet_conversion') throw new DebridNotCachedError('Real-Debrid does not recognize this torrent')
        throw new DebridError(`Timed out waiting for Real-Debrid (${info.status})`)
      }
      await new Promise(resolve => setTimeout(resolve, this.config.timeouts.poll).unref?.())
    }
  }
}
