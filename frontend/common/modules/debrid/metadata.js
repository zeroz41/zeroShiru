import { EbmlTagId, EbmlIteratorDecoder } from 'ebml-iterator'
import { arr2hex, hex2bin, concat } from 'uint8-util'
import { parseCues, cueJumpTarget, lastClusterBefore, mergeCovered, coversByte } from '@/modules/playback/cue-index.js'
import { parseSubtitleTracks, decodeBlock, findClusterStart, SCAN_TAIL } from '@/modules/playback/mkv-subtitles.js'
import { createHeader, foldHeaderTag, missingHeaderTags, parseChapters, parseAttachments, HEADER_TAGS } from '@/modules/playback/mkv-header.js'
import { createSchedule, observeTime, noteRestart, shouldRestart } from '@/modules/playback/subtitle-scheduler.js'
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
// how long the first read waits for the file's own seek index before giving up and reading
// from the top. It is one bounded range request against a link that just answered a probe,
// so this is a backstop, not a budget
const FIRST_READ_CUE_WAIT = 2_500
// the most header a single pass will download before concluding the file is not a video
// container worth reading this way (attachments run tens of MB; nothing sane runs hundreds)
const HEADER_READ_CAP = 256_000_000
// a targeted read for one promised element parked past the clusters
const TARGETED_READ_CAP = 64_000_000

/**
 * Blob-like wrapper around a remote URL, read through HTTP range requests.
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
            // NOTHING may be awaited before this abort, and the body must be iterated
            // rather than read through a reader of our own. Every reader of this file stops
            // early on purpose — the header pass and the cue read both break out the moment
            // they have their tags — so this abort is what ends those requests, and it must
            // be the first thing that happens.
            // 2026-08-22: an `await reader.cancel()` was put in front of it to tidy an
            // AbortError out of the log. Every suite stayed green and the user could not
            // play anything at all until it was reverted. The mechanism was never pinned
            // down — the mock body lets go instantly where a network stream need not — so
            // treat this as measured behaviour rather than a theory, and change it only
            // with evidence from a real link.
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
 * Extracts embedded tracks, fonts, chapters and subtitles from an HTTP stream (debrid CDN or
 * the local torrent server) and feeds them into the player's Subtitles pipeline. Unlike a
 * local file the playback bytes can't be tapped, so subtitle cues come from a second range
 * request paced to stay just ahead of the play position.
 *
 * The whole container header is read in ONE sequential pass (modules/playback/mkv-header.js).
 * The dependency this replaced opened an open-ended `bytes=0-` request PER header tag — six
 * concurrent GETs against the host the video element is prerolling from, under the webview's
 * six-connections-per-host cap. Measured live (DanMachi BD over TorBox, 2026-08-23): six
 * byte-zero opens before the first cue could be requested, each ~1s on a busy evening.
 * "Subtitles take forever to appear" was substantially that. Tracks are delivered — and the
 * cue stream started — the moment the pass reaches them, while the same single connection
 * carries on into the attachments behind them.
 *
 * WHEN the cue stream moves is decided by modules/playback/subtitle-scheduler.js. The rule
 * it replaced — restart whenever the playhead's cluster is more than 1MB past the parser —
 * turned a briefly slow link into a livelock of doomed once-a-second restarts (main.log
 * 2026-08-23 01:25, "the stream restarted but delivered nothing" ×21).
 */
export default class DebridMetadata {
  /** How long the subtitle stream may deliver nothing before its request is retried. Static so tests can shorten it. */
  static STALL_TIMEOUT = 30_000
  /** How often the watcher looks at the playback position while the parser waits on bytes. */
  static WATCH_INTERVAL = 250
  /** How long a restart after a seek may deliver nothing before it is worth reporting. */
  static SILENCE_TIMEOUT = 12_000
  /** Scheduler tunables, exposed for tests; see subtitle-scheduler.js for what they mean. */
  static SETTLE_MS = 400
  static DRIFT_SLACK_SECONDS = 45
  static DRIFT_INTERVAL_MS = 10_000

