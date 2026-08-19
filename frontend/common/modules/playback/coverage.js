// Whether a release can hold the episode being asked for, judged from its title alone. Pure and
// transport free: it runs over search results before anything knows or cares whether they will
// be played from a torrent, from debrid, or from a cache — every source's results go through it.
//
// Why it exists: a title that names several episodes parses to an array of numbers, and the app
// read any array as "this is a batch, so it has everything". `[F-R] One Piece 0487+0490` parses
// to ["0487", "0490"] exactly like `One Piece 0001-0782` does, so a two episode fix release was
// offered for every episode of the show, and picking any of them played 487.

/**
 * The episode numbers a parsed title claims, as an inclusive span. A single number is a span of
 * one; several become the range they enclose, which is how a batch names itself.
 * @param {string | string[] | undefined} episodeNumber - `parseObject.episode_number`.
 * @returns {{ first: number, last: number } | null} Null when the title names no episodes.
 */
export function releaseSpan (episodeNumber) {
  if (episodeNumber == null) return null
  const numbers = (Array.isArray(episodeNumber) ? episodeNumber : [episodeNumber]).map(Number).filter(Number.isFinite)
  if (!numbers.length) return null
  return { first: Math.min(...numbers), last: Math.max(...numbers) }
}

/**
 * Whether a release should still be offered for an episode. False only when its title proves it
 * cannot hold it; everything unproven stays listed, since a release wrongly hidden is worse than
 * one wrongly shown.
 *
 * Two things keep it honest. A title that names no episodes — a season pack, a complete series —
 * proves nothing and is always kept. And a title numbered past the end of the show is speaking a
 * different numbering than the request: an absolute numbered release of a split cour season, say.
 * When the caller could not supply the absolute number to compare against, that is unjudgeable
 * rather than wrong, so it is kept too.
 * @param {{ episode_number?: string | string[] }} [parseObject] - Anitomy's parse of the release title.
 * @param {Object} request
 * @param {number} [request.episode] - The episode asked for, in the media's own numbering.
 * @param {number} [request.absoluteEpisode] - The same episode counted from the start of the series, when known.
 * @param {number} [request.episodeCount] - How many episodes the media has.
 * @returns {boolean}
 */
export function releaseHoldsEpisode (parseObject, { episode, absoluteEpisode, episodeCount } = {}) {
  const wanted = [episode, absoluteEpisode].map(Number).filter(Number.isFinite)
  if (!wanted.length) return true // nothing was asked for, so nothing can be ruled out
  const span = releaseSpan(parseObject?.episode_number)
  if (!span) return true
  if (wanted.some(number => span.first <= number && number <= span.last)) return true
  // numbered past the end of the show, with no absolute number to compare against: this is a
  // numbering we cannot map, not a release we can rule out
  const count = Number(episodeCount)
  if (!Number.isFinite(absoluteEpisode) && (!Number.isFinite(count) || count <= 0 || span.last > count)) return true
  return false
}
