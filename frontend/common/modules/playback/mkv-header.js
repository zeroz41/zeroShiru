// One pass over a Matroska file's header, and everything the player wants from it.
//
// The dependency this replaces (matroska-metadata) opened a SEPARATE `bytes=0-` request
// for every header tag it wanted: segment, seek head, info, tracks, chapters,
// attachments — six open-ended GETs against the same host the video element is trying
// to preroll from, under the webview's six-connections-per-host cap. Measured live
// against a real TorBox link (DanMachi BD, 2026-08-23): six byte-zero opens before the
// first cue could even be asked for, each costing a ~1s round trip on a busy evening.
// "Subtitles take forever to appear" was largely this connection churn.
//
// Everything a muxer puts in front of the first cluster — which for ordinary releases
// is the entire header including the font attachments — now comes from ONE request,
// decoded in one walk. Tags the seek head promises beyond the first cluster (chapters
// at the end of the file, occasionally) are fetched afterwards with small bounded
// reads. Pure functions over EBML tags; the request itself lives in metadata.js.

import { EbmlTagId, EbmlTagPosition, Tools } from 'ebml-iterator'

const child = (tag, id) => tag?.Children?.find(entry => entry?.id === id)
const data = (tag, id) => child(tag, id)?.data

/** The header elements worth buffering whole during the walk. */
export const HEADER_TAGS = [EbmlTagId.SeekHead, EbmlTagId.Info, EbmlTagId.Tracks, EbmlTagId.Chapters, EbmlTagId.Attachments]

export function createHeader () {
  return {
    /** Absolute byte where the segment's data starts; seek-head positions are relative to it. */
    segmentStart: 0,
    /** @type {Record<string, number>} Tag name -> absolute byte, from the seek head. */
    positions: {},
    /** Milliseconds per raw timecode unit. */
    timecodeScale: 1,
    /** @type {number} Duration in ms, 0 while unknown. */
    durationMs: 0,
    /** @type {any | null} Raw Tracks element, for parseSubtitleTracks. */
    tracks: null,
    /** @type {any | null} Raw Chapters element. */
    chapters: null,
    /** @type {any | null} Raw Attachments element. */
    attachments: null,
    /** Set once the walk reaches the first cluster: the header prefix is over. */
    sawCluster: false,
    /** Absolute byte of the first cluster, for restarting streams without a cue index. */
    firstClusterAt: 0
  }
}

/**
 * Folds one decoded tag into the header. Call for every tag the decoder yields; returns
 * true while the walk should continue, false once the first cluster begins (everything
 * in front of it has been seen).
 *
 * @param {ReturnType<typeof createHeader>} header
 * @param {any} tag - A tag from EbmlIteratorDecoder (HEADER_TAGS buffered).
 * @returns {boolean}
 */
export function foldHeaderTag (header, tag) {
  switch (tag.id) {
    case EbmlTagId.Segment:
      if (tag.position === EbmlTagPosition.Start) header.segmentStart = tag.absoluteStart + tag.tagHeaderLength
      return true
    case EbmlTagId.SeekHead:
      readSeekHead(header, tag)
      return true
    case EbmlTagId.Info:
      header.timecodeScale = Number(data(tag, EbmlTagId.TimecodeScale) ?? 1_000_000) / 1_000_000
      header.durationMs = Number(data(tag, EbmlTagId.Duration) ?? 0) * header.timecodeScale
      return true
    case EbmlTagId.Tracks:
      header.tracks = tag
      return true
    case EbmlTagId.Chapters:
      header.chapters = tag
      return true
    case EbmlTagId.Attachments:
      header.attachments = tag
      return true
    case EbmlTagId.Cluster:
      if (tag.position === EbmlTagPosition.Start) {
        header.sawCluster = true
        header.firstClusterAt = tag.absoluteStart
        return false
      }
      return true
    default:
      return true
  }
}

/** The seek head's promises as absolute byte positions, keyed by tag name. */
function readSeekHead (header, seekHead) {
  for (const entry of seekHead.Children ?? []) {
    if (entry?.id !== EbmlTagId.Seek) continue
    const idBytes = data(entry, EbmlTagId.SeekID)
    const position = data(entry, EbmlTagId.SeekPosition)
    if (idBytes == null || position == null) continue
    const name = EbmlTagId[Tools.readUnsigned(idBytes)]
    if (name) header.positions[name] = header.segmentStart + Number(position)
  }
}

/** Which promised header elements the prefix walk did NOT deliver — the rare muxes that
 * park chapters or attachments behind the clusters. Each is worth one bounded read. */
export function missingHeaderTags (header) {
  const wanted = { Info: 'timecodeScale', Tracks: 'tracks', Chapters: 'chapters', Attachments: 'attachments' }
  const missing = []
  for (const [name, field] of Object.entries(wanted)) {
    if (header.positions[name] == null) continue
    const have = field === 'timecodeScale' ? header.durationMs > 0 : Boolean(header[field])
    if (!have && header.positions[name] >= (header.firstClusterAt || Infinity)) missing.push(name)
  }
  return missing
}

/**
 * A parsed Chapters element as the player's chapter list. Ported from the dependency,
 * with its default-edition and hidden-atom rules kept.
 * @param {any} chaptersTag
 * @param {number} timecodeScaleMs - Milliseconds per raw unit (chapter times are in ns).
 * @param {number} durationMs - Fallback end for the last chapter.
 * @returns {{ start: number, end: number, text?: string, language?: string }[]}
 */
export function parseChapters (chaptersTag, timecodeScaleMs = 1, durationMs = 0) {
  const editions = (chaptersTag?.Children ?? []).filter(entry => entry?.id === EbmlTagId.EditionEntry)
  if (!editions.length) return []
  // https://www.matroska.org/technical/chapters.html#default-edition
  const defaultEdition = editions.find(edition => edition.Children?.some(entry => entry?.id === EbmlTagId.EditionFlagDefault && Boolean(entry.data))) || editions[0]
  const atoms = (defaultEdition.Children ?? []).filter(entry => entry?.id === EbmlTagId.ChapterAtom && !data(entry, EbmlTagId.ChapterFlagHidden))
  const chapters = []
  for (let i = atoms.length - 1; i >= 0; --i) {
    const start = Number(data(atoms[i], EbmlTagId.ChapterTimeStart) ?? 0) / timecodeScaleMs / 1_000_000
    const end = (Number(data(atoms[i], EbmlTagId.ChapterTimeEnd) ?? 0) / timecodeScaleMs / 1_000_000) || chapters[i + 1]?.start || durationMs || 0
    const display = child(atoms[i], EbmlTagId.ChapterDisplay)
    chapters[i] = {
      start,
      end,
      text: data(display, EbmlTagId.ChapString)?.toString(),
      language: data(display, EbmlTagId.ChapLanguage)?.toString()
    }
  }
  return chapters
}

/**
 * The attached files of an Attachments element.
 * @param {any} attachmentsTag
 * @returns {{ filename: string, mimetype: string, data: Uint8Array }[]}
 */
export function parseAttachments (attachmentsTag) {
  return (attachmentsTag?.Children ?? [])
    .filter(entry => entry?.id === EbmlTagId.AttachedFile)
    .map(entry => ({
      filename: data(entry, EbmlTagId.FileName)?.toString(),
      mimetype: data(entry, EbmlTagId.FileMimeType)?.toString(),
      data: data(entry, EbmlTagId.FileData)
    }))
    .filter(attachment => attachment.data)
}
