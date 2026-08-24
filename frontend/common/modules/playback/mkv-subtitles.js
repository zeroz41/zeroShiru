// Reading subtitle cues out of a Matroska container, done here instead of trusted to a
// dependency. The vendored matroska-metadata parser this replaces assumed every
// compressed track was zlib ("TODO: Assume zlib deflate compression") and decoded blocks
// in a fire-and-forget async handler, so a track using header stripping — or any block
// that failed to decode — produced no cue and no error, forever. These are pure
// functions over EBML tags: bytes go in, cue events come out, and every failure mode is
// a return value a test can assert on.

import { inflate } from 'pako'
import { arr2text, concat } from 'uint8-util'
import { EbmlTagId } from 'ebml-iterator'

/** Matroska ContentCompAlgo values this reader can undo. */
export const COMPRESSION = { zlib: 0, headerStripping: 3 }

const SSA_FIELDS = ['readOrder', 'layer', 'style', 'name', 'marginL', 'marginR', 'marginV', 'effect']
/** SSA/ASS blocks carry their fields inline; everything else is plain cue text. */
const SSA_TYPES = new Set(['ssa', 'ass'])
/** A subtitle block with no BlockDuration still has to leave the screen eventually. */
export const FALLBACK_DURATION_MS = 5_000

const child = (tag, id) => tag?.Children?.find(entry => entry?.id === id)
const data = (tag, id) => child(tag, id)?.data

/**
 * The subtitle tracks of a raw Tracks element, with everything block decoding needs.
 *
 * Compared to the dependency's reader this keeps the compression DESCRIPTOR — which
 * algorithm, and the stripped header bytes for algo 3 — rather than a boolean that
 * hard-coded zlib. A track compressed with an algorithm nobody can undo is still
 * returned (the picker should show it exists) but marked undecodable so the stream can
 * say why it stays empty instead of staying quiet.
 *
 * @param {{ Children?: any[] } | null | undefined} tracksTag - Raw EbmlMasterTag for Tracks.
 * @returns {Array<{ number: number, language: string, type: string, name?: string,
 *   header?: string, default: boolean, forced: boolean,
 *   compression: null | { algo: number, settings: Uint8Array | null }, decodable: boolean }>}
 */
export function parseSubtitleTracks (tracksTag) {
  const tracks = []
  for (const entry of tracksTag?.Children ?? []) {
    if (entry?.id !== EbmlTagId.TrackEntry) continue
    if (data(entry, EbmlTagId.TrackType) !== 0x11) continue
    const codec = String(data(entry, EbmlTagId.CodecID) || '')
    if (!codec.startsWith('S_TEXT')) continue

    const compression = readCompression(entry)
    const header = data(entry, EbmlTagId.CodecPrivate)
    tracks.push({
      number: Number(data(entry, EbmlTagId.TrackNumber)),
      language: String(data(entry, EbmlTagId.Language) ?? 'eng'),
      type: codec.substring(7).toLowerCase(), // S_TEXT/ASS -> ass, S_TEXT/UTF8 -> utf8
      name: data(entry, EbmlTagId.Name)?.toString(),
      header: header ? arr2text(header) : undefined,
      default: Boolean(data(entry, EbmlTagId.FlagDefault) ?? 1),
      forced: Boolean(data(entry, EbmlTagId.FlagForced) ?? 0),
      compression,
      decodable: !compression || compression.algo === COMPRESSION.zlib || compression.algo === COMPRESSION.headerStripping
    })
  }
  return tracks
}

/** The first ContentCompression of a TrackEntry, or null for a stored-as-is track. */
function readCompression (entry) {
  for (const encoding of child(entry, EbmlTagId.ContentEncodings)?.Children ?? []) {
    if (encoding?.id !== EbmlTagId.ContentEncoding) continue
    const comp = child(encoding, EbmlTagId.ContentCompression)
    if (!comp) continue
    const settings = data(comp, EbmlTagId.ContentCompSettings)
    return {
      // absent means zlib, per the Matroska spec's default
      algo: Number(data(comp, EbmlTagId.ContentCompAlgo) ?? COMPRESSION.zlib),
      settings: settings ? new Uint8Array(settings) : null
    }
  }
  return null
}

/**
 * A block's payload as stored → the bytes the codec actually wrote.
 * @param {Uint8Array} payload
 * @param {{ algo: number, settings: Uint8Array | null } | null} compression
 * @returns {Uint8Array}
 */
export function decompressBlock (payload, compression) {
  if (!compression) return payload
  if (compression.algo === COMPRESSION.zlib) return inflate(payload)
  if (compression.algo === COMPRESSION.headerStripping) {
    return compression.settings?.length ? concat([compression.settings, payload]) : payload
  }
  throw new Error(`unsupported ContentCompAlgo ${compression.algo}`)
}

/**
 * One Block or SimpleBlock payload as a cue event, or null when the block belongs to no
 * known subtitle track. Throws on undecodable payloads — the caller owns counting and
 * reporting those, because only it knows the track and the stream position.
 *
 * @param {{ track: number, value: number, payload: Uint8Array }} block - Parsed Block tag.
 * @param {number | undefined} durationMs - BlockDuration already scaled to ms, if present.
 * @param {Map<number, ReturnType<typeof parseSubtitleTracks>[0]>} tracks - By track number.
 * @param {number} timecodeScale - Milliseconds per raw timecode unit.
 * @param {number} clusterTimecode - The containing cluster's raw timecode.
 * @returns {{ trackNumber: number, cue: any } | null}
 */
export function decodeBlock (block, durationMs, tracks, timecodeScale, clusterTimecode) {
  const track = tracks.get(block?.track)
  if (!track) return null
  const payload = decompressBlock(block.payload, track.compression)
  const cue = {
    text: arr2text(payload),
    time: (block.value + clusterTimecode) * timecodeScale,
    duration: Number.isFinite(durationMs) ? durationMs : FALLBACK_DURATION_MS
  }
  if (SSA_TYPES.has(track.type)) {
    const values = cue.text.split(',')
    for (let i = 0; i < SSA_FIELDS.length; i++) cue[SSA_FIELDS[i]] = values[i]
    cue.text = values.slice(SSA_FIELDS.length).join(',')
  }
  return { trackNumber: block.track, cue }
}

/**
 * Where a Cluster element starts inside `bytes`, or -1. This is how a read that begins
 * in the middle of the file — a seek restart landing on a byte estimate — finds its
 * footing: scan for the Cluster id and hand the parser everything from there.
 *
 * The candidate is only believed if the byte after its size field is itself a valid
 * one-byte EBML id (Timecode, SimpleBlock, CRC-32…), because the four id bytes can and
 * do appear inside video data.
 *
 * @param {Uint8Array} bytes
 * @returns {number}
 */
export function findClusterStart (bytes) {
  for (let i = 0; i + 12 < bytes.length; i++) {
    // EbmlTagId.Cluster, 0x1F43B675
    if (bytes[i] !== 0x1f || bytes[i + 1] !== 0x43 || bytes[i + 2] !== 0xb6 || bytes[i + 3] !== 0x75) continue
    const lead = bytes[i + 4]
    if (!lead) continue // a size vint cannot start 0x00
    const sizeLength = 8 - Math.floor(Math.log2(lead))
    if (EbmlTagId[bytes[i + 4 + sizeLength]]) return i
  }
  return -1
}

/** How much of a scanned chunk must be kept so a Cluster id straddling two chunks is
 * still seen: the id and size can span at most 12 bytes, and the validity probe reads
 * one more. */
export const SCAN_TAIL = 16
