// Fonts reach Subtitles.handleFile as a binary string, never as bytes. Producers encode with
// hex2bin(arr2hex(bytes)) because handleFile decodes with hex2arr(bin2hex(detail)); sending
// anything else drops the font silently, which is the bug fixed in 62791bbf.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { hex2arr, bin2hex } from 'uint8-util'
import DebridMetadata from '../../../common/modules/debrid/metadata.js'

const decodeAsPlayer = detail => hex2arr(bin2hex(detail))

const everyByte = new Uint8Array(256).map((_, index) => index)
const fontBytes = new Uint8Array([0x4f, 0x54, 0x54, 0x4f, 0x00, 0xff, 0x80, 0x7f, 0x00, 0x00, 0xc3, 0xa9])

function stubFetch (bytesByUrl) {
  const real = globalThis.fetch
  globalThis.fetch = async url => {
    const bytes = bytesByUrl[url]
    if (!bytes) throw new Error(`unexpected fetch of ${url}`)
    return { arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) }
  }
  return () => { globalThis.fetch = real }
}

function subtitleSpy () {
  const fonts = []
  return { fonts, handleFile: detail => fonts.push(detail), handleSubtitleFile () {}, handleTracks () {}, handleSubtitle () {} }
}

// an .mp4 carries no Matroska metadata, so only the external font fetches run
async function playWithFonts (fonts) {
  const files = [{ name: 'Show - 01.mp4', url: 'https://host/video', size: 1 }, ...fonts]
  const restore = stubFetch(Object.fromEntries(fonts.map(font => [font.url, font.bytes])))
  const spy = subtitleSpy()
  const metadata = new DebridMetadata(files[0], files, spy)
  // the fetches are fire-and-forget inside the constructor, let them settle
  for (let tick = 0; tick < 20 && spy.fonts.length < fonts.length; tick++) await new Promise(resolve => setImmediate(resolve))
  metadata.destroy()
  restore()
  return spy.fonts
}

test('a debrid font arrives as a binary string the player can decode back to the same bytes', async () => {
  const [detail] = await playWithFonts([{ name: 'Gothic.otf', url: 'https://host/gothic.otf', bytes: fontBytes }])

  assert.equal(typeof detail, 'string', 'handleFile is given a binary string, not bytes')
  assert.deepEqual(decodeAsPlayer(detail), fontBytes, 'the player must recover the font byte for byte')
})

test('every byte value survives the trip to the player', async () => {
  const [detail] = await playWithFonts([{ name: 'Full.ttf', url: 'https://host/full.ttf', bytes: everyByte }])

  assert.deepEqual(decodeAsPlayer(detail), everyByte)
})

test('every font of a release is sent, once each', async () => {
  const fonts = await playWithFonts([
    { name: 'Gothic.otf', url: 'https://host/gothic.otf', bytes: fontBytes },
    { name: 'Arial.ttf', url: 'https://host/arial.ttf', bytes: everyByte }
  ])

  assert.equal(fonts.length, 2)
  for (const detail of fonts) assert.equal(typeof detail, 'string')
})

test('the payload the torrent client used to send never yields the font', () => {
  // bin2hex walks its argument with charCodeAt, so { data } decodes to an empty font in the
  // renderer and throws under node's Buffer build. Lost either way.
  let decoded
  try { decoded = decodeAsPlayer({ data: fontBytes }) } catch { decoded = null }
  assert.notDeepEqual(decoded, fontBytes, 'the old payload must not decode to the font')
  assert.ok(!decoded?.length, 'the old payload carries no font bytes at all')
})

test('a font that arrives empty decodes to nothing, so the player can discard it', async () => {
  const [detail] = await playWithFonts([{ name: 'Empty.ttf', url: 'https://host/empty.ttf', bytes: new Uint8Array(0) }])

  assert.equal(decodeAsPlayer(detail).length, 0)
})

test('a release with no fonts sends nothing', async () => {
  assert.deepEqual(await playWithFonts([]), [])
})
