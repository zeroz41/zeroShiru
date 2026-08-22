// The session's memory of images already shown. The pop-in it exists to stop: every page
// switch destroys every <img>, and each remount waited a frame behind a lazy-load gate
// before its real src went in — so grids of art the app had ALREADY shown flashed
// placeholder-first on every navigation, cache or no cache.
import { test, beforeEach } from 'bun:test'
import assert from 'node:assert/strict'
import { rememberShown, wasShown, forgetShown, imageSignature, warmCount, IMAGE_MEMORY_LIMIT, IMAGE_WARM_LIMIT } from '@/modules/lib/image-memory.js'

/** A stand-in for the engine's image element, so the holding can be counted at all. */
class FakeImage {
  static made = []
  set src (value) { this._src = value; FakeImage.made.push(value) }
  get src () { return this._src }
}

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


test('shown images are held, so a later mount of the same art is a cache hit', () => {
  // holding a live element is what keeps the engine's in-memory copy from being evicted;
  // without it every remount went back to the host over the custom scheme and decoded again
  globalThis.Image = FakeImage
  FakeImage.made = []
  try {
    rememberShown('shiru-media://localhost/cover-1.jpg')
    rememberShown('shiru-media://localhost/cover-1.jpg')
    assert.deepEqual(FakeImage.made, ['shiru-media://localhost/cover-1.jpg'], 'held once, however often it is shown')
    assert.equal(warmCount(), 1)
  } finally {
    delete globalThis.Image
    forgetShown()
  }
})

test('holding images is bounded — it is memory, not a leak', () => {
  globalThis.Image = FakeImage
  FakeImage.made = []
  try {
    for (let index = 0; index < IMAGE_WARM_LIMIT + 20; index++) rememberShown(`https://cdn/cover-${index}.jpg`)
    assert.equal(warmCount(), IMAGE_WARM_LIMIT)
  } finally {
    delete globalThis.Image
    forgetShown()
  }
})

test('a session with no Image constructor still remembers what it showed', () => {
  // the TV core and the tests have no DOM; remembering must not depend on holding
  rememberShown('https://cdn/headless.jpg')
  assert.equal(wasShown('https://cdn/headless.jpg'), true)
  assert.equal(warmCount(), 0)
})

test('two renders of the same candidate list describe the same picture', () => {
  // the flash this stops: the prop is a fresh array on every render of the parent, so
  // identity said "new art" for a card whose cover had not changed
  const first = ['https://cdn/cover.jpg', 'https://cdn/medium.jpg', './no_image_cover.jpg']
  const second = ['https://cdn/cover.jpg', 'https://cdn/medium.jpg', './no_image_cover.jpg']
  assert.equal(imageSignature(first), imageSignature(second))
  assert.notEqual(imageSignature(first), imageSignature(['https://cdn/other.jpg', 'https://cdn/medium.jpg', './no_image_cover.jpg']))
  assert.notEqual(imageSignature(first), imageSignature(first.slice(1)), 'a shorter list is a different list')
})

test('a candidate that is a promise or a function describes nothing, and starts over', () => {
  assert.equal(imageSignature(['https://cdn/cover.jpg', () => 'later.jpg']), null)
  assert.equal(imageSignature([Promise.resolve('later.jpg')]), null)
  assert.equal(imageSignature([]), '')
  assert.equal(imageSignature(undefined), '')
})

test('a missing candidate holds its place, so a gap is not the same as no gap', () => {
  assert.notEqual(imageSignature([null, 'https://cdn/cover.jpg']), imageSignature(['https://cdn/cover.jpg']))
})
