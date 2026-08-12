// The four state vocabulary the whole debrid layer speaks. Small module, but everything else
// leans on these invariants: unknown is an absence of an answer rather than a negative one,
// and anything unrecognised degrades to unknown rather than to "not cached".
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  Availability,
  AVAILABILITY_ORDER,
  AVAILABILITY_TTL,
  availabilityOf,
  describeAvailability,
  isAvailability,
  normalizeAvailability,
  streamsInstantly
} from '../../../common/modules/debrid/availability.js'

const STATES = Object.values(Availability)

test('the four states are distinct, frozen and completely ordered', () => {
  assert.equal(STATES.length, 4)
  assert.equal(new Set(STATES).size, 4, 'no two states may share a value')
  assert.ok(Object.isFrozen(Availability), 'the vocabulary must not be editable at runtime')
  assert.deepEqual([...AVAILABILITY_ORDER].sort(), [...STATES].sort(), 'every state must have a place in the display order')
  assert.equal(AVAILABILITY_ORDER[0], Availability.CACHED, 'the best case leads')
})

test('only a cached release streams now', () => {
  for (const state of STATES) assert.equal(streamsInstantly(state), state === Availability.CACHED, state)
})

test('anything unrecognised reads as unknown rather than as a negative answer', () => {
  for (const junk of [undefined, null, '', 'CACHED', 'maybe', 0, false, {}]) {
    assert.equal(isAvailability(junk), false, String(junk))
    assert.equal(normalizeAvailability(junk), Availability.UNKNOWN, String(junk))
  }
  for (const state of STATES) {
    assert.equal(isAvailability(state), true, state)
    assert.equal(normalizeAvailability(state), state, state)
  }
})

test('a hit is trusted for far longer than a miss, and unknown is never trusted', () => {
  assert.ok(AVAILABILITY_TTL[Availability.CACHED] > AVAILABILITY_TTL[Availability.AVAILABLE], 'anyone can cache a release at any moment, so a miss goes stale fast')
  assert.ok(AVAILABILITY_TTL[Availability.UNAVAILABLE] > 0, 'a dead release is worth remembering for a while')
  assert.equal(AVAILABILITY_TTL[Availability.UNKNOWN], 0, 'unknown is not an answer to remember')
})

test('reading a hash out of an availability map copes with what callers actually hold', () => {
  const hash = 'a'.repeat(40)
  const known = new Map([[hash, Availability.CACHED]])
  assert.equal(availabilityOf(known, hash), Availability.CACHED)
  assert.equal(availabilityOf(known, hash.toUpperCase()), Availability.CACHED, 'results carry mixed case hashes')
  assert.equal(availabilityOf(known, 'b'.repeat(40)), Availability.UNKNOWN, 'absent means unknown, never uncached')
  for (const missing of [undefined, null, '']) assert.equal(availabilityOf(known, missing), Availability.UNKNOWN, 'a result with no hash is simply unknown')
  // the store starts empty and the components read it before any service exists
  for (const empty of [undefined, null, new Map()]) assert.equal(availabilityOf(empty, hash), Availability.UNKNOWN)
})

test('every state has wording that names the service and never says "undefined"', () => {
  for (const state of [...STATES, 'nonsense']) {
    const { label, description } = describeAvailability(state, 'TestBrid')
    assert.ok(label && description, state)
    assert.match(description, /TestBrid/, `${state} must name the service`)
    assert.doesNotMatch(`${label} ${description}`, /undefined|null/, state)
  }
  // the UI passes the title straight from a store that is null before a service is picked
  assert.doesNotMatch(describeAvailability(Availability.CACHED, undefined).description, /undefined/)
})
