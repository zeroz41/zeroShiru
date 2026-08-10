// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError, DebridAuthError, DebridNotCachedError, DebridUnavailableError, archiveRx } from './service.js'
import { Availability } from './availability.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

const API = 'https://api.real-debrid.com/rest/1.0'
// the account's torrent list comes back in one request, newest first. Accounts larger than
// this keep their most recent torrents badged, which is the half anyone is browsing.
const LIST_LIMIT = 1_000

/**
 * What each Real-Debrid torrent status means for playback. Statuses left out — magnet
 * conversion and file selection — are moments in a torrent's life rather than outcomes,
 * so they answer nothing and leave the release unknown.
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

// https://api.real-debrid.com/ error_code values worth explaining, anything else
// falls back to the message the API sends
const errorMessages = {
  8: 'Invalid Real-Debrid API key',
  9: 'Real-Debrid denied the request, check the account permissions',
  21: 'Too many active Real-Debrid downloads, wait for one to finish',
  23: 'This Real-Debrid account has exhausted its traffic',
  34: 'Real-Debrid is rate limiting this account, try again shortly',
  35: 'Real-Debrid would not accept this release, try again shortly or pick a different one',
  36: 'Real-Debrid fair usage limit reached'
}
// only these mean the key or account is the problem, the rest are per-request
const authCodes = [8, 9]

/**
 * Real-Debrid implementation, see https://api.real-debrid.com/
 *
 * Two quirks of the live API shape this client:
 * - `/torrents/instantAvailability` is disabled (403 `disabled_endpoint`), so the only way to
 *   ask about a release is to add the magnet and read the status back. That is what
 *   `probeAvailability` does, and why the base class caps how many of them a search may cost.
 * - Selecting multiple files can serve a single RAR archive instead of individual links, so
 *   when that happens the torrent is re-added selecting only the target file.
 */
export default class RealDebrid extends DebridService {
  static id = 'realdebrid'
  static title = 'Real-Debrid'
  static available = true
  // documented allowance is 250 requests per minute, keep some headroom
  static limits = { reservoir: 200, reservoirRefreshAmount: 200, reservoirRefreshInterval: 60_000, maxConcurrent: 4, minTime: 150 }
  // no cache endpoint any more, so availability has to be probed a hash at a time
  static availabilityCheck = 'probe'

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

  /**
   * The whole account in one request. The base class shares this between the badge refresh and
   * playback, so a search followed by a play reads it once rather than twice.
   */
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
   * Finds out what Real-Debrid can do with a release, the only way it still can be asked: add
   * the magnet and read the status it settles on. A cached torrent reports 'downloaded' within
   * a second or so of file selection, anything else is being fetched fresh or is not something
   * Real-Debrid can take at all. Costs about five requests and a few seconds, hence the cap in
   * the base class.
   *
   * The torrent is always removed again. Adding a hash the account already holds creates a
   * separate entry with its own id, so this can never delete the user's own download.
   *
   * Nothing here decides what a failure means: `#awaitStatus` raises the typed errors that
   * carry an answer, and any other error travels up as "no answer at all".
   * @param {string} hash
   * @returns {Promise<string>}
   */
  async probeAvailability (hash) {
    const magnetURI = RealDebrid.toMagnet(hash)
    if (!magnetURI) throw new DebridError('Not a usable info hash') // no answer, rather than a made up one
    const timeout = this.config.timeouts.probe
    let torrentId = null
    try {
      torrentId = await this.#addAndSelect(magnetURI, () => true, undefined, timeout)
      await this.#awaitStatus(torrentId, 'downloaded', timeout)
      return Availability.CACHED
    } finally {
      // awaited, so the probe has genuinely left the account as it found it by the time it
      // answers. Playback waits on this before reusing a torrent, and teardown waits on it
      // before stopping the limiter, so neither can trip over a half-finished probe.
      if (torrentId) await this.release(`${API}/torrents/delete/${torrentId}`)
    }
  }

