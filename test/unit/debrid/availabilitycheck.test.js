// The generic availability contract in DebridService. Every service is asked the same way,
// whichever way it can answer: one batch call where the API has a cache endpoint, a capped
// number of probes where it does not, and nothing at all where neither is possible.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import DebridService, { DebridAuthError, DebridError, DebridNotCachedError, DebridUnavailableError, DebridNotImplementedError } from '../../../common/modules/debrid/service.js'
import { Availability } from '../../../common/modules/debrid/availability.js'

const hash = n => String(n).padStart(40, '0')
const { CACHED, AVAILABLE, UNAVAILABLE, UNKNOWN } = Availability

/** A service with no cache endpoint, counting how often it is actually asked. */
class Prober extends DebridService {
  static id = 'prober'
  static title = 'Prober'
  static availabilityCheck = 'probe'
  static maxProbes = 3
  probed = []
  states = new Map()
  fail = null
  async probeAvailability (h) {
    this.probed.push(h)
    if (this.fail) throw this.fail(h)
    return this.states.get(h) ?? AVAILABLE
  }
}

/** Same, with a wider window, for the tests about how a sweep gives up. */
class WideProber extends Prober {
  static maxProbes = 10
}
const tenHashes = Array.from({ length: 10 }, (_, index) => hash(index))

/** A service with a real cache endpoint: one call, however many hashes. */
class Batcher extends DebridService {
  static id = 'batcher'
  static title = 'Batcher'
  static availabilityCheck = 'batch'
  calls = []
  cachedHashes = new Set()
  async checkAvailabilityBatch (hashes) {
    this.calls.push(hashes)
    return new Map(hashes.filter(h => this.cachedHashes.has(h)).map(h => [h, CACHED]))
  }
}

/** A service whose API cannot be asked at all. */
class Silent extends DebridService {
  static id = 'silent'
  static title = 'Silent'
  static availabilityCheck = 'none'
  calls = 0
  async checkAvailabilityBatch (hashes) {
    this.calls++
    return new Map()
  }
}

test('a service with a cache endpoint answers everything in one request', async () => {
  const service = new Batcher('key')
  service.cachedHashes.add(hash(2))
  const answers = await service.checkAvailability([hash(1), hash(2), hash(3)])
  assert.equal(service.calls.length, 1, 'a batch service must not be asked per hash')
  assert.equal(answers.get(hash(2)), CACHED)
  assert.equal(answers.size, 3, 'every hash got a real answer')
})

// a cache endpoint answering "no" means the service would have to fetch the release, which is
// a different thing from it not being able to serve it at all
test('a hash a cache endpoint does not mention is available, not unavailable', async () => {
  const service = new Batcher('key')
  const answers = await service.checkAvailability([hash(1)])
  assert.equal(answers.get(hash(1)), AVAILABLE)
})

test('a long results list is split into batches the API will accept', async () => {
  class Small extends Batcher { static maxBatch = 10 }
  const service = new Small('key')
  const wanted = Array.from({ length: 25 }, (_, index) => hash(index))
  service.cachedHashes.add(hash(24))
  const answers = await service.checkAvailability(wanted)
  assert.deepEqual(service.calls.map(call => call.length), [10, 10, 5], 'chunked to maxBatch')
  assert.equal(answers.size, 25, 'the whole list still gets answered')
  assert.equal(answers.get(hash(24)), CACHED, 'a hit in the last chunk is not lost')
})

// the probe cap exists because Real-Debrid has no cache endpoint. It must not follow a service
// that does: a batch service answers the whole list, however long, in as few requests as it takes
test('the probe cap never leaks onto a service that can answer in bulk', async () => {
  const service = new Batcher('key')
  const wanted = Array.from({ length: 200 }, (_, index) => hash(index))
  service.cachedHashes.add(hash(150)) // well past any probing service's window
  const answers = await service.checkAvailability(wanted)
  assert.equal(answers.size, 200, 'every result gets a badge, not just the top of the list')
  assert.equal(answers.get(hash(150)), CACHED, 'including ones a prober would never have reached')
  assert.deepEqual(service.unknownHashes(wanted), [], 'and nothing is left to ask about')
  assert.deepEqual(service.calls.map(call => call.length), [100, 100], 'in maxBatch sized requests')
  // the probing machinery must not have been involved at all
  assert.equal(service.sweeping, false)
  assert.equal(service.probes.size, 0)
})

test('a service with no cache endpoint is never asked, and reports nothing rather than "uncached"', async () => {
  const service = new Silent('key')
  const answers = await service.checkAvailability([hash(1), hash(2)])
  assert.equal(service.calls, 0, 'no endpoint means no request')
  assert.equal(answers.size, 0, 'unanswered hashes must read as unknown, never as not cached')
})

test('answers are remembered, so asking again costs nothing', async () => {
  const service = new Batcher('key')
  service.cachedHashes.add(hash(1))
  await service.checkAvailability([hash(1), hash(2)])
  assert.equal(service.calls.length, 1)
  const answers = await service.checkAvailability([hash(1), hash(2)])
  assert.equal(service.calls.length, 1, 'no repeat request')
  assert.equal(answers.get(hash(1)), CACHED)
  assert.equal(answers.get(hash(2)), AVAILABLE)
})