  destroyed = false
  /** Cues handed to the renderer, so a stream that goes quiet can prove it. */
  cues = 0
  /** @type {RemoteFile | null} */
  remote = null
  /** @type {ReturnType<typeof createHeader> | null} The container header, once read. */
  header = null
  /** Media duration in ms once known; also bounds what counts as a real seek target. */
  durationMs = 0
  /** @type {Map<number, any>} Subtitle track descriptors by track number, for block decode. */
  subtitleTracks = new Map()
  /** @type {{ time: number, byte: number }[] | null} The file's own seek index, once read. */
  cuesIndex = null
  /** Milliseconds per raw timecode unit; from the Info element, updated by the stream. */
  timecodeScale = 1
  /** The current cluster's raw timecode, carried across restarts. */
  clusterTimecode = 0
  /** @type {{ start: number, end: number }[]} Byte ranges whose cues are already in the
   * renderer, so a seek back into one needs nothing from the link. See cue-index.js. */
  #covered = []
  /** @type {Promise<void> | null} Settles when the cue read has finished, either way. */
  #cuesReady = null
  /** @type {Map<number, number>} Failed block decodes per track, reported once. */
  #decodeFailures = new Map()
  /** When this parser was created, so the first cue can say how long it took. */
  #startedAt = Date.now()
  /** @type {Promise<any[]>} Settles once the header has decided about embedded tracks:
   * with the descriptors, or an empty list when the container carries none. */
  tracksReady = Promise.resolve([])
  #settleTracks = (/** @type {any[]} */ _tracks) => {}

  /**
   * @param {any} file - The playing file object.
   * @param {any[]} files - All resolved files of the torrent, used to find external subtitles.
   * @param {import('@/modules/subtitles.js').default} subtitles - Player subtitle instance to feed.
   * @param {{ getTime?: () => number, onChapters?: (chapters: any[]) => void }} [opts]
   */
  constructor (file, files, subtitles, { getTime = () => 0, onChapters } = {}) {
    debug('Initializing metadata parser for: ' + file?.name)
    this.file = file
    this.subtitles = subtitles
    this.getTime = getTime
    this.schedule = createSchedule({
      settleMs: this.constructor.SETTLE_MS,
      driftSlackSeconds: this.constructor.DRIFT_SLACK_SECONDS,
      driftIntervalMs: this.constructor.DRIFT_INTERVAL_MS
    })

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
    this.tracksReady = new Promise(resolve => { this.#settleTracks = resolve })
    this.#bootstrap(onChapters).catch(error => {
      if (!this.destroyed) console.warn(`[subtitles] the container header could not be read (${error?.message}); embedded subtitles are unavailable for this file`)
    }).finally(() => this.#settleTracks([...this.subtitleTracks.values()]))
  }

  /** The single header pass, and everything that hangs off it. */
  async #bootstrap (onChapters) {
    const header = await this.#readHeader()
    if (this.destroyed || !header) return
    this.header = header
    this.timecodeScale = header.timecodeScale
    this.durationMs = header.durationMs

    // the rare mux that parks a promised element behind the clusters gets one bounded
    // targeted read for it — still nothing like the old request-per-tag behaviour
    for (const name of missingHeaderTags(header)) await this.#readMissing(header, name)
    if (this.destroyed) return

    const chapters = parseChapters(header.chapters, header.timecodeScale, header.durationMs)
    if (chapters.length) {
      debug(`Found ${chapters.length} chapters`)
      onChapters?.(chapters)
    }
    this.#deliverAttachments(header.attachments)
  }

