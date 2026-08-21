// One in-flight attempt per key, for actions a user retries by mashing.
//
// A debrid resolve of a batch takes a few seconds, during which the player shows a
// spinner and the play button still works. Every extra click started a whole second
// resolve — the log showed the same episode resolved three times inside a minute,
// each round costing TorBox link requests and an AniList sweep over every file in
// the pack, which is how one impatient minute earned a rate-limit toast. The first
// click is the request; the rest are the same request, and this remembers that.

/**
 * @returns {{ begin: (key: string) => boolean, end: (key: string) => void }}
 *   begin: whether this attempt is the first — false means one is already running.
 *   end: the attempt for that key finished, however it went.
 */
export function createSingleFlight () {
  /** @type {Set<string>} */
  const inFlight = new Set()
  return {
    begin (key) {
      if (inFlight.has(key)) return false
      inFlight.add(key)
      return true
    },
    end (key) {
      inFlight.delete(key)
    }
  }
}
