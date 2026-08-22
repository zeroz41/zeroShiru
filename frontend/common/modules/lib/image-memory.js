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

/** How many shown images are remembered before the oldest are forgotten. At ~100 bytes a
 * URL this is under a megabyte, sized for a long browsing session, bounded so a marathon
 * one cannot grow it forever. */
export const IMAGE_MEMORY_LIMIT = 4000

/** How many of those are also HELD — see [keepWarm]. Encoded cover art runs 40-120KB, so
 * this is tens of megabytes at worst, for the art of the last few screens the user was on. */
export const IMAGE_WARM_LIMIT = 400

/** @type {Set<string>} Insertion-ordered, so eviction drops the longest-ago image. */
const shown = new Set()

/** @type {Map<string, HTMLImageElement>} The held decoders, same ordering, same eviction. */
const warm = new Map()

/**
 * Holds a reference to an image that has been shown, so the engine keeps its resource.
 *
 * Remembering that a URL was shown stops the placeholder flash, but it does not make the
 * second mount free: the covers come from the host over a custom URI scheme, which
 * WebKitGTK does not put in its HTTP cache, so every remount was another trip to the host
 * and another JPEG decode. That is the "images load in again even though I saw them twenty
 * seconds ago" complaint — the bytes were local, the work was not.
 *
 * A live image element, even one that is in no document, keeps its entry in the engine's
 * in-memory resource cache alive: it is a client of that resource, and clients are what
 * stop it being evicted. So one detached element per shown URL turns every later mount of
 * the same art into a memory-cache hit, with no request and usually no decode.
 *
 * @param {string} url
 */
function keepWarm (url) {
  if (typeof Image !== 'function') return // not a browser: tests, and the TV core's shims
  if (warm.has(url)) {
    const held = warm.get(url)
    warm.delete(url)
    warm.set(url, held) // re-inserting keeps it fresh under eviction, same as `shown`
    return
  }
  while (warm.size >= IMAGE_WARM_LIMIT) warm.delete(warm.keys().next().value)
  const keeper = new Image()
  keeper.decoding = 'async'
  keeper.src = url
  warm.set(url, keeper)
}

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
  keepWarm(key)
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
 * @param {any[]} [list]
 * @returns {string | null} Null when the list cannot be described — a candidate that is a
 *   function or a promise produces something new each time it is asked, and there starting
 *   over is the only answer that cannot be wrong.
 */
export function imageSignature (list) {
  const parts = []
  for (const image of list ?? []) {
    if (!image) { parts.push(''); continue }
    if (typeof image !== 'string') return null
    parts.push(image)
  }
  return parts.join('\u0000')
}

/** How many images are currently held warm. Test seam, and a number worth having in a
 * diagnostic: it is the only bounded memory this module owns. */
export function warmCount () {
  return warm.size
}

/** Test seam: a session's memory, forgotten. */
export function forgetShown () {
  shown.clear()
  warm.clear()
}
