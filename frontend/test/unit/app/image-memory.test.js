// The session's memory of images already shown. The pop-in it exists to stop: every page
// switch destroys every <img>, and each remount waited a frame behind a lazy-load gate
// before its real src went in — so grids of art the app had ALREADY shown flashed
// placeholder-first on every navigation, cache or no cache.
import { test, beforeEach } from 'bun:test'
import assert from 'node:assert/strict'
import { rememberShown, wasShown, forgetShown, IMAGE_MEMORY_LIMIT } from '@/modules/lib/image-memory.js'

beforeEach(forgetShown)

test('an image that has been shown is known, and one that has not is not', () => {
  rememberShown('shiru-media://localhost/cover-1.jpg')
  assert.equal(wasShown('shiru-media://localhost/cover-1.jpg'), true)
  assert.equal(wasShown('shiru-media://localhost/cover-2.jpg'), false, 'a first appearance still gets the lazy gate — its bytes may genuinely be far away')
})

test('the placeholder pixel is nobody\'s memory', () => {
  // every image renders a data: gif before its real src; remembering it would mean
  // every image "was shown" the moment it mounted, and the gate would never gate
  rememberShown('data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7')
  assert.equal(wasShown('data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'), false)
  rememberShown(null)
  rememberShown(undefined)
  rememberShown('')
  assert.equal(wasShown(''), false)
  assert.equal(wasShown(null), false)
})

test('a marathon session forgets its oldest images, never its newest', () => {
  for (let index = 0; index < IMAGE_MEMORY_LIMIT + 5; index++) rememberShown(`https://cdn/cover-${index}.jpg`)
  assert.equal(wasShown('https://cdn/cover-0.jpg'), false, 'the longest-ago image made room')
  assert.equal(wasShown(`https://cdn/cover-${IMAGE_MEMORY_LIMIT + 4}.jpg`), true)
  assert.equal(wasShown(`https://cdn/cover-${IMAGE_MEMORY_LIMIT - 1}.jpg`), true)
})

test('showing an image again keeps it fresh under eviction', () => {
  rememberShown('https://cdn/pinned.jpg')
  for (let index = 0; index < IMAGE_MEMORY_LIMIT - 1; index++) rememberShown(`https://cdn/cover-${index}.jpg`)
  rememberShown('https://cdn/pinned.jpg') // seen again, right before the memory fills
  rememberShown('https://cdn/one-more.jpg')
  assert.equal(wasShown('https://cdn/pinned.jpg'), true, 're-showing moved it to the young end')
  assert.equal(wasShown('https://cdn/cover-0.jpg'), false, 'the image nobody looked at again is the one forgotten')
})
