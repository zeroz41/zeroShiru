// The Matroska block layer: track descriptors with real compression info, block decoding
// that can undo zlib AND header stripping, and the mid-file resync scan. The dependency
// this replaced assumed every compressed track was zlib and swallowed decode errors in a
// fire-and-forget handler — a header-stripped track produced zero cues and zero log lines.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { deflate } from 'pako'
import { EbmlTagId } from 'ebml-iterator'
import { parseSubtitleTracks, decodeBlock, decompressBlock, findClusterStart, COMPRESSION, FALLBACK_DURATION_MS } from '../../../common/modules/playback/mkv-subtitles.js'

const tag = (id, rest) => ({ id, ...rest })
const leaf = (id, data) => ({ id, data })

/** A raw TrackEntry the way readSeekHeadTag hands it over. */
function trackEntry ({ number = 2, codec = 'S_TEXT/ASS', language, name, header, compression } = {}) {
  const children = [
    leaf(EbmlTagId.TrackNumber, number),
    leaf(EbmlTagId.TrackType, 0x11),
    leaf(EbmlTagId.CodecID, codec)
  ]
  if (language != null) children.push(leaf(EbmlTagId.Language, language))
  if (name != null) children.push(leaf(EbmlTagId.Name, name))
  if (header != null) children.push(leaf(EbmlTagId.CodecPrivate, Buffer.from(header)))
  if (compression) {
    const comp = [leaf(EbmlTagId.ContentCompAlgo, compression.algo)]
    if (compression.settings) comp.push(leaf(EbmlTagId.ContentCompSettings, Buffer.from(compression.settings)))
    children.push(tag(EbmlTagId.ContentEncodings, {
      Children: [tag(EbmlTagId.ContentEncoding, { Children: [tag(EbmlTagId.ContentCompression, { Children: comp })] })]
    }))
  }
  return tag(EbmlTagId.TrackEntry, { Children: children })
}

const tracksTag = (...entries) => tag(EbmlTagId.Tracks, { Children: entries })

test('subtitle tracks parse with language, name, header and defaults', () => {
  const parsed = parseSubtitleTracks(tracksTag(
    trackEntry({ number: 3, language: 'spa', name: 'Full', header: '[Script Info]\nx' }),
    trackEntry({ number: 4, codec: 'S_TEXT/UTF8' })
  ))
  assert.equal(parsed.length, 2)
  assert.deepEqual(
    [parsed[0].number, parsed[0].language, parsed[0].type, parsed[0].name, parsed[0].decodable],
    [3, 'spa', 'ass', 'Full', true])
  assert.ok(parsed[0].header.startsWith('[Script Info]'))
  assert.equal(parsed[1].language, 'eng', 'no Language element means English, per the spec default')
  assert.equal(parsed[1].type, 'utf8')
})

test('video and audio tracks, and non-text subtitles, are not offered', () => {
  const video = tag(EbmlTagId.TrackEntry, { Children: [leaf(EbmlTagId.TrackNumber, 1), leaf(EbmlTagId.TrackType, 0x01), leaf(EbmlTagId.CodecID, 'V_MPEG4/ISO/AVC')] })
  const pgs = tag(EbmlTagId.TrackEntry, { Children: [leaf(EbmlTagId.TrackNumber, 5), leaf(EbmlTagId.TrackType, 0x11), leaf(EbmlTagId.CodecID, 'S_HDMV/PGS')] })
  assert.deepEqual(parseSubtitleTracks(tracksTag(video, pgs)), [])
  assert.deepEqual(parseSubtitleTracks(null), [], 'a file with no Tracks element')
})

test('a zlib-compressed track carries its descriptor and its blocks inflate', () => {
  const [track] = parseSubtitleTracks(tracksTag(trackEntry({ compression: { algo: COMPRESSION.zlib } })))
  assert.equal(track.compression.algo, COMPRESSION.zlib)
  assert.ok(track.decodable)
  const text = '1,0,Default,,0,0,0,,compressed line'
  const out = decompressBlock(deflate(Buffer.from(text)), track.compression)
  assert.equal(Buffer.from(out).toString(), text)
})

test('a header-stripped track gets its stripped bytes put back', () => {
  // ContentCompAlgo 3: the muxer removed these bytes from the front of every block
  const [track] = parseSubtitleTracks(tracksTag(trackEntry({ compression: { algo: COMPRESSION.headerStripping, settings: 'Dialogue' } })))
  assert.ok(track.decodable, 'header stripping is trivially undoable and must not disable the track')
  const out = decompressBlock(Buffer.from(': rest of the line'), track.compression)
  assert.equal(Buffer.from(out).toString(), 'Dialogue: rest of the line')
})

