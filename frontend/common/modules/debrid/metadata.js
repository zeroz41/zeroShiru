import Metadata from 'matroska-metadata'
import { EbmlTagId } from 'ebml-iterator'
import { arr2hex, hex2bin } from 'uint8-util'
import { parseCues, cueJumpTarget, lastClusterBefore, mergeCovered, coversByte } from '@/modules/playback/cue-index.js'
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
  /** How often the watcher looks at the playback position while the parser waits on bytes.
   * It is arithmetic on a number, so it is cheap — and it is the delay between a user
   * seeking and the stream being asked to move, which used to be a whole second of the
   * few the subtitles took to come back. */
  static WATCH_INTERVAL = 250
  /** How long a restart after a seek may deliver nothing before it is worth reporting. */
  static SILENCE_TIMEOUT = 12_000

  destroyed = false
  /** Cues handed to the renderer, so a stream that goes quiet can prove it. */
  cues = 0
  /** @type {RemoteFile | null} */
  remote = null
  /** @type {Metadata | null} */
  metadata = null
  /** @type {{ time: number, byte: number }[] | null} The file's own seek index, once read. */
  cuesIndex = null
  /** @type {{ start: number, end: number }[]} Byte ranges whose cues are already in the
   * renderer, so a seek back into one needs nothing from the link. See cue-index.js. */
  #covered = []
  #cuesRequested = false
  /** Media duration in ms once known, bounding what counts as a real seek target. */
  #durationMs = 0

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
      this.cues++
      if (!this.destroyed) subtitles.handleSubtitle({ subtitle, trackNumber })
    })
  }

  /**
   * Streams the file through the parser, throttled against the playback position.
   *
   * @param {number} [from] Byte offset to start at, for picking a given-up stream back up.
   */
  async #streamSubtitles (from = 0) {
    this.#loadCues()
    const durationMs = await this.metadata.duration
    this.#durationMs = durationMs > 0 ? durationMs : 0
    const byteRate = durationMs > 0 ? this.file.size / (durationMs / 1_000) : 0
    // the window of bytes fed to the parser so far, seeks outside it restart the stream
    let start = from
    let offset = from
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
          this.#claimCoverage(start, offset)
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
          this.#watchForSilence(jumpTo)
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
    if (!this.destroyed) {
      console.warn(`[subtitles] the stream gave up after its retries at byte ${offset} with ${this.cues} cues delivered; a seek will try again`)
    }
    // The retries are spent. Nothing used to restart this, so a stream that gave up —
    // three stalls on a busy link is enough — left the rest of the film with no
    // subtitles at all, and seeking did nothing because the seek was only ever noticed
    // by a loop that had already exited. Wait, asking the link for nothing, until a seek
    // leaves the parsed window: that is a new place to read from, and worth one more go.
    await this.#reviveOnSeek(byteRate, start, offset)
  }

  /**
   * Says so, once, if a restart after a seek delivers nothing.
   *
   * Subtitles going missing after a seek is a symptom with several possible causes — a
   * parser that cannot find its footing mid-file, a link that will not serve the range, a
   * renderer that stopped asking — and they are indistinguishable from the outside. This
   * is the one place that knows a seek happened AND whether anything came of it, so it is
   * the only place that can say which. It costs nothing when subtitles work.
   */
  #watchForSilence (from) {
    const before = this.cues
    setTimeout(() => {
      if (this.destroyed || this.cues > before) return
      console.warn(
        `[subtitles] no cues in ${this.constructor.SILENCE_TIMEOUT / 1000}s after seeking to byte ${from} ` +
        `(${this.cues} cues so far, file ${this.file?.size} bytes) — the stream restarted but delivered nothing`
      )
    }, this.constructor.SILENCE_TIMEOUT)
  }

  /**
   * Waits at a standstill for a seek out of the parsed window, then picks the stream back
   * up there. Costs nothing while nobody seeks, which is what keeps a genuinely dead link
   * from being retried forever.
   */
  async #reviveOnSeek (byteRate, start, offset) {
    while (!this.destroyed) {
      const jump = this.#jumpTarget(byteRate, start, offset)
      if (jump !== null && jump !== offset) {
        debug(`A seek to ${jump} picks the given-up subtitle stream back up`)
        return this.#streamSubtitles(jump)
      }
      await sleep(this.constructor.WATCH_INTERVAL)
    }
  }

  /**
   * Reads the file's Cues element — the exact timestamp-to-cluster map the video
   * element itself seeks with — so a restart after a seek lands on the right cluster
   * instead of a bitrate guess. One bounded range request; a file without cues, or a
   * link that will not serve them, just leaves the estimate in charge as before.
   */
  #loadCues () {
    if (this.#cuesRequested || !this.metadata || !this.remote) return
    this.#cuesRequested = true
    Promise.resolve(this.metadata.seekHead).then(async seekHead => {
      const position = seekHead?.Cues?.data
      if (position == null || this.destroyed) return
      const start = this.metadata.segmentStart + Number(position)
      if (!Number.isFinite(start) || start >= this.file.size) return
      // cues are tens of kilobytes; the request streams and is dropped once the tag is whole
      const source = this.remote.slice(start, Math.min(this.file.size, start + 4_000_000))
      const tag = await this.metadata.readUntilTag(source.stream(), EbmlTagId.Cues)
      source.abort()
      if (this.destroyed) return
      this.cuesIndex = parseCues(tag, this.metadata.segmentStart)
      debug(this.cuesIndex
        ? `Read ${this.cuesIndex.length} cue points; seeks will restart the subtitle stream exactly`
        : 'The file lists no usable cue points; seeks fall back to the bitrate estimate')
    }).catch(error => debug('Failed to read cues, seeks fall back to the bitrate estimate:', error))
  }

  /**
   * Where the parser should restart because a seek left the parsed window, or null while
   * reading on from where it is stays right. Reading on past a forward seek would download
   * everything in between for nothing; a backward seek needs the bytes again.
   *
   * The cue index answers exactly when it has arrived; until then — or for a file
   * without one — the average-bitrate estimate stands in, with its safety margin.
   */
  #jumpTarget (byteRate, start, offset) {
    const target = this.#restartTarget(byteRate, start, offset)
    // the cues in a range already parsed were handed to the renderer, and it keeps them:
    // seeking back into one shows subtitles instantly, so asking the link to serve those
    // bytes a second time buys nothing but the wait it used to cost
    if (target !== null && coversByte(this.#covered, target)) return null
    return target
  }

  /** Where a restart would have to begin to cover the playhead, ignoring what is already
   * parsed. See [#jumpTarget]. */
  #restartTarget (byteRate, start, offset) {
    if (this.cuesIndex) {
      const position = this.getTime()
      // a playhead past the end of the file is not a seek, it is a caller reading
      // straight through — the same overshoot escape the estimate below has always had
      if (this.#durationMs && position * 1_000 > this.#durationMs) return null
      return cueJumpTarget(this.cuesIndex, position, this.metadata?.timecodeScale || 1, { start, offset })
    }
    if (!byteRate) return null // no duration to estimate from, so read straight through
    const position = this.getTime() * byteRate
    const jump = Math.max(0, Math.floor(position - JUMP_BACK_SECONDS * byteRate))
    // a target beyond the file means the estimate overshot, sequential reading covers it
    if (jump < this.file.size && (position < start || jump > offset)) return jump
    return null
  }

  /**
   * Remember what has been parsed, up to the last cluster the parser FINISHED — the one
   * it is inside may have delivered only some of its lines, and a seek that landed there
   * would show a scene with half its subtitles. Without the file's own index there is no
   * exact boundary to claim, so nothing is remembered and seeks re-read as they always
   * have: this only ever makes the link do less work, never a cue go missing.
   */
  #claimCoverage (start, offset) {
    if (!this.cuesIndex) return
    const finished = lastClusterBefore(this.cuesIndex, offset)
    if (finished > start) this.#covered = mergeCovered(this.#covered, start, finished)
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
