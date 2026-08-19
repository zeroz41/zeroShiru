// Which media the home banner may rotate through, and in what order.
//
// Pulled out of Banner.svelte because it was where an offline start went wrong: with no
// connection the media query resolves to nothing, `media?.filter(...)` short-circuits to
// undefined, and the shuffle that followed read `.filter` off it. Even surviving that, an
// empty list still reached the banner, which renders `mediaList[0]` unguarded and threw
// on every field it touched. Neither failure is visible in a normal online run.
//
// So this always answers with an array, and the caller renders nothing when it is empty.

/**
 * Media worth putting behind the banner: it needs something to actually show.
 * @param {Array<object|null|undefined>} [media] - AniList page entries, possibly absent.
 * @param {object} [options]
 * @param {boolean} [options.coverFallback] - Also accept a cover image where there is no banner.
 * @param {number} [options.pool] - How many of the most popular entries to shuffle among.
 * @param {number} [options.limit] - How many to hand back.
 * @returns {object[]} Never undefined, never holes.
 */
export function bannerList (media, { coverFallback = false, pool = 10, limit = 5 } = {}) {
  if (!Array.isArray(media)) return []
  const showable = media.filter(entry =>
    entry && (entry.bannerImage || entry.trailer?.id || (coverFallback && entry.coverImage?.extraLarge)))

  // Shuffle only the head of the list: entries arrive by popularity, and rotating the
  // whole page would put the 40th most popular show on the front page as often as the 1st.
  let index = Math.min(pool, showable.length)
  while (index > 0) {
    const random = Math.floor(Math.random() * index--)
    ;[showable[index], showable[random]] = [showable[random], showable[index]]
  }
  return showable.slice(0, limit)
}