  /**
   * Reads the file once from the top to the first cluster, folding every header element
   * on the way. Tracks are ACTED ON the moment they fold — the subtitle stream and the
   * cue-index read start while this same connection is still pulling the attachments
   * that sit behind them.
   */
  async #readHeader () {
    const source = this.remote.slice(0)
    const decoder = new EbmlIteratorDecoder({ bufferTagIds: HEADER_TAGS })
    const header = createHeader()
    let read = 0
    try {
      readLoop: for await (const chunk of source.stream()) {
        if (this.destroyed) return null
        read += chunk.length
        for (const tag of decoder.parseTags(chunk)) {
          if (!foldHeaderTag(header, tag)) break readLoop
          if (header.tracks && !this.subtitleTracks.size) this.#deliverTracks(header)
        }
        if (read > HEADER_READ_CAP) {
          debug(`Header pass gave up after ${read} bytes without reaching a cluster`)
          break
        }
      }
    } finally {
      source.abort()
    }
    if (!this.destroyed && header.tracks && !this.subtitleTracks.size) this.#deliverTracks(header)
    debug(`Header pass read ${read} bytes: tracks=${Boolean(header.tracks)} chapters=${Boolean(header.chapters)} attachments=${Boolean(header.attachments)} cluster@${header.firstClusterAt}`)
    return header
  }

  /** Announces the subtitle tracks and starts the machinery that feeds them. */
  #deliverTracks (header) {
    const tracks = parseSubtitleTracks(header.tracks)
    debug(`Found ${tracks.length} subtitle tracks`)
    for (const track of tracks) {
      if (!track.decodable) console.warn(`[subtitles] track ${track.number} (${track.language}) uses ContentCompAlgo ${track.compression?.algo}, which cannot be decoded; it will stay empty`)
    }
    if (!tracks.length) return
    this.subtitleTracks = new Map(tracks.map(track => [track.number, track]))
    this.timecodeScale = header.timecodeScale
    this.durationMs = header.durationMs
    this.subtitles.handleTracks(tracks)
    this.#loadCues(header)
    this.#streamSubtitles()
  }

  /** Embedded font attachments into the renderer, with the torrent client's guards. */
  #deliverAttachments (attachmentsTag) {
    const attachments = parseAttachments(attachmentsTag)
    if (!attachments.length) return
    debug(`Found ${attachments.length} attachments`)
    for (const attachment of attachments) {
      if (!fontRx.test(attachment.filename) && !attachment.mimetype?.toLowerCase().includes('font')) continue
      if (SUPPORTS.isAndroid && attachment.data.length > MAX_ANDROID_FONT) continue
      this.subtitles.handleFile(hex2bin(arr2hex(attachment.data)))
    }
  }

  /** One bounded read for a promised element the prefix walk did not meet. */
  async #readMissing (header, name) {
    const at = header.positions[name]
    if (at == null || at >= this.file.size) return
    debug(`Reading ${name} with a targeted request at ${at}`)
    const tag = await this.#readTagAt(at, EbmlTagId[name], TARGETED_READ_CAP)
    if (!tag) return
    foldHeaderTag(header, tag)
    if (name === 'Tracks' && !this.subtitleTracks.size) this.#deliverTracks(header)
  }

  /** Reads one whole element from a byte position, bounded, over one request. */
  async #readTagAt (start, tagId, cap) {
    const source = this.remote.slice(start, Math.min(this.file.size, start + cap))
    const decoder = new EbmlIteratorDecoder({ bufferTagIds: [tagId] })
    try {
      for await (const chunk of source.stream()) {
        if (this.destroyed) return null
        for (const tag of decoder.parseTags(chunk)) {
          if (tag.id === tagId) return tag
        }
      }
    } catch (error) {
      debug(`Targeted read for ${EbmlTagId[tagId]} failed:`, error)
    } finally {
      source.abort()
    }
    return null
  }

  /**
   * Streams the file's clusters through the decoder, throttled against the playback position.
   *
   * @param {number} [from] Byte offset to start at, for picking a given-up stream back up.
   */
  async #streamSubtitles (from = 0) {
    const byteRate = this.durationMs > 0 ? this.file.size / (this.durationMs / 1_000) : 0
    if (from === 0) from = await this.#firstReadTarget(byteRate)
    if (this.destroyed) return
    // the window of bytes fed to the parser so far; restarts land outside it
    let start = from
    let offset = from
    for (let attempt = 0; attempt < RETRIES && !this.destroyed; ++attempt) {
      const source = this.remote.slice(offset)
      // a stalled connection yields no chunk, and chunk handling used to be the only place a
      // seek was noticed — so a seek during a stall never restarted the stream, and a dead link
      // hung the subtitle stream forever. This watcher covers the waiting: a settled seek out
      // of the window or a stall past the budget aborts the request, which ends the parse loop.
      let jumpTo = null
      let stalled = false
      let streaming = true
      let progressed = Date.now()
      const watcher = (async () => {
        while (streaming && !this.destroyed) {
          observeTime(this.schedule, this.getTime())
          const jump = this.#restartDecision(byteRate, start, offset)
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
        for await (const length of this.#parse(source.stream(), offset === 0)) {
          if (this.destroyed) return
          offset += length
          this.#claimCoverage(start, offset)
          progressed = Date.now()
          const next = await this.#pace(byteRate, start, offset)
          if (next !== offset) {
            debug(`Seek left the parsed subtitle window, restarting stream at ${next}`)
            noteRestart(this.schedule)
            this.#watchForSilence(next)
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
          noteRestart(this.schedule)
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
    // subtitles at all. Wait, asking the link for nothing, until a seek leaves the
    // parsed window: that is a new place to read from, and worth one more go.
    await this.#reviveOnSeek(byteRate, start, offset)
  }

  /**
   * The cluster stream: bytes in, cue events out through the player's Subtitles instance,
   * chunk lengths yielded so the caller can track its window. A read that starts mid-file
   * finds its footing by scanning for a Cluster id — a header can straddle two chunks, so
   * the scan carries a tail across; without that, a restart could drain the whole rest of
   * the file without emitting a single cue.
   *
   * @param {AsyncIterable<Uint8Array>} stream
   * @param {boolean} stable - Whether the stream starts at the top of the file, where the
   *   decoder needs no resync.
   */
  async * #parse (stream, stable) {
    const decoder = new EbmlIteratorDecoder({ bufferTagIds: [EbmlTagId.BlockGroup] })
    let tail = new Uint8Array(0)
    for await (const chunk of stream) {
      if (this.destroyed) return
      if (!stable) {
        const scan = tail.length ? concat([tail, chunk]) : chunk
        const at = findClusterStart(scan)
        if (at === -1) {
          tail = scan.slice(Math.max(0, scan.length - SCAN_TAIL))
        } else {
          stable = true
          for (const tag of decoder.parseTags(scan.slice(at))) this.#handleTag(tag)
        }
      } else {
        for (const tag of decoder.parseTags(chunk)) this.#handleTag(tag)
      }
      yield chunk.length
    }
  }

  /** One decoded EBML tag from the cluster stream. */
  #handleTag (tag) {
    if (tag.id === EbmlTagId.TimecodeScale && tag.data) {
      this.timecodeScale = Number(tag.data) / 1_000_000
    } else if (tag.id === EbmlTagId.Timecode) {
      this.clusterTimecode = Number(tag.data)
    } else if (tag.id === EbmlTagId.BlockGroup) {
      const block = tag.Children?.find(child => child?.id === EbmlTagId.Block)
      const rawDuration = tag.Children?.find(child => child?.id === EbmlTagId.BlockDuration)?.data
      this.#emitBlock(block, rawDuration != null ? Number(rawDuration) * this.timecodeScale : undefined)
    } else if (tag.id === EbmlTagId.SimpleBlock) {
      // rare for text subtitles (the spec wants BlockGroup for the duration) but muxers
      // exist that do it; a fallback duration beats a cue that never appears
      this.#emitBlock(tag, undefined)
    }
  }

  /** A subtitle block becomes a cue event, and a block that cannot be decoded becomes a
   * counted, once-reported failure instead of silence. */
  #emitBlock (block, durationMs) {
    if (!block || !this.subtitleTracks.has(block.track)) return
    try {
      const decoded = decodeBlock(block, durationMs, this.subtitleTracks, this.timecodeScale, this.clusterTimecode)
      if (!decoded || this.destroyed) return
      if (this.cues === 0) debug(`First cue after ${Date.now() - this.#startedAt}ms`)
      this.cues++
      this.subtitles.handleSubtitle({ subtitle: decoded.cue, trackNumber: decoded.trackNumber })
    } catch (error) {
      const failures = (this.#decodeFailures.get(block.track) ?? 0) + 1
      this.#decodeFailures.set(block.track, failures)
      if (failures === 1) console.warn(`[subtitles] track ${block.track} cues cannot be decoded (${error?.message}); further failures on this track are counted silently`)
    }
  }

  /**
   * Where the very first read should begin.
   *
   * Reading from byte zero would re-download the header and attachments the header pass
   * already covered. The first read starts where the first cue the viewer can see
   * actually lives: the cluster holding the playhead from the file's own seek index, or
   * failing that the first cluster the header pass located.
   *
   * @param {number} byteRate
   * @returns {Promise<number>}
   */
  async #firstReadTarget (byteRate) {
    try {
      await Promise.race([this.#cuesReady, sleep(FIRST_READ_CUE_WAIT)])
    } catch { /* a failed cue read just leaves the estimate in charge */ }
    if (this.destroyed) return 0
    if (this.cuesIndex) {
      const target = this.#restartTarget(byteRate, 0, 0)
      if (target && target > 0) {
        debug(`Starting the subtitle stream at cluster byte ${target}, skipping ${target} bytes of header and attachments`)
        return target
      }
    }
    return this.header?.firstClusterAt || 0
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
      observeTime(this.schedule, this.getTime())
      const jump = this.#restartDecision(byteRate, start, offset)
      if (jump !== null && jump !== offset) {
        debug(`A seek to ${jump} picks the given-up subtitle stream back up`)
        noteRestart(this.schedule)
        return this.#streamSubtitles(jump)
      }
      await sleep(this.constructor.WATCH_INTERVAL)
    }
  }

  /**
   * Reads the file's Cues element — the exact timestamp-to-cluster map the video
   * element itself seeks with — so a restart after a seek lands on the right cluster
   * instead of a bitrate guess. One bounded range request against the position the seek
   * head names; a file without cues just leaves the estimate in charge as before.
   */
  #loadCues (header) {
    if (this.#cuesReady) return this.#cuesReady
    this.#cuesReady = (async () => {
      const at = header.positions.Cues
      if (at == null || at >= this.file.size || this.destroyed) return
      // cues are tens of kilobytes; the request is bounded and dropped once the tag is whole
      const tag = await this.#readTagAt(at, EbmlTagId.Cues, 4_000_000)
      if (this.destroyed || !tag) return
      this.cuesIndex = parseCues(tag, header.segmentStart)
      debug(this.cuesIndex
        ? `Read ${this.cuesIndex.length} cue points; seeks will restart the subtitle stream exactly`
        : 'The file lists no usable cue points; seeks fall back to the bitrate estimate')
    })().catch(error => debug('Failed to read cues, seeks fall back to the bitrate estimate:', error))
    return this.#cuesReady
  }

  /**
   * Where the stream should restart right now, or null. Position says WHERE (the cue
   * index or the bitrate estimate, minus what is already parsed or covered); the
   * schedule says WHEN (seeks after they settle, catch-up only past real distance and
   * rate-limited). Both must agree.
   */
  #restartDecision (byteRate, start, offset) {
    let target = this.#restartTarget(byteRate, start, offset)
    // the cues in a range already parsed were handed to the renderer, and it keeps them:
    // seeking back into one shows subtitles instantly, so asking the link to serve those
    // bytes a second time buys nothing but the wait it used to cost
    if (target !== null && coversByte(this.#covered, target)) target = null
    if (!shouldRestart(this.schedule, { target, offset, byteRate })) return null
    return target
  }

  /** Where a restart would have to begin to cover the playhead, ignoring the schedule. */
  #restartTarget (byteRate, start, offset) {
    if (this.cuesIndex) {
      const position = this.getTime()
      // a playhead past the end of the file is not a seek, it is a caller reading
      // straight through — the same overshoot escape the estimate below has always had
      if (this.durationMs && position * 1_000 > this.durationMs) return null
      return cueJumpTarget(this.cuesIndex, position, this.timecodeScale || 1, { start, offset })
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
   * playback approaches it, or a fresh one when a settled seek left the parsed window. The
   * renderer deduplicates events, so overlapping parses are safe.
   */
  async #pace (byteRate, start, offset) {
    if (!byteRate) return offset
    while (!this.destroyed) {
      const jump = this.#restartDecision(byteRate, start, offset)
      if (jump !== null) return jump
      // wait for playback to catch up before buffering further ahead
      if (offset <= this.getTime() * byteRate + AHEAD_SECONDS * byteRate) return offset
      await sleep(1_000)
    }
    return offset
  }

  destroy () {
    if (this.destroyed) return
    debug('Destroying metadata parser')
    this.destroyed = true
    this.remote?.destroy()
    this.remote = null
    this.subtitleTracks.clear()
    this.subtitles = null
    this.file = null
  }
}
