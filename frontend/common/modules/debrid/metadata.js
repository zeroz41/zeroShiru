import Metadata from 'matroska-metadata'
import { arr2hex, hex2bin } from 'uint8-util'
import { fontRx, matroskaRx, matchFontFiles, matchSubtitleFiles, sleep } from '@/modules/util.js'
import { SUPPORTS } from '@/modules/support.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

// stay this many seconds of video ahead of playback when streaming subtitles
const AHEAD_SECONDS = 120
// land this many seconds of video before a seek, so a rough byte estimate still covers it
const JUMP_BACK_SECONDS = 15
const RETRIES = 3
const MAX_ANDROID_FONT = 15_000_000 // matches the torrent client's guard

/**
 * Blob-like wrapper around a remote URL so matroska-metadata can read it through HTTP range
 * requests, mirroring how it reads torrent files.
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
    // one controller per slice, created eagerly so the subtitle streamer can abort a request
    // that is sitting idle waiting on bytes — a stalled connection never yields the chunk whose
    // handling would otherwise be the only place a seek gets noticed
    const controller = new AbortController()
    controllers.add(controller)
    return {
      abort () { controller.abort() },
      stream () {
        return (async function * () {
          try {
            const res = await fetch(url, { headers: { Range: range }, signal: controller.signal })
            if (!res.ok && res.status !== 206) throw new Error(`Failed to fetch stream: ${res.status}`)
            yield * res.body
          } catch (error) {
            // the only things that abort these are our own teardown and the seek watcher, so
            // end the stream quietly rather than surfacing a failure nobody can act on
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
 * Extracts embedded tracks, fonts, chapters and subtitles from a debrid HTTP stream and feeds
 * them into the same Subtitles pipeline torrents use. Unlike torrents the playback bytes can't be
 * tapped, so subtitle events come from a second range request paced to stay just ahead of the
 * play position.
 */
export default class DebridMetadata {
  /** How long the subtitle stream may deliver nothing before its request is retried. Static so tests can shorten it. */
  static STALL_TIMEOUT = 30_000
  /** How often the watcher looks at the playback position while the parser waits on bytes. */
  static WATCH_INTERVAL = 1_000

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

    // external subtitles and the fonts they style with, matched exactly like the torrent client
    // does so a season pack loads one episode's subs
    const subFiles = matchSubtitleFiles(files, file.name)
    debug(`Found ${subFiles.length} subtitle files`)
    for (const sub of subFiles) {
      fetch(sub.url).then(res => res.arrayBuffer()).then(data => {
        if (!this.destroyed) subtitles.handleSubtitleFile({ name: sub.name, data })
      }).catch(error => debug(`Failed to fetch subtitle file ${sub.name}:`, error))
    }
    const fontFiles = matchFontFiles(files)
    debug(`Found ${fontFiles.length} font files`)
    for (const font of fontFiles) {
      fetch(font.url).then(res => res.arrayBuffer()).then(data => {
        if (this.destroyed || (SUPPORTS.isAndroid && data.byteLength > MAX_ANDROID_FONT)) return
        subtitles.handleFile(hex2bin(arr2hex(new Uint8Array(data))))
      }).catch(error => debug(`Failed to fetch font file ${font.name}:`, error))
    }

