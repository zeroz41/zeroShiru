// Resolution hooks so plain Node can import modules webpack normally resolves: maps the
// '@/' and '@client/' aliases, and shims UI-only dependencies.
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const repo = join(dirname(fileURLToPath(import.meta.url)), '..')
const aliases = {
  '@/': pathToFileURL(join(repo, 'common') + '/').href,
  '@client/': pathToFileURL(join(repo, 'client') + '/').href
}

// Aliased app modules that cannot load outside the browser (localStorage, window, a WASM
// renderer). Checked before alias mapping, so the key is the specifier as the app writes it.
// Each stub is the smallest surface its importers actually touch; tests import the same
// specifier to read state back (e.g. JASSUB.instances) or steer it (settings.value).
const appStubs = {
  '@/modules/settings.js': `
    import { writable } from 'simple-store-svelte'
    export const settings = writable({
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
    export const ELECTRON = new Proxy({}, handler)
  `
}

const stubs = {
  'simple-store-svelte': 'export const writable = value => { let v = value; const subs = new Set(); const store = { get value () { return v }, set value (n) { v = n; subs.forEach(fn => fn(v)) }, set (n) { store.value = n }, update (fn) { store.value = fn(v) }, subscribe (fn) { subs.add(fn); fn(v); return () => subs.delete(fn) } }; return store }',
  'svelte/easing': 'export const cubicOut = t => t\nexport const cubicIn = t => t',
  'js-levenshtein': 'export default () => 0',
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

export async function resolve (specifier, context, nextResolve) {
  if (specifier in appStubs) return { url: `stub:${specifier}`, shortCircuit: true, format: 'module' }
  for (const [alias, base] of Object.entries(aliases)) {
    if (specifier.startsWith(alias)) return nextResolve(new URL(specifier.slice(alias.length), base).href, context)
  }
  if (specifier in stubs) return { url: `stub:${specifier}`, shortCircuit: true, format: 'module' }
  try {
    return await nextResolve(specifier, context)
  } catch (error) {
    // webpack imports a package subdirectory happily, node refuses
    if (error.code === 'ERR_UNSUPPORTED_DIR_IMPORT') return nextResolve(specifier.replace(/\/?$/, '/index.js'), context)
    throw error
  }
}

// anitomyscript's emscripten glue was built for CommonJS: under Node it reaches for __dirname
// and require() to find its .wasm, neither of which exists in an ES module. Webpack papers over
// this at bundle time; here the glue is served with a prelude defining both, so its own path
// resolution finds the wasm on disk.
const anitomyGlueRx = /\/anitomyscript\/dist\/anitomyscript\.js$/
const cjsPrelude = `
import { createRequire as __createRequire } from 'node:module'
import { fileURLToPath as __fileURLToPath } from 'node:url'
const require = __createRequire(import.meta.url)
const __dirname = __fileURLToPath(new URL('.', import.meta.url))
`

export async function load (url, context, nextLoad) {
  if (url.startsWith('stub:')) {
    const specifier = url.slice(5)
    return { format: 'module', source: appStubs[specifier] ?? stubs[specifier], shortCircuit: true }
  }
  if (anitomyGlueRx.test(new URL(url).pathname)) {
    const loaded = await nextLoad(url, context)
    // without a locateFile the glue builds the wasm path from import.meta.url, and then feeds
    // that "file:" URL string to fs.readFileSync, so one naming the on-disk path is forced in
    const source = String(loaded.source).replace(
      'export default anitomyscript;',
      'export default (mod = {}) => anitomyscript({ locateFile: file => __dirname + file, ...mod });'
    )
    return { ...loaded, source: cjsPrelude + source }
  }
  return nextLoad(url, context)
}
