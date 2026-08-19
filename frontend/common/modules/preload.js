// How far ahead of the viewport the app starts working, in one place so every surface —
// the home rows, a genre or search grid, and every image in either — agrees.
//
// The complaint this answers: scrolling down lands on a row that is still black, because
// nothing about it had started. Three separate delays stacked up to make that happen.
// A home row asked for its media only once it was 200px away, and until that query came
// back there was nothing to draw at all. A search grid asked for its next page only 500px
// from the bottom. And every image waited on the browser's own `loading="lazy"`, whose
// threshold is not ours to set and, in WebKit, is tight. Arriving somewhere was the thing
// that started the work, so arriving always meant waiting.
//
// The fix is to start earlier, not to load everything: distances are given in viewports,
// so they mean the same thing on a phone, a desktop and a television. AniList requests go
// through a rate limiter that queues, so asking sooner costs latency we were spending
// anyway rather than requests we cannot afford.

/**
 * Images start downloading this far out: two screens, roughly three rows of covers ahead on
 * a desktop. Enough that an ordinary scroll never outruns them and that dragging the bar a
 * screen or two lands on art, without pulling down a whole page nobody looks at.
 */
export const AHEAD_IMAGES = '200%'

/**
 * Section media queries start this far out, further than the images because they gate them:
 * nothing can be drawn, let alone downloaded, until the query answers.
 */
export const AHEAD_SECTIONS = '300%'

/** Screens of remaining scroll at which a grid asks for its next page. */
export const AHEAD_PAGES = 1.5

/**
 * The element a node actually scrolls inside, or null where that is the page itself.
 *
 * This is the difference between the distances above meaning something and meaning nothing.
 * An observer watching against the viewport sees a node inside a scrolling div only once the
 * div itself has scrolled it into view: everything past that div's edge is clipped away
 * before `rootMargin` is ever applied, so the margin buys nothing and work starts exactly as
 * the user arrives. Pointing the observer at the scroller instead is what lets it look ahead.
 *
 * The outermost scroller wins, so a card inside a horizontal row is measured against the page
 * it scrolls down, while the row's own clipping still keeps its off-screen cards unloaded.
 *
 * @param {Element} node
 * @returns {Element | null}
 */
export function scrollRoot (node) {
  if (typeof getComputedStyle !== 'function') return null
  let outermost = null
  for (let element = node?.parentElement; element; element = element.parentElement) {
    const style = getComputedStyle(element)
    if (/auto|scroll|overlay/.test(`${style?.overflowY} ${style?.overflowX}`)) outermost = element
  }
  return outermost
}

/**
 * Svelte action: runs `near` once the node comes within `margin` of the scroller it lives in,
 * then stops watching. Where IntersectionObserver is missing the node counts as near
 * immediately — showing everything at once beats showing nothing ever.
 *
 * @param {Element} node
 * @param {{ near: () => void, margin?: string, skip?: boolean }} options
 */
export function nearViewport (node, { near, margin = AHEAD_IMAGES, skip = false } = {}) {
  if (skip || typeof IntersectionObserver !== 'function') {
    near?.()
    return {}
  }
  // once, and by our own bookkeeping: one callback may carry several entries, and the
  // node this loads is downloaded once no matter how often it is scrolled past
  let fired = false
  const observer = new IntersectionObserver(entries => {
    if (fired || !entries.some(entry => entry.isIntersecting)) return
    fired = true
    observer.disconnect()
    near?.()
  }, { root: scrollRoot(node), threshold: 0, rootMargin: margin })
  observer.observe(node)
  return { destroy: () => observer.disconnect() }
}

/**
 * How close to the bottom of a scroller the next page should be requested, in pixels.
 * Viewport-relative, with a floor for the short containers a fixed guess was written for.
 *
 * @param {{ clientHeight?: number }} [container]
 * @returns {number}
 */
export function pageThreshold (container) {
  return Math.max(500, Math.round((container?.clientHeight || 0) * AHEAD_PAGES))
}
