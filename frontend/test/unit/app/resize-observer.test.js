// Resize callbacks answer on the next frame, not inside the observation.
//
// Every caller of this helper measures an element and writes a style back onto the page.
// Doing that while resize notifications are still being delivered restarts the cycle —
// "ResizeObserver loop completed with undelivered notifications", 59 of them in the user's
// main.log, each one a layout pass computed and thrown away.
import { test, beforeEach, afterEach } from 'bun:test'
import assert from 'node:assert/strict'
import { resizeObserver } from '@/modules/util.js'

let observed
let frames

class FakeResizeObserver {
  constructor (callback) { this.callback = callback; observed = this }
  observe (node) { this.node = node }
  disconnect () { this.disconnected = true }
  /** The engine delivering a size change. */
  emit (width) { this.callback([{ contentRect: { width } }]) }
}

beforeEach(() => {
  frames = []
  globalThis.ResizeObserver = FakeResizeObserver
  globalThis.requestAnimationFrame = callback => { frames.push(callback); return frames.length }
  globalThis.cancelAnimationFrame = handle => { frames[handle - 1] = null }
})
afterEach(() => {
  delete globalThis.ResizeObserver
  delete globalThis.requestAnimationFrame
  delete globalThis.cancelAnimationFrame
})

const runFrames = () => { const pending = frames; frames = []; for (const frame of pending) frame?.() }
const node = { tagName: 'DIV', getBoundingClientRect: () => ({ width: 100 }) }

test('a resize is answered on the next frame, never during the observation', () => {
  const seen = []
  const action = resizeObserver((element, entry) => seen.push(entry.contentRect.width))(node)
  observed.emit(300)
  assert.deepEqual(seen, [], 'nothing may run while the engine is still delivering sizes')
  runFrames()
  assert.deepEqual(seen, [300])
  action.destroy()
})

test('a burst of sizes costs one callback, at the last size', () => {
  // dragging a window edge, or the sidebar widening: every intermediate size used to be
  // measured and written back
  const seen = []
  const action = resizeObserver((element, entry) => seen.push(entry.contentRect.width))(node)
  observed.emit(300)
  observed.emit(420)
  observed.emit(555)
  runFrames()
  assert.deepEqual(seen, [555], 'one answer, and it is the size the element actually ended at')
  action.destroy()
})

test('the node is handed to the callback, and destroying stops both the frame and the observer', () => {
  const seen = []
  const action = resizeObserver(element => seen.push(element))(node)
  observed.emit(300)
  action.destroy()
  runFrames()
  assert.deepEqual(seen, [], 'a callback must not fire after the component is gone')
  assert.equal(observed.disconnected, true)

  const alive = []
  const second = resizeObserver(element => alive.push(element))(node)
  observed.emit(300)
  runFrames()
  assert.deepEqual(alive, [node])
  second.destroy()
})

test('an explicit update measures the node itself, on a frame like everything else', () => {
  const seen = []
  const action = resizeObserver((element, entry) => seen.push(entry.contentRect.width))(node)
  action.update()
  assert.deepEqual(seen, [])
  runFrames()
  assert.deepEqual(seen, [100])
  action.destroy()
})
