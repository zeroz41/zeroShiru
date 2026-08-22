// What the player shows and holds between files — because for seconds at a time it has
// nothing: the old episode has been left, and the new one is still resolving.
//
// Two bugs live in that gap, and both were shipped. Removing a <video> element's src does
// NOT unload it — only load() re-runs resource selection — so the previous episode stayed
// decoded, kept its last frame on screen, and if it was playing, kept playing under the
// spinner until the new file finally arrived. And the page-return logic could actively
// un-pause it: its guard read `buffer === 0`, but a finished debrid play leaves buffer at
// 100 and the teardown never reset it. What the user saw was the LAST episode flashing,
// sometimes audibly playing, at the start of every new one.
//
// So the between-files state is one explicit contract (idleState), and the gap itself gets
// a face: the show's own cover art, which the play request carries from its first moment.

/**
 * Everything the player must write when it is left between files. One object so the reset
 * list is a contract a test can hold, not a scatter of assignments that each forgets one:
 * - `paused: true`, because the old element otherwise keeps playing under the spinner;
 * - `buffer: 0`, because the page-return logic reads it as "nothing loaded, do not touch
 *   playback" — at its stale 100 it would un-pause the old episode on navigation;
 * - `videos: []`, because next/previous and watch-together jump by index, and a stale
 *   list would land them in the PREVIOUS release's files (empty, not null: the index
 *   arithmetic reads `.length` and `.indexOf` unguarded);
 * - `canPlay: false` and `buffering: true`, which is what puts the loading screen up.
 */
export function idleState () {
  return { src: null, current: null, videos: [], canPlay: false, buffer: 0, paused: true, buffering: true, currentTime: 0, targetTime: 0 }
}

/**
 * Whether the loading screen is showing instead of the video: whenever the file being
 * played cannot yet put a frame up. Between files there is no current; a file that just
 * arrived has no frame until it can play. External playback owns its own screen.
 * @param {object} state
 * @param {any} [state.current]
 * @param {boolean} [state.canPlay]
 * @param {boolean} [state.externalPlayback]
 */
export function showsLoadingArt ({ current, canPlay, externalPlayback = false } = {}) {
  if (externalPlayback) return false
  return !current || !canPlay
}

/**
 * The art and words for the loading screen, from the play request's own media — available
 * from the moment the user clicks, seconds before anything resolves. Null when the request
 * carries no described media (a raw magnet or dropped torrent file), which the caller
 * renders as the plain spinner it always had.
 * @param {{ media?: { title?: object, coverImage?: object, bannerImage?: string }, episode?: number }} [nowPlaying]
 * @param {(media: any) => string} [title] - Title resolver, anilistClient.title in the app.
 * @returns {null | { cover: string | undefined, banner: string | undefined, title: string, episode: number | null }}
 */
export function loadingArt (nowPlaying, title = media => media?.title?.userPreferred) {
  const media = nowPlaying?.media
  if (!media || (!media.coverImage && !media.title)) return null
  return {
    cover: media.coverImage?.extraLarge || media.coverImage?.medium,
    banner: media.bannerImage || media.coverImage?.extraLarge,
    title: title(media) || '',
    episode: Number.isFinite(Number(nowPlaying?.episode)) ? Number(nowPlaying.episode) : null
  }
}
