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

/** @type {Set<string>} Insertion-ordered, so eviction drops the longest-ago image. */
const shown = new Set()

/**
 * Records that an image finished loading on screen.
 * @param {string} [url] - The src that loaded; data: placeholders are nobody's memory.
 */
export function rememberShown (url) {
  if (!url || typeof url !== 'string' || url.startsWith('data:')) return
  if (shown.has(url)) shown.delete(url) // re-adding keeps it fresh under eviction
  if (shown.size >= IMAGE_MEMORY_LIMIT) shown.delete(shown.values().next().value)
  shown.add(url)
}

/**
 * Whether an image has already been on screen this session — meaning showing it again
 * immediately is free, and lazy-gating it would only add a placeholder flash.
 * @param {string} [url]
 */
export function wasShown (url) {
  return typeof url === 'string' && shown.has(url)
}

/** Test seam: a session's memory, forgotten. */
export function forgetShown () {
  shown.clear()
}