test('a miss expires sooner than a hit, since anything can become cached later', async () => {
  const service = new Batcher('key')
  service.remember(hash(1), CACHED)
  service.remember(hash(2), AVAILABLE)
  // age both answers past the available TTL but not the cached one
  const aged = Date.now() - (DebridService.availabilityTTL[AVAILABLE] + 1_000)
  for (const entry of service.availabilityState.values()) entry.at = aged
  assert.deepEqual(service.unknownHashes([hash(1), hash(2)]), [hash(2)], 'only the stale miss is worth re-asking')
})

test('unknown is not an answer, so remembering it forgets instead', async () => {
  const service = new Batcher('key')
  service.remember(hash(1), CACHED)
  service.remember(hash(1), UNKNOWN)
  assert.deepEqual(service.unknownHashes([hash(1)]), [hash(1)], 'the release is back to needing an answer')
  assert.equal(service.availabilityState.size, 0, 'and nothing is left behind to badge it with')
})

test('playback teaches the cache too, in every direction', async () => {
  const service = new Batcher('key')
  service.remember(`magnet:?xt=urn:btih:${hash(1).toUpperCase()}`, CACHED)
  service.remember(hash(2), AVAILABLE)
  service.remember(hash(3), UNAVAILABLE)
  const answers = await service.checkAvailability([hash(1), hash(2), hash(3)])
  assert.equal(service.calls.length, 0, 'what playback proved needs no request')
  assert.deepEqual([...answers], [[hash(1), CACHED], [hash(2), AVAILABLE], [hash(3), UNAVAILABLE]])
})

test('magnets, uppercase and junk are all accepted as input', async () => {
  const service = new Batcher('key')
  service.cachedHashes.add(hash(1))
  const answers = await service.checkAvailability([
    `magnet:?xt=urn:btih:${hash(1).toUpperCase()}&dn=whatever`,
    hash(2).toUpperCase(),
    'not-a-hash',
    null,
    hash(2) // duplicate of the one above once normalized
  ])
  assert.deepEqual(service.calls[0], [hash(1), hash(2)], 'deduplicated, lowercased, junk dropped')
  assert.equal(answers.get(hash(1)), CACHED)
  assert.equal(answers.size, 2)
})

test('a batch service that has not implemented its endpoint says so', async () => {
  class Unfinished extends DebridService {
    static id = 'unfinished'
    static title = 'Unfinished'
    static availabilityCheck = 'batch'
  }
  await assert.rejects(() => new Unfinished('key').checkAvailability([hash(1)]), DebridNotImplementedError)
})

test('a failed batch call leaves the hashes re-checkable instead of remembering a guess', async () => {
  class Broken extends Batcher {
    async checkAvailabilityBatch () { throw new Error('service is having a moment') }
  }
  const service = new Broken('key')
  await assert.rejects(() => service.checkAvailability([hash(1), hash(2)]))
  assert.deepEqual(service.unknownHashes([hash(1), hash(2)]), [hash(1), hash(2)], 'nothing was remembered')
})

test('unknownHashes reports only what still needs asking about', async () => {
  const service = new Batcher('key')
  service.remember(hash(1), CACHED)
  service.remember(hash(2), AVAILABLE)
  assert.deepEqual(service.unknownHashes([hash(1), hash(2), hash(3)]), [hash(3)])
})

// --- probing services (Real-Debrid and anything else without a cache endpoint) ---

test('probing is capped, and the hashes given first are the ones checked', async () => {
  const service = new Prober('key')
  const wanted = [hash(1), hash(2), hash(3), hash(4), hash(5)]
  const answers = await service.checkAvailability(wanted)
  assert.deepEqual(service.probed, wanted.slice(0, 3), 'the top of the list, in priority order')
  assert.equal(answers.size, 3)
  // the uncapped remainder must read as unknown, never as "not cached"
  assert.ok(!answers.has(hash(4)))
})

test('a capped sweep does not creep down the list on every re-ask', async () => {
  const service = new Prober('key')
  const wanted = [hash(1), hash(2), hash(3), hash(4), hash(5)]
  await service.checkAvailability(wanted)
  await service.checkAvailability(wanted)
  await service.checkAvailability(wanted)
  // the whole point of the cap: one results list costs at most maxProbes, forever
  assert.deepEqual(service.probed, wanted.slice(0, 3), 'nothing past the cap is ever probed')
  assert.deepEqual(service.unknownHashes(wanted), [], 'and the window has no unknowns left to re-ask')
})

test('probe answers are reported as they land, not banked until the sweep ends', async () => {
  const service = new Prober('key')
  service.states.set(hash(1), CACHED).set(hash(3), UNAVAILABLE)
  const seen = []
  await service.checkAvailability([hash(1), hash(2), hash(3)], { onAnswer: (h, state) => seen.push([h, state]) })
  assert.deepEqual(seen, [[hash(1), CACHED], [hash(2), AVAILABLE], [hash(3), UNAVAILABLE]])
})

