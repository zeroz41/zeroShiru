// The session's memory of images already shown. The pop-in it exists to stop: every page
// switch destroys every <img>, and each remount waited a frame behind a lazy-load gate
// before its real src went in — so grids of art the app had ALREADY shown flashed
// placeholder-first on every navigation, cache or no cache.
import { test, beforeEach } from 'bun:test'
import assert from 'node:assert/strict'
import { rememberShown, wasShown, forgetShown, imageSignature, IMAGE_MEMORY_LIMIT } from '@/modules/lib/image-memory.js'

/** A stand-in for the engine's image element, so the holding can be counted at all. */
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


test('a session with no Image constructor still remembers what it showed', () => {
  // the TV core and the tests have no DOM; remembering is bookkeeping, not holding
  rememberShown('https://cdn/headless.jpg')
  assert.equal(wasShown('https://cdn/headless.jpg'), true)
  forgetShown()
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

test('dynamic candidates contribute a marker, and the caller-supplied identity separates shows', () => {
  // a function candidate is a fresh closure per render — its own identity says nothing.
  // What tells two lists apart is the identity of what the art is OF, plus the strings.
  const forShow = id => imageSignature([() => 'later.jpg', 'https://cdn/banner.jpg'], id)
  assert.equal(forShow(21), forShow(21), 'the same show re-rendering is the same picture')
  assert.notEqual(forShow(21), forShow(170), 'a recycled card for another show must reset')
  assert.notEqual(
    imageSignature([() => 'later.jpg'], 21),
    imageSignature(['later.jpg'], 21),
    'a dynamic candidate is not the string it might resolve to'
  )
})

test('a missing candidate holds its place, so a gap is not the same as no gap', () => {
  assert.notEqual(imageSignature([null, 'https://cdn/cover.jpg']), imageSignature(['https://cdn/cover.jpg']))
})

test('a relative candidate and the absolute src it loaded as are one memory', () => {
  // rememberShown receives the element's absolute currentSrc; the lazy gate asks with
  // the raw candidate string. For local fallback art those strings never matched, so
  // the placeholder image re-played the gate and the fade on every single remount.
  const hadDocument = globalThis.document
  globalThis.document = { baseURI: 'https://app.test/index.html' }
  try {
    rememberShown('https://app.test/no_image_cover.jpg')
    assert.equal(wasShown('./no_image_cover.jpg'), true, 'the candidate resolves to what loaded')
    assert.equal(wasShown('/no_image_cover.jpg'), true)
    assert.equal(wasShown('./other.jpg'), false)
  } finally {
    if (hadDocument === undefined) delete globalThis.document
    else globalThis.document = hadDocument
    forgetShown()
  }
})
