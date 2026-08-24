import JASSUB from 'jassub'
import { assetUrl } from '@/modules/lib/asset.js'
import { hex2arr, bin2hex } from 'uint8-util'
import { toTS, subRx, videoRx } from '@/modules/util.js'
import { settings } from '@/modules/settings.js'
import { chooseSubtitleTrack, CHOICE } from '@/modules/playback/subtitle-select.js'
import clipboard from '@/modules/lib/clipboard.js'
import { SUPPORTS } from '@/modules/support.js'

/** Types whose container header and cue fields are already ASS-shaped. */
const ASS_TYPES = new Set(['ass', 'ssa'])

/** Built per call, not at module load: the font setting is read when a track actually
 * needs a header, not whenever this file happened to be imported. */
const defaultHeader = () => `[Script Info]
Title: English (US)
ScriptType: v4.00+
WrapStyle: 0
PlayResX: 1280
PlayResY: 720
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default, ${settings.value.font?.name?.toLowerCase() || 'Roboto Medium'},52,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2.6,0,2,20,20,46,1
[Events]

`
const stylesRx = /^Style:[^,]*/gm

/**
 * Track state and the libass renderer: everything between a cue event arriving from a
 * parser and text appearing over the video. Selection flows through exactly one door
 * (selectCaptions); which track deserves selecting is a pure function in
 * modules/playback/subtitle-select.js, fed the remembered choice by the player — the
 * old design had the player re-selecting from inside this class's change callback,
 * which is the recursion that once overflowed the stack and killed the stream.
 */
export default class Subtitles {
  /**
   * @param {HTMLVideoElement | null} video
   * @param {any[]} files - Every file of the release, for finding external subtitles.
   * @param {any} selected - The playing file.
   * @param {() => void} onHeader - Announces any change to tracks or selection. Never
   *   select a track from inside it; pass the choice through `getRemembered` instead.
   * @param {{ getRemembered?: () => any }} [opts] - The persisted choice for this show:
   *   'OFF', { language, name }, or a legacy label string.
   */
  constructor (video, files, selected, onHeader, { getRemembered } = {}) {
    this.video = video
    this.selected = selected || null
    this.files = files || []
    this.getRemembered = getRemembered
    /** Sparse, indexed by track number; the shape the player's picker renders. */
    this.headers = []
    /** Cue events per track, kept so switching tracks replays instantly. */
    this.tracks = []
    /** @type {Set<string>[]} Compact cue keys per track — overlapping parses after a
     * seek redeliver cues, and the renderer must see each exactly once. */
    this._seen = []
    this._stylesMap = []
    // absolute: the renderer fetches these from inside its worker, which sits under
    // assets/ and resolves a relative path against itself. See modules/lib/asset.js
    this.fonts = [assetUrl('/Roboto.ttf'), assetUrl('/NotoSansCJK.otf')]
    this.renderer = null
    /** -1 is subtitles off; anything else is a registered track number. */
    this.current = -1
    /** How strongly the current selection was chosen (a CHOICE rank, or Infinity for a
     * user's manual pick) — a later-arriving track only takes over by outranking it. */
    this.chosenScore = CHOICE.none
    this.onHeader = onHeader
    this.videoFiles = files.filter(file => videoRx.test(file.name))
    this.subtitleFiles = []

    this.handleFile = (detail) => {
      if (!this.selected) return
      const uint8 = hex2arr(bin2hex(detail))
      if (!uint8.length) return console.warn('Discarded an empty font, subtitles may render with a fallback typeface.')
      this.fonts.push(uint8)
      this.renderer?.addFont(uint8)
    }
    this.handleSubtitle = ({ subtitle, trackNumber }) => {
      if (!this.selected || !this._seen[trackNumber]) return
      const key = `${subtitle.time}|${subtitle.duration}|${subtitle.style ?? ''}|${subtitle.layer ?? ''}|${subtitle.text}`
      if (this._seen[trackNumber].has(key)) return
      this._seen[trackNumber].add(key)
      const event = this.constructSub(subtitle, !ASS_TYPES.has(this.headers[trackNumber].type), this.tracks[trackNumber].length, trackNumber)
      this.tracks[trackNumber].push(event)
      if (this.current === trackNumber) this.renderer?.createEvent(event)
    }
    this.handleTracks = (detail) => {
      if (!this.selected) return
      let changed = false
      for (const track of detail ?? []) {
        if (this.headers[track.number]) continue
        this.#registerTrack(track)
        changed = true
      }
      if (!changed) return
      this.initSubtitleRenderer()
      this.onHeader()
      this.#autoSelect()
    }
    this.handleSubtitleFile = (detail) => {
      this.addSingleSubtitleFile(new File([detail.data], detail.name))
    }
    this.handleClipboardText = ({ detail }) => {
      for (const { text, type } of detail) {
        if (text.startsWith('[Script Info]')) this.addSingleSubtitleFile(new File([text], 'Subtitle', { type }))
      }
    }
    this.handleClipboardFiles = ({ detail }) => {
      for (const file of detail) {
        if (subRx.test(file.name)) this.addSingleSubtitleFile(file)
      }
    }
    clipboard.addEventListener('text', this.handleClipboardText)
    clipboard.addEventListener('files', this.handleClipboardFiles)
  }

