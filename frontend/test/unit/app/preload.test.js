// Starting work before the user arrives. Written for the reported behaviour: scroll down,
// land on a row that is still black, watch it fill in. Everything here is about distance —
// how far ahead of the viewport an image, a row's media query, or a grid's next page begins.
import { test, afterEach } from 'bun:test'
import assert from 'node:assert/strict'
import { AHEAD_IMAGES, AHEAD_PAGES, AHEAD_SECTIONS, nearViewport, pageThreshold, scrollRoot } from '../../../common/modules/preload.js'

const withStyles = (fn) => {
  globalThis.getComputedStyle = (element) => ({
    overflowY: element.overflow?.split(' ')[0] ?? 'visible',
    overflowX: element.overflow?.split(' ')[1] ?? element.overflow?.split(' ')[0] ?? 'visible'
  })
  try { return fn() } finally { delete globalThis.getComputedStyle }
}

/** Stands in for the browser's IntersectionObserver, so a test can decide when a node is near. */
class FakeObserver {
  static last = null
  static instances = []
  constructor (callback, options) {
    this.callback = callback
    this.options = options
    this.observing = []
    this.disconnected = false
    FakeObserver.last = this
    FakeObserver.instances.push(this)
  }

  observe (node) { this.observing.push(node) }
  unobserve (node) { this.observing = this.observing.filter(observed => observed !== node) }
  disconnect () { this.disconnected = true }
  /** What the browser does when the node comes within rootMargin — never after disconnect. */
  arrive (isIntersecting = true, node = this.observing[0]) {
    if (this.disconnected) return
    this.callback([{ isIntersecting, target: node }], this)
  }
}

const withObserver = (fn) => {
  globalThis.IntersectionObserver = FakeObserver
  try { return fn() } finally { delete globalThis.IntersectionObserver }
}

afterEach(() => { FakeObserver.last = null; FakeObserver.instances = [] })

test('nothing loads until the node is near', () => {
  withObserver(() => {
    let loaded = false
    nearViewport({}, { near: () => { loaded = true } })
    assert.equal(loaded, false, 'a card two screens down has no business downloading yet')
    FakeObserver.last.arrive()
    assert.equal(loaded, true)
  })
})

test('a node that is merely observed, and never arrives, stays unloaded', () => {
  withObserver(() => {
    let loaded = false
    const action = nearViewport({}, { near: () => { loaded = true } })
    FakeObserver.last.arrive(false)
    assert.equal(loaded, false)
    action.destroy()
  })
})

test('arriving once is enough, and the watch ends there', () => {
  withObserver(() => {
    let loads = 0
    nearViewport({}, { near: () => loads++ })
    // a real observer stops delivering once disconnected; the action must not depend on it,
    // since one callback can carry several entries
    const node = FakeObserver.last.observing[0]
    FakeObserver.last.callback([{ isIntersecting: true, target: node }, { isIntersecting: true, target: node }], FakeObserver.last)
    FakeObserver.last.arrive()
    assert.equal(loads, 1, 'an image is downloaded once, not once per scroll past it')
    assert.equal(FakeObserver.last.disconnected, true)
  })
})

test('the action watches with the distance it was given', () => {
  withObserver(() => {
    const action = nearViewport({}, { near: () => {}, margin: AHEAD_SECTIONS })
    assert.equal(FakeObserver.last.options.rootMargin, AHEAD_SECTIONS)
    assert.equal(FakeObserver.last.options.threshold, 0, 'a single pixel of the node is enough')
    action.destroy()
  })
})

test('images lead by more than a screen, and their section leads by more still', () => {
  // the query has to answer before an image can even be requested, so it starts first
  const viewports = (margin) => Number(margin.replace('%', '')) / 100
  assert.ok(viewports(AHEAD_IMAGES) > 1, `images should start over a screen early, got ${AHEAD_IMAGES}`)
  assert.ok(viewports(AHEAD_SECTIONS) > viewports(AHEAD_IMAGES), 'the media query gates the images')
})

test('leaving the page stops the watch', () => {
  withObserver(() => {
    const { destroy } = nearViewport({}, { near: () => {} })
    destroy()
    assert.equal(FakeObserver.last.disconnected, true)
  })
})

test('skip loads immediately and never observes', () => {
  withObserver(() => {
    let loaded = false
    nearViewport({}, { near: () => { loaded = true }, skip: true })
    assert.equal(loaded, true)
    assert.equal(FakeObserver.last, null, 'nothing to watch for')
  })
})

test('without IntersectionObserver everything loads rather than nothing', () => {
  let loaded = false
  nearViewport({}, { near: () => { loaded = true } })
  assert.equal(loaded, true, 'a host missing the API must still show its art')
})

test('the next page is asked for a screen and a half from the bottom', () => {
  assert.equal(pageThreshold({ clientHeight: 1000 }), 1000 * AHEAD_PAGES)
})

test('a short or unmeasured container keeps the old fixed distance', () => {
  assert.equal(pageThreshold({ clientHeight: 100 }), 500, 'never less than the 500px this replaced')
  assert.equal(pageThreshold(undefined), 500)
  assert.equal(pageThreshold({}), 500)
})


test('a rail image watches the nearest scroller, so horizontal lookahead is real', () => {
  // A page-rooted observer cannot see past the nested rail's clipping edge. The rail must
  // be the root for its two-screen margin to preload art before a horizontal drag reaches it.
  withStyles(() => {
    const page = { overflow: 'scroll visible', parentElement: null }
    const row = { overflow: 'auto scroll', parentElement: page }
    const card = { parentElement: row }
    assert.equal(scrollRoot(card), row, 'the nearest horizontal rail owns image lookahead')
  })
})

test('images with the same viewport and margin share one observer', () => {
  withObserver(() => {
    const first = {}
    const second = {}
    let firstLoads = 0
    let secondLoads = 0
    const firstAction = nearViewport(first, { near: () => firstLoads++ })
    const secondAction = nearViewport(second, { near: () => secondLoads++ })

    assert.equal(FakeObserver.instances.length, 1, 'a grid pays for one native observer, not one per card')
    FakeObserver.last.arrive(true, first)
    assert.equal(firstLoads, 1)
    assert.equal(secondLoads, 0, 'one intersecting card does not load its neighbours')
    assert.equal(FakeObserver.last.disconnected, false, 'the observer stays for remaining cards')

    secondAction.destroy()
    assert.equal(FakeObserver.last.disconnected, true, 'the empty pool releases its observer')
    firstAction.destroy()
  })
})

test('a node with nothing scrollable above it is measured against the page', () => {
  withStyles(() => {
    const plain = { overflow: 'visible', parentElement: null }
    assert.equal(scrollRoot({ parentElement: plain }), null)
    assert.equal(scrollRoot(undefined), null)
  })
})

test('hidden overflow is not something a node scrolls inside', () => {
  withStyles(() => {
    const clipped = { overflow: 'hidden', parentElement: null }
    assert.equal(scrollRoot({ parentElement: clipped }), null)
  })
})

test('the watch is rooted at that scroller', () => {
  withStyles(() => {
    globalThis.IntersectionObserver = FakeObserver
    try {
      const page = { overflow: 'scroll', parentElement: null }
      const action = nearViewport({ parentElement: page }, { near: () => {} })
      assert.equal(FakeObserver.last.options.root, page)
      action.destroy()
    } finally { delete globalThis.IntersectionObserver }
  })
})
