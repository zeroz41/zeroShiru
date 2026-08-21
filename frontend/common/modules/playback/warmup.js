// The head start a resolved stream gets while the app is still deciding to play it.
//
// Between a debrid resolve answering and the <video> element asking for its first
// byte, the app parses filenames, matches episodes, and sometimes asks AniList who
// the file even is — hundreds of milliseconds in which the stream's host is a
// stranger: no DNS answer, no TCP connection, no TLS session, and a CDN that has
// not looked up the file yet. All of that is sequential with playback unless it is
// started here, the moment the links exist.
//
// A HEAD in no-cors mode is the whole trick: same connection pool as the media
// loader, no body to pay for, no CORS preflight, and an opaque answer is fine
// because the answer is not the point — the connection is. A host that rejects
// HEAD has still done the handshakes by the time it says no.

/** How many resolved files are worth greeting. The played file is first in a debrid
 * resolve; neighbors are only worth it when the first one costs nothing extra. */
export const WARM_LIMIT = 1

/**
 * The URLs out of a resolved file list that are worth warming: HTTP(S), deduplicated,
 * played file first, at most `limit`. Pure, so the choice is testable without a network.
 * @param {{ url?: string }[]} [files]
 * @param {number} [limit]
 * @returns {string[]}
 */
export function warmable (files, limit = WARM_LIMIT) {
  const urls = (files || []).map(file => file?.url).filter(url => typeof url === 'string' && /^https?:/i.test(url))
  return [...new Set(urls)].slice(0, Math.max(0, limit))
}

/**
 * Opens the connections playback is about to need. Fire and forget: a warm-up that
 * fails has cost nothing, and one that works has moved the handshakes off the
 * critical path.
 * @param {{ url?: string }[]} [files] - Resolved player files, played file first.
 * @param {Object} [options]
 * @param {typeof fetch} [options.fetcher] - Defaults to the global fetch.
 * @param {number} [options.limit]
 * @returns {string[]} What was warmed, so callers can log it.
 */
export function warmStream (files, { fetcher = globalThis.fetch?.bind(globalThis), limit = WARM_LIMIT } = {}) {
  const targets = warmable(files, limit)
  if (!fetcher) return []
  for (const url of targets) {
    try {
      const answered = fetcher(url, { method: 'HEAD', mode: 'no-cors', cache: 'no-store' })
      if (answered && typeof answered.catch === 'function') answered.catch(() => {})
    } catch {}
  }
  return targets
}