  async resolve (magnet, { fileFilter = () => true, pickFile, maxFiles = this.config.maxFiles } = {}) {
    const hash = RealDebrid.parseHash(magnet)
    const magnetURI = RealDebrid.toMagnet(magnet)
    let torrentId = null
    let added = false
    try {
      // a cache probe of this same release is about to delete its own torrent, so let it
      // finish first rather than reusing an id that is seconds from disappearing
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
      info ??= await this.#awaitStatus(torrentId, 'downloaded', this.config.timeouts.ready)

      // work out which single file playback is really after before unrestricting, so a
      // capped pack never drops the wanted episode, and so archives and reused torrents
      // that are missing it can be recovered from
      const wanted = info.files.filter(file => fileFilter(file.path)).map(file => ({ id: file.id, path: file.path, size: file.bytes }))
      const target = wanted.length ? (pickFile ? await pickFile(wanted) : [...wanted].sort((a, b) => b.size - a.size)[0]) : null
      let files = await this.#unrestrictLinks(info, fileFilter, maxFiles, target)
      if (target && !files.some(file => file.name === target.path.split('/').pop())) {
        debug(`Re-adding torrent to select only ${target.path}`)
        const retryId = await this.#addAndSelect(magnetURI, null, target.id)
        // not awaited, unlike the failure paths: the user is sat in front of an open player
        // waiting for this resolve, and removing the superseded torrent can catch up later
        if (added) this.release(`${API}/torrents/delete/${torrentId}`)
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
      if (added && torrentId) await this.release(`${API}/torrents/delete/${torrentId}`)
      throw error
    }
  }

  /**
   * The account's current entry for an info hash, or null when it does not hold one.
   *
   * The listing behind this can be up to a minute old, so the entry it names is read back from
   * the API before playback acts on its id: a torrent deleted from another device in the
   * meantime has to read as "not on the account" and be added again, not fail the resolve with
   * an id that no longer exists. The read is also what makes the reuse path cheap — it returns
   * the files and links, so nothing else has to be fetched.
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
   * @param {number} [fileId]
   * @param {number} [timeout] - Budget for the service to accept the magnet, shortened for probes.
   * @returns {Promise<string>} The new torrent id.
   */
  async #addAndSelect (magnetURI, fileFilter, fileId, timeout = this.config.timeouts.select) {
    const torrentId = (await this.request(`${API}/torrents/addMagnet`, { method: 'POST', body: { magnet: magnetURI } }))?.id
    this.forgetListing() // the account has a torrent the remembered listing does not
    try {
      const info = await this.#awaitStatus(torrentId, 'waiting_files_selection', timeout)
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
   * Polls torrent info until it reaches the wanted status. A torrent the service has to fetch
   * fresh, or cannot process at all, is not something playback can stream now.
   * @param {string} id
   * @param {string} wanted
   * @param {number} timeout
   */
  async #awaitStatus (id, wanted, timeout) {
    const started = Date.now()
    while (true) {
      const info = await this.request(`${API}/torrents/info/${id}`)
      if (info.status === wanted || (wanted === 'waiting_files_selection' && info.status === 'downloaded')) return info
      const settled = unstreamable(info.status)
      if (settled) throw settled
      // deliberately not an answer at all: a rare or old release can sit in magnet_conversion
      // for a while, and calling that a miss is what empties the badges on exactly those
      // titles. No answer means the release stays unknown and re-checkable.
      if (Date.now() - started > timeout) throw new DebridError(`Timed out waiting for Real-Debrid (${info.status})`)
      await new Promise(resolve => setTimeout(resolve, this.config.timeouts.poll).unref?.())
    }
  }
}

/**
 * The typed answer a settled status stands for, or null while the torrent is still making up
 * its mind. One mapping serves both callers: playback reads it as a reason to fall back, the
 * base class reads it as the release's availability.
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
