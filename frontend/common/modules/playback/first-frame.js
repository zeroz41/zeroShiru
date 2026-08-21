// How long the player took to start, measured where the complaints are.
//
// "It's slow to play" has three suspects that all look identical from the couch:
// the debrid resolve (the host logs that), the network fetch of the file's header,
// and the decoder getting to a first frame. This timer splits the renderer's share
// at the two seams the media element announces — metadata parsed, playback going —
// so a slow start names its culprit in the log instead of being a feeling.
//
// A start that took longer than SLOW_START is a warning, which always crosses to
// the host log; a normal start is debug chatter, visible only when someone asked.

/** Longer than this to first frame is worth a line in everyone's log. */
export const SLOW_START = 10_000

/**
 * One playback start, from src assignment to first frame. Create per player, call
 * start() when the source is set; the element's events drive the rest.
 * @param {Object} [options]
 * @param {() => number} [options.now] - Defaults to performance.now.
 * @param {{ debug?: Function, warn?: Function }} [options.console] - Defaults to the global console.
 */
export function createStartupTimer ({ now = () => performance.now(), console: target = globalThis.console } = {}) {
  /** @type {{ label: string, at: number, metadata: number | null } | null} */
  let started = null
  return {
    /** A new source was just assigned. Restarts cleanly if the last start never finished. */
    start (label) {
      started = { label: String(label ?? 'stream'), at: now(), metadata: null }
    },
    /** The element parsed the container header (loadedmetadata). */
    metadata () {
      if (started && started.metadata === null) started.metadata = now() - started.at
    },
    /** The element is rendering (playing). Reports once and disarms. */
    playing () {
      if (!started) return null
      const total = now() - started.at
      const header = started.metadata === null ? 'metadata never reported' : `metadata in ${Math.round(started.metadata)}ms`
      const line = `playback of ${started.label} started in ${Math.round(total)}ms (${header})`
      started = null
      if (total >= SLOW_START) target?.warn?.(`slow start: ${line}`)
      else target?.debug?.(line)
      return line
    },
    /** The source went away before it ever played; a report now would blame the wrong stream. */
    cancel () {
      started = null
    }
  }
}
