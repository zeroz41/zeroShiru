// A bound on work that may never finish.
//
// Extensions are third-party code talking to third-party hosts from inside a worker. A
// host that accepts a connection and then says nothing — which is a normal thing for a
// tracker site to do — leaves that query pending forever, and everything waiting on the
// full set of sources waits forever with it: the results list never counts as complete,
// the spinner never stops, autoplay never fires, and the debrid badges are never asked
// for at all.
//
// The bound is deliberately generous. Bad connections are a feature requirement here, and
// a source that answers in forty seconds on a hotel wifi is a source worth having; what is
// not acceptable is one that answers never.

/** How long a single source has to answer before the rest of the app stops waiting on it. */
export const SOURCE_DEADLINE = 45_000

/**
 * The value of `work`, or `late()` if it takes longer than `ms`. The work is not cancelled —
 * nothing here can cancel a fetch inside a worker — it is merely no longer waited on, and a
 * late answer is dropped rather than arriving after the app has moved on.
 *
 * @template T
 * @param {Promise<T>} work
 * @param {Object} options
 * @param {number} [options.ms]
 * @param {() => T} options.late - What to return when the deadline passes.
 * @param {(callback: () => void, delay: number) => any} [options.schedule] - Defaults to setTimeout.
 * @param {(timer: any) => void} [options.cancel] - Defaults to clearTimeout.
 * @returns {Promise<T>}
 */
export function withDeadline (work, { ms = SOURCE_DEADLINE, late, schedule = setTimeout, cancel = clearTimeout }) {
  return new Promise((resolve, reject) => {
    let settled = false
    const timer = schedule(() => {
      if (settled) return
      settled = true
      resolve(late())
    }, ms)
    timer?.unref?.()

    const finish = (settle, value) => {
      if (settled) return
      settled = true
      cancel(timer)
      settle(value)
    }
    work.then(value => finish(resolve, value), error => finish(reject, error))
  })
}
