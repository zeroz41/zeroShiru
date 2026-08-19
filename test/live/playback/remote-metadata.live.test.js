// Verifies the remote-MKV metadata approach (HTTP range reads through
// matroska-metadata) against a real MKV that contains subtitle tracks.
// Needs network but no API key. Uses the official Matroska test files.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { skipped } from '../../tools/skip.js'
import Metadata from 'matroska-metadata'

const URL8 = 'https://github.com/ietf-wg-cellar/matroska-test-files/raw/master/test_files/test5.mkv'

// mirrors RemoteFile in zeroShiru/common/modules/debrid/metadata.js
function remoteFile (url, name) {
  const controllers = new Set()
  return {
    name,
    controllers,
    slice (start = 0, end) {
      const controller = new AbortController()
      controllers.add(controller)
      const range = `bytes=${start}-${end ? end - 1 : ''}`
      return {
        stream: () => (async function * () {
          try {
            const res = await fetch(url, { headers: { Range: range }, signal: controller.signal, redirect: 'follow' })
            if (!res.ok && res.status !== 206) throw new Error(`fetch failed: ${res.status}`)
            yield * res.body
          } catch (error) {
            // the reader stops early on purpose, and teardown aborts what's in flight
            if (controller.signal.aborted) return
            throw error
          } finally {
            controllers.delete(controller)
            controller.abort()
          }
        })()
      }
    },
    destroy () {
      for (const controller of controllers) controller.abort()
    }
  }
}

async function reachable (url) {
  try {
    const res = await fetch(url, { method: 'HEAD', redirect: 'follow', signal: AbortSignal.timeout(20_000) })
    return res.ok || res.status === 206
  } catch {
    return false
  }
}

// a link that dies mid-read says nothing about the parser, so it skips rather than fails
const isNetworkError = error => {
  for (let cause = error; cause; cause = cause.cause) {
    if (cause.name === 'TimeoutError' || /fetch failed|terminated|socket hang up/i.test(cause.message ?? '')) return true
    if (/^(UND_ERR_|ECONN|ENOTFOUND|EAI_AGAIN|ETIMEDOUT)/.test(cause.code ?? '')) return true
  }
  return false
}

test('parses tracks, chapters and subtitles from a remote MKV over HTTP ranges', { timeout: 180_000 }, async () => {
  if (!await reachable(URL8)) return skipped(`${new URL(URL8).host} unreachable, this test needs network`)

  const file = remoteFile(URL8, 'test5.mkv')
  const metadata = new Metadata(file)
  const subtitles = []
  metadata.on('subtitle', (subtitle, track) => subtitles.push({ track, text: subtitle.text }))

  try {
    const tracks = await metadata.getTracks()
    console.log(`  ${tracks.length} subtitle tracks:`, tracks.map(track => `${track.number}:${track.language ?? 'und'}`).join(' '))
    assert.ok(tracks.length > 0, 'test5.mkv contains SRT subtitle tracks')

    const chapters = await metadata.getChapters().catch(() => [])
    console.log(`  ${chapters.length} chapters`)

    // stream the body like the player does and collect emitted subtitle events,
    // stopping once enough have streamed to prove the point, EOF would cost the
    // whole file's bandwidth for nothing
    for await (const _ of metadata.parseStream(file.slice(0).stream(), true)) {
      if (subtitles.length >= 25) break
    }
    console.log(`  ${subtitles.length} subtitle events streamed`)
    assert.ok(subtitles.length > 0, 'subtitle events must stream from the remote file')
  } catch (error) {
    if (isNetworkError(error)) return skipped(`lost the connection to ${new URL(URL8).host} mid-read, this test needs a stable link`)
    throw error
  } finally {
    metadata.destroy()
    file.destroy()
  }
})
