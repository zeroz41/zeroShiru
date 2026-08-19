// Episode picking for season packs, free of UI imports so it runs under plain Node for tests.
// The parser is injected because the app's anitomyscript wrapper lives in the UI bundle; the
// tests hand in the raw parser, the app hands in its corrected one.
import { videoRx } from '@/modules/util.js'
import Debug from 'debug'
const debug = Debug('ui:debrid')

/**
 * The release provably does not contain the requested episode: every video file parsed to an
 * episode number and none of them covers it. Thrown instead of guessing, because the guess used
 * to be "largest file" — asking a 459-516 pack for episode 23 played episode 475, which is a
 * spoiler, a wrong watch entry, and a resume position under the wrong episode all at once.
 */
export class EpisodeNotInPackError extends Error {
  /**
   * @param {number} episode - What was asked for.
   * @param {number} first - Lowest episode the pack holds.
   * @param {number} last - Highest episode the pack holds.
   */
  constructor (episode, first, last) {
    const span = first === last ? `episode ${first}` : `episodes ${first}-${last}`
    super(`This release holds ${span}, not episode ${episode}. Pick a release that has it.`)
    this.name = 'EpisodeNotInPackError'
    this.episode = episode
    this.first = first
    this.last = last
  }
}

/**
 * Picks the requested episode out of a pack, using the same anitomy parsing as the rest of the
 * app. Extras carry episode numbers of their own ("NCOP1" parses as episode 1), so candidates
 * are ranked rather than taking the first number that matches: a real episode beats an extra,
 * and an exact match beats a multi-episode file that merely spans the number.
 *
 * When nothing matches, what happens depends on how sure the parse is. Every file numbered and
 * none covering the episode is proof the release cannot serve it, and throwing
 * `EpisodeNotInPackError` beats playing episode 475 of a 459-516 pack to someone who asked for
 * 23. Anything less certain — unnumbered files, a failed parse — falls back to the largest
 * episode-like video, which is the best guess there is.
 * @template {{ path: string, size: number }} T
 * @param {T[]} files
 * @param {number} episode
 * @param {(names: string[]) => Promise<any[]>} parse - anitomyscript, or the app's corrected wrapper.
 * @returns {Promise<T | undefined>}
 * @throws {EpisodeNotInPackError} When the pack provably does not contain the episode.
 */
export async function pickEpisodeFile (files, episode, parse) {
  const videoFiles = files.filter(({ path }) => videoRx.test(path))
  if (videoFiles.length <= 1) return videoFiles[0] || files[0]
  let candidates = videoFiles
  try {
    const parsed = await parse(videoFiles.map(({ path }) => path.split('/').pop()))
    // rank 0: episode, exact. 1: episode, range. 2: extra, exact. 3: extra, range.
    // First file in torrent order wins within a rank, so duplicate resolutions stay stable.
    const ranks = [null, null, null, null]
    const held = [] // every episode number the pack's files answer to
    let unnumbered = 0
    parsed?.forEach((parse, index) => {
      const numbers = episodeNumbers(parse?.episode_number)
      if (!numbers.length) unnumbered++
      else held.push(...numbers)
      const match = matchesEpisode(numbers, episode)
      if (!match) return
      const rank = (parse.anime_type ? 2 : 0) + (match === 'range' ? 1 : 0)
      ranks[rank] ??= index
    })
    const match = ranks.find(index => index !== null)
    if (match !== undefined) return videoFiles[match]
    const episodes = videoFiles.filter((_, index) => !parsed?.[index]?.anime_type)
    // every video answered with a number and none covers the episode: the release cannot
    // serve this request, and no fallback can make it
    if (parsed?.length === videoFiles.length && !unnumbered && held.length) {
      // the reported span reads off the real episodes where any exist, so an NCOP1 in the pack
      // does not make a 459-516 release claim to start at episode 1
      const span = episodes.length ? episodes.flatMap(file => episodeNumbers(parsed[videoFiles.indexOf(file)]?.episode_number)) : held
      throw new EpisodeNotInPackError(episode, Math.min(...span), Math.max(...span))
    }
    // nothing matched but nothing is proven either: never fall back onto an extra while real
    // episodes exist
    if (episodes.length) candidates = episodes
  } catch (error) {
    if (error instanceof EpisodeNotInPackError) throw error
    debug('Failed to parse pack file names:', error)
  }
  return [...candidates].sort((a, b) => b.size - a.size)[0]
}

/**
 * The finite episode numbers a parsed name answers to. Multi-episode files parse as an array
 * ("01-12" -> ["01", "12"]).
 * @param {string | string[] | undefined} episodeNumber
 * @returns {number[]}
 */
function episodeNumbers (episodeNumber) {
  if (episodeNumber == null) return []
  return (Array.isArray(episodeNumber) ? episodeNumber : [episodeNumber]).map(Number).filter(Number.isFinite)
}

/**
 * Whether a file's episode numbers cover the requested episode. More than one number means a
 * multi-episode file, which counts as a range containing everything between.
 * @param {number[]} numbers
 * @param {number} episode
 * @returns {'exact' | 'range' | null}
 */
function matchesEpisode (numbers, episode) {
  if (!numbers.length) return null
  if (numbers.length === 1) return numbers[0] === episode ? 'exact' : null
  return Math.min(...numbers) <= episode && episode <= Math.max(...numbers) ? 'range' : null
}

/**
 * Picks the episode for a debrid resolve, refusing only when refusing costs nothing.
 *
 * The picker matches the requested episode against the numbers in the file names, which is the
 * release's own numbering. The player matches against AniList's, using season offset mappings
 * the picker does not have — so a split cour release numbered 13-24 looks like it lacks episode
 * 1 when it holds it under another name. That disagreement only matters when the file list has
 * to be windowed: when every file reaches the player anyway, handing the whole release over
 * lets the side that knows about offsets decide.
 * @template {{ path: string, size: number }} T
 * @param {T[]} files
 * @param {number} episode
 * @param {(names: string[]) => Promise<any[]>} parse
 * @param {{ maxFiles?: number }} [opts] - How many files the resolve may return.
 * @returns {Promise<T | undefined>} Undefined hands the choice to the player.
 * @throws {EpisodeNotInPackError} When the release provably lacks the episode and windowing
 *   would otherwise pick an arbitrary file out of it.
 */
export async function pickPackFile (files, episode, parse, { maxFiles = Infinity } = {}) {
  try {
    return await pickEpisodeFile(files, episode, parse)
  } catch (error) {
    if (!(error instanceof EpisodeNotInPackError)) throw error
    if (files.length <= maxFiles) {
      debug(`${error.message} Handing the whole release to the player, which resolves numbering differences.`)
      return undefined
    }
    throw error
  }
}
