// The home banner's media list. Written for an offline start: with no connection the media
// query resolves to nothing, and both the shuffle and the banner component assumed an array
// with something in it. The app opened on an unhandled error and no banner at all.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { bannerList } from '../../../common/modules/banner.js'

const withBanner = (id) => ({ id, bannerImage: `https://img/${id}.jpg` })
const withTrailer = (id) => ({ id, trailer: { id: `yt${id}` } })
const withCover = (id) => ({ id, coverImage: { extraLarge: `https://img/${id}.jpg` } })
const bare = (id) => ({ id })

test('nothing to show is an empty list, not a crash', () => {
  // exactly what an offline media query leaves behind
  assert.deepEqual(bannerList(undefined), [])
  assert.deepEqual(bannerList(null), [])
  assert.deepEqual(bannerList([]), [])
})

test('entries with nothing to display are left out', () => {
  assert.deepEqual(bannerList([bare(1), bare(2)]), [], 'a banner with no image is not a banner')
})

test('holes in the page never reach the banner', () => {
  const list = bannerList([null, withBanner(1), undefined, withBanner(2)])
  assert.equal(list.length, 2)
  assert.ok(list.every(entry => entry), 'the banner reads fields off every entry it is given')
})

test('a trailer is enough to show', () => {
  assert.deepEqual(bannerList([withTrailer(7)]).map(m => m.id), [7])
})

test('a cover image only counts where the caller says it does', () => {
  assert.deepEqual(bannerList([withCover(3)]), [], 'off by default')
  assert.deepEqual(bannerList([withCover(3)], { coverFallback: true }).map(m => m.id), [3])
})

test('the banner rotates through at most five', () => {
  const media = Array.from({ length: 30 }, (_, i) => withBanner(i))
  assert.equal(bannerList(media).length, 5)
})

test('fewer than five is fine', () => {
  assert.equal(bannerList([withBanner(1), withBanner(2)]).length, 2)
})

test('the shuffle draws from the popular head of the page', () => {
  // entries arrive by popularity; without a pool the 40th show would front the app as
  // often as the 1st. 200 draws over a pool of 10 makes a miss statistically impossible.
  const media = Array.from({ length: 40 }, (_, i) => withBanner(i))
  const drawn = new Set()
  for (let i = 0; i < 200; i++) for (const entry of bannerList(media)) drawn.add(entry.id)
  assert.ok(Math.max(...drawn) < 10, `only the first ten are eligible, saw id ${Math.max(...drawn)}`)
  assert.equal(drawn.size, 10, 'and all ten of them are')
})

test('the page it was handed is left alone', () => {
  const media = [withBanner(1), withBanner(2), withBanner(3)]
  const before = media.map(m => m.id)
  bannerList(media)
  assert.deepEqual(media.map(m => m.id), before, 'the caller may still be using its own list')
})
