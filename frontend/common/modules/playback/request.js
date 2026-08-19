// What the user explicitly asked to watch, carried from the click that started playback to the
// moment the resolved file list arrives. Free of UI imports so it runs under plain Node for
// tests, and free of app imports so neither the torrent lane nor the debrid lane creates a cycle.
//
// Why this exists: `handleFiles` re-derives which episode to play from the file list using watch
// status (currently watching -> progress + 1, otherwise the lowest unwatched episode present).
// That is the right answer when playback starts itself, and the wrong one when the user named an
// episode. It bit hardest on debrid, where the resolved list is a window centred on the wanted
// episode: the lowest episode in a 12 file window is the wanted one minus six, so picking
// episode 10 played episode 4 and picking 24 played 18.
import { writable } from 'simple-store-svelte'

/**
 * @typedef {Object} PlayRequest
 * @property {number} episode - The episode the user asked for.
 * @property {number} [mediaId] - AniList id, when the request came from a media page.
 */

/** @type {import('simple-store-svelte').Writable<PlayRequest | null>} The pending explicit request, or null when playback is choosing for itself. */
export const playRequest = writable(null)

/**
 * Records what a play request asked for, or clears it when it asked for nothing in particular.
 * Called for every play, so a request never outlives the playback it describes.
 * @param {{ media?: { id?: number }, episode?: number | string }} [search]
 */
export function requestPlayback (search) {
  const episode = Number(search?.episode)
  playRequest.set(Number.isFinite(episode) ? { episode, mediaId: search?.media?.id } : null)
}

/**
 * The file that serves an explicit request, or null when nothing does — in which case playback
 * falls back to choosing for itself, exactly as it did before a request was ever recorded.
 * @template {{ media?: any }} T
 * @param {T[]} files - Video files with their resolved media attached.
 * @param {PlayRequest | null} request
 * @returns {T | null}
 */
export function matchRequestedFile (files, request) {
  if (!request || !files?.length) return null
  const episode = Number(request.episode)
  if (!Number.isFinite(episode)) return null
  // a file whose media did not resolve is still a candidate: it belongs to the release the user
  // just asked to play, and refusing it would fall back to a worse guess
  const candidates = files.filter(sameMedia(request))
  return candidates.find(file => Number(file.media?.episode) === episode) ||
    candidates.find(file => Number(file.media?.parseObject?.episode_number) === episode) ||
    // a file holding several episodes serves any of them, which is how batched releases play
    candidates.find(file => covers(file.media?.episodeRange, episode)) ||
    null
}

/**
 * @param {{ first?: number, last?: number } | undefined} range
 * @param {number} episode
 */
function covers (range, episode) {
  const first = Number(range?.first)
  const last = Number(range?.last)
  return Number.isFinite(first) && Number.isFinite(last) && first <= episode && episode <= last
}

/**
 * Why a release cannot serve an explicit request, or null when it can — or when there is not
 * enough evidence to say so, in which case playback chooses for itself as it always did.
 *
 * A pack almost always carries something unnumbered — an extra, a special, a file whose name
 * defeats the parser — so requiring every file to be numbered meant a single such file let a
 * pack of episode 1085 onwards play episode 1085 to somebody who asked for 28. What the numbered
 * files say is evidence enough, as long as there is more than one file to choose between.
 *
 * This is the authoritative check, and it lives here rather than in the debrid picker because
 * this is the point where every file has been through AnimeResolver: episode numbers are in
 * AniList's terms, season offsets applied, so a release numbered 13-24 that really does hold
 * episode 1 has already been recognised as holding it. What is left is proof.
 *
 * The case it was written for: `[F-R] One Piece 0487+0490`, a two episode fix release. Asked for
 * episode 10 it matched nothing, so playback fell back to the lowest episode present and played
 * 487 — whichever episode had been asked for.
 * @param {{ media?: any, name?: string }[]} files - Video files with their resolved media attached.
 * @param {PlayRequest | null} request
 * @returns {string | null} A message for the user, or null to carry on.
 */
export function describeMissingEpisode (files, request) {
  if (!request || !files?.length) return null
  const episode = Number(request.episode)
  if (!Number.isFinite(episode)) return null
  const candidates = files.filter(sameMedia(request))
  // nothing here is the show that was asked for, which resolution failures alone can explain
  if (!candidates.length) return null
  if (matchRequestedFile(candidates, request)) return null
  const held = candidates.flatMap(episodesOf)
  // nothing here could be numbered at all, so the release says nothing about what it holds
  if (!held.length) return null
  const sorted = [...new Set(held)].sort((a, b) => a - b)
  return `This release holds ${listEpisodes(sorted)}, not episode ${episode}. Choose another release.`
}

/** @param {PlayRequest} request */
function sameMedia (request) {
  return file => !request.mediaId || !file.media?.media?.id || file.media.media.id === request.mediaId
}

/**
 * Every episode a resolved file answers to.
 * @param {{ media?: any }} file
 * @returns {number[]}
 */
function episodesOf (file) {
  const first = Number(file.media?.episodeRange?.first)
  const last = Number(file.media?.episodeRange?.last)
  if (Number.isFinite(first) && Number.isFinite(last) && last >= first) {
    // spelled out so a listing reads honestly, unless the span is too wide to be worth it
    if (last - first <= 50) return Array.from({ length: last - first + 1 }, (_, index) => first + index)
    return [first, last]
  }
  const episode = Number(file.media?.episode ?? file.media?.parseObject?.episode_number)
  return Number.isFinite(episode) ? [episode] : []
}

/**
 * Names what a release holds the way a person would: a run reads as a range, gaps are spelled
 * out, since "487-490" would claim two episodes this release does not have.
 * @param {number[]} episodes - Sorted, deduplicated.
 */
function listEpisodes (episodes) {
  if (episodes.length === 1) return `episode ${episodes[0]}`
  const contiguous = episodes.every((episode, index) => index === 0 || episode === episodes[index - 1] + 1)
  if (contiguous) return `episodes ${episodes[0]}-${episodes[episodes.length - 1]}`
  if (episodes.length <= 6) return `episodes ${episodes.slice(0, -1).join(', ')} and ${episodes[episodes.length - 1]}`
  return `episodes ${episodes.slice(0, 5).join(', ')} and ${episodes.length - 5} more, but not every episode in between`
}
