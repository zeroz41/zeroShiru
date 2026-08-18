// Resolution hooks so plain Node can import modules webpack normally resolves: maps the
// '@/' and '@client/' aliases, and shims UI-only dependencies.
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const repo = join(dirname(fileURLToPath(import.meta.url)), '..')
const aliases = {
  '@/': pathToFileURL(join(repo, 'common') + '/').href,
  '@client/': pathToFileURL(join(repo, 'client') + '/').href
}

const stubs = {
  'simple-store-svelte': 'export const writable = value => { let v = value; const subs = new Set(); const store = { get value () { return v }, set value (n) { v = n; subs.forEach(fn => fn(v)) }, set (n) { store.value = n }, update (fn) { store.value = fn(v) }, subscribe (fn) { subs.add(fn); fn(v); return () => subs.delete(fn) } }; return store }',
  'svelte/easing': 'export const cubicOut = t => t\nexport const cubicIn = t => t',
  'js-levenshtein': 'export default () => 0',
  'fuse.js': 'export default class Fuse { search () { return [] } }'
}

export async function resolve (specifier, context, nextResolve) {
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

export async function load (url, context, nextLoad) {
  if (url.startsWith('stub:')) return { format: 'module', source: stubs[url.slice(5)], shortCircuit: true }
  return nextLoad(url, context)
}
