// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError, DebridAuthError, DebridNotCachedError } from './service.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

const API = 'https://api.real-debrid.com/rest/1.0'
const hashRx = /urn:btih:([a-f\d]{40})/i
const archiveRx = /\.(rar|zip|7z)$/i
// statuses that mean the torrent will never complete
const deadStatuses = ['magnet_error', 'error', 'virus', 'dead']

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

  mapError (status, json) {
    // https://api.real-debrid.com/ error_code 8 = bad_token, 9 = permission_denied
    if (json?.error_code === 8 || json?.error_code === 9 || status === 401 || status === 403) return new DebridAuthError(json?.error === 'bad_token' ? 'Invalid Real-Debrid API key' : (json?.error || 'Real-Debrid denied the request'), { status, code: json?.error_code })
    return super.mapError(status, json)
  }

  async validate () {
    const user = await this.request(`${API}/user`)
    if (user?.type !== 'premium') throw new DebridAuthError('Real-Debrid premium is required to stream torrents')
    return { username: user.username, expires: user.expiration }
  }

  async listCachedHashes () {
    const torrents = await this.request(`${API}/torrents?limit=100`)
    return (torrents || []).filter(torrent => torrent.status === 'downloaded').map(torrent => torrent.hash.toLowerCase())
  }

  async resolve (magnet, { fileFilter = () => true, pickFile, maxFiles = 60 } = {}) {
    const hash = (hashRx.exec(magnet)?.[1] || (/^[a-f\d]{40}$/i.test(magnet) ? magnet : '')).toLowerCase()
    const magnetURI = magnet.startsWith('magnet:') ? magnet : `magnet:?xt=urn:btih:${hash}`
    let torrentId = null
    let added = false
    try {
      // reuse a torrent that is already on the account instead of adding a duplicate
      const existing = hash && (await this.request(`${API}/torrents?limit=100`))?.find(torrent => torrent.hash.toLowerCase() === hash)
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
      let info = await this.#awaitStatus(torrentId, 'downloaded', 5_000)
      let files = await this.#unrestrictLinks(info, fileFilter, maxFiles)

      // figure out which single file playback is really after, so archives and
      // reused torrents that are missing it can be recovered from
      const wanted = info.files.filter(file => fileFilter(file.path)).map(file => ({ id: file.id, path: file.path, size: file.bytes }))
      const target = wanted.length ? (pickFile ? await pickFile(wanted) : wanted.sort((a, b) => b.size - a.size)[0]) : null
      if (target && !files.some(file => file.name === target.path.split('/').pop())) {
        debug(`Re-adding torrent to select only ${target.path}`)
        const retryId = await this.#addAndSelect(magnetURI, null, target.id)
        if (added) this.request(`${API}/torrents/delete/${torrentId}`, { method: 'DELETE' }).catch(() => {})
        torrentId = retryId
        added = true
        info = await this.#awaitStatus(torrentId, 'downloaded', 5_000)
        files = await this.#unrestrictLinks(info, fileFilter, 1)
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
   * @returns {Promise<string>} The new torrent id.
   */
  async #addAndSelect (magnetURI, fileFilter, fileId) {
    const torrentId = (await this.request(`${API}/torrents/addMagnet`, { method: 'POST', body: { magnet: magnetURI } }))?.id
    try {
      const info = await this.#awaitStatus(torrentId, 'waiting_files_selection', 12_000)
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
   */
  async #unrestrictLinks (info, fileFilter, maxFiles) {
    if (!info.links?.length) throw new DebridError('Real-Debrid returned no links for this torrent')
    const selected = info.files.filter(file => file.selected)
    const aligned = info.links.length === selected.length
    const candidates = (aligned
      ? selected.map((file, index) => ({ link: info.links[index], path: file.path, size: file.bytes })).filter(file => fileFilter(file.path))
      : info.links.map(link => ({ link }))).slice(0, maxFiles)
    return (await Promise.all(candidates.map(async ({ link, path, size }) => {
      const unrestricted = await this.request(`${API}/unrestrict/link`, { method: 'POST', body: { link } })
      const name = path?.split('/').pop() || unrestricted.filename
      if (!path && !fileFilter(name)) return null
      if (archiveRx.test(name) && !selected.some(file => file.path.endsWith(name))) return null // RD packed the selection into an archive
      return { name, path: path || `/${name}`, size: unrestricted.filesize || size, url: unrestricted.download, type: unrestricted.mimeType }
    }))).filter(Boolean)
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
      if (['queued', 'downloading', 'uploading', 'compressing'].includes(info.status)) throw new DebridNotCachedError()
      if (Date.now() - started > timeout) {
        if (info.status === 'magnet_conversion') throw new DebridNotCachedError('Real-Debrid does not recognize this torrent')
        throw new DebridError(`Timed out waiting for Real-Debrid (${info.status})`)
      }
      await new Promise(resolve => setTimeout(resolve, 1_000).unref?.())
    }
  }
}
