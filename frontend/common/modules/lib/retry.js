// When to stop asking.
//
// Three request limiters — AniList, api.ani.zip and Jikan — answered a rate limit by
// waiting the requested time and trying again, with no count of how many times they had
// already done it. A source that stays rate limited is then asked forever, and anything
// waiting on that answer waits forever with it: an episode list that never fills in, or
// a play that never starts, with nothing on screen to say why.
//
// Giving up quickly would be its own bug — these are patient waits on someone else's
// clock, and a slow link or a busy API is not a failure. So the budget is generous in
// time and finite in attempts: keep the waiting, bound the asking. What a caller does
// once the promise finally rejects (fall back to what is cached, usually) is its own
// decision, and it can only make it if the promise actually settles.

/** How many extra attempts a request that was rate limited gets. */
export const RATE_LIMIT_RETRIES = 3

/** How many a request that failed for some other reason gets. */
export const ERROR_RETRIES = 1

/**
 * Whether a failed request is worth trying again.
 *
 * @param {object} attempt
 * @param {number} [attempt.retryCount] How many times it has already been retried.
 * @param {boolean} [attempt.limited] The service asked us to slow down, rather than failing.
 * @returns {boolean}
 */
export function retryWorthwhile ({ retryCount = 0, limited = false } = {}) {
  const budget = limited ? RATE_LIMIT_RETRIES : ERROR_RETRIES
  return Number(retryCount) < budget
}
