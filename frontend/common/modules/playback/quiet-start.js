// Who may touch the stream while playback is starting: nobody.
//
// Measured on a real TorBox link (GST_DEBUG, 2026-08-21): before the first frame the
// media pipeline must pull ~6.5MB across three requests — head, the Cues at the tail,
// then the first clusters — at a couple of MB/s per CDN connection. The app used to
// spend that exact window starting rivals on the same host: the subtitle parser (several
// header reads at construction, then a stream reading up to 120 SECONDS of video ahead
// of a playhead still at zero), the cue index, external subtitle and font fetches, and a
// whole second <video> for thumbnails at loadedmetadata. All of it shares the network
// process's per-host connections and the line's bandwidth with the one stream the user
// is actually waiting on — and none of it is worth anything until there is a picture.
//
// So the helpers wait for the element to hold a decoded frame — `loadeddata`, or
// `playing` as the belt to its braces. NOT `canplay`: this webview pins readyState below
// HAVE_FUTURE_DATA on debrid range streams even while visibly playing (the same lie the
// spinner logic has to work around, see playback/buffering.js), so a canplay gate simply
// never opened — no subtitles, no thumbnails, shipped and caught by the user within the
// hour. A frame existing is the element's own proof that startup got what it needed.

/**
 * Whether the stream helpers (subtitle metadata parser, thumbnailer) may start now.
 *
 * @param {object} state
 * @param {boolean} [state.hasFrame] The element decoded a frame of the current file
 *   (loadeddata or playing fired) — never readyState arithmetic, which lies here.
 * @param {boolean} [state.started] Helpers already started for this file — a rebuild or a
 *   later event must not start a second parser or a second thumbnail stream, which is
 *   its own amplifier bug (see playback/thumbnails.js history).
 * @param {boolean} [state.externalPlayback] Another player owns the stream entirely.
 * @returns {boolean}
 */
export function helpersMayStart ({ hasFrame = false, started = false, externalPlayback = false } = {}) {
  return hasFrame && !started && !externalPlayback
}
