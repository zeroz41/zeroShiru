// When a card's preview opens, and when the expensive part of it starts.
//
// A preview is not a hover style: it mounts a second card over the grid, loads a banner,
// and starts a YouTube trailer in an iframe — a whole nested renderer, a network fetch and
// a video decode. Opening it the instant a pointer touches a card means dragging the mouse
// across a row pays that cost once per card it crosses, none of which the user asked to
// see. On a system webview that is the difference between a grid that feels immediate and
// one that stutters while you move over it.
//
// So the pointer has to rest before anything opens, and the trailer waits a little longer
// than the card does: the picture and the details are what someone is usually after, and
// they are nearly free.

/** How long a pointer rests on a card before its preview opens. */
export const PREVIEW_DWELL = 250

/** How long a preview stays open before its trailer starts. */
export const TRAILER_DWELL = 900

/**
 * Opens on a rest rather than on arrival. Closing is never delayed: leaving is unambiguous,
 * and a preview that lingers after the pointer has gone reads as a stuck UI.
 *
 * @param {Object} options
 * @param {(open: boolean) => void} options.apply - Sets the card's preview state.
 * @param {number} [options.delay]
 * @param {(callback: () => void, delay: number) => any} [options.schedule] - Defaults to setTimeout.
 * @param {(timer: any) => void} [options.cancel] - Defaults to clearTimeout.
 */
export function createHoverIntent ({ apply, delay = PREVIEW_DWELL, schedule = setTimeout, cancel = clearTimeout }) {
  /** @type {any} */
  let timer = null

  function stop () {
    if (timer !== null) cancel(timer)
    timer = null
  }

  return {
    /**
     * @param {boolean} open - Whether the preview should be showing.
     * @param {boolean} [immediate] - A tap or a keyboard action, which is a decision rather
     *   than a pointer passing over, so it opens at once.
     */
    set (open, immediate = false) {
      stop()
      if (!open || immediate) return apply(Boolean(open))
      timer = schedule(() => {
        timer = null
        apply(true)
      }, delay)
      timer?.unref?.()
    },
    /** Drops a pending open, for a card being destroyed or scrolled away. */
    cancel: stop,
    /** Whether an open is waiting on the pointer staying put. */
    get waiting () {
      return timer !== null
    }
  }
}
