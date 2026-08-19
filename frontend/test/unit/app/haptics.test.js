// The haptic tap a click gives back. Written for a bug that made the whole app unusable:
// the click action buzzed before calling its handler, WebKitGTK has no Vibration API, and so
// every click threw on the buzz and never reached the thing it was supposed to do. Nothing in
// the app was clickable — no navigation, no buttons, no cards — and the only symptom was a
// TypeError nobody was looking at.
import { test, afterEach } from 'bun:test'
import assert from 'node:assert/strict'
import { tap } from '../../../common/modules/lib/haptics.js'

const original = globalThis.navigator
afterEach(() => {
  if (original === undefined) delete globalThis.navigator
  else Object.defineProperty(globalThis, 'navigator', { value: original, configurable: true, writable: true })
})

const withNavigator = (value) => Object.defineProperty(globalThis, 'navigator', { value, configurable: true, writable: true })

test('a platform without haptics is not an error', () => {
  // desktop WebKit, which is what Tauri renders with on Linux
  withNavigator({})
  assert.doesNotThrow(() => tap())
  assert.equal(tap(), false)
})

test('no navigator at all is not an error either', () => {
  withNavigator(undefined)
  assert.doesNotThrow(() => tap())
  assert.equal(tap(), false)
})

test('a platform that refuses to buzz is not an error', () => {
  // some engines throw when there has been no user gesture, or inside a cross-origin frame
  withNavigator({ vibrate: () => { throw new Error('not allowed without a user gesture') } })
  assert.doesNotThrow(() => tap())
  assert.equal(tap(), false)
})

test('a platform with haptics buzzes, for as long as it was asked to', () => {
  const asked = []
  withNavigator({ vibrate: (duration) => { asked.push(duration); return true } })
  assert.equal(tap(), true)
  tap(40)
  assert.deepEqual(asked, [15, 40], 'the default is a tap, not a rumble')
})