test('an unknown compression marks the track undecodable instead of pretending', () => {
  const [track] = parseSubtitleTracks(tracksTag(trackEntry({ compression: { algo: 2 } }))) // lzo
  assert.equal(track.decodable, false)
  assert.throws(() => decompressBlock(Buffer.from('x'), track.compression), /ContentCompAlgo 2/)
})

test('a block that fails to inflate throws instead of vanishing', () => {
  assert.throws(() => decompressBlock(Buffer.from('this is not zlib data'), { algo: COMPRESSION.zlib, settings: null }))
})

// --- block → cue ---

function subtitleTrackMap (overrides) {
  const [track] = parseSubtitleTracks(tracksTag(trackEntry(overrides)))
  return new Map([[track.number, track]])
}

test('an ASS block decodes into a cue with its inline fields split out', () => {
  const tracks = subtitleTrackMap({ number: 2 })
  const payload = Buffer.from('7,0,Signs,Sign,0,0,60,,{\\pos(1,2)}On the wall, text')
  const decoded = decodeBlock({ track: 2, value: 40, payload }, 1_500, tracks, 1, 10_000)
  assert.equal(decoded.trackNumber, 2)
  assert.equal(decoded.cue.time, 10_040, 'cluster timecode plus block offset, scaled')
  assert.equal(decoded.cue.duration, 1_500)
  assert.equal(decoded.cue.style, 'Signs')
  assert.equal(decoded.cue.marginV, '60')
  assert.equal(decoded.cue.text, '{\\pos(1,2)}On the wall, text', 'commas inside the text survive the field split')
})

test('an SRT block is plain text with no field surgery', () => {
  const tracks = subtitleTrackMap({ number: 4, codec: 'S_TEXT/UTF8' })
  const decoded = decodeBlock({ track: 4, value: 0, payload: Buffer.from('Plain, with a comma') }, 2_000, tracks, 1, 0)
  assert.equal(decoded.cue.text, 'Plain, with a comma')
  assert.equal(decoded.cue.style, undefined)
})

test('a block with no duration gets the fallback instead of NaN', () => {
  const tracks = subtitleTrackMap({ number: 4, codec: 'S_TEXT/UTF8' })
  const decoded = decodeBlock({ track: 4, value: 5, payload: Buffer.from('SimpleBlock text') }, undefined, tracks, 1, 100)
  assert.equal(decoded.cue.duration, FALLBACK_DURATION_MS, 'NaN durations used to reach the renderer')
})

test('a compressed block decodes through the track descriptor on the way to a cue', () => {
  const tracks = subtitleTrackMap({ number: 2, compression: { algo: COMPRESSION.zlib } })
  const payload = deflate(Buffer.from('1,0,Default,,0,0,0,,inflated dialogue'))
  const decoded = decodeBlock({ track: 2, value: 0, payload }, 1_000, tracks, 1, 0)
  assert.equal(decoded.cue.text, 'inflated dialogue')
})

test('a block for an unknown track is nobody\'s business', () => {
  assert.equal(decodeBlock({ track: 9, value: 0, payload: Buffer.from('x') }, 1, subtitleTrackMap({}), 1, 0), null)
})

// --- the mid-file resync scan ---

/** A plausible cluster start: id, a 4-byte size vint, then a Timecode child. */
const CLUSTER_START = Buffer.from([0x1f, 0x43, 0xb6, 0x75, 0x10, 0x00, 0x30, 0x00, 0xe7, 0x81, 0x05, 0xa3, 0x40, 0x00, 0x00, 0x00])

test('a cluster id is found wherever it sits in the chunk', () => {
  assert.equal(findClusterStart(CLUSTER_START), 0)
  const buried = Buffer.concat([Buffer.from([9, 9, 9, 9, 9]), CLUSTER_START])
  assert.equal(findClusterStart(buried), 5)
})

test('the id bytes appearing inside video data are not believed', () => {
  // the four id bytes followed by garbage that fails the first-child probe
  const decoy = Buffer.from([0x1f, 0x43, 0xb6, 0x75, 0x81, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  assert.equal(findClusterStart(decoy), -1, 'a decoy id with an invalid first child is skipped')
  assert.equal(findClusterStart(Buffer.from([1, 2, 3])), -1, 'a chunk too small to hold a header')
})
