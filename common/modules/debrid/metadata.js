import Metadata from 'matroska-metadata'
import { arr2hex, hex2bin } from 'uint8-util'
import { fontRx, matroskaRx, matchSubtitleFiles, sleep } from '@/modules/util.js'
import { SUPPORTS } from '@/modules/support.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

// stay this many seconds of video ahead of playback when streaming subtitles
const AHEAD_SECONDS = 120
const RETRIES = 3

/**
 * Blob-like wrapper around a remote URL so matroska-metadata can read it
 * through HTTP range requests, mirroring how it reads torrent files.
 */
class RemoteFile {
  /**
   * @param {string} url
   * @param {number} size
   * @param {string} name
   */
  constructor (url, size, name) {
    this.url = url
    this.size = size
    this.name = name
    this.controllers = new Set()
  }

  /** @param {number} [start] @param {number} [end] */
  slice (start = 0, end) {
    const { url, controllers } = this
    const range = `bytes=${start}-${end ? end - 1 : ''}`
    return {
      stream () {
        const controller = new AbortController()
        controllers.add(controller)
        return (async function * () {
          try {
            const res = await fetch(url, { headers: { Range: range }, signal: controller.signal })
            if (!res.ok && res.status !== 206) throw new Error(`Failed to fetch stream: ${res.status}`)
            yield * res.body
          } catch (error) {
            // the only thing that aborts these is our own teardown, so end the stream
            // quietly rather than surfacing a failure nobody can act on
            if (error?.name !== 'AbortError') throw error
          } finally {
            controllers.delete(controller)
            controller.abort()
          }
        })()
      }
    }
  }

  destroy () {
    for (const controller of this.controllers) controller.abort()
    this.controllers.clear()
  }
}

/**
 * Extracts embedded tracks, fonts, chapters and subtitles from a debrid HTTP
 * stream and feeds them into the same Subtitles pipeline torrents use. Unlike
 * torrents the playback bytes can't be tapped, so subtitle events come from a
 * second range request that is paced to stay just ahead of the play position.
 */
export default class DebridMetadata {
  destroyed = false
  /** @type {RemoteFile | null} */
  remote = null
  /** @type {Metadata | null} */
  metadata = null

  /**
   * @param {any} file - The playing debrid file object.
   * @param {any[]} files - All resolved files of the torrent, used to find external subtitles.
   * @param {import('@/modules/subtitles.js').default} subtitles - Player subtitle instance to feed.
   * @param {{ getTime?: () => number, onChapters?: (chapters: any[]) => void }} [opts]
   */
  constructor (file, files, subtitles, { getTime = () => 0, onChapters } = {}) {
    debug('Initializing debrid metadata parser for: ' + file?.name)
    this.file = file
    this.getTime = getTime

    // external subtitle files that were resolved alongside the video, matched to it
    // exactly like the torrent client does so season packs load one episode's subs
    for (const sub of matchSubtitleFiles(files, file.name)) {
      fetch(sub.url).then(res => res.arrayBuffer()).then(data => {
        if (!this.destroyed) subtitles.handleSubtitleFile({ name: sub.name, data })
      }).catch(error => debug(`Failed to fetch subtitle file ${sub.name}:`, error))
    }

    // everything below reads the Matroska container, which only these formats have
    if (!matroskaRx.test(file.name)) {
      debug('Not a Matroska container, skipping embedded metadata: ' + file.name)
      return
    }
    this.remote = new RemoteFile(file.url, file.size, file.name)
    this.metadata = new Metadata(this.remote)

    this.metadata.getTracks().then(tracks => {
      if (this.destroyed) return
      debug(`Found ${tracks?.length} subtitle tracks`)
      // nothing embedded to stream, drop the parser but stay alive for external subtitle files
      if (!tracks.length) return this.#releaseParser()
      subtitles.handleTracks(tracks)
      this.#streamSubtitles()
    }).catch(error => debug('Failed to read tracks:', error))

    this.metadata.getChapters().then(chapters => {
      if (this.destroyed || !chapters?.length) return
      debug(`Found ${chapters.length} chapters`)
      onChapters?.(chapters)
    }).catch(error => debug('Failed to read chapters:', error))

    this.metadata.getAttachments().then(attachments => {
      if (this.destroyed) return
      debug(`Found ${attachments?.length} attachments`)
      for (const attachment of attachments) {
        if (fontRx.test(attachment.filename) || attachment.mimetype?.toLowerCase().includes('font')) {
          if (SUPPORTS.isAndroid && attachment.data.length > 15_000_000) continue // matches the torrent client's large font guard
          subtitles.handleFile(hex2bin(arr2hex(attachment.data)))
        }
      }
    }).catch(error => debug('Failed to read attachments:', error))

    this.metadata.on('subtitle', (subtitle, trackNumber) => {
      if (!this.destroyed) subtitles.handleSubtitle({ subtitle, trackNumber })
    })
  }

  /** Streams the file through the parser, throttled against the playback position. */
  async #streamSubtitles () {
    const durationMs = await this.metadata.duration
    const byteRate = durationMs > 0 ? this.file.size / (durationMs / 1_000) : 0
    for (let attempt = 0, offset = 0; attempt < RETRIES && !this.destroyed; ++attempt) {
      try {
        const stream = this.remote.slice(offset).stream()
        for await (const chunk of this.metadata.parseStream(stream, offset === 0)) {
          if (this.destroyed) return
          offset += chunk.length
          // wait for playback to catch up before buffering further, seeks resume instantly
          while (!this.destroyed && byteRate && offset > (this.getTime() + AHEAD_SECONDS) * byteRate) await sleep(1_000)
        }
        return
      } catch (error) {
        if (this.destroyed) return
        debug(`Subtitle stream interrupted at ${offset}, retrying:`, error)
        await sleep(1_000 * (attempt + 1))
      }
    }
  }

  /** Releases the container parser and its range requests, leaving external subtitles alone. */
  #releaseParser () {
    this.metadata?.removeAllListeners()
    this.metadata?.destroy()
    this.remote?.destroy()
    this.metadata = null
    this.remote = null
  }

  destroy () {
    if (this.destroyed) return
    debug('Destroying debrid metadata parser')
    this.destroyed = true
    this.#releaseParser()
    this.file = null
  }
}
