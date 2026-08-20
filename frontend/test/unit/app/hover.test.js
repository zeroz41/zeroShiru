// When a card preview opens. The rule exists because opening one is expensive — a second
// card, a banner fetch and a trailer in an iframe — so a pointer crossing a grid must not
// open one per card it passes over.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { createHoverIntent, PREVIEW_DWELL, TRAILER_DWELL } from '@/modules/lib/hover.js'

/** Timers that only run when the test says so. */
function fakeClock () {
  const pending = new Map()
  let next = 1
  return {
    pending,
    schedule: (callback, delay) => { pending.set(next, { callback, delay }); return next++ },
    cancel: (timer) => pending.delete(timer),
    run: () => { for (const { callback } of [...pending.values()]) callback(); pending.clear() }
  }
}

/** A card whose preview state is recorded rather than rendered. */
function card (clock, delay) {
  const states = []
  const intent = createHoverIntent({ apply: value => states.push(value), delay, schedule: clock.schedule, cancel: clock.cancel })
  return { states, intent }
}

test('a pointer passing over a card opens nothing', () => {
  const clock = fakeClock()
  const { states, intent } = card(clock)

  intent.set(true)
  assert.deepEqual(states, [], 'arriving is not the same as stopping')
  assert.equal(intent.waiting, true)

  intent.set(false) // moved on to the next card
  assert.deepEqual(states, [false], 'and the pending open is dropped, not merely closed after')
  assert.equal(clock.pending.size, 0)

  clock.run()
  assert.deepEqual(states, [false], 'nothing opens later either')
})

test('a pointer that rests opens the preview', () => {
  const clock = fakeClock()
  const { states, intent } = card(clock)

  intent.set(true)
  clock.run()
  assert.deepEqual(states, [true])
  assert.equal(intent.waiting, false)
})

test('a tap opens at once, since it is a decision rather than a pointer passing', () => {
  const clock = fakeClock()
  const { states, intent } = card(clock)

  intent.set(true, true)
  assert.deepEqual(states, [true], 'nobody taps a card and waits')
  assert.equal(clock.pending.size, 0)
})

test('closing is never delayed', () => {
  const clock = fakeClock()
  const { states, intent } = card(clock)
  intent.set(true, true)
  intent.set(false)
  assert.deepEqual(states, [true, false], 'a preview lingering after the pointer has gone reads as stuck')
})

test('crossing back and forth leaves at most one open pending', () => {
  const clock = fakeClock()
  const { states, intent } = card(clock)
  for (let index = 0; index < 5; index++) {
    intent.set(true)
    intent.set(false)
  }
  intent.set(true)
  assert.equal(clock.pending.size, 1)
  clock.run()
  assert.deepEqual(states.filter(Boolean), [true], 'one open, however many times the pointer swept over it')
})

test('a card being destroyed drops its pending open', () => {
  const clock = fakeClock()
  const { states, intent } = card(clock)
  intent.set(true)
  intent.cancel()
  clock.run()
  assert.deepEqual(states, [], 'a card scrolled away must not open a preview afterwards')
})

test('the delays are short enough to feel immediate and long enough to be worth having', () => {
  assert.ok(PREVIEW_DWELL >= 100 && PREVIEW_DWELL <= 400, 'a rest, not a wait')
  assert.ok(TRAILER_DWELL > PREVIEW_DWELL, 'the expensive half comes after the cheap half')
})
