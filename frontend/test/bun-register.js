// Test-harness preload for `bun test`: maps the '@/' alias onto common/ and
// stubs UI-only dependencies so app modules import under the test runtime.
import { plugin } from 'bun'
import { join } from 'node:path'

const repo = join(import.meta.dir, '..')

// cache.js persists through Web Storage, which the test runtime lacks
if (!globalThis.localStorage) {
  const store = new Map()
  globalThis.localStorage = {
    getItem: key => (store.has(key) ? store.get(key) : null),
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: key => store.delete(key),
    clear: () => store.clear(),
    key: index => [...store.keys()][index] ?? null,
    get length () { return store.size }
  }
}

// Aliased app modules that cannot load outside the browser (localStorage, window, a WASM
// renderer). Checked before alias mapping, so the key is the specifier as the app writes it.
// Each stub is the smallest surface its importers actually touch; tests import the same
// specifier to read state back (e.g. JASSUB.instances) or steer it (settings.value).
const appStubs = {
  '@/modules/settings.js': `
    import { writable } from 'simple-store-svelte'
    export const settings = writable({
      debridService: '',
      debridApiKeys: {},
      debridMode: 'prefer',
      debridCacheCheck: true,
      font: null,
      subtitleLanguage: 'eng',
      subtitleRenderHeight: '0',
      missingFont: false,
      disableSubtitleBlur: false,
      playerSeek: 5
    })
    export const alToken = null
    export const malToken = null
  `,
  '@/modules/lib/clipboard.js': `
    export function copyToClipboard () {}
    export default new EventTarget()
  `,
  '@/modules/bridge.js': `
    const noop = () => {}
    const handler = { get: (target, key) => key in target ? target[key] : noop }
    export const TORRENT = new Proxy({}, handler)
    export const COMMON = new Proxy({}, handler)
    export const ANDROID = new Proxy({}, handler)
    export const DESKTOP = new Proxy({}, handler)
    // the debrid core, as the host injects it. Mutable so a test can answer for it:
    // the shape here is the contract crates/debrid serves over IPC
    export const DEBRID = {
      services: [
        { id: 'torbox', title: 'TorBox', check_adds_magnets: false, max_files: 12 },
        { id: 'realdebrid', title: 'Real-Debrid', check_adds_magnets: true, max_files: 60 }
      ],
      validate: async () => ({ username: 'tester' }),
      listAvailability: async () => ({ answers: {}, names: {} }),
      checkAvailability: async () => ({ answers: {}, names: {}, busy: false }),
      unknownHashes: async (service, apiKey, hashes) => hashes,
      remember: async () => {},
      resolve: async () => ({ hash: '', name: '', files: [] }),
      onAvailability: (callback) => { DEBRID.publishAvailability = callback }
    }
  `,
  '@/components/MediaHandler.svelte': `
    import { writable } from 'simple-store-svelte'
    export const files = writable([])
    export default {}
  `,
  '@/modules/networking.js': `
    import { writable } from 'simple-store-svelte'
    export const status = writable('online')
  `
}

const stubs = {
  'simple-store-svelte': 'export const writable = value => { let v = value; const subs = new Set(); const store = { get value () { return v }, set value (n) { v = n; subs.forEach(fn => fn(v)) }, set (n) { store.value = n }, update (fn) { store.value = fn(v) }, subscribe (fn) { subs.add(fn); fn(v); return () => subs.delete(fn) } }; return store }',
  'svelte/easing': 'export const cubicOut = t => t\nexport const cubicIn = t => t',
  'js-levenshtein': 'export default () => 0',
  'svelte-sonner': `
    const record = (type) => (title, options) => { toast.shown.push({ type, title, ...options }) }
    export const toast = Object.assign(record('info'), {
      shown: [],
      error: record('error'),
      warning: record('warning'),
      success: record('success')
    })
  `,
  'fuse.js': 'export default class Fuse { search () { return [] } }',
  jassub: `
    export default class JASSUB {
      static instances = []
      static _hasBitmapBug = false
      constructor (options) {
        this.options = options
        this.fonts = []
        this.events = []
        this.track = null
        this.defaultFont = null
        this.destroyed = false
        JASSUB.instances.push(this)
      }
      addFont (font) { this.fonts.push(font) }
      createEvent (event) { this.events.push(event) }
      setTrack (header) { this.track = header }
      setDefaultFont (font) { this.defaultFont = font }
      _timeupdate () {}
      resize () {}
      destroy () { this.destroyed = true }
    }
  `
}

// anitomyscript's emscripten glue builds its .wasm path from import.meta.url and
// hands that "file:" string to fs.readFileSync; force a locateFile naming the
// on-disk path instead.
const anitomyGlueRx = /anitomyscript[\\/]dist[\\/]anitomyscript\.js$/

// the '@/' alias itself resolves through jsconfig.json "paths", which bun reads
const appStubFiles = Object.fromEntries(
  Object.entries(appStubs).map(([specifier, contents]) => [join(repo, 'common', specifier.slice(2)), contents])
)
const appStubRx = /common[\\/](modules[\\/](settings\.js|bridge\.js|networking\.js|lib[\\/]clipboard\.js)|components[\\/]MediaHandler\.svelte)$/

plugin({
  name: 'shiru-test-harness',
  setup (build) {
    for (const [specifier, contents] of Object.entries(stubs)) {
      build.module(specifier, () => ({ contents, loader: 'js' }))
    }
    build.onLoad({ filter: appStubRx }, args => ({
      contents: appStubFiles[args.path],
      loader: 'js'
    }))
    build.onLoad({ filter: anitomyGlueRx }, async args => {
      const source = await Bun.file(args.path).text()
      const dir = args.path.slice(0, args.path.lastIndexOf('/') + 1)
      return {
        contents: source.replace(
          'export default anitomyscript;',
          `export default (mod = {}) => anitomyscript({ locateFile: file => ${JSON.stringify(dir)} + file, ...mod });`
        ),
        loader: 'js'
      }
    })
  }
})
