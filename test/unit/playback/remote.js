// A fetch mock that serves HTTP range requests from an in-memory buffer, the way a debrid CDN
// serves a video file. Shared by the DebridMetadata streaming and seeking tests. It respects
// AbortSignals and can be told to stall or drop a connection at a given byte, which is how the
// poor-connection tests are staged.
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

export const FIXTURE = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../fixtures/episode.mkv'))

/** Resolves when the signal aborts, so a "stalled" stream can still be torn down. */
const aborted = signal => new Promise(resolve => {
  if (!signal) return // nothing will ever resolve this, which is what a hung request is
  if (signal.aborted) return resolve()
  signal.addEventListener('abort', resolve, { once: true })
})

/**
 * Installs the mock. Returns the request log and counters; restore the real fetch yourself if a
 * test needs it back (none currently do — the runner isolates files).
 * @param {Uint8Array} bytes - The file body to serve.
 * @param {string} url - The URL the video is served under.
 * @param {Object} [opts]
 * @param {number} [opts.chunkSize] - Bytes per yielded chunk.
 * @param {number} [opts.delay] - Milliseconds between chunks, to emulate a slow link.
 * @param {(request: { start: number }, position: number) => 'stall' | 'error' | void} [opts.behave]
 *   Consulted before each chunk: 'stall' hangs the stream until it is aborted, 'error' drops it.
 * @param {Record<string, Uint8Array>} [opts.extra] - Whole files served at other URLs (external subs, fonts).
 */
export function serveRemote (bytes, url, opts = {}) {
  const state = { requests: [], served: 0, extraFetched: [] }
  globalThis.fetch = async (target, init = {}) => {
    const href = String(target)
    if (href !== url) {
      const body = opts.extra?.[href]
      if (!body) throw new Error(`unexpected fetch of ${href}`)
      state.extraFetched.push(href)
      return { ok: true, status: 200, arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) }
    }
    const match = /bytes=(\d+)-(\d*)/.exec(init.headers?.Range || init.headers?.range || '')
    const start = match ? Number(match[1]) : 0
    const end = match?.[2] ? Number(match[2]) : bytes.length - 1
    const signal = init.signal
    const request = { start, end, served: 0, done: false, get aborted () { return Boolean(signal?.aborted) } }
    state.requests.push(request)
    const chunkSize = opts.chunkSize ?? 4096
    async function * body () {
      try {
        for (let position = start; position <= end;) {
          if (signal?.aborted) return
          const verdict = opts.behave?.(request, position)
          if (verdict === 'stall') return await aborted(signal)
          if (verdict === 'error') throw new Error('connection reset')
          const chunk = bytes.subarray(position, Math.min(position + chunkSize, end + 1))
          position += chunk.length
          request.served += chunk.length
          state.served += chunk.length
          yield chunk
          if (opts.delay) await new Promise(resolve => setTimeout(resolve, opts.delay))
        }
      } finally {
        request.done = true
      }
    }
    return { ok: true, status: 206, body: body() }
  }
  return state
}

/** Polls until the condition holds or the deadline passes; the tests' only clock. */
export async function until (condition, timeout = 5_000, step = 50) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (condition()) return true
    await new Promise(resolve => setTimeout(resolve, step))
  }
  return condition()
}

/** Captures everything DebridMetadata hands to the player's Subtitles instance. */
export function subtitleSpy () {
  const seen = { tracks: [], subtitles: [], fonts: [], files: [] }
  return {
    seen,
    handleTracks: tracks => seen.tracks.push(...tracks),
    handleSubtitle: event => seen.subtitles.push(event),
    handleFile: data => seen.fonts.push(data),
    handleSubtitleFile: file => seen.files.push(file)
  }
}
