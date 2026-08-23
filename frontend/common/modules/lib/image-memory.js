// Which images this session has already put on screen.
//
// The pop-in the user kept seeing was not the network: covers are served from the host's
// disk cache. It was the rendering path — every page switch destroys every <img>, and each
// remount waited one frame behind a lazy-load gate before its real src went in, so a whole
// grid of art the app had ALREADY shown flashed placeholder-first, every time. The lazy
// gate earns its keep exactly once per image: the first time, when the bytes might genuinely
// be far away. An image that has already been shown is local and warm, and the gate is pure
// flash. So the gate asks this memory first.
//
// Session-scoped on purpose: surviving restarts is the disk cache's job; this only answers
// "would showing it immediately be free?", which restarting makes false again (the decoded
// image is gone, the first paint would block on a disk read).

// The holding of actual bytes moved to lib/image-store.js (blob URLs, byte-bounded):
// detached-<img> "warm holds" were disproven live — the engine evicted their resources
// under its own pressure heuristics anyway, while their decoded frames CAUSED pressure.
// This module keeps only the cheap part: which URLs have been on screen, so the lazy
// gate and the entrance fade are not re-played for art the user has already watched arrive.

/** How many shown images are remembered before the oldest are forgotten. At ~100 bytes a
 * URL this is under a megabyte, sized for a long browsing session, bounded so a marathon
 * one cannot grow it forever. */
export const IMAGE_MEMORY_LIMIT = 4000

/** @type {Set<string>} Insertion-ordered, so eviction drops the longest-ago image. */
const shown = new Set()

/**
 * The one identity an image URL has, whatever form a caller held it in. What loaded is
 * remembered from the element's absolute `currentSrc`, but the lazy gate asks with the
 * raw candidate string — and for local fallback art (`./no_image_cover.jpg`) those never
 * matched, so local placeholders re-played the gate and the fade on every remount.
 * @param {string} [url]
 * @returns {string | null}
 */
function identity (url) {
  if (!url || typeof url !== 'string' || url.startsWith('data:')) return null
  try {
    return new URL(url, typeof document !== 'undefined' ? document.baseURI : undefined).href
  } catch {
    return url // no base to resolve against: the raw string is the best identity there is
  }
}

/**
 * Records that an image finished loading on screen.
 * @param {string} [url] - The src that loaded; data: placeholders are nobody's memory.
 */
export function rememberShown (url) {
  const key = identity(url)
  if (!key) return
  if (shown.has(key)) shown.delete(key) // re-adding keeps it fresh under eviction
  if (shown.size >= IMAGE_MEMORY_LIMIT) shown.delete(shown.values().next().value)
  shown.add(key)
}

/**
 * Whether an image has already been on screen this session — meaning showing it again
 * immediately is free, and lazy-gating it would only add a placeholder flash.
 * @param {string} [url]
 */
export function wasShown (url) {
  const key = identity(url)
  return Boolean(key && shown.has(key))
}

/**
 * What a list of image candidates IS, rather than which array object carried it.
 *
 * Every call site builds its list inline — `images={[cover, medium, fallback]}` — so the
 * prop is a new array on every render of the parent, however little has changed. Treating
 * that as new art meant throwing away the resolved URL and starting the load again: a
 * placeholder flash for a picture that was already on screen and had not changed.
 *
 * A function or promise candidate is a fresh closure every render, so its own identity
 * says nothing; it contributes a constant marker instead, and the caller passes
 * `identity` (the media id, typically) so two different shows whose string candidates
 * happen to match — or that have none — can never share a signature. The heavy modals
 * all carry function candidates, and treating those lists as indescribable meant they
 * re-ran the whole load per parent render, which was the exact flash this exists to stop.
 *
 * @param {any[]} [list]
 * @param {string|number|null} [identity] - What the art is OF, when candidates are dynamic.
 * @returns {string}
 */
export function imageSignature (list, identity = null) {
  const parts = [String(identity ?? '')]
  for (const image of list ?? []) {
    if (!image) { parts.push(''); continue }
    parts.push(typeof image === 'string' ? image : '\u0001dynamic')
  }
  return parts.join('\u0000')
}

/** Test seam: a session's memory, forgotten. */
export function forgetShown () {
  shown.clear()
}