  /** A track becomes selectable: header registered, style names mapped to indices.
   * External files arrive with a fully built header (their dialogue is IN it); embedded
   * tracks only keep their container header when it is ASS-shaped — a CodecPrivate for
   * SRT or WebVTT is junk here and a synthesized ASS header stands in. */
  #registerTrack (track) {
    const header = track.external || (ASS_TYPES.has(track.type) && track.header) ? track.header : defaultHeader()
    this.headers[track.number] = { ...track, header }
    this.tracks[track.number] = []
    this._seen[track.number] = new Set()
    this._stylesMap[track.number] = { Default: 0 }
    const styleMatches = header.match(stylesRx) ?? []
    for (let i = 0; i < styleMatches.length; ++i) {
      const style = styleMatches[i].replace('Style:', '').trim()
      this._stylesMap[track.number][style] = i + 1
    }
  }

  /** Applies the chooser — remembered choice first, then the settings language — but
   * never over a manual pick, and never sideways: only a strictly better match wins. */
  #autoSelect () {
    const available = this.headers?.filter(Boolean)
    if (!available?.length) return
    const choice = chooseSubtitleTrack(available, {
      remembered: this.getRemembered?.(),
      language: settings.value.subtitleLanguage
    })
    if (!choice || choice.score <= this.chosenScore) return
    if (choice.number === this.current) {
      this.chosenScore = choice.score
      return
    }
    this.chosenScore = choice.score
    this.selectCaptions(choice.number)
  }

  async addSingleSubtitleFile (file) {
    // external tracks number from 100, far above any real Matroska track number
    const index = 100 + this.headers.filter(header => header?.external).length
    this.subtitleFiles[index] = file
    const type = file.name.substring(file.name.lastIndexOf('.') + 1).toLowerCase()
    const subname = file.name.slice(0, file.name.lastIndexOf('.'))
    // the file name usually carries the video name (with or without extension) plus a language
    const name = subname.includes(this.selected.name)
      ? subname.replace(this.selected.name, '')
      : subname.replace(this.selected.name.slice(0, this.selected.name.lastIndexOf('.')), '')
    const subtitles = Subtitles.convertSubText(await file.text(), type)
    if (!subtitles) return console.debug(`Failed to load the file ${file.name} as it is not a subtitle file.`)
    const header = type === 'ass' ? subtitles : defaultHeader() + subtitles.join('\n')
    this.#registerTrack({
      number: index,
      language: name.replace(/[,._-]/g, ' ').trim() || 'Track ' + index,
      type,
      header,
      external: true
    })
    this.initSubtitleRenderer()
    this.onHeader()
    this.#autoSelect()
    // a user who keeps auto-selection off still dropped this file here on purpose
    if (this.current === -1 && this.chosenScore === CHOICE.none) {
      this.chosenScore = CHOICE.fallback
      this.selectCaptions(index)
    }
  }

  initSubtitleRenderer () {
    if (this.renderer) return
    const options = {
      video: this.video,
      subContent: defaultHeader(),
      fonts: this.fonts,
      offscreenRender: SUPPORTS.offscreenRender,
      libassMemoryLimit: 1024,
      libassGlyphLimit: 80000,
      maxRenderHeight: parseInt(settings.value.subtitleRenderHeight) || 0,
      fallbackFont: settings.value.font?.name || 'roboto medium',
      availableFonts: {
        'roboto medium': assetUrl('/Roboto.ttf'),
        'noto sans cjk regular': assetUrl('/NotoSansCJK.otf')
      },
      workerUrl: new URL('jassub/dist/jassub-worker.js', import.meta.url).toString(),
      wasmUrl: new URL('jassub/dist/jassub-worker.wasm', import.meta.url).toString(),
      legacyWasmUrl: new URL('jassub/dist/jassub-worker.wasm.js', import.meta.url).toString(),
      modernWasmUrl: new URL('jassub/dist/jassub-worker-modern.wasm', import.meta.url).toString(),
      useLocalFonts: settings.value.missingFont,
      dropAllBlur: settings.value.disableSubtitleBlur,
      // Drive rendering from the media events rather than from a video frame callback.
      // On-demand rendering registers a requestVideoFrameCallback and nothing else — no
      // seeking, waiting or playing listener — and re-arms itself only from inside its
      // own callback. A flush seek in the system webview can drop the pending callback,
      // and then nothing on either side re-arms it: subtitles freeze on the frame the
      // seek left and never come back. It also messages the worker once per video frame,
      // which is a cost this webview can ill afford for text that changes every few
      // seconds. The event path re-syncs on every seek by construction
      onDemandRender: false
    }
    if (SUPPORTS.isAndroid) JASSUB._hasBitmapBug = true
    this.renderer = new JASSUB(options)
    this.renderer?.setDefaultFont('noto sans cjk regular')
  }

  static convertSubText (text, type) {
    const srtRx = /(?:\d+\r?\n)?(\S{9,12})\s?-->\s?(\S{9,12})(.*)\r?\n([\s\S]*)$/i
    const srt = text => {
      const subtitles = []
      const replaced = text.replace(/\r/g, '')
      for (const split of replaced.split(/\r?\n\r?\n/)) {
        const match = split.match(srtRx)
        if (match) {
          // timestamps: strip to centiseconds, then to ASS's H:MM:SS.cc shape
          match[1] = match[1].match(/.*[.,]\d{2}/)[0]
          match[2] = match[2].match(/.*[.,]\d{2}/)[0]
          if (match[1].length === 9) match[1] = '0:' + match[1]
          else if (match[1][0] === '0') match[1] = match[1].substring(1)
          if (match[2].length === 9) match[2] = '0:' + match[2]
          else if (match[2][0] === '0') match[2] = match[2].substring(1)
          const matches = match[4].match(/<[^>]+>/g)
          if (matches) {
            matches.forEach(matched => {
              if (/<\//.test(matched)) { // a closing tag
                match[4] = match[4].replace(matched, matched.replace('</', '{\\').replace('>', '0}'))
              } else {
                match[4] = match[4].replace(matched, matched.replace('<', '{\\').replace('>', '1}'))
              }
            })
          }
          subtitles.push('Dialogue: 0,' + match[1].replace(',', '.') + ',' + match[2].replace(',', '.') + ',Default,,0,0,0,,' + match[4].replace(/\r?\n/g, '\\N'))
        }
      }
      return subtitles
    }
    const microRx = /[{[](\d+)[}\]][{[](\d+)[}\]](.+)/i
    const sub = text => {
      const subtitles = []
      const replaced = text.replace(/\r/g, '')
      let frames = 1000 / Number(replaced.match(microRx)[3])
      if (!frames || isNaN(frames)) frames = 41.708
      for (const split of replaced.split('\n')) {
        const match = split.match(microRx)
        if (match) subtitles.push('Dialogue: 0,' + toTS((match[1] * frames) / 1000, 1) + ',' + toTS((match[2] * frames) / 1000, 1) + ',Default,,0,0,0,,' + match[3].replace('|', '\\N'))
      }
      return subtitles
    }
    if (type === 'ass' || type === 'ssa') return text
    if (type === 'srt' || type === 'vtt') return srt(text)
    if (type === 'sub') return sub(text)
    // subbers have a tendency to not set the extensions properly
    if (srtRx.test(text)) return srt(text)
    if (microRx.test(text)) return sub(text)
  }

  constructSub (subtitle, isNotAss, subtitleIndex, trackNumber) {
    if (isNotAss === true) { // converts VTT or other to SSA
      const matches = subtitle.text.match(/<[^>]+>/g)
      if (matches) {
        matches.forEach(match => {
          if (/<\//.test(match)) { // a closing tag
            subtitle.text = subtitle.text.replace(match, match.replace('</', '{\\').replace('>', '0}'))
          } else {
            subtitle.text = subtitle.text.replace(match, match.replace('<', '{\\').replace('>', '1}'))
          }
        })
      }
      subtitle.text = subtitle.text.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, '\\h').replace(/\r?\n/g, '\\N')
    }
    return {
      Start: subtitle.time,
      Duration: subtitle.duration,
      Style: this._stylesMap[trackNumber][subtitle.style || 'Default'] || 0,
      Name: subtitle.name || '',
      MarginL: Number(subtitle.marginL) || 0,
      MarginR: Number(subtitle.marginR) || 0,
      MarginV: Number(subtitle.marginV) || 0,
      Effect: subtitle.effect || '',
      Text: subtitle.text || '',
      ReadOrder: 1,
      Layer: Number(subtitle.layer) || 0,
      _index: subtitleIndex
    }
  }

  /**
   * The one door selection goes through. -1 turns subtitles off.
   * @param {number} trackNumber
   * @param {{ manual?: boolean }} [opts] - A manual pick is the user's own and nothing
   *   automatic may override it for the rest of the file.
   */
  selectCaptions (trackNumber, { manual = false } = {}) {
    if (trackNumber == null || !this.headers) return
    this.current = Number(trackNumber)
    if (manual) this.chosenScore = Infinity
    if (this.current !== -1 && !this.headers[this.current]) return
    // the full header, ending in exactly one newline — a slice(0, -1) here used to chop
    // a real character off any container header that did not end with one
    const header = this.current === -1 ? defaultHeader() : this.headers[this.current].header.replace(/\s*$/, '\n')
    this.renderer?.setTrack(header)
    if (this.current !== -1 && this.renderer) {
      for (const event of this.tracks[this.current] ?? []) this.renderer.createEvent(event)
    }
    this.onHeader()
  }

  destroy () {
    clipboard.removeEventListener('text', this.handleClipboardText)
    clipboard.removeEventListener('files', this.handleClipboardFiles)
    this.renderer?.destroy()
    this.renderer = null
    this.files = null
    this.video = null
    this.selected = null
    this.tracks = null
    this.headers = null
    this._seen = null
    this.onHeader()
  }
}