    // everything below reads the Matroska container, which only these formats have
    if (!matroskaRx.test(file.name)) {
      debug('Not a Matroska container, skipping embedded metadata: ' + file.name)
      return
    }
    this.remote = new RemoteFile(file.url, file.size, file.name)
    this.metadata = new Metadata(this.remote)
    // the parser starts several reads in its constructor, settle the ones nothing may ever await
    // (duration when no tracks stream) so they cannot reject unhandled
    for (const pending of [this.metadata.segment, this.metadata.seekHead, this.metadata.duration]) Promise.resolve(pending).catch(() => {})

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
          if (SUPPORTS.isAndroid && attachment.data.length > MAX_ANDROID_FONT) continue
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
    // the window of bytes fed to the parser so far, seeks outside it restart the stream
    let start = 0
    let offset = 0
    for (let attempt = 0; attempt < RETRIES && !this.destroyed; ++attempt) {
      const source = this.remote.slice(offset)
      // a stalled connection yields no chunk, and chunk handling used to be the only place a
      // seek was noticed — so a seek during a stall never restarted the stream, and a dead link
      // hung the subtitle stream forever. This watcher covers the waiting: a seek out of the
      // window or a stall past the budget aborts the request, which ends the parse loop below.
      let jumpTo = null
      let stalled = false
      let streaming = true
      let progressed = Date.now()
      const watcher = (async () => {
        while (streaming && !this.destroyed) {
          const jump = this.#jumpTarget(byteRate, start, offset)
          if (jump !== null && jump !== offset) {
            jumpTo = jump
            return source.abort()
          }
          // only reading that should be delivering counts as a stall; a stream the pacing below
          // deliberately holds back is quiet on purpose
          const throttled = byteRate && offset > this.getTime() * byteRate + AHEAD_SECONDS * byteRate
          if (throttled) progressed = Date.now()
          else if (Date.now() - progressed > this.constructor.STALL_TIMEOUT) {
            debug(`Subtitle stream stalled at ${offset}, aborting the request to retry it`)
            stalled = true
            return source.abort()
          }
          await sleep(this.constructor.WATCH_INTERVAL)
        }
      })()
      try {
        let jumped = false
        for await (const chunk of this.metadata.parseStream(source.stream(), offset === 0)) {
          if (this.destroyed) return
          offset += chunk.length
          progressed = Date.now()
          const next = await this.#pace(byteRate, start, offset)
          if (next !== offset) {
            debug(`Seek left the parsed subtitle window, restarting stream at ${next}`)
            start = offset = next
            jumped = true
            break
          }
          if (jumpTo !== null || stalled) break // the watcher already ended the request
        }
        streaming = false
        await watcher
        if (jumpTo !== null) {
          debug(`Seek left the parsed subtitle window, restarting stream at ${jumpTo}`)
          start = offset = jumpTo
          attempt = -1 // following a seek is progress, not a failed attempt
          continue
        }
        if (stalled) continue // costs an attempt: a link that keeps stalling is given up on
        if (!jumped) return // parsed to the end of the file
        attempt = -1
      } catch (error) {
        if (this.destroyed) return
        debug(`Subtitle stream interrupted at ${offset}, retrying:`, error)
        await sleep(1_000 * (attempt + 1))
      } finally {
        streaming = false
      }
    }
  }

  /**
   * Where the parser should restart because a seek left the parsed window, or null while
   * reading on from where it is stays right. Reading on past a forward seek would download
   * everything in between for nothing; a backward seek needs the bytes again.
   */
  #jumpTarget (byteRate, start, offset) {
    if (!byteRate) return null // no duration to estimate from, so read straight through
    const position = this.getTime() * byteRate
    const jump = Math.max(0, Math.floor(position - JUMP_BACK_SECONDS * byteRate))
    // a target beyond the file means the estimate overshot, sequential reading covers it
    if (jump < this.file.size && (position < start || jump > offset)) return jump
    return null
  }

  /**
   * Waits until the parser should read further, and says where from: the current offset while
   * playback approaches it, or a fresh one when a seek left the parsed window. The renderer
   * deduplicates events, so overlapping parses are safe.
   */
  async #pace (byteRate, start, offset) {
    if (!byteRate) return offset
    while (!this.destroyed) {
      const jump = this.#jumpTarget(byteRate, start, offset)
      if (jump !== null) return jump
      // wait for playback to catch up before buffering further ahead
      if (offset <= this.getTime() * byteRate + AHEAD_SECONDS * byteRate) return offset
      await sleep(1_000)
    }
    return offset
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
