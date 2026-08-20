// The four state vocabulary the whole debrid layer speaks. Small module, but everything else
// leans on these invariants: unknown is an absence of an answer rather than a negative one,
// and anything unrecognised degrades to unknown rather than to "not cached".
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import {
  Availability,
  AVAILABILITY_ORDER,
  AVAILABILITY_TTL,
  availabilityOf,
  describeAvailability,
  isAvailability,
  normalizeAvailability,
  outageNotice,
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

// Why badges go missing. TorBox's /torrents/checkcached began accepting authenticated requests
// and never answering them (its account listing kept working, so nothing else looked wrong).
// Every check timed out, the failure went to a debug log, and the results list showed no cached
// badges at all — indistinguishable from a library where nothing is cached.
test('a service that stops answering is worth saying out loud', () => {
  const notice = outageNotice({ kind: 'timeout', message: 'request timed out after 30000ms' }, 'TorBox')
  assert.ok(notice, 'silence is the one failure the user cannot see for themselves')
  assert.match(notice.title, /TorBox/)
  assert.match(notice.title, /not answering/i)
})

test('a rejected key says so, since that one is the user\'s to fix', () => {
  const notice = outageNotice({ kind: 'auth', message: 'Invalid API key' }, 'TorBox')
  assert.match(notice.title, /rejected the key/i)
  assert.match(notice.description, /Invalid API key/)
  assert.match(notice.description, /settings/i, 'tell them where to fix it')
})

test('an unreachable service is distinguished from an unanswering one', () => {
  assert.match(outageNotice({ kind: 'network' }, 'TorBox').title, /could not be reached/i)
  assert.match(outageNotice({ kind: 'service', message: 'DATABASE_ERROR' }, 'TorBox').description, /DATABASE_ERROR/)
})

test('answers about a release are not outages', () => {
  // these say something true about the release, and the badges already show it
  for (const kind of ['not-cached', 'unavailable', 'rejected']) {
    assert.equal(outageNotice({ kind }, 'TorBox'), null, kind)
  }
})

test('a failure nobody wrote a case for still says something', () => {
  // the shape that hurt: a call that failed before it reached the service at all — a bad
  // argument, a host command that errored — carries no kind, and used to be silent, which
  // is indistinguishable from a library where nothing is cached
  assert.match(outageNotice(new TypeError('invalid args for command'), 'TorBox').title, /could not be checked/i)
  assert.match(outageNotice(new TypeError('invalid args for command'), 'TorBox').description, /invalid args/)
  assert.match(outageNotice({}, 'TorBox').title, /TorBox/)
  assert.ok(outageNotice(undefined), 'even a failure with nothing in it is worth one line')
})

test('the service is named, so the user knows who went quiet', () => {
  assert.match(outageNotice({ kind: 'timeout' }, 'Real-Debrid').title, /Real-Debrid/)
  assert.match(outageNotice({ kind: 'timeout' }).title, /your debrid service/)
})
