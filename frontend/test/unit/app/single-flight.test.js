// One resolve per play request, however many times the button is pressed. The log
// showed one episode resolved three times in a minute — each round a spinner-length
// wait, a set of TorBox link requests, and an AniList sweep over the whole pack.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { createSingleFlight } from '../../../common/modules/lib/single-flight.js'

test('the first attempt runs and repeats while it lasts do not', () => {
  const flight = createSingleFlight()
  assert.equal(flight.begin('magnet:a:4'), true)
  assert.equal(flight.begin('magnet:a:4'), false)
  assert.equal(flight.begin('magnet:a:4'), false)
})

test('a different request is not a repeat', () => {
  const flight = createSingleFlight()
  assert.equal(flight.begin('magnet:a:4'), true)
  assert.equal(flight.begin('magnet:a:5'), true)
  assert.equal(flight.begin('magnet:b:4'), true)
})

test('finishing makes the same request fresh again, success or failure alike', () => {
  const flight = createSingleFlight()
  flight.begin('magnet:a:4')
  flight.end('magnet:a:4')
  assert.equal(flight.begin('magnet:a:4'), true)
})

test('ending something never begun is harmless', () => {
  const flight = createSingleFlight()
  assert.doesNotThrow(() => flight.end('never-started'))
  assert.equal(flight.begin('never-started'), true)
})
