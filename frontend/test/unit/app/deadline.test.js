// A bound on work that may never finish. The failure this prevents is not a slow app: it
// is an app that waits forever on one source and therefore never does the things that come
// after — asking a debrid service what it holds, most of all.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { withDeadline, SOURCE_DEADLINE } from '@/modules/lib/deadline.js'

/** Timers the test fires by hand. */
function fakeClock () {
  const pending = new Map()
  let next = 1
  return {
    pending,
    schedule: (callback) => { pending.set(next, callback); return next++ },
    cancel: (timer) => pending.delete(timer),
    run: () => { for (const callback of [...pending.values()]) callback(); pending.clear() }
  }
}

test('work that answers in time answers normally', async () => {
  const clock = fakeClock()
  const value = await withDeadline(Promise.resolve({ results: [1, 2] }), { late: () => null, schedule: clock.schedule, cancel: clock.cancel })
  assert.deepEqual(value, { results: [1, 2] })
  assert.equal(clock.pending.size, 0, 'and leaves no timer behind')
})

test('work that never answers gives up its place', async () => {
  const clock = fakeClock()
  const pending = withDeadline(new Promise(() => {}), {
    late: () => ({ results: [], errors: [{ message: 'Source nyaa did not answer within 45s' }] }),
    schedule: clock.schedule,
    cancel: clock.cancel
  })
  clock.run()
  const value = await pending
  assert.equal(value.results.length, 0)
  assert.match(value.errors[0].message, /did not answer/, 'and says so, rather than looking like a source with nothing to offer')
})

test('a late answer is dropped rather than arriving after the app moved on', async () => {
  const clock = fakeClock()
  let finish
  const pending = withDeadline(new Promise(resolve => { finish = resolve }), {
    late: () => 'gave up',
    schedule: clock.schedule,
    cancel: clock.cancel
  })
  clock.run()
  finish('too late')
  assert.equal(await pending, 'gave up')
})

test('a rejection still rejects, and is not turned into a timeout', async () => {
  const clock = fakeClock()
  const failing = withDeadline(Promise.reject(new Error('source is unreachable')), {
    late: () => 'gave up',
    schedule: clock.schedule,
    cancel: clock.cancel
  })
  await assert.rejects(() => failing, /unreachable/)
  assert.equal(clock.pending.size, 0)
})

test('the bound is generous, because bad connections are a feature requirement', () => {
  assert.ok(SOURCE_DEADLINE >= 30_000, 'a source that answers slowly on a bad link is still worth having')
  assert.ok(SOURCE_DEADLINE <= 90_000, 'but nothing may be waited on forever')
})