test('the same hash asked about twice at once is only probed once', async () => {
  const service = new Prober('key')
  let release
  service.fail = null
  service.probeAvailability = h => { service.probed.push(h); return new Promise(resolve => { release = () => resolve(CACHED) }) }
  const first = service.checkAvailability([hash(1)])
  const second = service.checkAvailability([hash(1)])
  release()
  await Promise.all([first, second])
  assert.deepEqual(service.probed, [hash(1)], 'a second caller must join the probe already running')
})

test('a transient failure is not an answer, and must not be remembered as uncached', async () => {
  const service = new Prober('key')
  service.fail = () => new DebridError('service had a moment')
  const answers = await service.checkAvailability([hash(1)])
  assert.equal(answers.size, 0, 'no answer means unknown')
  assert.deepEqual(service.unknownHashes([hash(1)]), [hash(1)], 'and it stays re-checkable')
})

// the two errors that carry a verdict, so a service only has to throw the right one
test('the definite negatives ARE answers, and each is remembered as what it proves', async () => {
  for (const [makeError, expected] of [[() => new DebridNotCachedError(), AVAILABLE], [() => new DebridUnavailableError(), UNAVAILABLE]]) {
    const service = new Prober('key')
    service.fail = makeError
    const answers = await service.checkAvailability([hash(1)])
    assert.equal(answers.get(hash(1)), expected)
    assert.deepEqual(service.unknownHashes([hash(1)]), [], 'no need to ask again')
  }
})

// "answered hashes only" has to mean it: an unknown in the result map would badge a release
// with nothing, and would reset the failure counter that stops a broken sweep
test('a probe returning something unrecognised counts as no answer at all', async () => {
  const service = new WideProber('key')
  service.probeAvailability = async h => { service.probed.push(h); return 'probably?' }
  const answers = await service.checkAvailability(tenHashes)
  assert.equal(answers.size, 0, 'nothing unrecognised may reach the caller')
  assert.ok(![...answers.values()].includes(UNKNOWN), 'unknown is never an entry in the map')
  assert.deepEqual(service.unknownHashes(tenHashes), tenHashes, 'a nonsense answer must not stick')
  assert.ok(service.probed.length < tenHashes.length, 'and a service answering junk gives up like any other failure')
})

// a sweep stops on a run of failures, but the probes already in flight when it decides to stop
// still finish, so the counts below are bounds rather than exact numbers
const started = WideProber.maxProbeConcurrency

test('a run of failures stops the sweep instead of burning the whole window on it', async () => {
  const service = new WideProber('key')
  service.fail = () => new DebridError('nope')
  await service.checkAvailability(tenHashes)
  assert.ok(service.probed.length <= 3 + started - 1, `gives up after a run of unanswered probes, tried ${service.probed.length}`)
  assert.ok(service.probed.length < tenHashes.length, 'and never works through the whole list')
})

test('being told to slow down stops the sweep at once', async () => {
  const service = new WideProber('key')
  service.fail = () => new DebridError('too many requests', { status: 429 })
  await service.checkAvailability(tenHashes)
  assert.ok(service.probed.length <= started, 'a 429 is unambiguous, so nothing starts after one lands')
})

test('a bad key aborts the sweep rather than burning every probe on it', async () => {
  const service = new WideProber('key')
  service.fail = () => new DebridAuthError('bad key')
  await assert.rejects(() => service.checkAvailability(tenHashes), DebridAuthError)
  assert.ok(service.probed.length <= started, 'every other probe would fail the same way')
})

test('probes run a few at a time, which is what a slow link needs, but never more', async () => {
  const service = new WideProber('key')
  let inFlight = 0
  let peak = 0
  service.probeAvailability = async h => {
    service.probed.push(h)
    peak = Math.max(peak, ++inFlight)
    await new Promise(resolve => setTimeout(resolve, 5))
    inFlight--
    return AVAILABLE
  }
  await service.checkAvailability(tenHashes)
  assert.equal(peak, started, 'a probe is mostly spent waiting, so a few overlap')
  assert.equal(service.probed.length, tenHashes.length, 'and every hash still gets asked about exactly once')
})

test('only one sweep runs at a time, so answers landing cannot start a second', async () => {
  const service = new Prober('key')
  service.probeAvailability = async h => {
    service.probed.push(h)
    await new Promise(resolve => setTimeout(resolve, 5))
    return AVAILABLE
  }
  await Promise.all([
    service.checkAvailability([hash(1), hash(2), hash(3)]),
    service.checkAvailability([hash(1), hash(2), hash(3)])
  ])
  assert.equal(service.probed.length, 3, 'a second sweep over the same list must not double the cost')
})

test('a probing service that has not implemented probeAvailability says so', async () => {
  class Unfinished extends DebridService {
    static id = 'unfinished'
    static title = 'Unfinished'
    static availabilityCheck = 'probe'
  }
  const service = new Unfinished('key')
  const answers = await service.checkAvailability([hash(1)])
  // it reports nothing rather than crashing the caller, and the debug log names the service
  assert.equal(answers.size, 0)
})
