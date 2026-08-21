// Proof that a stream link actually serves bytes, before and after the player trusts it.
//
// The lesson this encodes: a debrid resolve can succeed in under a second and hand back a
// link whose CDN node never sends a single byte. "Cached" is a claim about the service's
// storage; it says nothing about the one host the link points at. And the link cannot be
// swapped for a fresh one — TorBox pins one URL per (torrent, file), so asking again
// returns the identical dead address (verified live: two requestdl calls, byte-identical
// answers, and redirect=true 307s to the same place). The only honest moves are to prove
// the link early, retry it in place, or give up fast and let the fallback machinery play
// something that works. Waiting is never one of them.
//
// A probe is a 2-byte range request: ~100ms against a healthy node, and it doubles as the
// warm-up (DNS, TLS, and the CDN locating the file all happen under it, on the connection
// pool playback is about to use).

/** How long one probe waits before calling the link dead. Generous against a slow CDN
 * round trip, but two probes and the pause between them must land well inside the stall
 * watchdog's 15s window, so a dead link is decided before the spinner machinery stirs. */
export const PROBE_TIMEOUT_MS = 6_000

/** The pause before a failed probe is tried once more. One flap is weather; two is a verdict. */
export const PROBE_RETRY_DELAY_MS = 1_500

/**
 * The file a resolve should be judged by: the one the service picked to play. Pack files
 * land on different CDN nodes (verified live: neighbor links on nexus-143 and nexus-145),
 * so probing an arbitrary file proves nothing about the one the user is about to watch.
 * @param {{ path?: string, url?: string }[]} [files]
 * @param {string | null} [targetPath] - The resolver's pick, when it said.
 * @returns {{ path?: string, url?: string } | null}
 */
export function probeTarget (files, targetPath) {
  if (!files?.length) return null
  return (targetPath && files.find(file => file.path === targetPath)) || files[0]
}

/**
 * The URL to re-open a stream under after `attempt` failed tries. The CDN accepts unknown
 * query parameters (verified live: 206 with one appended), and a changed URL is a changed
 * identity at every layer — connection pool, media pipeline, any middlebox — where
 * re-loading the same address has been observed to change nothing at all.
 * @param {string} url
 * @param {number} [attempt] - 0 leaves the URL alone.
 * @returns {string}
 */
export function bustedUrl (url, attempt = 0) {
  if (!url || !attempt) return url || ''
  return `${url}${url.includes('?') ? '&' : '?'}zsr=${attempt}`
}

/**
 * Asks the link for its first two bytes, bounded. Any 2xx is life; an error status is a
 * dead link with a name (an expired token 403s), and silence past the timeout is the
 * failure this whole module exists for.
 * @param {string} url
 * @param {{ fetcher?: typeof fetch, timeoutMs?: number }} [options]
 * @returns {Promise<{ alive: boolean, status?: number, reason?: string, elapsed: number }>}
 */
export async function probeStream (url, { fetcher = globalThis.fetch?.bind(globalThis), timeoutMs = PROBE_TIMEOUT_MS } = {}) {
  const started = Date.now()
  const elapsed = () => Date.now() - started
  if (!fetcher || !url) return { alive: false, reason: 'nothing to probe with', elapsed: 0 }
  const abort = new AbortController()
  const deadline = setTimeout(() => abort.abort(), timeoutMs)
  try {
    const response = await fetcher(url, {
      headers: { Range: 'bytes=0-1' },
      cache: 'no-store',
      signal: abort.signal
    })
    if (response.ok) return { alive: true, status: response.status, elapsed: elapsed() }
    return { alive: false, status: response.status, reason: `the stream host answered ${response.status}`, elapsed: elapsed() }
  } catch (error) {
    const timedOut = abort.signal.aborted
    return {
      alive: false,
      reason: timedOut ? `the stream host did not answer within ${Math.round(timeoutMs / 1_000)}s` : `the stream host was unreachable (${error?.message || error})`,
      elapsed: elapsed()
    }
  } finally {
    clearTimeout(deadline)
  }
}

/**
 * The full verdict on a link: one probe, and on failure one more after a short pause,
 * because a single flap is not worth abandoning a debrid stream over. Both misses make
 * it a dead link.
 * @param {string} url
 * @param {{ fetcher?: typeof fetch, timeoutMs?: number, retryDelayMs?: number, sleep?: (ms: number) => Promise<void> }} [options]
 * @returns {Promise<{ alive: boolean, status?: number, reason?: string, elapsed: number, attempts: number }>}
 */
export async function verifiedStream (url, { fetcher, timeoutMs, retryDelayMs = PROBE_RETRY_DELAY_MS, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)) } = {}) {
  const first = await probeStream(url, { fetcher, timeoutMs })
  if (first.alive) return { ...first, attempts: 1 }
  await sleep(retryDelayMs)
  const second = await probeStream(url, { fetcher, timeoutMs })
  return { ...second, attempts: 2 }
}
