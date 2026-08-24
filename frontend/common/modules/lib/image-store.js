// The bytes of every image the app has shown, pinned in the renderer's own memory.
//
// The previous attempt held detached <img> elements ("warm holds") on the theory that a
// live client keeps WebKitGTK's memory-resource cache from evicting the resource. The
// user's own testing disproved it: scrolling the home page up and down visibly unloaded
// and reloaded art the app had just shown. The engine's cache answers to its own
// pressure heuristics and owes this app nothing — and four hundred held elements pin
// DECODED frames, which is exactly the memory pressure that invites eviction (and puts
// the whole web process on the kernel's kill list).
//
// A blob: URL is different in kind: the encoded bytes live in a Blob this module owns,
// and the engine can no more evict them than it can evict any other JS object. An <img>
// pointed at a blob: URL re-decodes from memory in microseconds — no scheme-handler
// round trip, no disk read, no visible reload. Bytes, not decoded frames, so the budget
// below buys thousands of covers rather than hundreds.

/** The most encoded image data held at once. Covers run 40-120KB, banners a few
 * hundred; this is roughly two to three thousand covers — several screens of every
 * page the user visits in a long session. */
export const IMAGE_STORE_BYTE_LIMIT = 160 * 1024 * 1024

/** A home rail deliberately asks for its art before the user flings it into view. Keep
 * that from turning into 150 simultaneous fetch/decode pipelines when the first three
 * rails mount together. Twelve keeps the network busy without monopolising WebKit's
 * main process with response and Blob bookkeeping. */
export const IMAGE_FETCH_CONCURRENCY = 12

/** @type {Map<string, { object: string, bytes: number }>} Insertion-ordered; eviction
 * drops the least recently touched. Keyed by the URL the image is fetched from. */
const held = new Map()

/** @type {Map<string, Promise<string>>} Fetches in flight, so two cards showing the
 * same art cost one request. */
const pending = new Map()

let totalBytes = 0
let activeFetches = 0
const fetchQueue = []

function acquireFetchSlot () {
  if (activeFetches < IMAGE_FETCH_CONCURRENCY) {
    activeFetches++
    return Promise.resolve()
  }
  // The active count is intentionally not incremented when this waiter wakes: release
  // hands its occupied slot straight to the next waiter. This avoids a new caller and a
  // waking caller both claiming the same newly freed slot.
  return new Promise(resolve => fetchQueue.push(resolve))
}

function releaseFetchSlot () {
  const next = fetchQueue.shift()
  if (next) next()
  else activeFetches--
}

async function inFetchSlot (work) {
  await acquireFetchSlot()
  try {
    return await work()
  } finally {
    releaseFetchSlot()
  }
}

/** Whether a URL's bytes are pinnable at all: real requests, not inline data. */
function pinnable (url) {
  return typeof url === 'string' && !!url && !url.startsWith('data:') && !url.startsWith('blob:')
}

/**
 * The held object URL for `url` if its bytes are pinned, refreshed under eviction.
 * @param {string} [url]
 * @returns {string | null}
 */
export function heldNow (url) {
  const entry = held.get(url)
  if (!entry) return null
  held.delete(url)
  held.set(url, entry) // re-inserting keeps it fresh under eviction
  return entry.object
}

/** Whether showing this URL right now costs nothing — its bytes are already pinned. */
export function isHeld (url) {
  return held.has(url)
}

/**
 * Pins a URL's bytes and answers with an object URL, or answers with the URL itself
 * when pinning is impossible — a failed fetch, an opaque response, a data: URI. The
 * caller always gets something an <img> can load; pinning is an upgrade, not a gate.
 * @param {string} url
 * @param {{ fetcher?: typeof fetch, createObjectURL?: (blob: Blob) => string, revokeObjectURL?: (url: string) => void }} [options] - Test seams.
 * @returns {Promise<string>}
 */
export async function pin (url, { fetcher = globalThis.fetch?.bind(globalThis), createObjectURL = globalThis.URL?.createObjectURL?.bind(globalThis.URL), revokeObjectURL = globalThis.URL?.revokeObjectURL?.bind(globalThis.URL) } = {}) {
  if (!pinnable(url) || !fetcher || !createObjectURL) return url
  const already = heldNow(url)
  if (already) return already
  if (pending.has(url)) return pending.get(url)
  const claim = (async () => {
    try {
      return await inFetchSlot(async () => {
        const response = await fetcher(url)
        if (!response?.ok || typeof response.blob !== 'function') return url
        const blob = await response.blob()
        if (!blob?.size || blob.size > IMAGE_STORE_BYTE_LIMIT) return url
        // a racer may have pinned it while the bytes were in flight
        const raced = heldNow(url)
        if (raced) return raced
        while (totalBytes + blob.size > IMAGE_STORE_BYTE_LIMIT && held.size) {
          const [oldest, entry] = held.entries().next().value
          held.delete(oldest)
          totalBytes -= entry.bytes
          revokeObjectURL?.(entry.object)
        }
        const object = createObjectURL(blob)
        held.set(url, { object, bytes: blob.size })
        totalBytes += blob.size
        return object
      })
    } catch {
      return url // the <img> can still try the URL itself
    } finally {
      pending.delete(url)
    }
  })()
  pending.set(url, claim)
  return claim
}

/** How much is pinned, for the diagnostics panel and the tests. */
export function heldStats () {
  return { entries: held.size, bytes: totalBytes }
}

/** Test seam: everything let go, object URLs revoked. */
export function releaseAll (revokeObjectURL = globalThis.URL?.revokeObjectURL?.bind(globalThis.URL)) {
  for (const entry of held.values()) revokeObjectURL?.(entry.object)
  held.clear()
  pending.clear()
  totalBytes = 0
}
