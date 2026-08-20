// When a list built row by row is worth showing. The episode list is assembled in
// order (each air date is validated against the one before), so the only lever is
// when to stop waiting — and waiting for rows nobody can see is the bug this fixes.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { firstPaintAt } from '../../../common/modules/lib/progressive.js'

test('a long list paints as soon as the screen is full', () => {
  assert.equal(firstPaintAt(1100, 15), 15, 'One Piece must not wait on episode 1100 to show episode 1')
  assert.equal(firstPaintAt(16, 15), 15)
})

test('a list shorter than the screen paints only when it is complete', () => {
  assert.equal(firstPaintAt(12, 15), 12, 'painting at 15 would never happen and the list would never appear')
  assert.equal(firstPaintAt(1, 15), 1)
})

test('an empty list never paints, so the skeletons are not replaced by nothing', () => {
  assert.equal(firstPaintAt(0, 15), 0)
  assert.equal(firstPaintAt(-3, 15), 0)
  assert.equal(firstPaintAt(NaN, 15), 0)
})

test('a nonsense visible count falls back to painting the whole list at once', () => {
  assert.equal(firstPaintAt(40, 0), 40)
  assert.equal(firstPaintAt(40, -1), 40)
  assert.equal(firstPaintAt(40, NaN), 40)
  assert.equal(firstPaintAt(40, 7.6), 7, 'a fractional row count is rounded down to whole rows')
})
